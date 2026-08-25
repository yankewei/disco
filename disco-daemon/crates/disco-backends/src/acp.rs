use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::schema::v1::{
    CancelNotification, CloseSessionRequest, ContentBlock, DeleteSessionRequest, ErrorCode,
    InitializeRequest, InitializeResponse, LoadSessionRequest, NewSessionRequest, PermissionOption,
    PermissionOptionKind, PromptRequest, RequestPermissionOutcome, RequestPermissionRequest,
    RequestPermissionResponse, SelectedPermissionOutcome, SessionConfigId, SessionConfigKind,
    SessionConfigOption, SessionConfigOptionValue, SessionConfigSelectOptions, SessionId,
    SessionUpdate, SetSessionConfigOptionRequest, StopReason, ToolCall, ToolCallStatus,
    ToolCallUpdate, ToolKind,
};
use agent_client_protocol::{
    AcpAgent, AcpAgentConfig, Agent, Client, ConnectTo, ConnectionTo, JsonRpcMessage,
    JsonRpcNotification, Responder, UntypedMessage,
};
use anyhow::{Context, Result, anyhow, bail};
use async_trait::async_trait;
use disco_core::{
    AgentBackend, AgentOutput, ApprovalManager, ApprovalRequest, BackendCapabilities, BackendRun,
    BackendRunRequest, BackendSession, CompactionMode, CompactionUpdate, PreparedApproval,
};
use disco_protocol::types::{ApprovalDecision, ApprovalImpact, CompactionStatus};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio::time::{Duration, timeout};
use tokio_stream::wrappers::UnboundedReceiverStream;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

/// 连接外部 ACP agent 的 backend adapter。
///
/// Adapter 持有一条已初始化的 ACP 长连接；下游 session ID 仅作为 Disco 的不透明
/// `backend_handle`。ACP 通知、权限请求和连接生命周期不会泄漏到 AgentBackend interface。
pub struct AcpAdapter {
    connection: ConnectionTo<Agent>,
    capabilities: BackendCapabilities,
    can_load_sessions: bool,
    active_run_by_session: ActiveRunMap,
    loaded_sessions: Mutex<HashSet<SessionId>>,
    shutdown: CancellationToken,
    connection_alive: Arc<AtomicBool>,
    session_config_options: Vec<SessionConfigSelection>,
}

/// 每次创建/恢复 session 后下发给 ACP agent 的配置项（`session/set_config_option`）。
///
/// 例如 opencode 的模型（config_id `model`）与思考级别（config_id `effort`）。
#[derive(Debug, Clone)]
pub struct SessionConfigSelection {
    pub config_id: String,
    pub value: String,
}

type ActiveRunMap = Arc<Mutex<HashMap<SessionId, AcpRunContext>>>;

#[derive(Clone)]
struct AcpRunContext {
    run_id: Uuid,
    approval_manager: Arc<ApprovalManager>,
    cancellation: CancellationToken,
    event_tx: mpsc::UnboundedSender<AgentOutput>,
    tool_title_by_id: Arc<StdMutex<HashMap<String, String>>>,
}

/// 允许接收 ACP v1 尚未纳入 SDK 枚举的 `compaction_update`，避免未知 update
/// 因反序列化失败而丢失。已知 update 仍在收到后转换为 SDK 类型处理。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawSessionNotification {
    session_id: SessionId,
    update: serde_json::Value,
}

#[derive(Debug, Clone)]
struct RawExtensionNotification {
    method: Arc<str>,
    params: serde_json::Value,
}

#[derive(Debug, Clone)]
enum AcpAgentNotification {
    Session(RawSessionNotification),
    Extension(RawExtensionNotification),
}

impl JsonRpcMessage for AcpAgentNotification {
    fn matches_method(method: &str) -> bool {
        method == "session/update" || method.starts_with('_')
    }

    fn method(&self) -> &str {
        match self {
            Self::Session(_) => "session/update",
            Self::Extension(notification) => &notification.method,
        }
    }

    fn to_untyped_message(&self) -> agent_client_protocol::Result<UntypedMessage> {
        match self {
            Self::Session(notification) => UntypedMessage::new(self.method(), notification),
            Self::Extension(notification) => {
                UntypedMessage::new(self.method(), &notification.params)
            }
        }
    }

    fn parse_message(
        method: &str,
        params: &impl serde::Serialize,
    ) -> agent_client_protocol::Result<Self> {
        if method == "session/update" {
            return agent_client_protocol::util::json_cast_params(params).map(Self::Session);
        }
        if method.starts_with('_') {
            let params = serde_json::to_value(params).map_err(|error| {
                agent_client_protocol::Error::internal_error().data(error.to_string())
            })?;
            return Ok(Self::Extension(RawExtensionNotification {
                method: Arc::from(method),
                params,
            }));
        }
        Err(agent_client_protocol::Error::method_not_found())
    }
}

impl JsonRpcNotification for AcpAgentNotification {}

impl AcpAdapter {
    /// 启动外部 ACP agent 并完成协议初始化。
    pub async fn connect(config: AcpAgentConfig) -> Result<Self> {
        Self::connect_with_session_config(config, Vec::new()).await
    }

    /// 启动外部 ACP agent 并完成协议初始化；session 创建/恢复后按序下发配置项。
    pub async fn connect_with_session_config(
        config: AcpAgentConfig,
        session_config_options: Vec<SessionConfigSelection>,
    ) -> Result<Self> {
        Self::connect_transport(AcpAgent::new(config), session_config_options).await
    }

