use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use async_trait::async_trait;
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use disco_core::{
    AgentBackend, AgentOutput, ApprovalManager, ApprovalRequest, BackendCapabilities, BackendRun,
    BackendRunRequest, BackendSession, CompactionMode, PreparedApproval,
};
use disco_protocol::types::{ApprovalDecision, ApprovalImpact, ModelCatalogEntry};
use eventsource_stream::Eventsource;
use reqwest::{Client, Method, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::{Mutex, mpsc};
use tokio_stream::StreamExt;
use tokio_stream::wrappers::ReceiverStream;
use tokio_util::sync::CancellationToken;
use tracing::warn;
use uuid::Uuid;

const SERVER_START_TIMEOUT: Duration = Duration::from_secs(10);
const HEALTH_PROBE_TIMEOUT: Duration = Duration::from_secs(1);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

const HANDLE_PREFIX: &str = "opencode:v1:";

/// OpenCode 的原生 session 句柄，同时携带项目目录，便于 daemon 重启后恢复会话。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct OpenCodeHandle {
    session_id: String,
    workspace_path: String,
}

/// daemon 托管的唯一 `opencode serve` 实例。
struct OpenCodeServer {
    base_url: String,
    username: String,
    password: String,
    client: Client,
    event_client: Client,
    context_windows: StdMutex<HashMap<(String, String), i64>>,
    child: StdMutex<Child>,
}

impl OpenCodeServer {
    fn start(binary: &str) -> Result<Self> {
        let listener =
            TcpListener::bind(("127.0.0.1", 0)).context("无法为 OpenCode server 保留本地端口")?;
        let port = listener
            .local_addr()
            .context("无法读取 OpenCode server 端口")?
            .port();
        drop(listener);

        let username = "opencode".to_string();
        let password = Uuid::new_v4().as_simple().to_string();
        let child = disco_tools::command_env::std_command(binary)
            .args([
                "serve",
                "--hostname",
                "127.0.0.1",
                "--port",
                &port.to_string(),
            ])
            .env("OPENCODE_SERVER_PASSWORD", &password)
            .env("OPENCODE_SERVER_USERNAME", &username)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| format!("无法启动 `opencode serve`：{binary}"))?;

        let server = Self {
            base_url: format!("http://127.0.0.1:{port}"),
            username,
            password,
            client: Client::builder()
                .timeout(REQUEST_TIMEOUT)
                .build()
                .context("无法创建 OpenCode HTTP 客户端")?,
            event_client: Client::builder()
                .build()
                .context("无法创建 OpenCode SSE 客户端")?,
            context_windows: StdMutex::new(HashMap::new()),
            child: StdMutex::new(child),
        };

        let started_at = Instant::now();
        loop {
            if health_probe(port, &server.username, &server.password) {
                return Ok(server);
            }
            if server
                .child
                .lock()
                .map_err(|_| anyhow!("OpenCode server 子进程锁已损坏"))?
                .try_wait()
                .context("无法检查 OpenCode server 状态")?
                .is_some()
            {
                bail!("OpenCode server 在启动期间退出");
            }
            if started_at.elapsed() >= SERVER_START_TIMEOUT {
                bail!("等待 OpenCode server 启动超时");
            }
            std::thread::sleep(Duration::from_millis(40));
        }
    }

    fn is_alive(&self) -> bool {
        self.child
            .lock()
            .ok()
            .and_then(|mut child| child.try_wait().ok())
            .is_some_and(|status| status.is_none())
    }

    async fn request_at(
        &self,
        method: Method,
        path: &str,
        directory: &Path,
        body: Option<Value>,
    ) -> Result<Value> {
        let response = self.send_at(method.clone(), path, directory, body).await?;
        let status = response.status();
        let text = response
            .text()
            .await
            .with_context(|| format!("无法读取 OpenCode 响应：{method} {path}"))?;
        if !status.is_success() {
            bail!("OpenCode 返回 HTTP {status}：{text}");
        }
        if text.trim().is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_str(&text)
            .with_context(|| format!("OpenCode 返回了无效 JSON：{method} {path}"))
    }

    async fn send_at(
        &self,
        method: Method,
        path: &str,
        directory: &Path,
        body: Option<Value>,
    ) -> Result<reqwest::Response> {
        let url = project_url(&self.base_url, path, directory)?;
        let mut request = self
            .client
            .request(method.clone(), url)
            .basic_auth(&self.username, Some(&self.password));
        if let Some(body) = body {
            request = request.json(&body);
        }
        request
            .send()
            .await
            .with_context(|| format!("OpenCode 请求失败：{method} {path}"))
    }

    async fn open_event_stream(&self, directory: &Path) -> Result<reqwest::Response> {
        let url = project_url(&self.base_url, "/event", directory)?;
        let response = self
            .event_client
            .get(url)
            .header("Accept", "text/event-stream")
            .basic_auth(&self.username, Some(&self.password))
            .send()
            .await
            .context("无法连接 OpenCode SSE 事件流")?;
        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            bail!("OpenCode SSE 返回 HTTP {status}：{body}");
        }
        Ok(response)
    }
}

