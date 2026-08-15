//! Codex app-server provider adapter.
//!
//! Manages a `codex app-server` subprocess and communicates via JSON-RPC
//! over stdio (JSONL). Maps Codex turn events to the unified ProviderEvent stream.

use std::collections::HashMap;
use std::pin::Pin;
use std::sync::Arc;

use anyhow::{Context, Result};
use async_trait::async_trait;
use futures_core::Stream;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio::time::{Duration, timeout};
use tracing::{debug, info, warn};

use disco_protocol::types::TokenUsage;
use disco_tools::ToolDefinition;

use crate::ModelProvider;
use crate::openai_responses::{ChatMessage, ProviderEvent};

// MARK: - JSON-RPC types

/// A JSON-RPC envelope for messages from the codex app-server.
#[derive(Debug, Deserialize)]
pub struct RpcEnvelope {
    pub id: Option<i64>,
    pub method: Option<String>,
    pub params: Option<serde_json::Value>,
    pub result: Option<serde_json::Value>,
    pub error: Option<RpcErrorPayload>,
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
    id: i64,
    error: RpcErrorPayloadOut,
}

#[derive(Debug, Serialize)]
struct RpcErrorPayloadOut {
    code: i32,
    message: String,
}

// MARK: - Codex turn events (internal)

#[derive(Debug, Clone)]
enum CodexTurnEvent {
    Started { _turn_id: String },
    AgentMessageDelta(String),
    ReasoningSummaryDelta(String),
    TokenUsageUpdated(TokenUsage),
    Completed { status: CodexTurnStatus },
}

#[derive(Debug, Clone)]
enum CodexTurnStatus {
    Completed,
    Interrupted,
    Failed(String),
}

// MARK: - Pending request tracking

struct PendingRequest {
    sender: oneshot::Sender<Result<serde_json::Value>>,
}

// MARK: - Active turn tracking

struct ActiveTurn {
    sender: mpsc::Sender<CodexTurnEvent>,
    turn_id: Option<String>,
}

// MARK: - Write request for the writer task

enum WriteRequest {
    Line(String, oneshot::Sender<Result<()>>),
    Shutdown,
}

// MARK: - Internal state

struct CodexState {
    /// Whether we've completed the initialize handshake.
    initialized: bool,
    /// The thread ID for this session.
    thread_id: Option<String>,
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
            initialized: false,
            thread_id: None,
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
    /// Optional thread ID to resume.
    resume_thread_id: Option<String>,

    /// Internal state protected by mutex.
    state: Arc<Mutex<CodexState>>,
}

impl CodexProvider {
    /// Create a new CodexProvider.
    pub fn new(
        executable: String,
        model: String,
        reasoning_effort: Option<String>,
        resume_thread_id: Option<String>,
    ) -> Self {
        Self {
            executable,
            model,
            reasoning_effort,
            resume_thread_id,
            state: Arc::new(Mutex::new(CodexState::new())),
        }
    }

