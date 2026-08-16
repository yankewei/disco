//! Codex app-server provider adapter.
//!
//! 管理 `codex app-server` 子进程及 JSON-RPC stdio 连接。Codex 原始运行语义仅暴露给
//! CodexAdapter；ModelProvider 实现是迁移期的 compaction bridge。

use std::collections::HashMap;
use std::pin::Pin;
use std::sync::{Arc, Mutex as StdMutex};

use anyhow::{Context, Result};
use async_trait::async_trait;
use futures_core::Stream;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio::time::{Duration, sleep, timeout};
use tokio_stream::StreamExt;
use tracing::{debug, info, warn};

use disco_protocol::types::TokenUsage;
use disco_tools::ToolDefinition;

use crate::ModelProvider;
use crate::openai_responses::{ChatMessage, ProviderEvent};

// MARK: - JSON-RPC types

/// A JSON-RPC envelope for messages from the codex app-server.
#[derive(Debug, Deserialize)]
pub struct RpcEnvelope {
    pub id: Option<CodexRequestId>,
    pub method: Option<String>,
    pub params: Option<serde_json::Value>,
    pub result: Option<serde_json::Value>,
    pub error: Option<RpcErrorPayload>,
}

/// Codex app-server 允许 server request 使用数字或字符串 ID。
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(untagged)]
pub enum CodexRequestId {
    Number(i64),
    String(String),
}

#[derive(Debug, Deserialize)]
pub struct RpcErrorPayload {
    pub code: i32,
    pub message: String,
}

/// A JSON-RPC request we send to the codex app-server.
#[derive(Debug, Serialize)]
struct RpcRequest {
    id: i64,
    method: String,
    params: serde_json::Value,
}

/// A JSON-RPC notification (no id).
#[derive(Debug, Serialize)]
struct RpcNotification {
    method: String,
    params: serde_json::Value,
}

/// A JSON-RPC error response (for server requests we don't support).
#[derive(Debug, Serialize)]
struct RpcErrorResponse {
    id: CodexRequestId,
    error: RpcErrorPayloadOut,
}

#[derive(Debug, Serialize)]
struct RpcErrorPayloadOut {
    code: i32,
    message: String,
}

// MARK: - Codex turn events (internal)

#[derive(Debug, Clone)]
pub enum CodexProviderEvent {
    TextDelta(String),
    ReasoningDelta(String),
    Usage(TokenUsage),
    ToolStarted(CodexToolCall),
    ToolCompleted(CodexToolResult),
    ApprovalRequested(CodexApprovalRequest),
    Completed,
    Cancelled,
    Failed(String),
}

#[derive(Debug, Clone)]
pub struct CodexToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

#[derive(Debug, Clone)]
pub struct CodexToolResult {
    pub id: String,
    pub name: String,
    pub output: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexApprovalKind {
    CommandExecution,
    FileChange,
}

#[derive(Debug, Clone)]
pub struct CodexApprovalRequest {
    pub request_id: CodexRequestId,
    pub kind: CodexApprovalKind,
    pub item_id: String,
    pub title: String,
    pub reason: Option<String>,
    pub command: Option<String>,
    pub cwd: Option<String>,
    pub grant_root: Option<String>,
    pub allows_session_approval: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexApprovalDecision {
    Accept,
    AcceptForSession,
    Decline,
    Cancel,
}

impl CodexApprovalDecision {
    fn wire_value(self) -> &'static str {
        match self {
            Self::Accept => "accept",
            Self::AcceptForSession => "acceptForSession",
            Self::Decline => "decline",
            Self::Cancel => "cancel",
        }
    }
}

// MARK: - Pending request tracking

struct PendingRequest {
    sender: oneshot::Sender<Result<serde_json::Value>>,
}

// MARK: - Active turn tracking

struct ActiveTurn {
    sender: mpsc::Sender<CodexProviderEvent>,
    turn_id: Option<String>,
}

/// 事件流被取消时同步终止尚未完成的 turn/start 任务，避免留下 detached turn。
struct AbortTaskOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortTaskOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

// MARK: - Write request for the writer task

enum WriteRequest {
    Line(String, oneshot::Sender<Result<()>>),
    Shutdown,
}

// MARK: - Internal state

struct CodexState {
    /// Whether we've completed the initialize handshake.
    is_initialized: bool,
    /// The thread ID for this session.
    thread_id: Option<String>,
    /// 当前 app-server 进程是否已 start/resume 该 thread。
    is_thread_attached: bool,
    /// Next request ID for JSON-RPC.
    next_request_id: i64,
    /// Pending RPC requests waiting for responses.
    pending: HashMap<i64, PendingRequest>,
    /// Active turn event sender.
    active_turn: Option<ActiveTurn>,
    /// Sender for write requests to the writer task.
    write_tx: Option<mpsc::Sender<WriteRequest>>,
}

impl CodexState {
    fn new() -> Self {
        Self {
            is_initialized: false,
            thread_id: None,
            is_thread_attached: false,
            next_request_id: 0,
            pending: HashMap::new(),
            active_turn: None,
            write_tx: None,
        }
    }

    fn next_id(&mut self) -> i64 {
        let id = self.next_request_id;
        self.next_request_id += 1;
        id
    }
}

// MARK: - CodexProvider

/// Codex app-server provider.
///
/// Manages a `codex app-server` subprocess and communicates via JSON-RPC
/// over stdio. Implements the same streaming interface as other providers.
pub struct CodexProvider {
    /// Path to the codex executable.
    executable: String,
    /// Model to use.
    model: String,
    /// Optional reasoning effort.
    reasoning_effort: Option<String>,
    /// Thread 的项目工作目录。
    cwd: Option<String>,
    /// Optional thread ID to resume.
    resume_thread_id: Option<String>,