impl Drop for OpenCodeServer {
    fn drop(&mut self) {
        let Ok(mut child) = self.child.lock() else {
            return;
        };
        if child.try_wait().ok().flatten().is_some() {
            return;
        }
        let _ = child.kill();
        let _ = child.wait();
    }
}

fn health_probe(port: u16, username: &str, password: &str) -> bool {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let Ok(mut stream) = TcpStream::connect_timeout(&address, HEALTH_PROBE_TIMEOUT) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(HEALTH_PROBE_TIMEOUT));
    let _ = stream.set_write_timeout(Some(HEALTH_PROBE_TIMEOUT));
    let credentials = BASE64.encode(format!("{username}:{password}"));
    if write!(
        stream,
        "GET /global/health HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Basic {credentials}\r\nConnection: close\r\n\r\n"
    )
    .and_then(|_| stream.flush())
    .is_err()
    {
        return false;
    }
    let mut response = [0_u8; 256];
    let Ok(size) = stream.read(&mut response) else {
        return false;
    };
    let head = String::from_utf8_lossy(&response[..size]);
    head.starts_with("HTTP/1.1 200") || head.starts_with("HTTP/1.0 200")
}

fn project_url(base_url: &str, path: &str, directory: &Path) -> Result<reqwest::Url> {
    let mut url = reqwest::Url::parse(&format!("{base_url}{path}"))
        .with_context(|| format!("无法构造 OpenCode URL：{base_url}{path}"))?;
    url.query_pairs_mut()
        .append_pair("directory", &directory.to_string_lossy());
    Ok(url)
}

/// OpenCode server backend。对外仍然只暴露 AgentBackend，不把 REST/SSE 泄漏到 daemon facade。
pub struct OpenCodeAdapter {
    reasoning_effort: Option<String>,
    server_manager: Arc<OpenCodeServerManager>,
}

/// daemon 进程内共享的 OpenCode server 生命周期管理器。
///
/// Provider runtime 更新时，旧 runtime 可能仍被活动任务持有；将 server 放在独立
/// manager 中可以避免 runtime 替换导致重复启动 `opencode serve`。
pub struct OpenCodeServerManager {
    executable: String,
    server: Mutex<Option<Arc<OpenCodeServer>>>,
}

impl OpenCodeAdapter {
    pub fn new(executable: String, reasoning_effort: Option<String>) -> Self {
        Self::new_with_server_manager(
            Arc::new(OpenCodeServerManager::new(executable)),
            reasoning_effort,
        )
    }

    pub fn new_with_server_manager(
        server_manager: Arc<OpenCodeServerManager>,
        reasoning_effort: Option<String>,
    ) -> Self {
        Self {
            server_manager,
            reasoning_effort,
        }
    }

    /// 通过 OpenCode server API 获取当前登录态下的模型目录。
    pub async fn fetch_model_catalog(
        &self,
        workspace_path: Option<&str>,
    ) -> Result<Vec<ModelCatalogEntry>> {
        let workspace = match workspace_path.filter(|path| !path.trim().is_empty()) {
            Some(path) => normalized_workspace(path)?,
            None => current_workspace()?,
        };
        let server = self.server().await?;
        let response = server
            .request_at(Method::GET, "/provider", &workspace, None)
            .await?;
        let catalog = model_catalog_from_response(&response);
        cache_context_windows(&server, &workspace, &catalog);
        Ok(catalog)
    }
}

impl OpenCodeServerManager {
    pub fn new(executable: String) -> Self {
        Self {
            executable,
            server: Mutex::new(None),
        }
    }

    async fn server(&self) -> Result<Arc<OpenCodeServer>> {
        let mut server_slot = self.server.lock().await;
        if let Some(server) = server_slot.as_ref() {
            if server.is_alive() {
                return Ok(server.clone());
            }
        }
        server_slot.take();

        let binary = self.executable.clone();
        let server = tokio::task::spawn_blocking(move || OpenCodeServer::start(&binary))
            .await
            .context("启动 OpenCode server 的任务异常退出")??;
        let server = Arc::new(server);
        *server_slot = Some(server.clone());
        Ok(server)
    }
}

impl OpenCodeAdapter {
    async fn server(&self) -> Result<Arc<OpenCodeServer>> {
        self.server_manager.server().await
    }