    async fn connect_transport(
        transport: impl ConnectTo<Client>,
        session_config_options: Vec<SessionConfigSelection>,
    ) -> Result<Self> {
        let active_run_by_session = ActiveRunMap::default();
        let shutdown = CancellationToken::new();
        let connection_alive = Arc::new(AtomicBool::new(false));
        let (ready_tx, ready_rx) = oneshot::channel();

        let notification_runs = active_run_by_session.clone();
        let permission_runs = active_run_by_session.clone();
        let connection_shutdown = shutdown.clone();
        let task_connection_alive = connection_alive.clone();
        tokio::spawn(async move {
            let initialized_connection_alive = task_connection_alive.clone();
            let result = Client
                .builder()
                .on_receive_notification(
                    async move |notification: AcpAgentNotification, _connection| {
                        match notification {
                            AcpAgentNotification::Session(notification) => {
                                forward_session_update(notification, &notification_runs).await;
                            }
                            AcpAgentNotification::Extension(notification) => {
                                forward_extension_notification(notification, &notification_runs)
                                    .await;
                            }
                        }
                        Ok(())
                    },
                    agent_client_protocol::on_receive_notification!(),
                )
                .on_receive_request(
                    async move |request: RequestPermissionRequest,
                                responder: Responder<RequestPermissionResponse>,
                                connection| {
                        forward_permission_request(request, responder, connection, &permission_runs)
                            .await
                    },
                    agent_client_protocol::on_receive_request!(),
                )
                .connect_with(transport, async move |connection: ConnectionTo<Agent>| {
                    let mut initialize_params = serde_json::to_value(InitializeRequest::new(
                        ProtocolVersion::V1,
                    ))
                    .map_err(|error| {
                        agent_client_protocol::Error::internal_error()
                            .data(format!("ACP 初始化参数编码失败：{error}"))
                    })?;
                    initialize_params["clientCapabilities"]["session"]["compaction"] =
                        serde_json::json!({});
                    let initialization = connection
                        .send_request(UntypedMessage::new("initialize", initialize_params)?)
                        .block_task()
                        .await
                        .and_then(|value| {
                            serde_json::from_value::<InitializeResponse>(value).map_err(|error| {
                                agent_client_protocol::Error::internal_error()
                                    .data(format!("ACP 初始化响应解析失败：{error}"))
                            })
                        });
                    match initialization {
                        Ok(response) if response.protocol_version == ProtocolVersion::V1 => {
                            initialized_connection_alive.store(true, Ordering::Release);
                            let _ = ready_tx
                                .send(Ok((connection.clone(), response.agent_capabilities)));
                        }
                        Ok(response) => {
                            let message = format!(
                                "ACP agent 协商了不支持的协议版本: {:?}",
                                response.protocol_version
                            );
                            let _ = ready_tx.send(Err(message.clone()));
                            return Err(
                                agent_client_protocol::Error::internal_error().data(message)
                            );
                        }
                        Err(error) => {
                            let message = format!("ACP 初始化失败: {error}");
                            let _ = ready_tx.send(Err(message));
                            return Err(error);
                        }
                    }

                    connection_shutdown.cancelled().await;
                    Ok(())
                })
                .await;

            task_connection_alive.store(false, Ordering::Release);
            if let Err(error) = result {
                tracing::warn!(%error, "ACP agent 连接已终止");
            }
        });

        let (connection, agent_capabilities) = ready_rx
            .await
            .context("ACP agent 在初始化完成前关闭了连接")?
            .map_err(|message| anyhow!(message))?;
        let capabilities = BackendCapabilities {
            has_persistent_sessions: agent_capabilities.load_session,
            can_delete_session: agent_capabilities.session_capabilities.delete.is_some(),
            compaction: CompactionMode::Native,
        };

        Ok(Self {
            connection,
            capabilities,
            can_load_sessions: agent_capabilities.load_session,
            active_run_by_session,
            loaded_sessions: Mutex::new(HashSet::new()),
            shutdown,
            connection_alive,
            session_config_options,
        })
    }

    async fn ensure_session(
        &self,
        session: &BackendSession,
        workspace_path: Option<&str>,
    ) -> Result<SessionId> {
        let workspace = match workspace_path {
            Some(path) => PathBuf::from(path),
            None => std::env::current_dir().context("无法确定 ACP session 的工作目录")?,
        };
        if !workspace.is_absolute() {
            bail!(
                "ACP session 的工作目录必须是绝对路径: {}",
                workspace.display()
            );
        }

        if let Some(handle) = session.backend_handle.as_deref() {
            let session_id = SessionId::new(handle);
            if self.loaded_sessions.lock().await.contains(&session_id) {
                return Ok(session_id);
            }
            if !self.can_load_sessions {
                bail!("ACP agent 不支持恢复已有 session {handle}");
            }
            self.connection
                .send_request(LoadSessionRequest::new(session_id.clone(), workspace))
                .block_task()
                .await
                .with_context(|| format!("无法恢复 ACP session {handle}"))?;
            // session/load 返回的是历史 session 的配置。不要把当前 Provider profile
            // 的配置重新下发，否则切换模型后加载旧会话会改变它的运行语义。
            self.loaded_sessions.lock().await.insert(session_id.clone());
            return Ok(session_id);
        }

        let response = self
            .connection
            .send_request(NewSessionRequest::new(workspace))
            .block_task()
            .await
            .context("无法创建 ACP session")?;
        self.apply_session_config_options(&response.session_id, response.config_options)
            .await?;
        self.loaded_sessions
            .lock()
            .await
            .insert(response.session_id.clone());
        Ok(response.session_id)
    }

    /// 按序下发 session 配置项；依据 agent 返回的最新 configOptions 校验取值，
    /// 不可用或下发失败时返回错误，避免用户选择的模型/推理档位被静默忽略。
    async fn apply_session_config_options(
        &self,
        session_id: &SessionId,
        initial_options: Option<Vec<SessionConfigOption>>,
    ) -> Result<()> {
        let mut latest_options = initial_options;
        for selection in &self.session_config_options {
            if let Some(options) = &latest_options {
                match find_select_option(options, &selection.config_id, &selection.value) {
                    SelectionCheck::Supported => {}
                    SelectionCheck::UnknownOption => {
                        bail!(
                            "ACP agent 未提供请求的 session 配置项 {}={}",
                            selection.config_id,
                            selection.value
                        );
                    }
                    SelectionCheck::UnsupportedValue => {
                        bail!(
                            "当前模型不支持请求的 session 配置取值 {}={}",
                            selection.config_id,
                            selection.value
                        );
                    }
                }
            }
            let request = SetSessionConfigOptionRequest::new(
                session_id.clone(),
                SessionConfigId::new(selection.config_id.clone()),
                SessionConfigOptionValue::value_id(selection.value.clone()),
            );
            match self.connection.send_request(request).block_task().await {
                Ok(response) => {
                    tracing::debug!(
                        config_id = %selection.config_id,
                        value = %selection.value,
                        "已下发 ACP session 配置项"
                    );
                    latest_options = Some(response.config_options);
                }
                Err(error) => {
                    return Err(error).with_context(|| {
                        format!(
                            "无法下发 ACP session 配置项 {}={}",
                            selection.config_id, selection.value
                        )
                    });
                }
            }
        }
        Ok(())
    }