    /// Find the codex executable in PATH or well-known locations.
    pub fn find_codex() -> String {
        let candidates = [
            "codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
        ];

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

    /// 流式执行一个 turn：把最后一条用户消息发给 codex app-server，
    /// 转发事件（文本/推理/token 用量/完成状态）为统一 ProviderEvent。
    /// 多轮对话历史由 app-server 的 thread 状态管理，无需重复发送。
    pub async fn stream_turn(
        &self,
        messages: &[ChatMessage],
    ) -> Result<impl Stream<Item = Result<ProviderEvent>>> {
        let (event_tx, mut event_rx) = mpsc::channel::<Result<ProviderEvent>>(64);
        let state = self.state.clone();
        let executable = self.executable.clone();
        let model = self.model.clone();
        let reasoning_effort = self.reasoning_effort.clone();
        let resume_thread_id = self.resume_thread_id.clone();

        // Extract the user input (last user message)
        let user_input = messages
            .iter()
            .rev()
            .find(|m| m.role == "user")
            .map(|m| m.text.clone())
            .unwrap_or_default();

        let tx = event_tx.clone();

        tokio::spawn(async move {
            // Ensure transport is initialized
            if let Err(e) = Self::ensure_ready(
                &state,
                &executable,
                &model,
                resume_thread_id.as_deref(),
            )
            .await
            {
                let _ = tx.send(Err(e)).await;
                return;
            }

            // Get the thread ID
            let thread_id = {
                let s = state.lock().await;
                s.thread_id.clone()
            };

            let Some(thread_id) = thread_id else {
                let _ = tx.send(Err(anyhow::anyhow!("No active thread"))).await;
                return;
            };

            // Create a channel for turn events
            let (turn_tx, mut turn_rx) = mpsc::channel::<CodexTurnEvent>(64);

            // Register the active turn
            {
                let mut s = state.lock().await;
                s.active_turn = Some(ActiveTurn {
                    sender: turn_tx,
                    turn_id: None,
                });
            }

            // Send turn/start request
            let request_id = {
                let mut s = state.lock().await;
                s.next_id()
            };

            let turn_start = serde_json::json!({
                "id": request_id,
                "method": "turn/start",
                "params": {
                    "threadId": thread_id,
                    "input": [{"type": "text", "text": user_input}],
                    "effort": reasoning_effort,
                }
            });

            // Send the request via the writer
            if let Err(e) = Self::send_line(&state, &turn_start.to_string()).await {
                let _ = tx.send(Err(e)).await;
                return;
            }

            // Set up a pending request for the turn/start response
            let (resp_tx, resp_rx) = oneshot::channel();
            {
                let mut s = state.lock().await;
                s.pending.insert(request_id, PendingRequest { sender: resp_tx });
            }

            // Wait for the turn/start response (with timeout)
            match timeout(Duration::from_secs(30), resp_rx).await {
                Ok(Ok(Ok(_result))) => {
                    debug!("turn/start response received");
                }
                Ok(Ok(Err(e))) => {
                    let _ = tx.send(Err(anyhow::anyhow!("turn/start failed: {e}"))).await;
                    return;
                }
                Ok(Err(_)) => {
                    let _ = tx
                        .send(Err(anyhow::anyhow!("turn/start response channel closed")))
                        .await;
                    return;
                }
                Err(_) => {
                    let _ = tx.send(Err(anyhow::anyhow!("turn/start timed out"))).await;
                    return;
                }
            }

            // Now forward turn events as ProviderEvents
            let tx2 = tx.clone();
            while let Some(turn_event) = turn_rx.recv().await {
                match turn_event {
                    CodexTurnEvent::Started { .. } => {
                        debug!("Turn started");
                    }
                    CodexTurnEvent::AgentMessageDelta(delta) => {
                        if tx2.send(Ok(ProviderEvent::TextDelta(delta))).await.is_err() {
                            break;
                        }
                    }
                    CodexTurnEvent::ReasoningSummaryDelta(delta) => {
                        if tx2
                            .send(Ok(ProviderEvent::ReasoningDelta(delta)))
                            .await
                            .is_err()
                        {
                            break;
                        }
                    }
                    CodexTurnEvent::TokenUsageUpdated(usage) => {
                        if tx2.send(Ok(ProviderEvent::Usage(usage))).await.is_err() {
                            break;
                        }
                    }
                    CodexTurnEvent::Completed { status } => {
                        match status {
                            CodexTurnStatus::Completed => {
                                let _ = tx2.send(Ok(ProviderEvent::Completed)).await;
                            }
                            CodexTurnStatus::Interrupted => {
                                let _ = tx2.send(Ok(ProviderEvent::Completed)).await;
                            }
                            CodexTurnStatus::Failed(msg) => {
                                let _ = tx2.send(Ok(ProviderEvent::Failed(msg))).await;
                            }
                        }
                        // Clean up active turn
                        let mut s = state.lock().await;
                        s.active_turn = None;
                        return;
                    }
                }
            }

            // If we get here, the turn channel closed without a completed event
            let _ = tx.send(Ok(ProviderEvent::Completed)).await;
            let mut s = state.lock().await;
            s.active_turn = None;
        });

        // Return a stream that reads from the event channel
        let stream = async_stream::try_stream! {
            while let Some(event) = event_rx.recv().await {
                yield event?;
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
    ) -> Result<()> {
        let s = state.lock().await;

        if s.initialized && s.thread_id.is_some() {
            return Ok(());
        }

        // Launch subprocess if needed
        if s.write_tx.is_none() {
            drop(s); // Release lock before spawning process
            info!("Launching codex app-server: {executable}");

            let mut child = Command::new(executable)
                .arg("app-server")
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .spawn()
                .context("Failed to launch codex app-server")?;

            let stdin = child.stdin.take().context("Failed to take stdin")?;
            let stdout = child.stdout.take().context("Failed to take stdout")?;

            // Create a writer task that owns the stdin
            let (write_tx, mut write_rx) = mpsc::channel::<WriteRequest>(32);

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
                    }
                }
            });

            let (resp_tx, resp_rx) = oneshot::channel();
            {
                let mut s = state.lock().await;
                s.pending.insert(init_id, PendingRequest { sender: resp_tx });
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
                s.initialized = true;
            }
        }