    async fn ensure_session(
        &self,
        session: &BackendSession,
        workspace_path: Option<&str>,
    ) -> Result<(Arc<OpenCodeServer>, String, OpenCodeHandle)> {
        let parsed_handle = session.backend_handle.as_deref().and_then(decode_handle);
        let workspace =
            if let Some(workspace_path) = workspace_path.filter(|path| !path.trim().is_empty()) {
                normalized_workspace(workspace_path)?
            } else if let Some(handle) = parsed_handle.as_ref() {
                normalized_workspace(&handle.workspace_path)?
            } else {
                bail!("OpenCode session 缺少项目目录，无法恢复会话")
            };
        let server = self.server().await?;

        let existing_session_id = parsed_handle
            .as_ref()
            .map(|handle| handle.session_id.as_str())
            .or(session.backend_handle.as_deref());
        let session_id = if let Some(session_id) = existing_session_id {
            // 兼容迁移前保存的纯 OpenCode session ID。
            server
                .request_at(
                    Method::GET,
                    &format!("/session/{}", encode_path_segment(session_id)),
                    &workspace,
                    None,
                )
                .await?;
            session_id.to_string()
        } else {
            let response = server
                .request_at(
                    Method::POST,
                    "/session",
                    &workspace,
                    Some(json!({"agent": "build"})),
                )
                .await?;
            response
                .get("id")
                .and_then(Value::as_str)
                .or_else(|| response.pointer("/data/id").and_then(Value::as_str))
                .filter(|id| !id.is_empty())
                .ok_or_else(|| anyhow!("OpenCode 创建 session 后未返回 session ID"))?
                .to_string()
        };

        // OpenCode 的 build agent 默认可能直接执行 shell；Disco 的审批流
        // 需要让权限事件回到 daemon，再由 UI 决定是否放行。
        let permission_path = format!("/session/{}", encode_path_segment(&session_id));
        server
            .request_at(
                Method::PATCH,
                &permission_path,
                &workspace,
                Some(json!({
                    "permission": [
                        {"permission": "bash", "pattern": "*", "action": "ask"},
                        {"permission": "edit", "pattern": "*", "action": "ask"}
                    ]
                })),
            )
            .await
            .context("无法配置 OpenCode session 权限")?;

        let handle = OpenCodeHandle {
            session_id: session_id.clone(),
            workspace_path: workspace.to_string_lossy().into_owned(),
        };
        Ok((server, session_id, handle))
    }
}

#[async_trait]
impl AgentBackend for OpenCodeAdapter {
    fn capabilities(&self) -> BackendCapabilities {
        BackendCapabilities {
            has_persistent_sessions: true,
            can_delete_session: true,
            compaction: CompactionMode::Native,
        }
    }

    async fn load_session(
        &self,
        session: &BackendSession,
        workspace_path: Option<String>,
    ) -> Result<()> {
        if session.backend_handle.is_none() {
            return Ok(());
        }
        self.ensure_session(session, workspace_path.as_deref())
            .await
            .map(|_| ())
    }

    async fn list_models(&self, workspace_path: Option<String>) -> Result<Vec<ModelCatalogEntry>> {
        self.fetch_model_catalog(workspace_path.as_deref()).await
    }

    async fn start_run(&self, request: BackendRunRequest) -> Result<BackendRun> {
        let prompt = request
            .messages
            .last()
            .map(|message| message.text.trim().to_string())
            .filter(|text| !text.is_empty())
            .ok_or_else(|| anyhow!("OpenCode run 缺少用户 prompt"))?;
        let (server, session_id, handle) = self
            .ensure_session(&request.session, request.workspace_path.as_deref())
            .await?;
        let backend_handle = encode_handle(&handle)?;
        let (event_tx, event_rx) = mpsc::channel(128);
        let workspace = PathBuf::from(&handle.workspace_path);

        if request.cancellation.is_cancelled() {
            let _ = event_tx.send(AgentOutput::Cancelled).await;
            return Ok(BackendRun {
                events: Box::pin(ReceiverStream::new(event_rx)),
                backend_handle: Some(backend_handle),
            });
        }

        let response = server.open_event_stream(&workspace).await?;
        let metadata_server = server.clone();
        let metadata_workspace = workspace.clone();
        tokio::spawn(async move {
            if let Ok(response) = metadata_server
                .request_at(Method::GET, "/provider", &metadata_workspace, None)
                .await
            {
                cache_context_windows_from_response(
                    &metadata_server,
                    &metadata_workspace,
                    &response,
                );
            }
        });
        let stop_stream = CancellationToken::new();
        let stream_stop = stop_stream.clone();
        let stream_server = server.clone();
        let stream_session_id = session_id.clone();
        let stream_events = event_tx.clone();
        let stream_approval_manager = request.approval_manager.clone();
        let stream_cancellation = request.cancellation.clone();
        let run_id = request.run_id;
        let permission_manager = request.approval_manager.clone();
        let permission_cancellation = request.cancellation.clone();
        let permission_ids = Arc::new(Mutex::new(HashSet::new()));
        let stream_permission_ids = permission_ids.clone();
        let stream_workspace = workspace.clone();
        tokio::spawn(async move {
            consume_event_stream(
                response,
                stream_server,
                stream_session_id,
                stream_workspace,
                run_id,
                stream_events,
                stream_approval_manager,
                stream_cancellation,
                stream_stop,
                stream_permission_ids,
            )
            .await;
        });

        // SSE 连接建立后再读取快照，覆盖 daemon 重启或短暂断线期间已经
        // 产生、但不会再次发送的权限请求；共享 ID 集合负责去重重叠事件。
        if let Ok(response) = server
            .request_at(Method::GET, "/permission", &workspace, None)
            .await
        {
            let requests = response
                .as_array()
                .or_else(|| response.pointer("/data").and_then(Value::as_array));
            if let Some(requests) = requests {
                for request in requests {
                    if request.get("sessionID").and_then(Value::as_str) != Some(&session_id) {
                        continue;
                    }
                    dispatch_permission(
                        run_id,
                        request,
                        server.clone(),
                        workspace.clone(),
                        event_tx.clone(),
                        permission_manager.clone(),
                        permission_cancellation.clone(),
                        permission_ids.clone(),
                    )
                    .await;
                }
            }
        }

        let prompt_path = format!("/session/{}/prompt_async", encode_path_segment(&session_id));
        let prompt_body = prompt_body(
            &prompt,
            &request.session.model,
            self.reasoning_effort.as_deref(),
        );
        if let Err(error) = server
            .request_at(Method::POST, &prompt_path, &workspace, Some(prompt_body))
            .await
        {
            stop_stream.cancel();
            let _ = event_tx
                .send(AgentOutput::Failed(format!(
                    "OpenCode prompt 失败：{error}"
                )))
                .await;
        }

        Ok(BackendRun {
            events: Box::pin(ReceiverStream::new(event_rx)),
            backend_handle: Some(backend_handle),
        })
    }