    /// Internal state protected by mutex.
    state: Arc<Mutex<CodexState>>,
    /// Drop 时同步通知 writer，使其释放并终止子进程。
    shutdown_tx: Arc<StdMutex<Option<mpsc::Sender<WriteRequest>>>>,
}

impl CodexProvider {
    /// Create a new CodexProvider.
    pub fn new(
        executable: String,
        model: String,
        reasoning_effort: Option<String>,
        resume_thread_id: Option<String>,
        cwd: Option<String>,
    ) -> Self {
        Self {
            executable,
            model,
            reasoning_effort,
            cwd,
            resume_thread_id,
            state: Arc::new(Mutex::new(CodexState::new())),
            shutdown_tx: Arc::new(StdMutex::new(None)),
        }
    }

    /// Find the codex executable in PATH or well-known locations.
    pub fn find_codex() -> String {
        let candidates = ["codex", "/usr/local/bin/codex", "/opt/homebrew/bin/codex"];

        // Check PATH
        if let Ok(path) = std::env::var("PATH") {
            for dir in path.split(':') {
                let candidate = format!("{dir}/codex");
                if std::path::Path::new(&candidate).exists() {
                    return candidate;
                }
            }
        }

        // Check home directory locations
        if let Ok(home) = std::env::var("HOME") {
            let home_candidates = [
                format!("{home}/.local/bin/codex"),
                format!("{home}/.codex/bin/codex"),
            ];
            for c in &home_candidates {
                if std::path::Path::new(c).exists() {
                    return c.clone();
                }
            }
        }

        // Fall back to first candidate (will fail at launch if not found)
        candidates[0].to_string()
    }

    /// 流式执行一个 turn，并保留 Codex 的审批与 item 生命周期语义。
    /// 多轮历史由 app-server thread 管理，只发送最后一条用户消息。
    pub async fn stream_turn(
        &self,
        messages: &[ChatMessage],
    ) -> Result<impl Stream<Item = Result<CodexProviderEvent>>> {
        let (event_tx, mut event_rx) = mpsc::channel::<CodexProviderEvent>(64);
        let user_input = messages
            .iter()
            .rev()
            .find(|m| m.role == "user")
            .map(|m| m.text.clone())
            .unwrap_or_default();
        self.ensure_session().await?;
        let thread_id = self
            .state
            .lock()
            .await
            .thread_id
            .clone()
            .context("Codex thread 尚未初始化")?;
        self.state.lock().await.active_turn = Some(ActiveTurn {
            sender: event_tx,
            turn_id: None,
        });
        let state = self.state.clone();
        let reasoning_effort = self.reasoning_effort.clone();
        let startup = AbortTaskOnDrop(tokio::spawn(async move {
            let response = Self::send_request(
                &state,
                "turn/start",
                serde_json::json!({
                    "threadId": thread_id,
                    "input": [{"type": "text", "text": user_input}],
                    "effort": reasoning_effort,
                }),
            )
            .await;
            match response {
                Ok(response) => {
                    if let Some(turn_id) = response["turn"]["id"].as_str() {
                        let mut state = state.lock().await;
                        if let Some(active_turn) = &mut state.active_turn
                            && active_turn.turn_id.is_none()
                        {
                            active_turn.turn_id = Some(turn_id.to_string());
                        }
                    }
                    debug!("turn/start response received");
                }
                Err(error) => {
                    let active_turn = state.lock().await.active_turn.take();
                    if let Some(active_turn) = active_turn {
                        let _ = active_turn
                            .sender
                            .send(CodexProviderEvent::Failed(format!(
                                "turn/start failed: {error}"
                            )))
                            .await;
                    }
                }
            }
        }));

        let stream = async_stream::try_stream! {
            let _startup = startup;
            while let Some(event) = event_rx.recv().await {
                yield event;
            }
        };

        Ok(stream)
    }

    /// Ensure the transport is ready (subprocess launched, handshake done, thread started).
    async fn ensure_ready(
        state: &Arc<Mutex<CodexState>>,
        executable: &str,
        model: &str,
        resume_thread_id: Option<&str>,
        cwd: Option<&str>,
        shutdown_tx: &StdMutex<Option<mpsc::Sender<WriteRequest>>>,
    ) -> Result<()> {
        let s = state.lock().await;

        if s.is_initialized && s.is_thread_attached && s.thread_id.is_some() {
            return Ok(());
        }

        // Launch subprocess if needed
        if s.write_tx.is_none() {
            drop(s); // Release lock before spawning process
            info!("Launching codex app-server: {executable}");

            let mut command = Command::new(executable);
            command
                .arg("app-server")
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(true);
            let mut child = command
                .spawn()
                .context("Failed to launch codex app-server")?;

            let stdin = child.stdin.take().context("Failed to take stdin")?;
            let stdout = child.stdout.take().context("Failed to take stdout")?;

            // Create a writer task that owns the stdin
            let (write_tx, mut write_rx) = mpsc::channel::<WriteRequest>(32);
            *shutdown_tx
                .lock()
                .expect("Codex shutdown sender mutex poisoned") = Some(write_tx.clone());

            tokio::spawn(async move {
                let mut stdin = stdin;
                let mut _child = child; // Keep child alive for the duration
                while let Some(req) = write_rx.recv().await {
                    match req {
                        WriteRequest::Line(line, resp_tx) => {
                            let result = async {
                                stdin
                                    .write_all(line.as_bytes())
                                    .await
                                    .context("Failed to write to codex stdin")?;
                                stdin
                                    .write_all(b"\n")
                                    .await
                                    .context("Failed to write newline")?;
                                stdin.flush().await.context("Failed to flush stdin")?;
                                Ok(())
                            }
                            .await;
                            let _ = resp_tx.send(result);
                        }
                        WriteRequest::Shutdown => break,
                    }
                }
            });

            // Start the read loop
            let state_clone = state.clone();
            tokio::spawn(async move {
                Self::read_loop(state_clone, stdout).await;
            });

            // Store the write channel
            {
                let mut s = state.lock().await;
                s.write_tx = Some(write_tx);
            }

            // Perform initialize handshake
            let init_id;
            {
                let mut s = state.lock().await;
                init_id = s.next_id();
            }

            let init_request = serde_json::json!({
                "id": init_id,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "disco",
                        "title": "Disco",
                        "version": env!("CARGO_PKG_VERSION")
                    },
                    "capabilities": null
                }
            });

