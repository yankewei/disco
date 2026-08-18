//! Disco daemon 的 ACP facade。
//!
//! daemon 唯一的 client transport：以 `--stdio` 启动时作为 ACP v1 agent 运行。facade
//! 复用共享 run service 和 `RunCoordinator`，session/provider/compaction 等产品操作由
//! 对应的 service 模块实现。

use std::path::{Path, PathBuf};
use std::sync::Arc;

use agent_client_protocol::schema::v1::{
    AgentCapabilities, CancelNotification, ClientRequest, CloseSessionRequest,
    CloseSessionResponse, ContentBlock, ContentChunk, DeleteSessionRequest, DeleteSessionResponse,
    ExtRequest, Implementation, InitializeRequest, InitializeResponse, ListSessionsRequest,
    ListSessionsResponse, LoadSessionRequest, LoadSessionResponse, MessageId, Meta,
    NewSessionRequest, NewSessionResponse, PermissionOption, PermissionOptionKind, PromptRequest,
    PromptResponse, RequestPermissionOutcome, RequestPermissionRequest, SelectedPermissionOutcome,
    SessionCapabilities, SessionCloseCapabilities, SessionDeleteCapabilities, SessionId,
    SessionInfo, SessionListCapabilities, SessionNotification, SessionUpdate, StopReason,
    TextContent, ToolCall, ToolCallStatus, ToolCallUpdate, ToolCallUpdateFields, ToolKind,
    UsageUpdate,
};
use agent_client_protocol::{Agent, Client, ConnectTo, ConnectionTo, Responder, Stdio};
use disco_core::AgentOutput;
use disco_protocol::types::TokenUsage;
use disco_protocol::{ApprovalKind, ApprovalRequestedData};
use serde::{Deserialize, Serialize};
use tracing::{debug, info, warn};
use uuid::Uuid;

use crate::daemon::AppState;
use crate::run_service::accumulate_usage;

const META_PROVIDER_ID: &str = "disco/providerId";
const META_SESSION_ID: &str = "disco/sessionId";
const ACP_PROVIDER_CONFIGURE_METHOD: &str = "disco/provider/configure";
const ACP_PROVIDER_LIST_METHOD: &str = "disco/provider/list";
const ACP_PROVIDER_MODELS_METHOD: &str = "disco/provider/models";
const ACP_SESSION_MESSAGES_METHOD: &str = "disco/session/messages";
const ACP_SESSION_COMPACT_METHOD: &str = "disco/session/compact";
const META_APPROVAL_ID: &str = "disco/approvalId";
const META_APPROVAL_SCOPE: &str = "disco/approvalScope";
const META_APPROVAL_FINGERPRINT: &str = "disco/approvalFingerprint";

/// 通过 stdin/stdout 运行 ACP v1 server。
///
/// stdout 只允许输出 ACP JSON-RPC frame。`main.rs` 会将 stdio 模式的日志写到 stderr，
/// 避免日志污染协议流。
pub async fn run_acp_stdio_server(app: Arc<AppState>) -> anyhow::Result<()> {
    run_acp_server(app, Stdio::new()).await
}