    async fn delete_session(
        &self,
        session: &BackendSession,
        workspace_path: Option<String>,
    ) -> Result<()> {
        let Some(raw_handle) = session.backend_handle.as_deref() else {
            return Ok(());
        };
        let parsed = decode_handle(raw_handle);
        let session_id = parsed
            .as_ref()
            .map(|handle| handle.session_id.as_str())
            .unwrap_or(raw_handle);
        let workspace =
            if let Some(workspace_path) = workspace_path.filter(|path| !path.trim().is_empty()) {
                normalized_workspace(&workspace_path)?
            } else if let Some(handle) = parsed.as_ref() {
                normalized_workspace(&handle.workspace_path)?
            } else {
                bail!("OpenCode session 缺少项目目录，无法删除会话")
            };
        let server = self.server().await?;
        let path = format!("/session/{}", encode_path_segment(session_id));
        let response = server
            .send_at(Method::DELETE, &path, &workspace, None)
            .await
            .with_context(|| format!("无法删除 OpenCode session {session_id}"))?;
        if response.status() == StatusCode::NOT_FOUND || response.status().is_success() {
            return Ok(());
        }
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        bail!("删除 OpenCode session 失败 HTTP {status}：{body}");
    }
}

async fn consume_event_stream(
    response: reqwest::Response,
    server: Arc<OpenCodeServer>,
    session_id: String,
    workspace: PathBuf,
    run_id: Uuid,
    event_tx: mpsc::Sender<AgentOutput>,
    approval_manager: Arc<ApprovalManager>,
    cancellation: CancellationToken,
    stop_stream: CancellationToken,
    permission_ids: Arc<Mutex<HashSet<String>>>,
) {
    let mut stream = response.bytes_stream().eventsource();
    let mut reasoning_parts = HashSet::new();
    let mut tools = HashMap::<String, ToolState>::new();
    loop {
        let next = tokio::select! {
            biased;
            _ = cancellation.cancelled() => {
                approval_manager.cancel_all().await;
                let path = format!("/session/{}/abort", encode_path_segment(&session_id));
                let _ = server
                    .request_at(Method::POST, &path, &workspace, None)
                    .await;
                let _ = event_tx.send(AgentOutput::Cancelled).await;
                return;
            }
            _ = stop_stream.cancelled() => return,
            event = stream.next() => event,
        };

        let Some(event) = next else {
            let _ = event_tx
                .send(AgentOutput::Failed(
                    "OpenCode SSE 事件流意外结束".to_string(),
                ))
                .await;
            return;
        };
        let event = match event {
            Ok(event) => event,
            Err(error) => {
                if !cancellation.is_cancelled() && !stop_stream.is_cancelled() {
                    let _ = event_tx
                        .send(AgentOutput::Failed(format!(
                            "OpenCode SSE 读取失败：{error}"
                        )))
                        .await;
                }
                return;
            }
        };
        if event.data.trim().is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(&event.data) else {
            warn!(data = %event.data, "忽略无法解析的 OpenCode SSE 数据");
            continue;
        };
        let properties = value.get("properties").unwrap_or(&Value::Null);
        if properties
            .get("sessionID")
            .or_else(|| properties.get("sessionId"))
            .and_then(Value::as_str)
            .is_some_and(|value| value != session_id)
        {
            continue;
        }

        let kind = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        match kind {
            "message.part.delta" => {
                let Some(delta) = properties.get("delta").and_then(Value::as_str) else {
                    continue;
                };
                if delta.is_empty() {
                    continue;
                }
                let part_id = properties.get("partID").and_then(Value::as_str);
                let is_reasoning = properties
                    .get("field")
                    .and_then(Value::as_str)
                    .is_some_and(|field| matches!(field, "reasoning" | "thinking"))
                    || part_id.is_some_and(|id| reasoning_parts.contains(id));
                let output = if is_reasoning {
                    AgentOutput::ReasoningDelta(delta.to_string())
                } else if properties.get("field").and_then(Value::as_str) == Some("text") {
                    AgentOutput::TextDelta(delta.to_string())
                } else {
                    continue;
                };
                if event_tx.send(output).await.is_err() {
                    return;
                }
            }
            "message.part.updated" => {
                let part = properties.get("part").unwrap_or(&Value::Null);
                let part_type = part.get("type").and_then(Value::as_str);
                if let Some(part_id) = part.get("id").and_then(Value::as_str) {
                    if matches!(part_type, Some("reasoning" | "thinking")) {
                        reasoning_parts.insert(part_id.to_string());
                    } else {
                        reasoning_parts.remove(part_id);
                    }
                }
                if part_type == Some("tool") {
                    for output in tool_outputs(part, &mut tools) {
                        if event_tx.send(output).await.is_err() {
                            return;
                        }
                    }
                }
            }
            "message.updated" => {
                if let Some(output) = context_usage_output(&server, &workspace, properties) {
                    if event_tx.send(output).await.is_err() {
                        return;
                    }
                }
            }
            "session.idle" => {
                approval_manager.cancel_all().await;
                let _ = event_tx.send(AgentOutput::Completed).await;
                return;
            }
            "session.error" => {
                let message = properties
                    .pointer("/error/message")
                    .or_else(|| properties.get("message"))
                    .and_then(Value::as_str)
                    .unwrap_or("OpenCode 返回错误");
                let _ = event_tx
                    .send(AgentOutput::Failed(message.to_string()))
                    .await;
                return;
            }
            "permission.replied" => {
                if let Some(id) = properties
                    .get("requestID")
                    .or_else(|| properties.get("id"))
                    .and_then(Value::as_str)
                {
                    permission_ids.lock().await.remove(id);
                }
            }
            _ if kind.starts_with("permission.") => {
                dispatch_permission(
                    run_id,
                    properties,
                    server.clone(),
                    workspace.clone(),
                    event_tx.clone(),
                    approval_manager.clone(),
                    cancellation.clone(),
                    permission_ids.clone(),
                )
                .await;
            }
            _ => {}
        }
    }
}

