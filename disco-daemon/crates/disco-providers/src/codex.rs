//! Codex app-server provider adapter.
//!
//! 管理 `codex app-server` 子进程及 JSON-RPC stdio 连接。Codex 原始运行语义仅暴露给
//! CodexAdapter；ModelProvider 实现是迁移期的 compaction bridge。

use std::collections::HashMap;
use std::pin::Pin;
use std::process::Stdio;
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

// MARK: - Codex app-server 模型目录

/// `model/list` 返回的单个模型条目（取本项目需要的字段，wire 字段为 camelCase）。
#[derive(Debug, Deserialize)]
pub struct CodexModelEntry {
    pub id: String,
    #[serde(rename = "displayName", default)]
    pub display_name: Option<String>,
    #[serde(rename = "defaultReasoningEffort", default)]
    pub default_reasoning_effort: Option<String>,
    #[serde(rename = "supportedReasoningEfforts", default)]
    pub supported_reasoning_efforts: Option<Vec<CodexReasoningEffort>>,
}

/// `model/list` 条目里的单个 effort 档位。
#[derive(Debug, Deserialize)]
pub struct CodexReasoningEffort {
    #[serde(rename = "reasoningEffort")]
    pub reasoning_effort: String,
}

// MARK: - Codex turn events (internal)