        // Start or resume thread
        {
            let mut s = state.lock().await;
            if s.thread_id.is_none() {
                let thread_id = if let Some(resume_id) = resume_thread_id {
                    // Resume existing thread
                    let req_id = s.next_id();
                    let request = serde_json::json!({
                        "id": req_id,
                        "method": "thread/resume",
                        "params": {
                            "threadId": resume_id,
                            "model": model,
                        }
                    });

                    let (resp_tx, resp_rx) = oneshot::channel();
                    s.pending.insert(req_id, PendingRequest { sender: resp_tx });

                    // Need to release lock to send
                    let write_tx = s.write_tx.clone();
                    drop(s);

                    if let Some(tx) = &write_tx {
                        let (ok_tx, ok_rx) = oneshot::channel();
                        let _ = tx.send(WriteRequest::Line(request.to_string(), ok_tx)).await;
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
                        }
                    });

                    let (resp_tx, resp_rx) = oneshot::channel();
                    s.pending.insert(req_id, PendingRequest { sender: resp_tx });

                    // Release the lock before sending
                    let write_tx = s.write_tx.clone();
                    drop(s);

                    if let Some(tx) = &write_tx {
                        let (ok_tx, ok_rx) = oneshot::channel();
                        let _ = tx.send(WriteRequest::Line(request.to_string(), ok_tx)).await;
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
            debug!("codex <<< {}", trimmed.chars().take(160).collect::<String>());

            Self::handle_envelope(&state, envelope).await;
        }

        info!("Codex app-server stdout closed");

        // Clean up state
        let mut s = state.lock().await;
        s.initialized = false;
        s.write_tx = None;

        // Fail any pending requests
        for (_, pending) in s.pending.drain() {
            let _ = pending.sender.send(Err(anyhow::anyhow!("Process exited")));
        }

        // Fail active turn
        if let Some(active) = s.active_turn.take() {
            let _ = active
                .sender
                .send(CodexTurnEvent::Completed {
                    status: CodexTurnStatus::Failed("Process exited".to_string()),
                })
                .await;
        }
    }