async fn dispatch_permission(
    run_id: Uuid,
    properties: &Value,
    server: Arc<OpenCodeServer>,
    workspace: PathBuf,
    event_tx: mpsc::Sender<AgentOutput>,
    approval_manager: Arc<ApprovalManager>,
    cancellation: CancellationToken,
    permission_ids: Arc<Mutex<HashSet<String>>>,
) {
    let Some((provider_request_id, approval)) = permission_request(run_id, properties) else {
        return;
    };
    if !permission_ids
        .lock()
        .await
        .insert(provider_request_id.clone())
    {
        return;
    }
    tokio::spawn(async move {
        resolve_permission(
            server,
            workspace,
            provider_request_id,
            approval,
            event_tx,
            approval_manager,
            cancellation,
        )
        .await;
    });
}

async fn resolve_permission(
    server: Arc<OpenCodeServer>,
    workspace: PathBuf,
    provider_request_id: String,
    approval: ApprovalRequest,
    event_tx: mpsc::Sender<AgentOutput>,
    approval_manager: Arc<ApprovalManager>,
    cancellation: CancellationToken,
) {
    let decision = match approval_manager.prepare_approval(&approval).await {
        PreparedApproval::SessionApproved => ApprovalDecision::ApproveOnce,
        PreparedApproval::Pending(pending) => {
            if cancellation.is_cancelled()
                || event_tx
                    .send(AgentOutput::approval_waiting(&approval))
                    .await
                    .is_err()
            {
                return;
            }
            tokio::select! {
                biased;
                _ = cancellation.cancelled() => return,
                decision = pending.wait() => decision,
            }
        }
    };

    let _ = event_tx
        .send(AgentOutput::ApprovalResolved {
            approval_id: approval.id,
            decision,
        })
        .await;
    let reply = match decision {
        ApprovalDecision::Decline => "reject",
        // Disco 自己维护会话级审批缓存；直接使用共享 server 的 `always`
        // 会把授权范围扩大到同一 server 的其他会话。
        ApprovalDecision::ApproveOnce | ApprovalDecision::ApproveForSession => "once",
    };
    let path = format!(
        "/permission/{}/reply",
        encode_path_segment(&provider_request_id)
    );
    if let Err(error) = server
        .request_at(
            Method::POST,
            &path,
            &workspace,
            Some(json!({"reply": reply})),
        )
        .await
    {
        let _ = event_tx
            .send(AgentOutput::Failed(format!(
                "无法回应 OpenCode 权限请求：{error}"
            )))
            .await;
    }
}