            let (resp_tx, resp_rx) = oneshot::channel();
            {
                let mut s = state.lock().await;
                s.pending
                    .insert(init_id, PendingRequest { sender: resp_tx });
            }

            Self::send_line(state, &init_request.to_string()).await?;

            match timeout(Duration::from_secs(30), resp_rx).await {
                Ok(Ok(Ok(_))) => {
                    debug!("initialize response received");
                }
                Ok(Ok(Err(e))) => {
                    return Err(anyhow::anyhow!("initialize failed: {e}"));
                }
                Ok(Err(_)) => {
                    return Err(anyhow::anyhow!("initialize response channel closed"));
                }
                Err(_) => {
                    return Err(anyhow::anyhow!("initialize timed out"));
                }
            }

            // Send initialized notification
            let notification = serde_json::json!({
                "method": "initialized",
                "params": {}
            });
            Self::send_line(state, &notification.to_string()).await?;

            {
                let mut s = state.lock().await;
                s.is_initialized = true;
            }
        }

        // Start or resume thread
        {
            let mut s = state.lock().await;
            if !s.is_thread_attached {
                let thread_to_resume = s
                    .thread_id
                    .clone()
                    .or_else(|| resume_thread_id.map(ToString::to_string));
                let thread_id = if let Some(resume_id) = thread_to_resume {
                    // Resume existing thread
                    let req_id = s.next_id();
                    let request = serde_json::json!({
                        "id": req_id,
                        "method": "thread/resume",
                        "params": {
                            "threadId": resume_id,
                            "model": model,
                            "cwd": cwd,
                            "approvalsReviewer": "user",
                        }
                    });

                    let (resp_tx, resp_rx) = oneshot::channel();
                    s.pending.insert(req_id, PendingRequest { sender: resp_tx });

                    // Need to release lock to send
                    let write_tx = s.write_tx.clone();
                    drop(s);

                    if let Some(tx) = &write_tx {
                        let (ok_tx, ok_rx) = oneshot::channel();
                        let _ = tx
                            .send(WriteRequest::Line(request.to_string(), ok_tx))
                            .await;
                        let _ = ok_rx.await;
                    }

                    match timeout(Duration::from_secs(30), resp_rx).await {
                        Ok(Ok(Ok(result))) => result["thread"]["id"]
                            .as_str()
                            .map(|s| s.to_string())
                            .context("Missing thread id in resume response")?,
                        Ok(Ok(Err(e))) => {
                            return Err(anyhow::anyhow!("thread/resume failed: {e}"));
                        }
                        Ok(Err(_)) => {
                            return Err(anyhow::anyhow!("thread/resume response channel closed"));
                        }
                        Err(_) => {
                            return Err(anyhow::anyhow!("thread/resume timed out"));
                        }
                    }
                } else {
                    // Start new thread
                    let req_id = s.next_id();
                    let request = serde_json::json!({
                        "id": req_id,
                        "method": "thread/start",
                        "params": {
                            "model": model,
                            "cwd": cwd,
                            "approvalsReviewer": "user",
                        }
                    });

                    let (resp_tx, resp_rx) = oneshot::channel();
                    s.pending.insert(req_id, PendingRequest { sender: resp_tx });

                    // Release the lock before sending
                    let write_tx = s.write_tx.clone();
                    drop(s);

                    if let Some(tx) = &write_tx {
                        let (ok_tx, ok_rx) = oneshot::channel();
                        let _ = tx
                            .send(WriteRequest::Line(request.to_string(), ok_tx))
                            .await;
                        let _ = ok_rx.await;
                    }

                    match timeout(Duration::from_secs(30), resp_rx).await {
                        Ok(Ok(Ok(result))) => result["thread"]["id"]
                            .as_str()
                            .map(|s| s.to_string())
                            .context("Missing thread id in start response")?,
                        Ok(Ok(Err(e))) => {
                            return Err(anyhow::anyhow!("thread/start failed: {e}"));
                        }
                        Ok(Err(_)) => {
                            return Err(anyhow::anyhow!("thread/start response channel closed"));
                        }
                        Err(_) => {
                            return Err(anyhow::anyhow!("thread/start timed out"));
                        }
                    }
                };

                let mut s = state.lock().await;
                s.thread_id = Some(thread_id.clone());
                s.is_thread_attached = true;
                info!("Codex thread ready: {thread_id}");
            }
        }