    /// 创建临时 session 读取 agent 的 session configOptions，读完后关闭该 session。
    ///
    /// 用于在真实会话之前获取 agent 的模型/配置目录（如下拉列表数据源）。
    pub async fn fetch_session_config_options(&self) -> Result<Vec<SessionConfigOption>> {
        let workspace = std::env::current_dir().context("无法确定临时 ACP session 的工作目录")?;
        let response = self
            .connection
            .send_request(NewSessionRequest::new(workspace))
            .block_task()
            .await
            .context("无法创建临时 ACP session")?;
        let options = response.config_options.unwrap_or_default();
        if let Err(error) = self
            .connection
            .send_request(CloseSessionRequest::new(response.session_id.clone()))
            .block_task()
            .await
        {
            tracing::warn!(session_id = %response.session_id, %error, "无法关闭临时 ACP session");
        }
        Ok(options)
    }

    /// 将临时 session 的模型切换到指定值，并读取该模型生效后的配置能力。
    ///
    /// OpenCode 会在模型变化后刷新 effort 等 model config 选项，因此不能只读取
    /// session/new 的初始快照。
    pub async fn fetch_session_config_options_for_model(
        &self,
        model: &str,
    ) -> Result<Vec<SessionConfigOption>> {
        let workspace = std::env::current_dir().context("无法确定临时 ACP session 的工作目录")?;
        let response = self
            .connection
            .send_request(NewSessionRequest::new(workspace))
            .block_task()
            .await
            .context("无法创建模型能力探测 ACP session")?;
        let session_id = response.session_id.clone();
        let result = async {
            let response = self
                .connection
                .send_request(SetSessionConfigOptionRequest::new(
                    session_id.clone(),
                    SessionConfigId::new("model"),
                    SessionConfigOptionValue::value_id(model.to_string()),
                ))
                .block_task()
                .await
                .with_context(|| format!("无法切换 ACP 模型 {model}"))?;
            Ok(response.config_options)
        }
        .await;
        if let Err(error) = self
            .connection
            .send_request(CloseSessionRequest::new(session_id.clone()))
            .block_task()
            .await
        {
            tracing::warn!(session_id = %session_id, %error, "无法关闭模型能力探测 ACP session");
        }
        result
    }
}

enum SelectionCheck {
    Supported,
    UnknownOption,
    UnsupportedValue,
}

/// 在 agent 返回的 configOptions 中校验某个配置取值是否可用。
fn find_select_option(
    options: &[SessionConfigOption],
    config_id: &str,
    value: &str,
) -> SelectionCheck {
    let Some(option) = options
        .iter()
        .find(|option| option.id.0.as_ref() == config_id)
    else {
        return SelectionCheck::UnknownOption;
    };
    let SessionConfigKind::Select(select) = &option.kind else {
        return SelectionCheck::Supported;
    };
    let values: Vec<&str> = match &select.options {
        SessionConfigSelectOptions::Ungrouped(entries) => {
            entries.iter().map(|entry| entry.value.0.as_ref()).collect()
        }
        SessionConfigSelectOptions::Grouped(groups) => groups
            .iter()
            .flat_map(|group| group.options.iter())
            .map(|entry| entry.value.0.as_ref())
            .collect(),
        _ => return SelectionCheck::Supported,
    };
    if values.iter().any(|entry| *entry == value) {
        SelectionCheck::Supported
    } else {
        SelectionCheck::UnsupportedValue
    }
}

impl Drop for AcpAdapter {
    fn drop(&mut self) {
        self.shutdown.cancel();
    }
}

#[async_trait]
impl AgentBackend for AcpAdapter {
    fn capabilities(&self) -> BackendCapabilities {
        self.capabilities
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
            .await?;
        Ok(())
    }

    async fn start_run(&self, request: BackendRunRequest) -> Result<BackendRun> {
        if !self.connection_alive.load(Ordering::Acquire) {
            bail!("ACP agent 连接不可用");
        }
        let prompt = request
            .messages
            .last()
            .map(|message| message.text.clone())
            .filter(|text| !text.is_empty())
            .ok_or_else(|| anyhow!("ACP run 缺少用户 prompt"))?;
        let session_id = self
            .ensure_session(&request.session, request.workspace_path.as_deref())
            .await?;
        let backend_handle = session_id.to_string();
        let (event_tx, event_rx) = mpsc::unbounded_channel();
        if request.cancellation.is_cancelled() {
            let _ = event_tx.send(AgentOutput::Cancelled);
            return Ok(BackendRun {
                events: Box::pin(UnboundedReceiverStream::new(event_rx)),
                backend_handle: Some(backend_handle),
            });
        }
        let run_context = AcpRunContext {
            run_id: request.run_id,
            approval_manager: request.approval_manager.clone(),
            cancellation: request.cancellation.clone(),
            event_tx: event_tx.clone(),
            tool_title_by_id: Arc::new(StdMutex::new(HashMap::new())),
        };

        let mut active_runs = self.active_run_by_session.lock().await;
        if active_runs.contains_key(&session_id) {
            bail!("ACP session {session_id} 已有活动 run");
        }
        active_runs.insert(session_id.clone(), run_context);
        drop(active_runs);

        let prompt_request = self
            .connection
            .send_request(PromptRequest::new(session_id.clone(), vec![prompt.into()]));
        let connection = self.connection.clone();
        let active_runs = self.active_run_by_session.clone();
        let shutdown = self.shutdown.clone();
        let connection_alive = self.connection_alive.clone();
        tokio::spawn(async move {
            let prompt_task = prompt_request.block_task();
            tokio::pin!(prompt_task);
            let terminal = tokio::select! {
                biased;
                _ = request.cancellation.cancelled() => {
                    request.approval_manager.cancel_all().await;
                    if let Err(error) = connection
                        .send_notification(CancelNotification::new(session_id.clone()))
                    {
                        tracing::warn!(%error, "无法向 ACP agent 发送 session/cancel");
                    }
                    match timeout(Duration::from_secs(10), &mut prompt_task).await {
                        Ok(_) => AgentOutput::Cancelled,
                        Err(_) => {
                            connection_alive.store(false, Ordering::Release);
                            shutdown.cancel();
                            AgentOutput::Failed(
                                "ACP agent 未在取消后结束 prompt，连接已关闭".to_string(),
                            )
                        }
                    }
                }
                response = &mut prompt_task => match response {
                    Ok(response) => output_for_stop_reason(response.stop_reason),
                    Err(_) if request.cancellation.is_cancelled() => AgentOutput::Cancelled,
                    Err(error) => AgentOutput::Failed(format!("ACP prompt 失败: {error}")),
                }
            };

            let mut runs = active_runs.lock().await;
            if runs
                .get(&session_id)
                .is_some_and(|active| active.run_id == request.run_id)
            {
                runs.remove(&session_id);
            }
            drop(runs);
            let _ = event_tx.send(terminal);
        });

        Ok(BackendRun {
            events: Box::pin(UnboundedReceiverStream::new(event_rx)),
            backend_handle: Some(backend_handle),
        })
    }