#[derive(Debug, Clone)]
pub enum CodexProviderEvent {
    TextDelta(String),
    ReasoningDelta(String),
    Usage(TokenUsage),
    /// Codex app-server 的当前上下文占用；与累计请求用量分开传递。
    ContextUsage {
        tokens: i64,
        window: Option<i64>,
    },
    Compaction(CodexCompactionUpdate),
    ToolStarted(CodexToolCall),
    ToolCompleted(CodexToolResult),
    ApprovalRequested(CodexApprovalRequest),
    Completed,
    Cancelled,
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexCompactionUpdate {
    pub id: String,
    pub status: String,
    pub before_tokens: Option<i64>,
    pub after_tokens: Option<i64>,
    pub summary: Option<String>,
    pub error_message: Option<String>,
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

/// 通过 `codex app-server` 的 `model/list` 查询可用模型。
///
/// 与对话用的 `CodexProvider` 相互独立：只完成 initialize 握手后请求一次
/// `model/list`，拿到结果即断开，不创建 thread。失败返回明确错误（CLI 缺失、
/// 启动失败、握手失败或模型列表不可用）。
pub async fn list_codex_models(executable: &str) -> Result<Vec<CodexModelEntry>> {
    let mut child = codex_command(executable)
        .arg("app-server")
        .kill_on_drop(true)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("无法启动 codex app-server")?;
    let mut stdin = child.stdin.take().context("codex stdin 不可用")?;
    let stdout = child.stdout.take().context("codex stdout 不可用")?;
    let mut lines = BufReader::new(stdout).lines();

    // initialize 握手
    send_jsonrpc_line(
        &mut stdin,
        &serde_json::json!({
            "id": 0,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "disco",
                    "title": "Disco",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": null,
            }
        }),
    )
    .await?;
    let init = recv_jsonrpc_response(&mut lines, &CodexRequestId::Number(0))
        .await
        .context("codex app-server initialize 握手失败")?;
    if let Some(error) = init.error {
        return Err(anyhow::anyhow!(
            "codex app-server initialize 失败：{}",
            error.message
        ));
    }

    send_jsonrpc_line(
        &mut stdin,
        &serde_json::json!({ "method": "initialized", "params": {} }),
    )
    .await?;

    // model/list：includeHidden 让客户端自行按 hidden 过滤
    send_jsonrpc_line(
        &mut stdin,
        &serde_json::json!({
            "id": 1,
            "method": "model/list",
            "params": { "includeHidden": true },
        }),
    )
    .await?;
    let list = recv_jsonrpc_response(&mut lines, &CodexRequestId::Number(1))
        .await
        .context("codex app-server model/list 请求失败")?;
    if let Some(error) = list.error {
        return Err(anyhow::anyhow!("model/list 失败：{}", error.message));
    }
    let data = list
        .result
        .and_then(|result| result.get("data").cloned())
        .unwrap_or_default();
    Ok(serde_json::from_value(data).context("解析 model/list 响应失败")?)
}

/// 向 app-server 写入一行 JSON-RPC 消息（JSONL）。
async fn send_jsonrpc_line(
    stdin: &mut tokio::process::ChildStdin,
    payload: &serde_json::Value,
) -> Result<()> {
    stdin.write_all(payload.to_string().as_bytes()).await?;
    stdin.write_all(b"\n").await?;
    stdin.flush().await?;
    Ok(())
}

/// 读取 app-server 响应行，跳过 notification 与其它 id 的响应，直到匹配目标 id。
/// 30 秒无匹配视为超时。
async fn recv_jsonrpc_response(
    lines: &mut tokio::io::Lines<tokio::io::BufReader<tokio::process::ChildStdout>>,
    target_id: &CodexRequestId,
) -> Result<RpcEnvelope> {
    timeout(Duration::from_secs(30), async {
        loop {
            let line = lines
                .next_line()
                .await?
                .ok_or_else(|| anyhow::anyhow!("codex app-server 已退出，未收到响应"))?;
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Ok(envelope) = serde_json::from_str::<RpcEnvelope>(trimmed) {
                if envelope.method.is_none() && envelope.id.as_ref() == Some(target_id) {
                    return Ok(envelope);
                }
            }
        }
    })
    .await
    .map_err(|_| anyhow::anyhow!("等待 codex app-server 响应超时"))?
}

/// 在给定的 PATH 中查找第一个存在的 codex 可执行文件。
fn find_codex_in_path(path: &str) -> Option<String> {
    for dir in path.split(':') {
        let dir = dir.trim();
        if dir.is_empty() {
            continue;
        }
        let candidate = format!("{dir}/codex");
        if std::path::Path::new(&candidate).exists() {
            return Some(candidate);
        }
    }
    None
}

/// 解析登录 shell 配置文件，提取真实的 PATH。
///
/// 解析登录 shell 配置文件，还原真实 PATH。
///
/// GUI 会话启动的进程 PATH 很精简（不含 Homebrew / npm-global 等安装目录），
/// 从用户 shell 配置里读 PATH 才能覆盖这些位置。zsh 常见的写法是
/// `export PATH="$HOME/.npm-global/bin:$PATH"`，因此按执行顺序收集每行的
/// 前置目录段，最后拼接上当前进程 PATH 作基底。
fn login_shell_path() -> Option<String> {
    static RC_FILES: &[&str] = &[
        "~/.zshenv",
        "~/.zprofile",
        "~/.zshrc",
        "~/.bash_profile",
        "~/.profile",
    ];
    let home = std::env::var("HOME").ok()?;
    let base_path = std::env::var("PATH").unwrap_or_default();
    let mut segments: Vec<String> = Vec::new();

    for rc_file in RC_FILES {
        let path = rc_file.replace('~', &home);
        let content = match std::fs::read_to_string(&path) {
            Ok(content) => content,
            Err(_) => continue,
        };
        for line in content.lines() {
            let line = line.trim();
            let Some(rest) = line
                .strip_prefix("export PATH=")
                .or_else(|| line.strip_prefix("PATH="))
            else {
                continue;
            };
            let value = rest.trim().trim_matches(|c| c == '\'' || c == '"');
            if value.is_empty() {
                continue;
            }
            // 取 `$PATH` / `${PATH}` 之前的目录段（zsh 通常用它引用旧值）
            let prefix = value.split("$PATH").next().unwrap_or(value).to_string();
            let prefix = if prefix != value {
                prefix
            } else {
                value.split("${PATH}").next().unwrap_or(value).to_string()
            };
            if prefix.is_empty() {
                continue;
            }
            let prefix = prefix
                .replace("${HOME}", &home)
                .replace("$HOME", &home)
                .replace('~', &home)
                .trim_end_matches(':')
                .to_string();
            if !prefix.is_empty() {
                segments.push(prefix);
            }
        }
    }

    if segments.is_empty() {
        return None;
    }
    segments.push(base_path);
    Some(segments.join(":"))
}

/// Build a Codex command with the tool paths available to the user's login shell.
///
/// GUI-launched processes often inherit a minimal PATH. The npm Codex launcher
/// uses `#!/usr/bin/env node`, so finding the launcher is not enough; its child
/// process must receive a PATH that can resolve Node as well.
fn codex_command(executable: &str) -> Command {
    let mut command = Command::new(executable);
    if let Some(runtime_path) = codex_runtime_path() {
        command.env("PATH", runtime_path);
    }
    command
}

fn codex_runtime_path() -> Option<String> {
    let current_path = std::env::var("PATH").ok();
    let shell_path = login_shell_path();
    build_codex_runtime_path(current_path.as_deref(), shell_path.as_deref())
}

fn build_codex_runtime_path(
    current_path: Option<&str>,
    shell_path: Option<&str>,
) -> Option<String> {
    let mut path_segments: Vec<String> = Vec::new();
    let mut append_path_segments = |path: &str| {
        for segment in path.split(':') {
            let segment = segment.trim();
            if segment.is_empty()
                || path_segments
                    .iter()
                    .any(|existing_segment| existing_segment == segment)
            {
                continue;
            }
            path_segments.push(segment.to_string());
        }
    };

    if let Some(path) = current_path {
        append_path_segments(path);
    }
    if let Some(path) = shell_path {
        append_path_segments(path);
    }
    for path in ["/usr/local/bin", "/usr/local/sbin"] {
        append_path_segments(path);
    }
    #[cfg(target_os = "macos")]
    for path in ["/opt/homebrew/bin", "/opt/homebrew/sbin"] {
        append_path_segments(path);
    }

    (!path_segments.is_empty()).then(|| path_segments.join(":"))
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
        // 1. 当前进程 PATH
        if let Ok(path) = std::env::var("PATH") {
            if let Some(found) = find_codex_in_path(&path) {
                return found;
            }
        }

        // 2. 从 app bundle 启动的 daemon 继承的 PATH 很精简（不含 Homebrew /
        //    npm-global 等），回退解析登录 shell 的 PATH 再找一遍。
        if let Some(shell_path) = login_shell_path() {
            if let Some(found) = find_codex_in_path(&shell_path) {
                return found;
            }
        }

        // 3. home 目录下的常见安装位置
        if let Ok(home) = std::env::var("HOME") {
            let home_candidates = [
                format!("{home}/.npm-global/bin/codex"),
                format!("{home}/.cargo/bin/codex"),
                format!("{home}/.local/bin/codex"),
                format!("{home}/.codex/bin/codex"),
            ];
            for c in &home_candidates {
                if std::path::Path::new(c).exists() {
                    return c.clone();
                }
            }
        }

        // 4. 系统级安装位置
        for c in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] {
            if std::path::Path::new(c).exists() {
                return c.to_string();
            }
        }