#[derive(Debug, Default)]
struct ToolState {
    name: String,
    arguments: String,
    started: bool,
    completed: bool,
}

fn tool_outputs(part: &Value, tools: &mut HashMap<String, ToolState>) -> Vec<AgentOutput> {
    let Some(id) = part
        .get("callID")
        .or_else(|| part.get("id"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
    else {
        return Vec::new();
    };
    let name = part
        .get("tool")
        .and_then(Value::as_str)
        .unwrap_or("tool")
        .to_string();
    let arguments = part
        .pointer("/state/input")
        .map(json_text)
        .unwrap_or_default();
    let status = part.pointer("/state/status").and_then(Value::as_str);
    let complete = matches!(status, Some("completed" | "error"));
    let entry = tools.entry(id.to_string()).or_default();
    if !name.is_empty() && entry.name.is_empty() {
        entry.name = name;
    }
    if !arguments.is_empty() {
        entry.arguments = arguments;
    }
    let mut outputs = Vec::new();
    if !entry.started {
        entry.started = true;
        outputs.push(AgentOutput::ToolStarted {
            tool_call_id: id.to_string(),
            tool_name: entry.name.clone(),
            arguments: entry.arguments.clone(),
        });
    }
    if complete && !entry.completed {
        entry.completed = true;
        let output = part
            .pointer("/state/error")
            .filter(|value| !value.is_null())
            .or_else(|| {
                part.pointer("/state/output")
                    .filter(|value| !value.is_null())
            })
            .map(json_text)
            .unwrap_or_default();
        outputs.push(AgentOutput::ToolCompleted {
            tool_call_id: id.to_string(),
            tool_name: entry.name.clone(),
            output,
        });
    }
    outputs
}

fn context_usage_output(
    server: &OpenCodeServer,
    workspace: &Path,
    properties: &Value,
) -> Option<AgentOutput> {
    let assistant_info = properties.get("info")?;
    if assistant_info.get("role").and_then(Value::as_str) != Some("assistant") {
        return None;
    }
    let context_tokens = opencode_context_tokens(assistant_info)?;
    let workspace = workspace.to_string_lossy().into_owned();
    let context_window = assistant_info
        .get("providerID")
        .and_then(Value::as_str)
        .zip(assistant_info.get("modelID").and_then(Value::as_str))
        .and_then(|(provider, model)| {
            server.context_windows.lock().ok().and_then(|windows| {
                windows
                    .get(&(workspace, format!("{provider}/{model}")))
                    .copied()
            })
        })
        .filter(|window| *window > 0);
    Some(AgentOutput::ContextUsage {
        tokens: context_tokens,
        window: context_window,
    })
}

fn opencode_context_tokens(assistant_info: &Value) -> Option<i64> {
    let token_fields = assistant_info.get("tokens")?;
    token_fields
        .get("total")
        .and_then(Value::as_i64)
        .filter(|total_tokens| *total_tokens > 0)
        .or_else(|| {
            [
                token_fields.get("input"),
                token_fields.get("output"),
                token_fields.pointer("/cache/read"),
                token_fields.pointer("/cache/write"),
            ]
            .into_iter()
            .flatten()
            .filter_map(Value::as_i64)
            .try_fold(0_i64, i64::checked_add)
            .filter(|total_tokens| *total_tokens > 0)
        })
}

fn cache_context_windows(server: &OpenCodeServer, workspace: &Path, catalog: &[ModelCatalogEntry]) {
    let Ok(mut windows) = server.context_windows.lock() else {
        return;
    };
    let workspace = workspace.to_string_lossy().into_owned();
    for entry in catalog {
        if let Some(size) = entry.context_window.filter(|size| *size > 0) {
            windows.insert((workspace.clone(), entry.id.clone()), size);
        }
    }
}

fn cache_context_windows_from_response(
    server: &OpenCodeServer,
    workspace: &Path,
    response: &Value,
) {
    let catalog = model_catalog_from_response(response);
    cache_context_windows(server, workspace, &catalog);
}

fn permission_request(run_id: Uuid, properties: &Value) -> Option<(String, ApprovalRequest)> {
    let request = ["permission", "request", "info"]
        .iter()
        .find_map(|key| properties.get(*key))
        .filter(|value| value.get("id").is_some())
        .unwrap_or(properties);
    let provider_request_id = request.get("id").and_then(Value::as_str)?.to_string();
    let permission = request
        .get("permission")
        .and_then(Value::as_str)
        .unwrap_or("permission");
    let patterns = request
        .get("patterns")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_string)
        .collect::<Vec<_>>();
    let title = if patterns.is_empty() {
        format!("OpenCode 请求权限：{permission}")
    } else {
        patterns.join(", ")
    };
    let fingerprint = format!("opencode:{permission}:{}", patterns.join("|"));
    let approval = ApprovalRequest {
        id: Uuid::new_v4(),
        run_id,
        kind: "permission".to_string(),
        title,
        reason: Some(format!("OpenCode 请求使用 {permission} 权限")),
        impact: ApprovalImpact::Permission {
            scope: permission.to_string(),
            description: patterns.join(", "),
        },
        fingerprint,
        allows_session_approval: true,
    };
    Some((provider_request_id, approval))
}

fn prompt_body(text: &str, model: &str, reasoning_effort: Option<&str>) -> Value {
    let mut body = json!({
        "agent": "build",
        "parts": [{"type": "text", "text": text}],
    });
    if let Some((provider_id, model_id)) = model.split_once('/') {
        body["model"] = json!({"providerID": provider_id, "modelID": model_id});
    }
    if let Some(variant) = reasoning_effort.filter(|value| !value.is_empty()) {
        body["variant"] = json!(variant);
    }
    body
}

fn model_catalog_from_response(response: &Value) -> Vec<ModelCatalogEntry> {
    if response.get("all").is_some() {
        return provider_model_catalog_from_response(response);
    }

    // 保留 v2 `/api/model` 响应的兼容解析，便于处理旧 server 或历史缓存。
    let models = response
        .pointer("/data")
        .and_then(Value::as_array)
        .or_else(|| response.as_array());
    models
        .into_iter()
        .flatten()
        .filter_map(model_catalog_entry)
        .collect()
}

fn provider_model_catalog_from_response(response: &Value) -> Vec<ModelCatalogEntry> {
    let connected = response
        .get("connected")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect::<HashSet<_>>();
    let Some(providers) = response.get("all").and_then(Value::as_array) else {
        return Vec::new();
    };

    let mut seen = HashSet::new();
    providers
        .iter()
        .filter_map(|provider| {
            let provider_id = provider.get("id").and_then(Value::as_str)?;
            if !connected.contains(provider_id) {
                return None;
            }
            Some((provider_id, provider.get("models")?.as_object()?))
        })
        .flat_map(|(provider_id, models)| models.values().map(move |model| (provider_id, model)))
        .filter_map(|(provider_id, model)| {
            let entry = model_catalog_entry_with_provider(model, provider_id)?;
            seen.insert(entry.id.clone()).then_some(entry)
        })
        .collect()
}

fn model_catalog_entry(model: &Value) -> Option<ModelCatalogEntry> {
    let provider = model.get("providerID").and_then(Value::as_str);
    model_catalog_entry_with_provider(model, provider.unwrap_or(""))
}

fn model_catalog_entry_with_provider(
    model: &Value,
    fallback_provider: &str,
) -> Option<ModelCatalogEntry> {
    let model_id = model.get("id").and_then(Value::as_str)?.trim();
    if model_id.is_empty() {
        return None;
    }
    let provider = model
        .get("providerID")
        .and_then(Value::as_str)
        .filter(|provider| !provider.is_empty())
        .unwrap_or(fallback_provider);
    let full_id = if provider.is_empty() {
        model_id.to_string()
    } else {
        format!("{provider}/{model_id}")
    };
    let display_name = model
        .get("name")
        .or_else(|| model.get("displayName"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let context_window = model
        .pointer("/limit/context")
        .and_then(Value::as_i64)
        .filter(|value| *value > 0);
    let supported_reasoning_efforts = model
        .get("variants")
        .and_then(Value::as_object)
        .map(|variants| variants.keys().cloned().collect());
    Some(ModelCatalogEntry {
        id: full_id,
        display_name,
        context_window,
        supported_reasoning_efforts,
        default_reasoning_effort: None,
    })
}

fn current_workspace() -> Result<PathBuf> {
    std::env::current_dir().context("无法确定 OpenCode workspace")
}

fn normalized_workspace(value: &str) -> Result<PathBuf> {
    let path = PathBuf::from(value);
    if !path.is_absolute() {
        bail!("OpenCode 项目目录必须是绝对路径：{value}");
    }
    Ok(path)
}

fn encode_handle(handle: &OpenCodeHandle) -> Result<String> {
    Ok(format!(
        "{HANDLE_PREFIX}{}",
        serde_json::to_string(handle).context("无法编码 OpenCode session handle")?
    ))
}

fn decode_handle(value: &str) -> Option<OpenCodeHandle> {
    value
        .strip_prefix(HANDLE_PREFIX)
        .or_else(|| value.strip_prefix("opencode:"))
        .and_then(|value| serde_json::from_str(value).ok())
}

fn encode_path_segment(value: &str) -> String {
    value
        .bytes()
        .flat_map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                vec![byte as char]
            }
            byte => format!("%{byte:02X}").chars().collect(),
        })
        .collect()
}