        Ok(())
    }

    /// Read lines from the codex app-server stdout and dispatch them.
    async fn read_loop(state: Arc<Mutex<CodexState>>, stdout: tokio::process::ChildStdout) {
        let reader = BufReader::new(stdout);
        let mut lines = reader.lines();

        while let Ok(Some(line)) = lines.next_line().await {
            let trimmed = line.trim().to_string();
            if trimmed.is_empty() {
                continue;
            }

            let envelope: RpcEnvelope = match serde_json::from_str(&trimmed) {
                Ok(e) => e,
                Err(e) => {
                    warn!("Failed to parse codex RPC line: {e}");
                    continue;
                }
            };
            debug!(
                "codex <<< {}",
                trimmed.chars().take(160).collect::<String>()
            );

            Self::handle_envelope(&state, envelope).await;
        }

        info!("Codex app-server stdout closed");

        // Clean up state
        let mut s = state.lock().await;
        s.is_initialized = false;
        s.is_thread_attached = false;
        s.write_tx = None;

        // Fail any pending requests
        for (_, pending) in s.pending.drain() {
            let _ = pending.sender.send(Err(anyhow::anyhow!("Process exited")));
        }

        // Fail active turn
        if let Some(active) = s.active_turn.take() {
            let _ = active
                .sender
                .send(CodexProviderEvent::Failed("Process exited".to_string()))
                .await;
        }
    }

    /// Handle a single RPC envelope from the codex app-server.
    async fn handle_envelope(state: &Arc<Mutex<CodexState>>, envelope: RpcEnvelope) {
        if let (Some(method), Some(id)) = (&envelope.method, envelope.id.clone())
            && envelope.result.is_none()
            && envelope.error.is_none()
        {
            if let Some(approval) = parse_approval_request(id.clone(), method, &envelope.params) {
                let sender = state
                    .lock()
                    .await
                    .active_turn
                    .as_ref()
                    .map(|active| active.sender.clone());
                if let Some(sender) = sender {
                    let _ = sender
                        .send(CodexProviderEvent::ApprovalRequested(approval))
                        .await;
                } else {
                    let response = serde_json::json!({
                        "id": id,
                        "result": { "decision": "cancel" }
                    });
                    let _ = Self::send_line(state, &response.to_string()).await;
                }
                return;
            }

            debug!("Codex server request not supported: {method}");
            let error_response = RpcErrorResponse {
                id,
                error: RpcErrorPayloadOut {
                    code: -32601,
                    message: format!("disco does not support server request: {method}"),
                },
            };
            let json = serde_json::to_string(&error_response).unwrap();
            let s = state.lock().await;
            if let Some(write_tx) = &s.write_tx {
                let (ok_tx, _ok_rx) = oneshot::channel();
                let _ = write_tx.send(WriteRequest::Line(json, ok_tx)).await;
            }
            return;
        }

        if envelope.method.is_none()
            && let Some(CodexRequestId::Number(id)) = envelope.id
        {
            let mut s = state.lock().await;
            if let Some(pending) = s.pending.remove(&id) {
                if let Some(error) = envelope.error {
                    let _ = pending.sender.send(Err(anyhow::anyhow!(
                        "RPC error {}: {}",
                        error.code,
                        error.message
                    )));
                } else {
                    let _ = pending
                        .sender
                        .send(Ok(envelope.result.unwrap_or(serde_json::Value::Null)));
                }
            }
            return;
        }

        if let Some(method) = &envelope.method {
            Self::handle_notification(state, method, &envelope.params).await;
        }
    }

    /// Handle a notification from the codex app-server.
    async fn handle_notification(
        state: &Arc<Mutex<CodexState>>,
        method: &str,
        params: &Option<serde_json::Value>,
    ) {
        let params = match params {
            Some(p) => p,
            None => return,
        };

        match method {
            "turn/started" => {
                if let Some(turn_id) = params["turn"]["id"].as_str() {
                    let mut s = state.lock().await;
                    if let Some(active) = &mut s.active_turn {
                        active.turn_id = Some(turn_id.to_string());
                    }
                }
            }
            "item/agentMessage/delta" => {
                if let Some(delta) = params["delta"].as_str() {
                    let s = state.lock().await;
                    if let Some(active) = &s.active_turn {
                        let _ = active
                            .sender
                            .send(CodexProviderEvent::TextDelta(delta.to_string()))
                            .await;
                    }
                }
            }
            "item/reasoning/summaryTextDelta" => {
                if let Some(delta) = params["delta"].as_str() {
                    let s = state.lock().await;
                    if let Some(active) = &s.active_turn {
                        let _ = active
                            .sender
                            .send(CodexProviderEvent::ReasoningDelta(delta.to_string()))
                            .await;
                    }
                }
            }
            "thread/tokenUsage/updated" => {
                if let Some(usage) = parse_codex_usage(params) {
                    let s = state.lock().await;
                    if let Some(active) = &s.active_turn {
                        let _ = active.sender.send(CodexProviderEvent::Usage(usage)).await;
                    }
                }
            }
            "turn/completed" => {
                let event = match params["turn"]["status"].as_str() {
                    Some("interrupted") => CodexProviderEvent::Cancelled,
                    Some("failed") => {
                        let msg = params["turn"]["error"]["message"]
                            .as_str()
                            .unwrap_or("Unknown error")
                            .to_string();
                        CodexProviderEvent::Failed(msg)
                    }
                    _ => CodexProviderEvent::Completed,
                };

                let mut s = state.lock().await;
                if let Some(active) = s.active_turn.take() {
                    let _ = active.sender.send(event).await;
                }
            }
            "item/started" => {
                if let Some(event) = tool_started_event(&params["item"]) {
                    let sender = state
                        .lock()
                        .await
                        .active_turn
                        .as_ref()
                        .map(|active| active.sender.clone());
                    if let Some(sender) = sender {
                        let _ = sender.send(event).await;
                    }
                }
            }
            "item/completed" => {
                if let Some(event) = tool_completed_event(&params["item"]) {
                    let sender = state
                        .lock()
                        .await
                        .active_turn
                        .as_ref()
                        .map(|active| active.sender.clone());
                    if let Some(sender) = sender {
                        let _ = sender.send(event).await;
                    }
                }
            }
            _ => {
                debug!("Codex notification: {method}");
            }
        }
    }

    /// Send a line to the codex app-server via the writer task.
    async fn send_line(state: &Mutex<CodexState>, line: &str) -> Result<()> {
        debug!("codex >>> {line}");
        let s = state.lock().await;
        let write_tx = s
            .write_tx
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Writer not initialized"))?
            .clone();
        drop(s);

        let (resp_tx, resp_rx) = oneshot::channel();
        write_tx
            .send(WriteRequest::Line(line.to_string(), resp_tx))
            .await
            .map_err(|_| anyhow::anyhow!("Writer task closed"))?;

        resp_rx
            .await
            .map_err(|_| anyhow::anyhow!("Writer response channel closed"))?
    }

    /// 初始化 app-server 并创建或恢复当前 thread。
    pub async fn ensure_session(&self) -> Result<String> {
        Self::ensure_ready(
            &self.state,
            &self.executable,
            &self.model,
            self.resume_thread_id.as_deref(),
            self.cwd.as_deref(),
            &self.shutdown_tx,
        )
        .await?;

        self.state
            .lock()
            .await
            .thread_id
            .clone()
            .ok_or_else(|| anyhow::anyhow!("Codex thread 初始化后仍缺少 thread ID"))
    }

    /// 发送需要响应的 JSON-RPC 请求，并集中处理 request ID、超时和 pending 清理。
    async fn send_request(
        state: &Arc<Mutex<CodexState>>,
        method: &str,
        params: serde_json::Value,
    ) -> Result<serde_json::Value> {
        let (request_id, response_rx) = {
            let mut state = state.lock().await;
            let request_id = state.next_id();
            let (response_tx, response_rx) = oneshot::channel();
            state.pending.insert(
                request_id,
                PendingRequest {
                    sender: response_tx,
                },
            );
            (request_id, response_rx)
        };

        let request = serde_json::json!({
            "id": request_id,
            "method": method,
            "params": params,
        });
        if let Err(error) = Self::send_line(state, &request.to_string()).await {
            state.lock().await.pending.remove(&request_id);
            return Err(error);
        }

        match timeout(Duration::from_secs(30), response_rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(anyhow::anyhow!("{method} 响应通道已关闭")),
            Err(_) => {
                state.lock().await.pending.remove(&request_id);
                Err(anyhow::anyhow!("{method} 请求超时"))
            }
        }
    }

    /// 回应 app-server 发起的 command/file approval request。
    pub async fn respond_to_approval(
        &self,
        request: &CodexApprovalRequest,
        decision: CodexApprovalDecision,
    ) -> Result<()> {
        let response = serde_json::json!({
            "id": request.request_id,
            "result": { "decision": decision.wire_value() }
        });
        Self::send_line(&self.state, &response.to_string()).await
    }

    /// Interrupt the current turn.
    pub async fn interrupt(&self) -> Result<()> {
        let s = self.state.lock().await;
        let thread_id = s
            .thread_id
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("No active thread"))?
            .clone();
        let turn_id = s
            .active_turn
            .as_ref()
            .and_then(|a| a.turn_id.clone())
            .ok_or_else(|| anyhow::anyhow!("No active turn"))?;
        drop(s);

        Self::send_request(
            &self.state,
            "turn/interrupt",
            serde_json::json!({
                "threadId": thread_id,
                "turnId": turn_id,
            }),
        )
        .await?;

        Ok(())
    }

    /// turn/start 已提交但 turn ID 尚未到达时短暂等待，避免把取消误报为成功。
    pub async fn interrupt_when_ready(&self) -> Result<()> {
        timeout(Duration::from_secs(2), async {
            loop {
                let turn_is_ready = {
                    let state = self.state.lock().await;
                    let Some(active_turn) = state.active_turn.as_ref() else {
                        return Err(anyhow::anyhow!("No active turn"));
                    };
                    active_turn.turn_id.is_some()
                };
                if turn_is_ready {
                    return Ok(());
                }
                sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .context("等待 Codex turn ID 超时")??;
        self.interrupt().await
    }

    /// 删除当前 Codex thread。调用方必须在删除本地会话前等待该操作成功。
    pub async fn delete_thread(&self) -> Result<()> {
        let thread_id = self
            .state
            .lock()
            .await
            .thread_id
            .clone()
            .ok_or_else(|| anyhow::anyhow!("No active thread"))?;

        self.delete_thread_by_id(&thread_id).await?;
        let mut state = self.state.lock().await;
        state.thread_id = None;
        state.is_thread_attached = false;
        Ok(())
    }

    /// 按持久化 handle 删除 thread，不要求先成功 resume。
    pub async fn delete_thread_by_id(&self, thread_id: &str) -> Result<()> {
        Self::send_request(
            &self.state,
            "thread/delete",
            serde_json::json!({ "threadId": thread_id }),
        )
        .await?;
        Ok(())
    }

    /// Stop the codex subprocess.
    pub async fn stop(&self) {
        self.stop_transport(true).await;
    }

    /// 无法按 turn 中断时终止 transport，但保留 thread ID 供下一次运行恢复。
    pub async fn abort_active_transport(&self) {
        self.stop_transport(false).await;
    }

    async fn stop_transport(&self, clear_thread: bool) {
        let mut s = self.state.lock().await;

        // Fail pending requests
        for (_, pending) in s.pending.drain() {
            let _ = pending.sender.send(Err(anyhow::anyhow!("Shutting down")));
        }

        // Fail active turn
        if let Some(active) = s.active_turn.take() {
            let _ = active
                .sender
                .send(CodexProviderEvent::Failed("Shutting down".to_string()))
                .await;
        }

        // Signal writer task to stop
        if let Some(write_tx) = s.write_tx.take() {
            let _ = write_tx.send(WriteRequest::Shutdown).await;
        }
        self.shutdown_tx
            .lock()
            .expect("Codex shutdown sender mutex poisoned")
            .take();

        s.is_initialized = false;
        s.is_thread_attached = false;
        if clear_thread {
            s.thread_id = None;
        }
    }
}

impl Drop for CodexProvider {
    fn drop(&mut self) {
        if let Some(shutdown_tx) = self
            .shutdown_tx
            .lock()
            .expect("Codex shutdown sender mutex poisoned")
            .take()
        {
            let _ = shutdown_tx.try_send(WriteRequest::Shutdown);
        }
    }
}

fn parse_approval_request(
    request_id: CodexRequestId,
    method: &str,
    params: &Option<serde_json::Value>,
) -> Option<CodexApprovalRequest> {
    let params = params.as_ref()?;
    let item_id = params.get("itemId")?.as_str()?.to_string();
    match method {
        "item/commandExecution/requestApproval" => {
            let command = params
                .get("command")
                .and_then(serde_json::Value::as_str)
                .map(ToString::to_string);
            let allows_session_approval = params
                .get("availableDecisions")
                .and_then(serde_json::Value::as_array)
                .is_none_or(|decisions| {
                    decisions
                        .iter()
                        .any(|decision| decision.as_str() == Some("acceptForSession"))
                });
            Some(CodexApprovalRequest {
                request_id,
                kind: CodexApprovalKind::CommandExecution,
                item_id,
                title: "执行 Codex 命令".to_string(),
                reason: params
                    .get("reason")
                    .and_then(serde_json::Value::as_str)
                    .map(ToString::to_string),
                command,
                cwd: params
                    .get("cwd")
                    .and_then(serde_json::Value::as_str)
                    .map(ToString::to_string),
                grant_root: None,
                allows_session_approval,
            })
        }
        "item/fileChange/requestApproval" => Some(CodexApprovalRequest {
            request_id,
            kind: CodexApprovalKind::FileChange,
            item_id,
            title: "应用 Codex 文件修改".to_string(),
            reason: params
                .get("reason")
                .and_then(serde_json::Value::as_str)
                .map(ToString::to_string),
            command: None,
            cwd: None,
            grant_root: params
                .get("grantRoot")
                .and_then(serde_json::Value::as_str)
                .map(ToString::to_string),
            allows_session_approval: true,
        }),
        _ => None,
    }
}

fn tool_started_event(item: &serde_json::Value) -> Option<CodexProviderEvent> {
    let (id, name, arguments) = tool_call_fields(item)?;
    Some(CodexProviderEvent::ToolStarted(CodexToolCall {
        id,
        name,
        arguments,
    }))
}

fn tool_completed_event(item: &serde_json::Value) -> Option<CodexProviderEvent> {
    let (id, name, _) = tool_call_fields(item)?;
    let output = match item.get("type").and_then(serde_json::Value::as_str)? {
        "commandExecution" => item
            .get("aggregatedOutput")
            .and_then(serde_json::Value::as_str)
            .map(ToString::to_string)
            .unwrap_or_else(|| json_text(item)),
        "mcpToolCall" => item
            .get("result")
            .filter(|result| !result.is_null())
            .or_else(|| item.get("error").filter(|error| !error.is_null()))
            .map(json_text)
            .unwrap_or_else(|| json_text(item)),
        _ => json_text(item),
    };
    Some(CodexProviderEvent::ToolCompleted(CodexToolResult {
        id,
        name,
        output,
    }))
}

fn tool_call_fields(item: &serde_json::Value) -> Option<(String, String, String)> {
    let item_type = item.get("type")?.as_str()?;
    let id = item.get("id")?.as_str()?.to_string();
    let (name, arguments) = match item_type {
        "commandExecution" => (
            "shell".to_string(),
            serde_json::json!({
                "command": item.get("command"),
                "cwd": item.get("cwd"),
            }),
        ),
        "fileChange" => (
            "file_change".to_string(),
            item.get("changes").cloned().unwrap_or_default(),
        ),
        "mcpToolCall" => {
            let server = item
                .get("server")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("mcp");
            let tool = item
                .get("tool")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("tool");
            (
                format!("{server}/{tool}"),
                item.get("arguments").cloned().unwrap_or_default(),
            )
        }
        "dynamicToolCall" => {
            let namespace = item.get("namespace").and_then(serde_json::Value::as_str);
            let tool = item
                .get("tool")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("tool");
            (
                namespace
                    .map(|namespace| format!("{namespace}/{tool}"))
                    .unwrap_or_else(|| tool.to_string()),
                item.get("arguments").cloned().unwrap_or_default(),
            )
        }
        "collabAgentToolCall" => (
            item.get("tool")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("agent")
                .to_string(),
            serde_json::json!({
                "prompt": item.get("prompt"),
                "receiverThreadIds": item.get("receiverThreadIds"),
                "model": item.get("model"),
            }),
        ),
        "webSearch" => ("web_search".to_string(), item.clone()),
        "imageView" => ("image_view".to_string(), item.clone()),
        "imageGeneration" => ("image_generation".to_string(), item.clone()),
        "sleep" => ("sleep".to_string(), item.clone()),
        _ => return None,
    };
    Some((id, name, json_text(&arguments)))
}

fn json_text(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(text) => text.clone(),
        value => serde_json::to_string(value).unwrap_or_else(|_| "null".to_string()),
    }
}

// MARK: - ModelProvider 统一接口实现

#[async_trait]
impl ModelProvider for CodexProvider {
    fn vendor_name(&self) -> &'static str {
        "codex-app-server"
    }

    /// 走 codex app-server 订阅额度：
    /// - `tools` 忽略（app-server 自行管理工具调用）
    /// - 多轮历史由 app-server 的 thread 状态管理
    async fn stream<'a>(
        &'a self,
        messages: &'a [ChatMessage],
        _tools: Option<&'a [ToolDefinition]>,
    ) -> Result<Pin<Box<dyn Stream<Item = Result<ProviderEvent>> + Send + 'a>>> {
        let mut stream = Box::pin(self.stream_turn(messages).await?);
        Ok(Box::pin(async_stream::try_stream! {
            while let Some(event) = stream.next().await {
                match event? {
                    CodexProviderEvent::TextDelta(delta) => {
                        yield ProviderEvent::TextDelta(delta);
                    }
                    CodexProviderEvent::ReasoningDelta(delta) => {
                        yield ProviderEvent::ReasoningDelta(delta);
                    }
                    CodexProviderEvent::Usage(usage) => {
                        yield ProviderEvent::Usage(usage);
                    }
                    CodexProviderEvent::ApprovalRequested(request) => {
                        self.respond_to_approval(&request, CodexApprovalDecision::Decline).await?;
                    }
                    CodexProviderEvent::Completed => {
                        yield ProviderEvent::Completed;
                        return;
                    }
                    CodexProviderEvent::Cancelled => {
                        yield ProviderEvent::Cancelled;
                        return;
                    }
                    CodexProviderEvent::Failed(error) => {
                        yield ProviderEvent::Failed(error);
                        return;
                    }
                    CodexProviderEvent::ToolStarted(_) | CodexProviderEvent::ToolCompleted(_) => {}
                }
            }
        }))
    }
}