    async fn delete_session(
        &self,
        session: &BackendSession,
        _workspace_path: Option<String>,
    ) -> Result<()> {
        let Some(handle) = session.backend_handle.as_deref() else {
            return Ok(());
        };
        if !self.capabilities.can_delete_session {
            bail!("ACP agent 不支持 session/delete");
        }

        let session_id = SessionId::new(handle);
        match self
            .connection
            .send_request(DeleteSessionRequest::new(session_id.clone()))
            .block_task()
            .await
        {
            Ok(_) => {}
            Err(error) if error.code == ErrorCode::ResourceNotFound => {}
            Err(error) => return Err(anyhow!("删除 ACP session {handle} 失败: {error}")),
        }
        self.loaded_sessions.lock().await.remove(&session_id);
        Ok(())
    }
}

async fn forward_session_update(notification: RawSessionNotification, active_runs: &ActiveRunMap) {
    forward_update_value(notification.session_id, notification.update, active_runs).await;
}

async fn forward_extension_notification(
    notification: RawExtensionNotification,
    active_runs: &ActiveRunMap,
) {
    let method = notification.method.to_ascii_lowercase();
    if notification.method.as_ref() != "_disco/session/compaction"
        && !method.contains("compact")
        && !method.contains("compaction")
    {
        return;
    }
    let Some(object) = notification.params.as_object() else {
        return;
    };
    let Some(session_id) = object
        .get("sessionId")
        .or_else(|| object.get("session_id"))
        .and_then(serde_json::Value::as_str)
        .map(SessionId::new)
    else {
        return;
    };
    let Some(update) = object.get("update").cloned().or_else(|| {
        object
            .get("sessionUpdate")
            .is_some()
            .then(|| notification.params.clone())
    }) else {
        return;
    };
    forward_update_value(session_id, update, active_runs).await;
}

async fn forward_update_value(
    session_id: SessionId,
    update: serde_json::Value,
    active_runs: &ActiveRunMap,
) {
    let Some(run) = active_runs.lock().await.get(&session_id).cloned() else {
        return;
    };
    for output in outputs_for_update_value(update, &run.tool_title_by_id) {
        let _ = run.event_tx.send(output);
    }
}

async fn forward_permission_request(
    request: RequestPermissionRequest,
    responder: Responder<RequestPermissionResponse>,
    connection: ConnectionTo<Agent>,
    active_runs: &ActiveRunMap,
) -> agent_client_protocol::Result<()> {
    let Some(run) = active_runs.lock().await.get(&request.session_id).cloned() else {
        return responder.respond(RequestPermissionResponse::new(
            RequestPermissionOutcome::Cancelled,
        ));
    };

    connection.spawn(async move {
        let approval = approval_request_from_acp(run.run_id, &request, &run.tool_title_by_id);
        let decision = match run.approval_manager.prepare_approval(&approval).await {
            PreparedApproval::SessionApproved => ApprovalDecision::ApproveOnce,
            PreparedApproval::Pending(pending) => {
                if run.cancellation.is_cancelled()
                    || run
                        .event_tx
                        .send(AgentOutput::approval_waiting(&approval))
                        .is_err()
                {
                    return responder.respond(RequestPermissionResponse::new(
                        RequestPermissionOutcome::Cancelled,
                    ));
                }
                tokio::select! {
                    biased;
                    _ = run.cancellation.cancelled() => {
                        return responder.respond(RequestPermissionResponse::new(
                            RequestPermissionOutcome::Cancelled,
                        ));
                    }
                    decision = pending.wait() => decision,
                }
            }
        };
        let _ = run.event_tx.send(AgentOutput::ApprovalResolved {
            approval_id: approval.id,
            decision,
        });
        responder.respond(RequestPermissionResponse::new(permission_outcome(
            decision,
            &request.options,
        )))
    })
}

fn outputs_for_session_update(
    update: SessionUpdate,
    tool_title_by_id: &StdMutex<HashMap<String, String>>,
) -> Vec<AgentOutput> {
    match update {
        SessionUpdate::AgentMessageChunk(chunk) => match chunk.content {
            ContentBlock::Text(text) => vec![AgentOutput::TextDelta(text.text)],
            _ => Vec::new(),
        },
        SessionUpdate::AgentThoughtChunk(chunk) => match chunk.content {
            ContentBlock::Text(text) => vec![AgentOutput::ReasoningDelta(text.text)],
            _ => Vec::new(),
        },
        SessionUpdate::ToolCall(tool_call) => outputs_for_tool_call(tool_call, tool_title_by_id),
        SessionUpdate::ToolCallUpdate(tool_call) => {
            outputs_for_tool_update(tool_call, tool_title_by_id)
        }
        SessionUpdate::UsageUpdate(usage) => vec![AgentOutput::ContextUsage {
            used: i64::try_from(usage.used).unwrap_or(i64::MAX),
            size: i64::try_from(usage.size).unwrap_or(i64::MAX),
        }],
        _ => Vec::new(),
    }
}