fn json_text(value: &Value) -> String {
    match value {
        Value::String(value) => value.clone(),
        value => serde_json::to_string(value).unwrap_or_else(|_| "null".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_catalog_uses_provider_qualified_ids_and_context_window() {
        let catalog = model_catalog_from_response(&json!({
            "all": [{
                "id": "opencode-go",
                "models": {
                    "gpt-5": {
                        "providerID": "opencode-go",
                        "id": "gpt-5",
                        "name": "GPT-5",
                        "limit": {"context": 200000},
                        "variants": {"high": {}, "max": {}}
                    }
                }
            }],
            "connected": ["opencode-go"]
        }));
        assert_eq!(catalog.len(), 1);
        assert_eq!(catalog[0].id, "opencode-go/gpt-5");
        assert_eq!(catalog[0].display_name.as_deref(), Some("GPT-5"));
        assert_eq!(catalog[0].context_window, Some(200000));
        assert_eq!(
            catalog[0].supported_reasoning_efforts,
            Some(vec!["high".to_string(), "max".to_string()])
        );
    }

    #[test]
    fn model_catalog_ignores_disconnected_providers() {
        let catalog = model_catalog_from_response(&json!({
            "all": [{
                "id": "configured",
                "models": {
                    "model-a": {"id": "model-a", "name": "Model A"}
                }
            }, {
                "id": "disconnected",
                "models": {
                    "model-b": {"id": "model-b", "name": "Model B"}
                }
            }],
            "connected": ["configured"]
        }));
        assert_eq!(
            catalog
                .iter()
                .map(|entry| entry.id.as_str())
                .collect::<Vec<_>>(),
            ["configured/model-a"]
        );
    }

    #[test]
    fn encoded_handle_preserves_workspace_for_delete_after_restart() {
        let handle = OpenCodeHandle {
            session_id: "ses_1".to_string(),
            workspace_path: "/tmp/project with spaces".to_string(),
        };
        let encoded = encode_handle(&handle).unwrap();
        assert_eq!(
            decode_handle(&encoded).unwrap().workspace_path,
            handle.workspace_path
        );
        assert_eq!(encode_path_segment("per/1"), "per%2F1");
    }

    #[test]
    fn project_scoped_routes_encode_directory_as_a_query_parameter() {
        let url = project_url(
            "http://127.0.0.1:4096",
            "/session/ses_1/prompt_async",
            Path::new("/tmp/project with spaces"),
        )
        .unwrap();
        assert_eq!(url.path(), "/session/ses_1/prompt_async");
        assert_eq!(
            url.query_pairs()
                .find(|(key, _)| key == "directory")
                .map(|(_, value)| value.into_owned()),
            Some("/tmp/project with spaces".to_string())
        );
    }

    #[test]
    fn versioned_handles_remain_compatible_with_legacy_handles() {
        let handle = OpenCodeHandle {
            session_id: "ses_1".to_string(),
            workspace_path: "/tmp/project".to_string(),
        };
        let encoded = encode_handle(&handle).unwrap();
        assert!(encoded.starts_with(HANDLE_PREFIX));
        assert_eq!(decode_handle(&encoded).unwrap().session_id, "ses_1");
        assert_eq!(
            decode_handle(&format!(
                "opencode:{}",
                serde_json::to_string(&handle).unwrap()
            ))
            .unwrap()
            .workspace_path,
            "/tmp/project"
        );
    }

    #[test]
    fn permission_request_generates_stable_session_approval_fingerprint() {
        let (_, approval) = permission_request(
            Uuid::nil(),
            &json!({
                "id": "per_1",
                "permission": "edit",
                "patterns": ["src/**"]
            }),
        )
        .unwrap();
        assert_eq!(approval.kind, "permission");
        assert_eq!(approval.fingerprint, "opencode:edit:src/**");
        assert!(approval.allows_session_approval);
    }

    #[test]
    fn tool_updates_emit_start_once_and_completion_once() {
        let part = json!({
            "type": "tool",
            "callID": "call_1",
            "tool": "shell",
            "state": {"input": {"command": "pwd"}, "status": "running"}
        });
        let mut tools = HashMap::new();
        assert!(matches!(
            tool_outputs(&part, &mut tools).as_slice(),
            [AgentOutput::ToolStarted { tool_call_id, .. }] if tool_call_id == "call_1"
        ));
        assert!(tool_outputs(&part, &mut tools).is_empty());

        let completed = json!({
            "type": "tool",
            "callID": "call_1",
            "tool": "shell",
            "state": {"status": "completed", "output": "ok"}
        });
        assert!(matches!(
            tool_outputs(&completed, &mut tools).as_slice(),
            [AgentOutput::ToolCompleted { output, .. }] if output == "ok"
        ));
        assert!(tool_outputs(&completed, &mut tools).is_empty());
    }

    #[test]
    fn context_tokens_fall_back_to_components_when_total_is_zero() {
        let info = json!({
            "tokens": {
                "total": 0,
                "input": 100,
                "output": 20,
                "cache": {"read": 3, "write": 2}
            }
        });

        assert_eq!(opencode_context_tokens(&info), Some(125));
    }
}