/// Parse Codex token usage from notification params.
fn parse_codex_usage(params: &serde_json::Value) -> Option<TokenUsage> {
    let usage = params.get("tokenUsage")?;

    // Try to get the "last" breakdown
    let last = usage.get("last")?;
    let input = last.get("inputTokens").and_then(|v| v.as_i64())?;
    let output = last.get("outputTokens").and_then(|v| v.as_i64())?;
    let total = last
        .get("totalTokens")
        .and_then(|v| v.as_i64())
        .unwrap_or(input + output);
    let cached_input = last.get("cachedInputTokens").and_then(|v| v.as_i64());
    let reasoning_output = last.get("reasoningOutputTokens").and_then(|v| v.as_i64());

    Some(TokenUsage {
        input,
        output,
        total,
        cached_input,
        reasoning_output,
    })
}

// MARK: - JSON-RPC encoding/decoding helpers (for testing)

/// Encode a JSON-RPC request (for testing).
pub fn encode_rpc_request(id: i64, method: &str, params: serde_json::Value) -> String {
    serde_json::to_string(&RpcRequest {
        id,
        method: method.to_string(),
        params,
    })
    .unwrap()
}

/// Encode a JSON-RPC notification (for testing).
pub fn encode_rpc_notification(method: &str, params: serde_json::Value) -> String {
    serde_json::to_string(&RpcNotification {
        method: method.to_string(),
        params,
    })
    .unwrap()
}