fn outputs_for_update_value(
    update: serde_json::Value,
    tool_title_by_id: &StdMutex<HashMap<String, String>>,
) -> Vec<AgentOutput> {
    if let Ok(update) = serde_json::from_value::<SessionUpdate>(update.clone()) {
        return outputs_for_session_update(update, tool_title_by_id);
    }
    compaction_output_from_value(&update).into_iter().collect()
}

fn compaction_output_from_value(value: &serde_json::Value) -> Option<AgentOutput> {
    if value
        .get("sessionUpdate")
        .and_then(serde_json::Value::as_str)
        != Some("compaction_update")
    {
        return None;
    }
    let id = value
        .get("compactionId")
        .or_else(|| value.get("id"))
        .and_then(serde_json::Value::as_str)?
        .to_string();
    let status = match value
        .get("status")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
    {
        "running" | "in_progress" | "started" => CompactionStatus::Running,
        "completed" | "complete" | "done" | "finished" => CompactionStatus::Completed,
        "failed" | "error" => CompactionStatus::Failed,
        _ => return None,
    };
    Some(AgentOutput::CompactionUpdate(CompactionUpdate {
        id,
        status,
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
    }))
}

fn outputs_for_tool_call(
    tool_call: ToolCall,
    tool_title_by_id: &StdMutex<HashMap<String, String>>,
) -> Vec<AgentOutput> {
    let tool_call_id = tool_call.tool_call_id.to_string();
    tool_title_by_id
        .lock()
        .expect("ACP tool title mutex poisoned")
        .insert(tool_call_id.clone(), tool_call.title.clone());
    let mut outputs = vec![AgentOutput::ToolStarted {
        tool_call_id: tool_call_id.clone(),
        tool_name: tool_call.title.clone(),
        arguments: tool_call
            .raw_input
            .as_ref()
            .map(json_text)
            .unwrap_or_else(|| "{}".to_string()),
    }];
    if matches!(
        tool_call.status,
        ToolCallStatus::Completed | ToolCallStatus::Failed
    ) {
        outputs.push(AgentOutput::ToolCompleted {
            tool_call_id,
            tool_name: tool_call.title,
            output: render_tool_output(tool_call.raw_output.as_ref(), &tool_call.content),
        });
    }
    outputs
}

fn outputs_for_tool_update(
    update: ToolCallUpdate,
    tool_title_by_id: &StdMutex<HashMap<String, String>>,
) -> Vec<AgentOutput> {
    let tool_call_id = update.tool_call_id.to_string();
    let mut titles = tool_title_by_id
        .lock()
        .expect("ACP tool title mutex poisoned");
    if let Some(title) = update.fields.title.as_ref() {
        titles.insert(tool_call_id.clone(), title.clone());
    }
    if !matches!(
        update.fields.status,
        Some(ToolCallStatus::Completed | ToolCallStatus::Failed)
    ) {
        return Vec::new();
    }
    let tool_name = update
        .fields
        .title
        .clone()
        .or_else(|| titles.get(&tool_call_id).cloned())
        .unwrap_or_else(|| "ACP tool".to_string());
    drop(titles);

    vec![AgentOutput::ToolCompleted {
        tool_call_id,
        tool_name,
        output: render_tool_output(
            update.fields.raw_output.as_ref(),
            update.fields.content.as_deref().unwrap_or_default(),
        ),
    }]
}

fn approval_request_from_acp(
    run_id: Uuid,
    request: &RequestPermissionRequest,
    tool_title_by_id: &StdMutex<HashMap<String, String>>,
) -> ApprovalRequest {
    let tool_call_id = request.tool_call.tool_call_id.to_string();
    let title = request
        .tool_call
        .fields
        .title
        .clone()
        .or_else(|| {
            tool_title_by_id
                .lock()
                .expect("ACP tool title mutex poisoned")
                .get(&tool_call_id)
                .cloned()
        })
        .unwrap_or_else(|| "ACP agent 请求执行操作".to_string());
    let arguments = request
        .tool_call
        .fields
        .raw_input
        .as_ref()
        .map(json_text)
        .unwrap_or_else(|| "{}".to_string());
    let impact = approval_impact(&request.tool_call, &title, &arguments);
    let fingerprint = format!("acp:{title}:{arguments}");

    ApprovalRequest {
        id: Uuid::new_v4(),
        run_id,
        kind: "acp_permission".to_string(),
        title,
        reason: None,
        impact,
        fingerprint,
        // “本会话允许”由 Disco 的 fingerprint 缓存实现；下游仍只获得单次授权。
        allows_session_approval: request
            .options
            .iter()
            .any(|option| option.kind == PermissionOptionKind::AllowOnce),
    }
}

fn approval_impact(tool_call: &ToolCallUpdate, title: &str, arguments: &str) -> ApprovalImpact {
    let is_file_change = matches!(
        tool_call.fields.kind,
        Some(ToolKind::Edit | ToolKind::Delete | ToolKind::Move)
    );
    if is_file_change
        && let Some(locations) = tool_call.fields.locations.as_ref()
        && !locations.is_empty()
    {
        return ApprovalImpact::FileChange {
            paths: locations
                .iter()
                .map(|location| location.path.display().to_string())
                .collect(),
            summary: title.to_string(),
            diff: None,
        };
    }

    ApprovalImpact::Permission {
        scope: format!("acp:{:?}", tool_call.fields.kind.unwrap_or(ToolKind::Other)),
        description: arguments.to_string(),
    }
}

fn permission_outcome(
    decision: ApprovalDecision,
    options: &[PermissionOption],
) -> RequestPermissionOutcome {
    let required_kind = match decision {
        ApprovalDecision::ApproveOnce | ApprovalDecision::ApproveForSession => {
            PermissionOptionKind::AllowOnce
        }
        ApprovalDecision::Decline => PermissionOptionKind::RejectOnce,
    };
    options
        .iter()
        .find(|option| option.kind == required_kind)
        .map(|option| {
            RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
                option.option_id.clone(),
            ))
        })
        .unwrap_or(RequestPermissionOutcome::Cancelled)
}