    /// Handle a single RPC envelope from the codex app-server.
    async fn handle_envelope(state: &Arc<Mutex<CodexState>>, envelope: RpcEnvelope) {
        // Server request (has both method and id, no result/error) - respond with "not supported"
        if let (Some(method), Some(id)) = (&envelope.method, envelope.id) {
            if envelope.result.is_none() && envelope.error.is_none() {
                debug!("Codex server request: {method} (id={id}) - rejecting");
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
        }

        // Response to our request (has id but no method)
        if let Some(id) = envelope.id {
            if envelope.method.is_none() {
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
        }

        // Notification (has method but no id)
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
                        let _ = active
                            .sender
                            .send(CodexTurnEvent::Started {
                                _turn_id: turn_id.to_string(),
                            })
                            .await;
                    }
                }
            }
            "item/agentMessage/delta" => {
                if let Some(delta) = params["delta"].as_str() {
                    let s = state.lock().await;
                    if let Some(active) = &s.active_turn {
                        let _ = active
                            .sender
                            .send(CodexTurnEvent::AgentMessageDelta(delta.to_string()))
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
                            .send(CodexTurnEvent::ReasoningSummaryDelta(delta.to_string()))
                            .await;
                    }
                }
            }
            "thread/tokenUsage/updated" => {
                if let Some(usage) = parse_codex_usage(params) {
                    let s = state.lock().await;
                    if let Some(active) = &s.active_turn {
                        let _ = active
                            .sender
                            .send(CodexTurnEvent::TokenUsageUpdated(usage))
                            .await;
                    }
                }
            }
            "turn/completed" => {
                let status = match params["turn"]["status"].as_str() {
                    Some("interrupted") => CodexTurnStatus::Interrupted,
                    Some("failed") => {
                        let msg = params["turn"]["error"]["message"]
                            .as_str()
                            .unwrap_or("Unknown error")
                            .to_string();
                        CodexTurnStatus::Failed(msg)
                    }
                    _ => CodexTurnStatus::Completed,
                };

                let mut s = state.lock().await;
                if let Some(active) = s.active_turn.take() {
                    let _ = active
                        .sender
                        .send(CodexTurnEvent::Completed { status })
                        .await;
                }
            }
            "item/started" | "item/completed" => {
                debug!("Codex item lifecycle: {method}");
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
        let write_tx = s
            .write_tx
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Writer not initialized"))?
            .clone();
        let req_id = s.next_request_id;
        drop(s);

        let request = serde_json::json!({
            "id": req_id,
            "method": "turn/interrupt",
            "params": {
                "threadId": thread_id,
                "turnId": turn_id,
            }
        });

        let (resp_tx, resp_rx) = oneshot::channel();
        write_tx
            .send(WriteRequest::Line(request.to_string(), resp_tx))
            .await
            .map_err(|_| anyhow::anyhow!("Writer task closed"))?;

        resp_rx
            .await
            .map_err(|_| anyhow::anyhow!("Writer response channel closed"))??;

        Ok(())
    }

    /// Stop the codex subprocess.
    pub async fn stop(&self) {
        let mut s = self.state.lock().await;

        // Fail pending requests
        for (_, pending) in s.pending.drain() {
            let _ = pending.sender.send(Err(anyhow::anyhow!("Shutting down")));
        }

        // Fail active turn
        if let Some(active) = s.active_turn.take() {
            let _ = active
                .sender
                .send(CodexTurnEvent::Completed {
                    status: CodexTurnStatus::Failed("Shutting down".to_string()),
                })
                .await;
        }

        // Signal writer task to stop
        if let Some(write_tx) = s.write_tx.take() {
            let _ = write_tx.send(WriteRequest::Shutdown).await;
        }

        s.initialized = false;
        s.thread_id = None;
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
        let stream = self.stream_turn(messages).await?;
        Ok(Box::pin(stream))
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
        let json = encode_rpc_request(
            1,
            "thread/start",
            serde_json::json!({"model": "o4-mini"}),
        );
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
        assert_eq!(envelope.id, Some(0));
        assert!(envelope.method.is_none());
        assert!(envelope.result.is_some());
    }

    #[test]
    fn decode_error_envelope() {
        let line = r#"{"id":1,"error":{"code":-32601,"message":"Method not found"}}"#;
        let envelope = decode_rpc_envelope(line).unwrap();
        assert_eq!(envelope.id, Some(1));
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
        let line = r#"{"id":99,"method":"approval/request","params":{"tool":"shell"}}"#;
        let envelope = decode_rpc_envelope(line).unwrap();
        assert_eq!(envelope.id, Some(99));
        assert_eq!(envelope.method.as_deref(), Some("approval/request"));
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
            id: 42,
            error: RpcErrorPayloadOut {
                code: -32601,
                message: "disco does not support server request: approval/request".to_string(),
            },
        };
        let json = serde_json::to_string(&response).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["id"], 42);
        assert_eq!(parsed["error"]["code"], -32601);
        assert!(parsed["error"]["message"]
            .as_str()
            .unwrap()
            .contains("approval/request"));
    }
}