        // 兜底裸命令名（启动时如仍找不到会给出明确错误）
        "codex".to_string()
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

            let mut command = codex_command(executable);
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
                    let context_window = parse_codex_context_window(params);
                    let s = state.lock().await;
                    if let Some(active) = &s.active_turn {
                        let _ = active
                            .sender
                            .send(CodexProviderEvent::Usage(usage.clone()))
                            .await;
                        let _ = active
                            .sender
                            .send(CodexProviderEvent::ContextUsage {
                                tokens: usage.total,
                                window: context_window,
                            })
                            .await;
                    }
                }
            }
            method
                if method.to_ascii_lowercase().contains("compaction")
                    || method.to_ascii_lowercase().contains("compact") =>
            {
                if let Some(update) = parse_codex_compaction(method, params) {
                    let s = state.lock().await;
                    if let Some(active) = &s.active_turn {
                        let _ = active
                            .sender
                            .send(CodexProviderEvent::Compaction(update))
                            .await;
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
                if let Some(event) = parse_codex_compaction_item(&params["item"], "running")
                    .or_else(|| tool_started_event(&params["item"]))
                {
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
                if let Some(event) = parse_codex_compaction_item(&params["item"], "completed")
                    .or_else(|| tool_completed_event(&params["item"]))
                {
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
                    CodexProviderEvent::ContextUsage { .. } => {}
                    CodexProviderEvent::Compaction(_) => {}
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

fn parse_codex_context_window(params: &serde_json::Value) -> Option<i64> {
    params
        .pointer("/tokenUsage/modelContextWindow")
        .and_then(serde_json::Value::as_i64)
        .filter(|window| *window > 0)
}

/// 兼容不同 Codex app-server 版本的原生压缩通知命名。
///
/// Codex app-server 的压缩通知尚未稳定为一个公开 ACP 类型，因此这里只在通知名明确
/// 表示 compact/compaction 且 payload 含有可识别状态时转为内部事件，不根据 token usage
/// 推断压缩。
fn parse_codex_compaction(
    method: &str,
    params: &serde_json::Value,
) -> Option<CodexCompactionUpdate> {
    let id = params
        .get("compactionId")
        .or_else(|| params.get("id"))
        .or_else(|| params.get("compaction").and_then(|value| value.get("id")))
        .and_then(serde_json::Value::as_str)
        .unwrap_or(method)
        .to_string();
    let status = params
        .get("status")
        .and_then(serde_json::Value::as_str)
        .map(str::to_ascii_lowercase)
        .unwrap_or_else(|| {
            let method = method.to_ascii_lowercase();
            if method.contains("start") || method.contains("progress") {
                "running".to_string()
            } else if method.contains("fail") || method.contains("error") {
                "failed".to_string()
            } else {
                "completed".to_string()
            }
        });
    let status = match status.as_str() {
        "running" | "in_progress" | "started" => "running",
        "completed" | "complete" | "done" | "finished" => "completed",
        "failed" | "error" => "failed",
        _ => return None,
    };
    let value = params.get("compaction").unwrap_or(params);
    Some(CodexCompactionUpdate {
        id,
        status: status.to_string(),
        before_tokens: value
            .get("beforeTokens")
            .or_else(|| value.get("before_tokens"))
            .and_then(serde_json::Value::as_i64),
        after_tokens: value
            .get("afterTokens")
            .or_else(|| value.get("after_tokens"))
            .and_then(serde_json::Value::as_i64),
        summary: value
            .get("summary")
            .and_then(serde_json::Value::as_str)
            .map(str::to_string),
        error_message: value
            .get("errorMessage")
            .or_else(|| value.get("error_message"))
            .and_then(serde_json::Value::as_str)
            .map(str::to_string),
    })
}

fn parse_codex_compaction_item(
    item: &serde_json::Value,
    default_status: &str,
) -> Option<CodexProviderEvent> {
    let item_type = item
        .get("type")
        .and_then(serde_json::Value::as_str)?
        .to_ascii_lowercase();
    if !item_type.contains("compact") && !item_type.contains("compaction") {
        return None;
    }
    let mut payload = item.clone();
    if let Some(object) = payload.as_object_mut() {
        object
            .entry("status")
            .or_insert_with(|| serde_json::Value::String(default_status.to_string()));
    }
    parse_codex_compaction("item/compaction", &payload).map(CodexProviderEvent::Compaction)
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

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    #[cfg(unix)]
    use uuid::Uuid;

    /// 临时可执行的 fake codex 脚本（模仿 disco-backends 测试的 FakeCodexExecutable）。
    #[cfg(unix)]
    struct FakeCodex {
        directory: std::path::PathBuf,
        path: std::path::PathBuf,
    }

    #[cfg(unix)]
    impl FakeCodex {
        fn new(script: &str) -> Self {
            let directory =
                std::env::temp_dir().join(format!("disco-list-codex-{}", Uuid::new_v4()));
            std::fs::create_dir_all(&directory).unwrap();
            let path = directory.join("codex");
            std::fs::write(&path, script).unwrap();
            let mut permissions = std::fs::metadata(&path).unwrap().permissions();
            permissions.set_mode(0o700);
            std::fs::set_permissions(&path, permissions).unwrap();
            Self { directory, path }
        }

        fn path(&self) -> String {
            self.path.display().to_string()
        }
    }

    #[cfg(unix)]
    impl Drop for FakeCodex {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
            let _ = std::fs::remove_dir(&self.directory);
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn builds_runtime_path_for_gui_processes() {
        let runtime_path =
            build_codex_runtime_path(Some("/usr/bin:/bin"), Some("/Users/test/.npm-global/bin"))
                .unwrap();

        assert!(
            runtime_path
                .split(':')
                .any(|segment| segment == "/Users/test/.npm-global/bin")
        );
        assert!(
            runtime_path
                .split(':')
                .any(|segment| segment == "/opt/homebrew/bin")
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn list_codex_models_parses_model_list() {
        // fake app-server：处理 initialize 后响应一条 model/list。
        let fake = FakeCodex::new(
            r###"#!/bin/sh
read -r init_line
printf '%s\n' '{"id":0,"result":{"protocolVersion":"1"}}'
read -r init_notification
read -r list_line
printf '%s\n' '{"id":1,"result":{"data":[{"id":"gpt-5.6-sol","model":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}]},{"id":"internal-model","hidden":true}]}}'"###,
        );

        let entries = list_codex_models(&fake.path())
            .await
            .expect("fake app-server 应返回模型列表");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].id, "gpt-5.6-sol");
        assert_eq!(entries[0].display_name.as_deref(), Some("GPT-5.6-Sol"));
        assert_eq!(entries[0].default_reasoning_effort.as_deref(), Some("low"));
        let efforts = entries[0].supported_reasoning_efforts.as_ref().unwrap();
        assert_eq!(efforts.len(), 2);
        assert_eq!(efforts[0].reasoning_effort, "low");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn list_codex_models_reports_app_server_exit() {
        // 脚本启动后立即退出（不响应 initialize）→ 明确报错，且不挂起。
        let fake = FakeCodex::new("#!/bin/sh\nexit 1\n");
        let err = list_codex_models(&fake.path()).await.unwrap_err();
        assert!(err.to_string().contains("initialize"), "{err}");
    }

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
                },
                "modelContextWindow": 200000
            }
        });
        let usage = parse_codex_usage(&params).unwrap();
        assert_eq!(usage.input, 100);
        assert_eq!(usage.output, 50);
        assert_eq!(usage.total, 150);
        assert_eq!(usage.cached_input, Some(30));
        assert_eq!(usage.reasoning_output, Some(20));
        assert_eq!(parse_codex_context_window(&params), Some(200_000));
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
    fn parse_codex_compaction_notification() {
        let update = parse_codex_compaction(
            "thread/compaction/completed",
            &serde_json::json!({
                "compactionId": "cmp-1",
                "status": "completed",
                "beforeTokens": 1000,
                "afterTokens": 250,
                "summary": "保留关键上下文"
            }),
        )
        .unwrap();
        assert_eq!(update.id, "cmp-1");
        assert_eq!(update.status, "completed");
        assert_eq!(update.before_tokens, Some(1000));
        assert_eq!(update.after_tokens, Some(250));
        assert_eq!(update.summary.as_deref(), Some("保留关键上下文"));
    }

    #[test]
    fn parse_codex_compaction_item_lifecycle() {
        let update = parse_codex_compaction_item(
            &serde_json::json!({
                "type": "contextCompaction",
                "id": "cmp-item"
            }),
            "running",
        );
        assert!(matches!(
            update,
            Some(CodexProviderEvent::Compaction(CodexCompactionUpdate {
                id,
                status,
                ..
            })) if id == "cmp-item" && status == "running"
        ));
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

#[cfg(test)]
mod temp_gui_repro {
    use super::*;

    #[tokio::test]
    async fn gui_lean_path_repro() {
        // 模拟 GUI 启动的 daemon：PATH 精简，靠 login_shell_path 回退
        unsafe { std::env::set_var("PATH", "/usr/bin:/bin:/usr/sbin:/sbin") };
        let exe = CodexProvider::find_codex();
        eprintln!("==> find_codex() = {exe}");
        match list_codex_models(&exe).await {
            Ok(models) => eprintln!("OK: {} models", models.len()),
            Err(e) => eprintln!("ERR: {e}"),
        }
    }
}