/// Decode a JSON-RPC envelope from a line (for testing).
pub fn decode_rpc_envelope(line: &str) -> Result<RpcEnvelope> {
    serde_json::from_str(line).context("Failed to decode RPC envelope")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_initialize_request() {
        let json = encode_rpc_request(
            0,
            "initialize",
            serde_json::json!({
                "clientInfo": {
                    "name": "disco",
                    "title": "Disco",
                    "version": "0.1.0"
                }
            }),
        );
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["id"], 0);
        assert_eq!(parsed["method"], "initialize");
        assert!(parsed["params"]["clientInfo"]["name"].as_str() == Some("disco"));
    }

    #[test]
    fn encode_thread_start_request() {
        let json = encode_rpc_request(1, "thread/start", serde_json::json!({"model": "o4-mini"}));
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["id"], 1);
        assert_eq!(parsed["method"], "thread/start");
        assert_eq!(parsed["params"]["model"], "o4-mini");
    }

    #[test]
    fn encode_turn_start_request() {
        let json = encode_rpc_request(
            2,
            "turn/start",
            serde_json::json!({
                "threadId": "thread-123",
                "input": [{"type": "text", "text": "Hello"}],
                "effort": "high"
            }),
        );
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["method"], "turn/start");
        assert_eq!(parsed["params"]["threadId"], "thread-123");
        assert_eq!(parsed["params"]["input"][0]["text"], "Hello");
    }

    #[test]
    fn encode_initialized_notification() {
        let json = encode_rpc_notification("initialized", serde_json::json!({}));
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["method"], "initialized");
        assert!(parsed.get("id").is_none());
    }

    #[test]
    fn decode_response_envelope() {
        let line = r#"{"id":0,"result":{"userAgent":"codex-cli/0.147.0"}}"#;
        let envelope = decode_rpc_envelope(line).unwrap();
        assert_eq!(envelope.id, Some(CodexRequestId::Number(0)));
        assert!(envelope.method.is_none());
        assert!(envelope.result.is_some());
    }

    #[test]
    fn decode_error_envelope() {
        let line = r#"{"id":1,"error":{"code":-32601,"message":"Method not found"}}"#;
        let envelope = decode_rpc_envelope(line).unwrap();
        assert_eq!(envelope.id, Some(CodexRequestId::Number(1)));
        assert!(envelope.error.is_some());
        let error = envelope.error.unwrap();
        assert_eq!(error.code, -32601);
    }

    #[test]
    fn decode_notification_envelope() {
        let line = r#"{"method":"turn/started","params":{"threadId":"t1","turn":{"id":"turn-1"}}}"#;
        let envelope = decode_rpc_envelope(line).unwrap();
        assert!(envelope.id.is_none());
        assert_eq!(envelope.method.as_deref(), Some("turn/started"));
        assert!(envelope.params.is_some());
    }

    #[test]
    fn decode_server_request_envelope() {
        let line = r#"{"id":"approval-99","method":"item/commandExecution/requestApproval","params":{"itemId":"tool-1"}}"#;
        let envelope = decode_rpc_envelope(line).unwrap();
        assert_eq!(
            envelope.id,
            Some(CodexRequestId::String("approval-99".to_string()))
        );
        assert_eq!(
            envelope.method.as_deref(),
            Some("item/commandExecution/requestApproval")
        );
    }

    #[test]
    fn parses_current_command_and_file_approval_requests() {
        let command = parse_approval_request(
            CodexRequestId::String("approval-1".to_string()),
            "item/commandExecution/requestApproval",
            &Some(serde_json::json!({
                "itemId": "command-1",
                "command": "git status",
                "cwd": "/workspace",
                "reason": "需要检查状态",
                "availableDecisions": ["accept", "acceptForSession", "decline"]
            })),
        )
        .unwrap();
        assert_eq!(command.kind, CodexApprovalKind::CommandExecution);
        assert_eq!(command.command.as_deref(), Some("git status"));
        assert!(command.allows_session_approval);

        let file = parse_approval_request(
            CodexRequestId::Number(7),
            "item/fileChange/requestApproval",
            &Some(serde_json::json!({
                "itemId": "file-1",
                "grantRoot": "/workspace/src"
            })),
        )
        .unwrap();
        assert_eq!(file.kind, CodexApprovalKind::FileChange);
        assert_eq!(file.grant_root.as_deref(), Some("/workspace/src"));
    }

    #[test]
    fn maps_current_command_item_lifecycle() {
        let started = tool_started_event(&serde_json::json!({
            "type": "commandExecution",
            "id": "command-1",
            "command": "cargo test",
            "cwd": "/workspace",
            "status": "inProgress"
        }))
        .unwrap();
        assert!(matches!(
            started,
            CodexProviderEvent::ToolStarted(CodexToolCall { id, name, arguments })
                if id == "command-1" && name == "shell" && arguments.contains("cargo test")
        ));

        let completed = tool_completed_event(&serde_json::json!({
            "type": "commandExecution",
            "id": "command-1",
            "command": "cargo test",
            "cwd": "/workspace",
            "status": "completed",
            "aggregatedOutput": "ok\n",
            "exitCode": 0
        }))
        .unwrap();
        assert!(matches!(
            completed,
            CodexProviderEvent::ToolCompleted(CodexToolResult { id, output, .. })
                if id == "command-1" && output == "ok\n"
        ));
    }

    #[test]
    fn parse_codex_usage_data() {
        let params = serde_json::json!({
            "threadId": "t1",
            "turnId": "turn-1",
            "tokenUsage": {
                "last": {
                    "inputTokens": 100,
                    "outputTokens": 50,
                    "totalTokens": 150,
                    "cachedInputTokens": 30,
                    "reasoningOutputTokens": 20
                },
                "total": {
                    "inputTokens": 500,
                    "outputTokens": 200,
                    "totalTokens": 700
                }
            }
        });
        let usage = parse_codex_usage(&params).unwrap();
        assert_eq!(usage.input, 100);
        assert_eq!(usage.output, 50);
        assert_eq!(usage.total, 150);
        assert_eq!(usage.cached_input, Some(30));
        assert_eq!(usage.reasoning_output, Some(20));
    }

    #[test]
    fn parse_codex_usage_missing_fields() {
        let params = serde_json::json!({
            "tokenUsage": {
                "last": {
                    "inputTokens": 100,
                    "outputTokens": 50,
                    "totalTokens": 150
                }
            }
        });
        let usage = parse_codex_usage(&params).unwrap();
        assert_eq!(usage.input, 100);
        assert_eq!(usage.output, 50);
        assert_eq!(usage.cached_input, None);
        assert_eq!(usage.reasoning_output, None);
    }

    #[test]
    fn parse_codex_usage_no_token_usage() {
        let params = serde_json::json!({"threadId": "t1"});
        assert!(parse_codex_usage(&params).is_none());
    }

    #[test]
    fn encode_turn_interrupt_request() {
        let json = encode_rpc_request(
            3,
            "turn/interrupt",
            serde_json::json!({
                "threadId": "thread-123",
                "turnId": "turn-456"
            }),
        );
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["method"], "turn/interrupt");
        assert_eq!(parsed["params"]["threadId"], "thread-123");
        assert_eq!(parsed["params"]["turnId"], "turn-456");
    }

    #[test]
    fn encode_thread_resume_request() {
        let json = encode_rpc_request(
            1,
            "thread/resume",
            serde_json::json!({
                "threadId": "existing-thread",
                "model": "o4-mini"
            }),
        );
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["method"], "thread/resume");
        assert_eq!(parsed["params"]["threadId"], "existing-thread");
    }

    #[test]
    fn error_response_encoding() {
        let response = RpcErrorResponse {
            id: CodexRequestId::Number(42),
            error: RpcErrorPayloadOut {
                code: -32601,
                message: "disco does not support server request: approval/request".to_string(),
            },
        };
        let json = serde_json::to_string(&response).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["id"], 42);
        assert_eq!(parsed["error"]["code"], -32601);
        assert!(
            parsed["error"]["message"]
                .as_str()
                .unwrap()
                .contains("approval/request")
        );
    }
}