fn output_for_stop_reason(reason: StopReason) -> AgentOutput {
    match reason {
        StopReason::EndTurn | StopReason::MaxTokens | StopReason::MaxTurnRequests => {
            AgentOutput::Completed
        }
        StopReason::Refusal => AgentOutput::Failed("ACP agent 拒绝继续当前任务".to_string()),
        StopReason::Cancelled => AgentOutput::Cancelled,
        _ => AgentOutput::Failed(format!("ACP agent 返回未知停止原因: {reason:?}")),
    }
}

fn render_tool_output(
    raw_output: Option<&serde_json::Value>,
    content: &[agent_client_protocol::schema::v1::ToolCallContent],
) -> String {
    if let Some(raw_output) = raw_output {
        return json_text(raw_output);
    }
    serde_json::to_string(content).unwrap_or_else(|_| "[]".to_string())
}

fn json_text(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(text) => text.clone(),
        value => serde_json::to_string(value).unwrap_or_else(|_| "null".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use agent_client_protocol::schema::v1::{
        AgentCapabilities, ContentChunk, DeleteSessionResponse, InitializeResponse,
        LoadSessionResponse, NewSessionResponse, PromptResponse, SessionCapabilities,
        SessionDeleteCapabilities, SessionNotification, TextContent, ToolCallUpdateFields,
        UsageUpdate,
    };
    use disco_providers::ChatMessage;
    use tokio::sync::Notify;
    use tokio_stream::StreamExt;

    use super::*;

    struct FakeAgentState {
        new_session_count: AtomicUsize,
        load_session_count: AtomicUsize,
        delete_session_count: AtomicUsize,
        prompt_count: AtomicUsize,
        prompt_sessions: StdMutex<Vec<SessionId>>,
        permission_outcomes: StdMutex<Vec<RequestPermissionOutcome>>,
    }

    impl FakeAgentState {
        fn new() -> Self {
            Self {
                new_session_count: AtomicUsize::new(0),
                load_session_count: AtomicUsize::new(0),
                delete_session_count: AtomicUsize::new(0),
                prompt_count: AtomicUsize::new(0),
                prompt_sessions: StdMutex::new(Vec::new()),
                permission_outcomes: StdMutex::new(Vec::new()),
            }
        }
    }

    fn backend_request(
        backend_handle: Option<String>,
        cancellation: CancellationToken,
        approval_manager: Arc<ApprovalManager>,
    ) -> BackendRunRequest {
        BackendRunRequest {
            run_id: Uuid::new_v4(),
            session: BackendSession {
                id: Uuid::new_v4(),
                model: "fake-acp".to_string(),
                backend_handle,
            },
            messages: vec![ChatMessage {
                role: "user".to_string(),
                text: "完成测试".to_string(),
                ..Default::default()
            }],
            workspace_path: Some("/tmp/disco-acp-tests".to_string()),
            cancellation,
            approval_manager,
        }
    }

    #[test]
    fn acp_usage_update_preserves_context_window() {
        let outputs = outputs_for_session_update(
            SessionUpdate::UsageUpdate(UsageUpdate::new(53_000, 200_000)),
            &StdMutex::new(HashMap::new()),
        );

        assert!(matches!(
            outputs.as_slice(),
            [AgentOutput::ContextUsage {
                used: 53_000,
                size: 200_000
            }]
        ));
    }

    #[test]
    fn acp_compaction_update_survives_unknown_session_update_variant() {
        let outputs = outputs_for_update_value(
            serde_json::json!({
                "sessionUpdate": "compaction_update",
                "compactionId": "cmp-1",
                "status": "in_progress",
                "beforeTokens": 120_000,
            }),
            &StdMutex::new(HashMap::new()),
        );

        assert!(matches!(
            outputs.as_slice(),
            [AgentOutput::CompactionUpdate(CompactionUpdate {
                id,
                status: CompactionStatus::Running,
                before_tokens: Some(120_000),
                ..
            })] if id == "cmp-1"
        ));
    }

    fn fake_agent(state: Arc<FakeAgentState>) -> impl ConnectTo<Client> {
        let new_session_state = state.clone();
        let load_session_state = state.clone();
        let delete_session_state = state.clone();
        let prompt_state = state;

        Agent
            .builder()
            .on_receive_request(
                async move |request: InitializeRequest,
                            responder: Responder<InitializeResponse>,
                            _connection: ConnectionTo<Client>| {
                    responder.respond(
                        InitializeResponse::new(request.protocol_version).agent_capabilities(
                            AgentCapabilities::new()
                                .load_session(true)
                                .session_capabilities(
                                    SessionCapabilities::new()
                                        .delete(SessionDeleteCapabilities::new()),
                                ),
                        ),
                    )
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: NewSessionRequest,
                            responder: Responder<NewSessionResponse>,
                            _connection: ConnectionTo<Client>| {
                    new_session_state
                        .new_session_count
                        .fetch_add(1, Ordering::Relaxed);
                    responder.respond(NewSessionResponse::new("acp-session-1"))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: LoadSessionRequest,
                            responder: Responder<LoadSessionResponse>,
                            _connection: ConnectionTo<Client>| {
                    load_session_state
                        .load_session_count
                        .fetch_add(1, Ordering::Relaxed);
                    responder.respond(LoadSessionResponse::new())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: DeleteSessionRequest,
                            responder: Responder<DeleteSessionResponse>,
                            _connection: ConnectionTo<Client>| {
                    delete_session_state
                        .delete_session_count
                        .fetch_add(1, Ordering::Relaxed);
                    responder.respond(DeleteSessionResponse::new())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: PromptRequest,
                            responder: Responder<PromptResponse>,
                            connection: ConnectionTo<Client>| {
                    let prompt_index = prompt_state.prompt_count.fetch_add(1, Ordering::Relaxed);
                    prompt_state
                        .prompt_sessions
                        .lock()
                        .expect("prompt session mutex poisoned")
                        .push(request.session_id.clone());

                    if prompt_index != 0 {
                        connection.send_notification(SessionNotification::new(
                            request.session_id,
                            SessionUpdate::AgentMessageChunk(ContentChunk::new(
                                ContentBlock::Text(TextContent::new("再次完成")),
                            )),
                        ))?;
                        return responder.respond(PromptResponse::new(StopReason::EndTurn));
                    }

                    connection.send_notification(SessionNotification::new(
                        request.session_id.clone(),
                        SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                            TextContent::new("正在执行"),
                        ))),
                    ))?;
                    connection.send_notification(SessionNotification::new(
                        request.session_id.clone(),
                        SessionUpdate::AgentThoughtChunk(ContentChunk::new(ContentBlock::Text(
                            TextContent::new("先检查权限"),
                        ))),
                    ))?;
                    connection.send_notification(SessionNotification::new(
                        request.session_id.clone(),
                        SessionUpdate::ToolCall(
                            ToolCall::new("tool-1", "写入文件")
                                .kind(ToolKind::Edit)
                                .raw_input(serde_json::json!({"path": "/tmp/example.txt"})),
                        ),
                    ))?;

                    let task_state = prompt_state.clone();
                    let task_connection = connection.clone();
                    connection.spawn(async move {
                        let permission = task_connection
                            .send_request(RequestPermissionRequest::new(
                                request.session_id.clone(),
                                ToolCallUpdate::new(
                                    "tool-1",
                                    ToolCallUpdateFields::new()
                                        .kind(ToolKind::Edit)
                                        .title("写入文件")
                                        .raw_input(serde_json::json!({
                                            "path": "/tmp/example.txt"
                                        })),
                                ),
                                vec![
                                    PermissionOption::new(
                                        "allow-once",
                                        "仅允许一次",
                                        PermissionOptionKind::AllowOnce,
                                    ),
                                    PermissionOption::new(
                                        "allow-always",
                                        "本会话允许",
                                        PermissionOptionKind::AllowAlways,
                                    ),
                                    PermissionOption::new(
                                        "reject-once",
                                        "拒绝",
                                        PermissionOptionKind::RejectOnce,
                                    ),
                                ],
                            ))
                            .block_task()
                            .await?;
                        task_state
                            .permission_outcomes
                            .lock()
                            .expect("permission outcome mutex poisoned")
                            .push(permission.outcome);
                        task_connection.send_notification(SessionNotification::new(
                            request.session_id,
                            SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                                "tool-1",
                                ToolCallUpdateFields::new()
                                    .status(ToolCallStatus::Completed)
                                    .raw_output(serde_json::json!({"written": true})),
                            )),
                        ))?;
                        responder.respond(PromptResponse::new(StopReason::EndTurn))
                    })
                },
                agent_client_protocol::on_receive_request!(),
            )
    }

    #[tokio::test]
    async fn acp_adapter_maps_runs_permissions_sessions_and_deletion() {
        let state = Arc::new(FakeAgentState::new());
        let backend = AcpAdapter::connect_transport(fake_agent(state.clone()), Vec::new())
            .await
            .unwrap();
        assert_eq!(
            backend.capabilities(),
            BackendCapabilities {
                has_persistent_sessions: true,
                can_delete_session: true,
                compaction: CompactionMode::Native,
            }
        );

        let approval_manager = Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new()))));
        let mut run = backend
            .start_run(backend_request(
                None,
                CancellationToken::new(),
                approval_manager.clone(),
            ))
            .await
            .unwrap();
        assert_eq!(run.backend_handle.as_deref(), Some("acp-session-1"));

        let mut events = Vec::new();
        while let Some(event) = run.events.next().await {
            if let AgentOutput::ApprovalWaiting { approval_id, .. } = &event {
                assert!(
                    approval_manager
                        .respond(*approval_id, ApprovalDecision::ApproveForSession)
                        .await,
                    "审批事件发出前必须已完成 pending 注册"
                );
            }
            events.push(event);
        }

        assert!(matches!(&events[0], AgentOutput::TextDelta(text) if text == "正在执行"));
        assert!(matches!(&events[1], AgentOutput::ReasoningDelta(text) if text == "先检查权限"));
        assert!(
            matches!(&events[2], AgentOutput::ToolStarted { tool_call_id, tool_name, .. } if tool_call_id == "tool-1" && tool_name == "写入文件")
        );
        assert!(matches!(
            &events[3],
            AgentOutput::ApprovalWaiting {
                allows_session_approval: true,
                ..
            }
        ));
        assert!(matches!(
            &events[4],
            AgentOutput::ApprovalResolved {
                decision: ApprovalDecision::ApproveForSession,
                ..
            }
        ));
        assert!(
            matches!(&events[5], AgentOutput::ToolCompleted { tool_call_id, output, .. } if tool_call_id == "tool-1" && output.contains("written"))
        );
        assert!(matches!(&events[6], AgentOutput::Completed));
        assert!(matches!(
            state
                .permission_outcomes
                .lock()
                .expect("permission outcome mutex poisoned")
                .as_slice(),
            [RequestPermissionOutcome::Selected(selected)] if selected.option_id.to_string() == "allow-once"
        ));

        let second = backend
            .start_run(backend_request(
                run.backend_handle.clone(),
                CancellationToken::new(),
                Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new())))),
            ))
            .await
            .unwrap();
        assert!(matches!(
            second.events.collect::<Vec<_>>().await.as_slice(),
            [AgentOutput::TextDelta(text), AgentOutput::Completed] if text == "再次完成"
        ));
        assert_eq!(state.new_session_count.load(Ordering::Relaxed), 1);
        assert_eq!(state.load_session_count.load(Ordering::Relaxed), 0);

        let restored = backend
            .start_run(backend_request(
                Some("restored-session".to_string()),
                CancellationToken::new(),
                Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new())))),
            ))
            .await
            .unwrap();
        assert!(matches!(
            restored.events.collect::<Vec<_>>().await.last(),
            Some(AgentOutput::Completed)
        ));
        assert_eq!(state.load_session_count.load(Ordering::Relaxed), 1);
        assert_eq!(
            state
                .prompt_sessions
                .lock()
                .expect("prompt session mutex poisoned")
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>(),
            [
                "acp-session-1".to_string(),
                "acp-session-1".to_string(),
                "restored-session".to_string(),
            ]
        );

        backend
            .delete_session(
                &BackendSession {
                    id: Uuid::new_v4(),
                    model: "fake-acp".to_string(),
                    backend_handle: Some("restored-session".to_string()),
                },
                None,
            )
            .await
            .unwrap();
        assert_eq!(state.delete_session_count.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn disco_session_approval_never_selects_persistent_acp_permission() {
        let options = vec![PermissionOption::new(
            "allow-always",
            "永久允许",
            PermissionOptionKind::AllowAlways,
        )];

        assert!(matches!(
            permission_outcome(ApprovalDecision::ApproveForSession, &options),
            RequestPermissionOutcome::Cancelled
        ));
        assert!(matches!(
            permission_outcome(ApprovalDecision::ApproveOnce, &options),
            RequestPermissionOutcome::Cancelled
        ));
    }

    #[tokio::test]
    async fn cancelling_a_run_notifies_the_agent_and_emits_one_terminal_event() {
        let prompt_responder = Arc::new(StdMutex::new(None::<Responder<PromptResponse>>));
        let prompt_received = Arc::new(AtomicBool::new(false));
        let cancel_count = Arc::new(AtomicUsize::new(0));
        let prompt_handler_responder = prompt_responder.clone();
        let prompt_handler_received = prompt_received.clone();
        let cancel_handler_responder = prompt_responder;
        let cancel_handler_count = cancel_count.clone();

        let agent = Agent
            .builder()
            .on_receive_request(
                async move |request: InitializeRequest,
                            responder: Responder<InitializeResponse>,
                            _connection: ConnectionTo<Client>| {
                    responder.respond(InitializeResponse::new(request.protocol_version))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: NewSessionRequest,
                            responder: Responder<NewSessionResponse>,
                            _connection: ConnectionTo<Client>| {
                    responder.respond(NewSessionResponse::new("cancel-session"))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: PromptRequest,
                            responder: Responder<PromptResponse>,
                            _connection: ConnectionTo<Client>| {
                    *prompt_handler_responder
                        .lock()
                        .expect("prompt responder mutex poisoned") = Some(responder);
                    prompt_handler_received.store(true, Ordering::Release);
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_notification(
                async move |_notification: CancelNotification,
                            _connection: ConnectionTo<Client>| {
                    cancel_handler_count.fetch_add(1, Ordering::Relaxed);
                    if let Some(responder) = cancel_handler_responder
                        .lock()
                        .expect("prompt responder mutex poisoned")
                        .take()
                    {
                        responder.respond(PromptResponse::new(StopReason::Cancelled))?;
                    }
                    Ok(())
                },
                agent_client_protocol::on_receive_notification!(),
            );
        let backend = AcpAdapter::connect_transport(agent, Vec::new())
            .await
            .unwrap();
        let cancellation = CancellationToken::new();
        let run = backend
            .start_run(backend_request(
                None,
                cancellation.clone(),
                Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new())))),
            ))
            .await
            .unwrap();

        for _ in 0..100 {
            if prompt_received.load(Ordering::Acquire) {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert!(prompt_received.load(Ordering::Acquire));
        cancellation.cancel();
        let events = run.events.collect::<Vec<_>>().await;
        assert!(matches!(events.as_slice(), [AgentOutput::Cancelled]));

        for _ in 0..100 {
            if cancel_count.load(Ordering::Relaxed) == 1 {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert_eq!(cancel_count.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn cancellation_waits_for_the_acp_prompt_to_finish() {
        let prompt_responder = Arc::new(StdMutex::new(None::<Responder<PromptResponse>>));
        let prompt_received = Arc::new(AtomicBool::new(false));
        let cancel_received = Arc::new(Notify::new());
        let prompt_handler_responder = prompt_responder.clone();
        let prompt_handler_received = prompt_received.clone();
        let cancel_handler_received = cancel_received.clone();

        let agent = Agent
            .builder()
            .on_receive_request(
                async move |request: InitializeRequest,
                            responder: Responder<InitializeResponse>,
                            _connection: ConnectionTo<Client>| {
                    responder.respond(InitializeResponse::new(request.protocol_version))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: NewSessionRequest,
                            responder: Responder<NewSessionResponse>,
                            _connection: ConnectionTo<Client>| {
                    responder.respond(NewSessionResponse::new("delayed-cancel-session"))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: PromptRequest,
                            responder: Responder<PromptResponse>,
                            _connection: ConnectionTo<Client>| {
                    *prompt_handler_responder
                        .lock()
                        .expect("prompt responder mutex poisoned") = Some(responder);
                    prompt_handler_received.store(true, Ordering::Release);
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_notification(
                async move |_notification: CancelNotification,
                            _connection: ConnectionTo<Client>| {
                    cancel_handler_received.notify_one();
                    Ok(())
                },
                agent_client_protocol::on_receive_notification!(),
            );
        let backend = AcpAdapter::connect_transport(agent, Vec::new())
            .await
            .unwrap();
        let cancellation = CancellationToken::new();
        let mut run = backend
            .start_run(backend_request(
                None,
                cancellation.clone(),
                Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new())))),
            ))
            .await
            .unwrap();

        for _ in 0..100 {
            if prompt_received.load(Ordering::Acquire) {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert!(prompt_received.load(Ordering::Acquire));
        cancellation.cancel();
        timeout(Duration::from_secs(1), cancel_received.notified())
            .await
            .unwrap();
        assert!(
            timeout(Duration::from_millis(50), run.events.next())
                .await
                .is_err(),
            "下游 prompt 结束前不应释放 ACP session"
        );

        prompt_responder
            .lock()
            .expect("prompt responder mutex poisoned")
            .take()
            .unwrap()
            .respond(PromptResponse::new(StopReason::Cancelled))
            .unwrap();
        assert!(matches!(
            timeout(Duration::from_secs(1), run.events.next())
                .await
                .unwrap(),
            Some(AgentOutput::Cancelled)
        ));
        assert!(run.events.next().await.is_none());
    }
}