async fn run_acp_server<T>(app: Arc<AppState>, transport: T) -> anyhow::Result<()>
where
    T: ConnectTo<Agent> + 'static,
{
    let mut capability_meta = Meta::new();
    capability_meta.insert(
        "disco/extensions".to_string(),
        serde_json::json!([
            "disco/provider/configure",
            "disco/provider/list",
            "disco/provider/models",
            "disco/session/messages",
            "disco/session/compact",
        ]),
    );
    let capabilities = AgentCapabilities::new()
        .load_session(true)
        .session_capabilities(
            SessionCapabilities::new()
                .list(SessionListCapabilities::new())
                .delete(SessionDeleteCapabilities::new())
                .close(SessionCloseCapabilities::new()),
        )
        .meta(capability_meta);
    let agent_version = env!("CARGO_PKG_VERSION").to_string();

    info!("ACP stdio facade listening");

    Agent
        .builder()
        .name("disco-daemon")
        .on_receive_request(
            {
                let capabilities = capabilities.clone();
                let agent_version = agent_version.clone();
                async move |request: InitializeRequest,
                            responder: Responder<InitializeResponse>,
                            _connection: ConnectionTo<Client>| {
                    if request.protocol_version
                        != agent_client_protocol::schema::ProtocolVersion::V1
                    {
                        return Err(agent_client_protocol::Error::invalid_params()
                            .data("Disco 当前只支持 ACP v1。"));
                    }
                    responder.respond(
                        InitializeResponse::new(request.protocol_version)
                            .agent_capabilities(capabilities.clone())
                            .agent_info(Implementation::new("disco-daemon", agent_version.clone())),
                    )
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            {
                let app = app.clone();
                async move |request: NewSessionRequest,
                            responder: Responder<NewSessionResponse>,
                            _connection: ConnectionTo<Client>| {
                    let response = create_session(&app, &request).await?;
                    responder.respond(response)
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            {
                let app = app.clone();
                async move |request: LoadSessionRequest,
                            responder: Responder<LoadSessionResponse>,
                            _connection: ConnectionTo<Client>| {
                    let response = load_session(&app, &request)?;
                    responder.respond(response)
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            {
                let app = app.clone();
                async move |request: ListSessionsRequest,
                            responder: Responder<ListSessionsResponse>,
                            _connection: ConnectionTo<Client>| {
                    let response = list_sessions(&app, &request)?;
                    responder.respond(response)
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            {
                let app = app.clone();
                async move |request: DeleteSessionRequest,
                            responder: Responder<DeleteSessionResponse>,
                            _connection: ConnectionTo<Client>| {
                    let response = delete_session(&app, &request).await?;
                    responder.respond(response)
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            {
                let app = app.clone();
                async move |request: CloseSessionRequest,
                            responder: Responder<CloseSessionResponse>,
                            _connection: ConnectionTo<Client>| {
                    let response = close_session(&app, &request).await?;
                    responder.respond(response)
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            {
                let app = app.clone();
                async move |request: PromptRequest,
                            responder: Responder<PromptResponse>,
                            connection: ConnectionTo<Client>| {
                    let session_uuid = parse_session_id(&request.session_id)?;
                    let prompt = extract_prompt_text(&request.prompt)?;
                    let app = app.clone();
                    let session_id = request.session_id.clone();

                    // prompt 在 run 进入终止状态后才返回响应。将等待任务从 dispatch callback
                    // 中分离，保证模型运行期间仍能重入处理 session/cancel 和 permission response。
                    let task_connection = connection.clone();
                    connection.spawn(async move {
                        bridge_prompt(
                            app,
                            task_connection,
                            responder,
                            session_uuid,
                            session_id,
                            prompt,
                        )
                        .await
                    })?;
                    Ok(())
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_notification(
            {
                let app = app.clone();
                async move |notification: CancelNotification, _connection: ConnectionTo<Client>| {
                    let Ok(session_id) = parse_session_id(&notification.session_id) else {
                        warn!(
                            session_id = %notification.session_id,
                            "忽略无法解析的 ACP session/cancel"
                        );
                        return Ok(());
                    };
                    if let Some(run_id) = app.run_coordinator.active_run_id(session_id).await {
                        let outcome = app.run_coordinator.cancel_run(run_id).await;
                        debug!(%session_id, %run_id, ?outcome, "ACP session cancelled");
                    }
                    Ok(())
                }
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .on_receive_request(
            {
                let app = app.clone();
                async move |request: ClientRequest,
                            responder: Responder<serde_json::Value>,
                            _connection: ConnectionTo<Client>| {
                    let ClientRequest::ExtMethodRequest(extension) = request else {
                        return Err(agent_client_protocol::Error::method_not_found());
                    };
                    let result = handle_disco_extension(&app, &extension).await?;
                    responder.respond(result)
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .connect_to(transport)
        .await
        .map_err(|error| anyhow::anyhow!(error.to_string()))?;

    app.shutdown.cancel();
    Ok(())
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AcpProviderConfigureParams {
    #[serde(default)]
    provider_id: Option<disco_protocol::ProviderId>,
    vendor: disco_protocol::Vendor,
    base_url: String,
    api_key: String,
    model: String,
    #[serde(default)]
    thinking_enabled: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AcpProviderConfigureResult {
    provider_id: String,
    vendor: disco_protocol::Vendor,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AcpProviderEntry {
    provider_id: String,
    vendor: disco_protocol::Vendor,
    base_url: String,
    model: String,
    thinking_enabled: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AcpProviderListResult {
    providers: Vec<AcpProviderEntry>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AcpProviderModelsParams {
    #[serde(default)]
    provider_id: Option<disco_protocol::ProviderId>,
    vendor: disco_protocol::Vendor,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AcpProviderModelsResult {
    models: Vec<AcpModelCatalogEntry>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AcpSessionMessagesParams {
    session_id: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AcpSessionMessage {
    id: String,
    role: String,
    text: String,
    created_at: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AcpSessionMessagesResult {
    messages: Vec<AcpSessionMessage>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AcpModelCatalogEntry {
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    display_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    context_window: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    supported_reasoning_efforts: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    default_reasoning_effort: Option<String>,
}

impl From<disco_protocol::ModelCatalogEntry> for AcpModelCatalogEntry {
    fn from(model: disco_protocol::ModelCatalogEntry) -> Self {
        Self {
            id: model.id,
            display_name: model.display_name,
            context_window: model.context_window,
            supported_reasoning_efforts: model.supported_reasoning_efforts,
            default_reasoning_effort: model.default_reasoning_effort,
        }
    }
}

async fn handle_disco_extension(
    app: &Arc<AppState>,
    extension: &ExtRequest,
) -> agent_client_protocol::Result<serde_json::Value> {
    match extension.method.as_ref() {
        ACP_PROVIDER_CONFIGURE_METHOD => configure_provider(app, extension).await,
        ACP_PROVIDER_LIST_METHOD => list_providers(app).await,
        ACP_PROVIDER_MODELS_METHOD => list_provider_models(app, extension).await,
        ACP_SESSION_MESSAGES_METHOD => list_session_messages(app, extension).await,
        ACP_SESSION_COMPACT_METHOD => compact_session(app, extension).await,
        method => Err(agent_client_protocol::Error::method_not_found()
            .data(format!("未知的 Disco ACP extension：{method}"))),
    }
}

async fn configure_provider(
    app: &Arc<AppState>,
    extension: &ExtRequest,
) -> agent_client_protocol::Result<serde_json::Value> {
    let params: AcpProviderConfigureParams = decode_extension_params(extension)?;
    let result = crate::provider_service::configure_provider(
        app,
        disco_protocol::ProviderConfigureParams {
            provider_id: params.provider_id,
            vendor: params.vendor,
            base_url: params.base_url,
            api_key: params.api_key,
            model: params.model,
            thinking_enabled: params.thinking_enabled,
        },
    )
    .await
    .map_err(crate::provider_service::ProviderError::into_acp_error)?;
    serde_json::to_value(AcpProviderConfigureResult {
        provider_id: result.provider_id.to_string(),
        vendor: result.vendor,
    })
    .map_err(|error| internal_error(format!("无法编码 Provider 配置结果：{error}")))
}

async fn list_providers(app: &Arc<AppState>) -> agent_client_protocol::Result<serde_json::Value> {
    let providers = crate::provider_service::list_providers(app)
        .map_err(crate::provider_service::ProviderError::into_acp_error)?
        .into_iter()
        .map(|provider| AcpProviderEntry {
            provider_id: provider.provider_id.to_string(),
            vendor: provider.vendor,
            base_url: provider.base_url,
            model: provider.model,
            thinking_enabled: provider.thinking_enabled,
        })
        .collect();
    serde_json::to_value(AcpProviderListResult { providers })
        .map_err(|error| internal_error(format!("无法编码 Provider 列表：{error}")))
}

async fn list_session_messages(
    app: &Arc<AppState>,
    extension: &ExtRequest,
) -> agent_client_protocol::Result<serde_json::Value> {
    let params: AcpSessionMessagesParams = decode_extension_params(extension)?;
    let session_id = Uuid::parse_str(&params.session_id)
        .map_err(|_| invalid_params(format!("无效的 Disco session ID：{}", params.session_id)))?;
    let stored_messages = app
        .db
        .list_messages(session_id)
        .map_err(|error| internal_error(format!("无法读取 session 消息：{error}")))?;
    let messages = stored_messages
        .into_iter()
        .map(|message| AcpSessionMessage {
            id: message.id.to_string(),
            role: message.role,
            text: message.text,
            created_at: message.created_at,
        })
        .collect();
    serde_json::to_value(AcpSessionMessagesResult { messages })
        .map_err(|error| internal_error(format!("无法编码 session 消息：{error}")))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AcpCompactionResult {
    compaction: AcpCompactionInfo,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AcpCompactionInfo {
    id: String,
    status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    before_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    after_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_message: Option<String>,
}

async fn compact_session(
    app: &Arc<AppState>,
    extension: &ExtRequest,
) -> agent_client_protocol::Result<serde_json::Value> {
    let params: AcpSessionMessagesParams = decode_extension_params(extension)?;
    let session_id = Uuid::parse_str(&params.session_id)
        .map_err(|_| invalid_params(format!("无效的 Disco session ID：{}", params.session_id)))?;
    let outcome = crate::compaction_service::compact_session(app, session_id)
        .await
        .map_err(crate::compaction_service::CompactionError::into_acp_error)?;
    serde_json::to_value(AcpCompactionResult {
        compaction: AcpCompactionInfo {
            id: outcome.id,
            status: format!("{:?}", outcome.status).to_lowercase(),
            before_tokens: outcome.before_tokens,
            after_tokens: outcome.after_tokens,
            error_message: outcome.error_message,
        },
    })
    .map_err(|error| internal_error(format!("无法编码压缩结果：{error}")))
}

async fn list_provider_models(
    _app: &Arc<AppState>,
    extension: &ExtRequest,
) -> agent_client_protocol::Result<serde_json::Value> {
    let params: AcpProviderModelsParams = decode_extension_params(extension)?;
    let models =
        crate::provider_service::list_provider_models(disco_protocol::ProviderModelsParams {
            provider_id: params.provider_id,
            vendor: params.vendor,
        })
        .map_err(crate::provider_service::ProviderError::into_acp_error)?
        .into_iter()
        .map(AcpModelCatalogEntry::from)
        .collect();
    serde_json::to_value(AcpProviderModelsResult { models })
        .map_err(|error| internal_error(format!("无法编码 Provider models：{error}")))
}

fn decode_extension_params<T: serde::de::DeserializeOwned>(
    extension: &ExtRequest,
) -> agent_client_protocol::Result<T> {
    serde_json::from_str(extension.params.get())
        .map_err(|error| invalid_params(format!("ACP extension 参数无效：{error}")))
}

async fn create_session(
    app: &Arc<AppState>,
    request: &NewSessionRequest,
) -> agent_client_protocol::Result<NewSessionResponse> {
    let cwd = validate_absolute_path(&request.cwd)?;
    let requested_session_id = request
        .meta
        .as_ref()
        .and_then(|meta| meta.get(META_SESSION_ID))
        .and_then(serde_json::Value::as_str)
        .map(|value| {
            Uuid::parse_str(value)
                .map_err(|_| invalid_params(format!("无效的 Disco session ID：{value}")))
        })
        .transpose()?;
    let provider_config = select_provider_config(app, request.meta.as_ref()).await?;

    if app
        .get_backend(&provider_config.provider_id)
        .await
        .is_none()
    {
        return Err(internal_error(format!(
            "Provider {} 当前没有可用的 Agent Backend。",
            provider_config.provider_id
        )));
    }

    let project = match app.db.get_project_by_path(&cwd_string(&cwd)) {
        Ok(Some(project)) => project,
        Ok(None) => {
            let name = project_name(&cwd);
            app.db
                .create_project(&name, &cwd_string(&cwd))
                .or_else(|_| {
                    // 查询和插入之间可能已有其他 client 注册同一 workspace；重新读取项目，
                    // 不把重复路径竞态暴露给协议调用方。
                    app.db
                        .get_project_by_path(&cwd_string(&cwd))
                        .and_then(|project| {
                            project.ok_or_else(|| anyhow::anyhow!("workspace project disappeared"))
                        })
                })
                .map_err(|error| internal_error(format!("无法创建 workspace project：{error}")))?
        }
        Err(error) => {
            return Err(internal_error(format!(
                "无法查询 workspace project：{error}"
            )));
        }
    };

    if let Some(session_id) = requested_session_id
        && app
            .db
            .get_session(session_id)
            .map_err(|error| internal_error(format!("无法检查 Disco session：{error}")))?
            .is_some()
    {
        return Err(invalid_params(format!(
            "Disco session {session_id} 已经存在。"
        )));
    }

    let session = match requested_session_id {
        Some(session_id) => app.db.create_session_with_id(
            session_id,
            project.id,
            provider_config.provider_id,
            provider_config.vendor,
            &provider_config.model,
            None,
        ),
        None => app.db.create_session(
            project.id,
            provider_config.provider_id,
            provider_config.vendor,
            &provider_config.model,
            None,
        ),
    }
    .map_err(|error| internal_error(format!("无法创建 Disco session：{error}")))?;

    Ok(NewSessionResponse::new(session.id.to_string()))
}

async fn select_provider_config(
    app: &Arc<AppState>,
    meta: Option<&Meta>,
) -> agent_client_protocol::Result<disco_persist::provider_configs::ProviderConfig> {
    let provider_id = meta
        .and_then(|meta| meta.get(META_PROVIDER_ID))
        .and_then(serde_json::Value::as_str);
    let configs = app
        .db
        .list_provider_configs()
        .map_err(|error| internal_error(format!("无法读取 Provider 配置：{error}")))?;

    let config = match provider_id {
        Some(provider_id) => configs
            .into_iter()
            .find(|config| config.provider_id.as_str() == provider_id)
            .ok_or_else(|| {
                resource_not_found(format!("Provider profile {provider_id} 不存在。"))
            })?,
        None => configs.into_iter().next().ok_or_else(|| {
            agent_client_protocol::Error::auth_required()
                .data("尚未配置可用的 Provider，请先通过 Disco ACP extension 配置。")
        })?,
    };
    Ok(config)
}

fn load_session(
    app: &Arc<AppState>,
    request: &LoadSessionRequest,
) -> agent_client_protocol::Result<LoadSessionResponse> {
    let cwd = validate_absolute_path(&request.cwd)?;
    let session_id = parse_session_id(&request.session_id)?;
    let session = app
        .db
        .get_session(session_id)
        .map_err(|error| internal_error(format!("无法读取 session：{error}")))?
        .ok_or_else(|| resource_not_found(format!("session {session_id} 不存在。")))?;
    let project = app
        .db
        .get_project(session.project_id)
        .map_err(|error| internal_error(format!("无法读取 session project：{error}")))?
        .ok_or_else(|| {
            resource_not_found(format!("session project {} 不存在。", session.project_id))
        })?;

    if project.path != cwd_string(&cwd) {
        return Err(invalid_params(format!(
            "session {session_id} 属于 workspace {}，不能在 {} 中加载。",
            project.path,
            cwd.display()
        )));
    }
    Ok(LoadSessionResponse::new())
}

fn list_sessions(
    app: &Arc<AppState>,
    request: &ListSessionsRequest,
) -> agent_client_protocol::Result<ListSessionsResponse> {
    let cwd = request
        .cwd
        .as_ref()
        .map(|path| validate_absolute_path(path))
        .transpose()?;
    let projects = app
        .db
        .list_projects()
        .map_err(|error| internal_error(format!("无法读取 workspace project：{error}")))?;
    let mut sessions = Vec::new();

    for project in projects {
        if cwd
            .as_ref()
            .is_some_and(|cwd| project.path != cwd_string(cwd))
        {
            continue;
        }
        let project_sessions = app
            .db
            .list_sessions(project.id)
            .map_err(|error| internal_error(format!("无法读取 session 列表：{error}")))?;
        sessions.extend(project_sessions.into_iter().map(|session| {
            SessionInfo::new(session.id.to_string(), PathBuf::from(project.path.clone()))
                .title(session.title)
                .updated_at(Some(session.updated_at))
        }));
    }

    Ok(ListSessionsResponse::new(sessions))
}

async fn delete_session(
    app: &Arc<AppState>,
    request: &DeleteSessionRequest,
) -> agent_client_protocol::Result<DeleteSessionResponse> {
    let session_id = parse_session_id(&request.session_id)?;
    match crate::session_service::delete_session(app, session_id).await {
        Ok(()) | Err(crate::session_service::SessionDeleteError::NotFound) => {
            Ok(DeleteSessionResponse::new())
        }
        Err(error) => Err(error.into_acp_error()),
    }
}

async fn close_session(
    app: &Arc<AppState>,
    request: &CloseSessionRequest,
) -> agent_client_protocol::Result<CloseSessionResponse> {
    let session_id = parse_session_id(&request.session_id)?;
    if let Some(run_id) = app.run_coordinator.active_run_id(session_id).await {
        let outcome = app.run_coordinator.cancel_run(run_id).await;
        debug!(%session_id, %run_id, ?outcome, "ACP session closed");
    }
    Ok(CloseSessionResponse::new())
}

async fn bridge_prompt(
    app: Arc<AppState>,
    connection: ConnectionTo<Client>,
    responder: Responder<PromptResponse>,
    session_uuid: Uuid,
    session_id: SessionId,
    prompt: String,
) -> agent_client_protocol::Result<()> {
    let managed_run = match crate::run_service::start_run(&app, session_uuid, prompt).await {
        Ok(run) => run,
        Err(crate::run_service::StartRunError::InvalidParams(message)) => {
            responder.respond_with_error(invalid_params(message))?;
            return Ok(());
        }
        Err(crate::run_service::StartRunError::Internal(message)) => {
            responder.respond_with_error(internal_error(message))?;
            return Ok(());
        }
    };

    let assistant_message_id = MessageId::new(format!("assistant-{}", Uuid::new_v4()));
    let mut events = managed_run.events;
    let mut accumulated_usage: Option<TokenUsage> = None;
    while let Some(output) = events.recv().await {
        match output {
            AgentOutput::TextDelta(delta) => {
                let chunk = ContentChunk::new(ContentBlock::Text(TextContent::new(delta)))
                    .message_id(assistant_message_id.clone());
                connection.send_notification(SessionNotification::new(
                    session_id.clone(),
                    SessionUpdate::AgentMessageChunk(chunk),
                ))?;
            }
            AgentOutput::Usage(usage) => {
                accumulated_usage = Some(accumulate_usage(&accumulated_usage, &usage));
                let mut meta = Meta::new();
                meta.insert(
                    "disco/usage".to_string(),
                    serde_json::json!({
                        "current": usage,
                        "accumulated": accumulated_usage.clone(),
                    }),
                );
                connection.send_notification(SessionNotification::new(
                    session_id.clone(),
                    SessionUpdate::UsageUpdate(
                        UsageUpdate::new(usage.total.max(0) as u64, 0).meta(meta),
                    ),
                ))?;
            }
            AgentOutput::ReasoningDelta(delta) => {
                let chunk = ContentChunk::new(ContentBlock::Text(TextContent::new(delta)))
                    .message_id(MessageId::new(format!("reasoning-{}", managed_run.run_id)));
                connection.send_notification(SessionNotification::new(
                    session_id.clone(),
                    SessionUpdate::AgentThoughtChunk(chunk),
                ))?;
            }
            AgentOutput::ToolStarted {
                tool_call_id,
                tool_name,
                arguments,
            } => {
                let tool = ToolCall::new(tool_call_id, tool_name.clone())
                    .kind(tool_kind(&tool_name))
                    .status(ToolCallStatus::InProgress)
                    .raw_input(parse_tool_json(&arguments));
                connection.send_notification(SessionNotification::new(
                    session_id.clone(),
                    SessionUpdate::ToolCall(tool),
                ))?;
            }
            AgentOutput::ToolCompleted {
                tool_call_id,
                output,
                ..
            } => {
                let fields = ToolCallUpdateFields::new()
                    .status(ToolCallStatus::Completed)
                    .raw_output(serde_json::Value::String(output));
                connection.send_notification(SessionNotification::new(
                    session_id.clone(),
                    SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(tool_call_id, fields)),
                ))?;
            }
            AgentOutput::ApprovalWaiting {
                approval_id,
                kind,
                title,
                impact,
                fingerprint,
                allows_session_approval,
            } => {
                let approval_kind = match kind.as_str() {
                    "command" => ApprovalKind::Command,
                    "file_change" => ApprovalKind::FileChange,
                    "network" => ApprovalKind::Network,
                    _ => ApprovalKind::Permission,
                };
                spawn_permission_request(
                    &app,
                    &connection,
                    session_id.clone(),
                    ApprovalRequestedData {
                        run_id: managed_run.run_id,
                        session_id: session_uuid,
                        approval_id,
                        kind: approval_kind,
                        title,
                        reason: None,
                        impact,
                        fingerprint,
                        allows_session_approval,
                    },
                )?;
            }
            AgentOutput::ApprovalResolved { .. } => {}
            AgentOutput::Completed => {
                responder.respond(PromptResponse::new(StopReason::EndTurn))?;
                return Ok(());
            }
            AgentOutput::Cancelled => {
                responder.respond(PromptResponse::new(StopReason::Cancelled))?;
                return Ok(());
            }
            AgentOutput::Failed(message) => {
                responder.respond_with_error(internal_error(message))?;
                return Ok(());
            }
        }
    }

    responder.respond_with_error(
        agent_client_protocol::Error::internal_error()
            .data("Disco run 在 ACP prompt 响应前结束，未产生终止状态。"),
    )?;
    Ok(())
}

fn spawn_permission_request(
    app: &Arc<AppState>,
    connection: &ConnectionTo<Client>,
    session_id: SessionId,
    data: disco_protocol::ApprovalRequestedData,
) -> agent_client_protocol::Result<()> {
    let mut meta = Meta::new();
    meta.insert(
        META_APPROVAL_ID.to_string(),
        serde_json::json!(data.approval_id),
    );
    meta.insert(
        META_APPROVAL_SCOPE.to_string(),
        serde_json::json!(if data.allows_session_approval {
            "session"
        } else {
            "once"
        }),
    );
    meta.insert(
        META_APPROVAL_FINGERPRINT.to_string(),
        serde_json::json!(data.fingerprint),
    );

    let tool_call = ToolCallUpdate::new(
        data.approval_id.to_string(),
        ToolCallUpdateFields::new()
            .title(data.title)
            .status(ToolCallStatus::Pending)
            .raw_input(serde_json::json!({
                "kind": format!("{:?}", data.kind),
                "impact": data.impact,
            })),
    );
    let mut options = vec![PermissionOption::new(
        "approve_once",
        "仅允许本次操作",
        PermissionOptionKind::AllowOnce,
    )];
    if data.allows_session_approval {
        options.push(PermissionOption::new(
            "approve_for_session",
            "本会话允许相同操作",
            PermissionOptionKind::AllowAlways,
        ));
    }
    options.push(PermissionOption::new(
        "decline",
        "拒绝操作",
        PermissionOptionKind::RejectOnce,
    ));

    let request = RequestPermissionRequest::new(session_id, tool_call, options).meta(meta);
    let approval_id = data.approval_id;
    let run_id = data.run_id;
    let task_connection = connection.clone();
    let app = app.clone();

    connection.clone().spawn(async move {
        let response = task_connection.send_request(request).block_task().await;
        let decision = match response {
            Ok(response) => match response.outcome {
                RequestPermissionOutcome::Cancelled => {
                    disco_protocol::types::ApprovalDecision::Decline
                }
                RequestPermissionOutcome::Selected(SelectedPermissionOutcome {
                    option_id, ..
                }) => match option_id.to_string().as_str() {
                    "approve_once" => disco_protocol::types::ApprovalDecision::ApproveOnce,
                    "approve_for_session" => {
                        disco_protocol::types::ApprovalDecision::ApproveForSession
                    }
                    _ => disco_protocol::types::ApprovalDecision::Decline,
                },
                _ => disco_protocol::types::ApprovalDecision::Decline,
            },
            Err(error) => {
                warn!(%error, %approval_id, "ACP permission request failed");
                disco_protocol::types::ApprovalDecision::Decline
            }
        };
        if !app
            .run_coordinator
            .respond_approval(approval_id, decision)
            .await
        {
            debug!(%run_id, %approval_id, "ACP permission response arrived after run ended");
        }
        Ok(())
    })
}

fn extract_prompt_text(prompt: &[ContentBlock]) -> agent_client_protocol::Result<String> {
    let text = prompt
        .iter()
        .filter_map(|block| match block {
            ContentBlock::Text(text) => Some(text.text.as_str()),
            _ => None,
        })
        .collect::<String>();
    if text.trim().is_empty() {
        return Err(invalid_params(
            "Disco ACP facade 当前只支持非空文本 prompt。",
        ));
    }
    Ok(text)
}

fn parse_session_id(session_id: &SessionId) -> agent_client_protocol::Result<Uuid> {
    Uuid::parse_str(session_id.to_string().as_str())
        .map_err(|_| invalid_params(format!("无效的 Disco session ID：{session_id}")))
}

fn validate_absolute_path(path: &Path) -> agent_client_protocol::Result<PathBuf> {
    if !path.is_absolute() {
        return Err(invalid_params(format!(
            "ACP workspace path 必须是绝对路径：{}",
            path.display()
        )));
    }
    Ok(path.to_path_buf())
}

fn cwd_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn project_name(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("Workspace")
        .to_string()
}

fn parse_tool_json(arguments: &str) -> serde_json::Value {
    serde_json::from_str(arguments)
        .unwrap_or_else(|_| serde_json::Value::String(arguments.to_string()))
}

fn tool_kind(tool_name: &str) -> ToolKind {
    match tool_name {
        "shell" => ToolKind::Execute,
        "search" => ToolKind::Search,
        "file_edit" | "file_write" => ToolKind::Edit,
        "file_read" => ToolKind::Read,
        _ => ToolKind::Other,
    }
}

fn invalid_params(message: impl Into<String>) -> agent_client_protocol::Error {
    agent_client_protocol::Error::invalid_params().data(message.into())
}

fn internal_error(message: impl Into<String>) -> agent_client_protocol::Error {
    agent_client_protocol::Error::internal_error().data(message.into())
}

fn resource_not_found(message: impl Into<String>) -> agent_client_protocol::Error {
    agent_client_protocol::Error::resource_not_found(None).data(message.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_client_protocol::Channel;
    use agent_client_protocol::schema::{ProtocolVersion, v1::ErrorCode};
    use std::time::Duration;

    #[test]
    fn extracts_text_content_blocks() {
        let prompt = vec![
            ContentBlock::Text(TextContent::new("hello ")),
            ContentBlock::Text(TextContent::new("world")),
        ];
        assert_eq!(extract_prompt_text(&prompt).unwrap(), "hello world");
    }

    #[test]
    fn rejects_non_text_prompt() {
        let prompt = vec![];
        let error = extract_prompt_text(&prompt).unwrap_err();
        assert_eq!(error.code, ErrorCode::InvalidParams);
    }

    #[test]
    fn session_ids_are_disco_uuids() {
        let id = Uuid::new_v4();
        let parsed = parse_session_id(&SessionId::new(id.to_string())).unwrap();
        assert_eq!(parsed, id);
        assert!(parse_session_id(&SessionId::new("not-a-uuid")).is_err());
    }

    #[test]
    fn initialize_response_uses_acp_camel_case_wire_names() {
        let response = InitializeResponse::new(ProtocolVersion::V1)
            .agent_capabilities(AgentCapabilities::new().load_session(true));
        let value = serde_json::to_value(response).unwrap();
        assert_eq!(value["protocolVersion"], 1);
        assert_eq!(value["agentCapabilities"]["loadSession"], true);
    }

    #[test]
    fn tool_mapping_preserves_json_arguments() {
        assert_eq!(tool_kind("shell"), ToolKind::Execute);
        assert_eq!(parse_tool_json(r#"{"command":"pwd"}"#)["command"], "pwd");
        assert_eq!(parse_tool_json("not-json"), serde_json::json!("not-json"));
    }

    #[test]
    fn permission_options_keep_session_scope_explicit() {
        let mut meta = Meta::new();
        meta.insert(
            META_APPROVAL_SCOPE.to_string(),
            serde_json::json!("session"),
        );
        let request = RequestPermissionRequest::new(
            SessionId::new(Uuid::new_v4().to_string()),
            ToolCallUpdate::new(
                "approval",
                ToolCallUpdateFields::new().status(ToolCallStatus::Pending),
            ),
            vec![PermissionOption::new(
                "approve_for_session",
                "本会话允许相同操作",
                PermissionOptionKind::AllowAlways,
            )],
        )
        .meta(meta);
        let value = serde_json::to_value(request).unwrap();
        assert_eq!(value["_meta"][META_APPROVAL_SCOPE], "session");
        assert_eq!(value["options"][0]["optionId"], "approve_for_session");
    }

    #[tokio::test]
    async fn acp_wire_prompt_streams_session_updates_and_returns_terminal() {
        let backend = Arc::new(crate::run_service::test_support::ScriptedBackend {
            outputs: vec![
                AgentOutput::TextDelta("wire hello".to_string()),
                AgentOutput::Usage(disco_protocol::types::TokenUsage {
                    input: 100,
                    output: 50,
                    total: 150,
                    cached_input: None,
                    reasoning_output: None,
                }),
                AgentOutput::Completed,
            ],
            backend_handle: None,
        });
        let (app, _session_id) = crate::run_service::test_support::make_test_app(backend);
        let (server_channel, client_channel) = Channel::duplex();
        let server_task = tokio::spawn(run_acp_server(app, server_channel));

        let (updates_tx, mut updates_rx) = tokio::sync::mpsc::unbounded_channel::<SessionUpdate>();
        let client = Client
            .builder()
            .on_receive_notification(
                {
                    let updates_tx = updates_tx.clone();
                    async move |notification: SessionNotification, _connection| {
                        let _ = updates_tx.send(notification.update);
                        Ok(())
                    }
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .connect_with(
                client_channel,
                async move |connection: ConnectionTo<Agent>| {
                    let initialize = connection
                        .send_request(InitializeRequest::new(ProtocolVersion::V1))
                        .block_task()
                        .await?;
                    assert_eq!(initialize.protocol_version, ProtocolVersion::V1);

                    let new_session = connection
                        .send_request(NewSessionRequest::new("/tmp/disco-wire-test"))
                        .block_task()
                        .await?;
                    let session_id = new_session.session_id;

                    let prompt = connection
                        .send_request(PromptRequest::new(
                            session_id,
                            vec![ContentBlock::Text(TextContent::new("wire test"))],
                        ))
                        .block_task()
                        .await?;
                    assert_eq!(prompt.stop_reason, StopReason::EndTurn);
                    Ok(())
                },
            );

        let client_result = tokio::time::timeout(Duration::from_secs(5), client).await;
        server_task.abort();
        client_result
            .expect("ACP wire client 超时")
            .expect("ACP wire client 失败");

        let update = tokio::time::timeout(Duration::from_secs(1), updates_rx.recv())
            .await
            .expect("等待 session update 超时")
            .expect("session update 流意外结束");
        match update {
            SessionUpdate::AgentMessageChunk(chunk) => match chunk.content {
                ContentBlock::Text(text) => assert_eq!(text.text, "wire hello"),
                _ => panic!("期望文本内容"),
            },
            other => panic!("期望 agent_message_chunk，收到 {other:?}"),
        }

        let usage_update = tokio::time::timeout(Duration::from_secs(1), updates_rx.recv())
            .await
            .expect("等待 usage update 超时")
            .expect("usage update 流意外结束");
        match usage_update {
            SessionUpdate::UsageUpdate(update) => {
                assert_eq!(update.used, 150);
                let disco_usage = update
                    .meta
                    .as_ref()
                    .and_then(|meta| meta.get("disco/usage"));
                assert!(disco_usage.is_some(), "UsageUpdate 应携带 disco/usage 明细");
            }
            other => panic!("期望 usage_update，收到 {other:?}"),
        }
    }

    #[tokio::test]
    async fn acp_wire_cancel_stops_pending_prompt_with_cancelled_stop_reason() {
        let (app, _session_id) = crate::run_service::test_support::make_test_app(Arc::new(
            crate::run_service::test_support::CancellationBackend,
        ));
        let (server_channel, client_channel) = Channel::duplex();
        let server_task = tokio::spawn(run_acp_server(app, server_channel));

        let client = Client.builder().connect_with(
            client_channel,
            async move |connection: ConnectionTo<Agent>| {
                let initialize = connection
                    .send_request(InitializeRequest::new(ProtocolVersion::V1))
                    .block_task()
                    .await?;
                assert_eq!(initialize.protocol_version, ProtocolVersion::V1);

                let new_session = connection
                    .send_request(NewSessionRequest::new("/tmp/disco-wire-test"))
                    .block_task()
                    .await?;
                let session_id = new_session.session_id;

                let prompt_task = connection
                    .send_request(PromptRequest::new(
                        session_id.clone(),
                        vec![ContentBlock::Text(TextContent::new("cancel me"))],
                    ))
                    .block_task();
                tokio::pin!(prompt_task);
                tokio::time::sleep(Duration::from_millis(50)).await;
                connection.send_notification(CancelNotification::new(session_id))?;

                let response = (&mut prompt_task).await?;
                assert_eq!(response.stop_reason, StopReason::Cancelled);
                Ok(())
            },
        );

        let client_result = tokio::time::timeout(Duration::from_secs(5), client).await;
        server_task.abort();
        client_result
            .expect("ACP wire client 超时")
            .expect("ACP wire client 失败");
    }
}
