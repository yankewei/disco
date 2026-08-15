use std::sync::Arc;

use disco_core::{AgentLoop, AgentOutput, ApprovalManager};
use disco_protocol::*;
use disco_providers::openai_responses::{ChatMessage, ToolCallInfo};
use disco_providers::{CodexProvider, ModelProvider, OpenAIResponsesProvider};
use tokio::sync::mpsc::Sender;
use tokio_util::sync::CancellationToken;
use tokio_stream::StreamExt;
use tracing::{debug, error, info, warn};
use uuid::Uuid;

use crate::daemon::AppState;

/// Handle a single request and send the response (and any events) via the output channel.
pub async fn handle_request(
    req: &Request,
    app: &Arc<AppState>,
    out_tx: &Sender<String>,
) {
    let response = match req.method.as_str() {
        "initialize" => handle_initialize(req),
        "shutdown" => handle_shutdown(req, app),
        "run/start" => handle_run_start(req, app, out_tx).await,
        "run/cancel" => handle_run_cancel(req, app),
        "run/approve" => handle_run_approve(req, app).await,
        "run/compact" => handle_run_compact(req, app, out_tx).await,
        "session/create" => handle_session_create(req, app),
        "session/list" => handle_session_list(req, app),
        "session/delete" => handle_session_delete(req, app),
        "session/projects" => handle_session_projects(req, app),
        "session/project/create" => handle_session_project_create(req, app),
        "provider/configure" => handle_provider_configure(req, app).await,
        "provider/list" => handle_provider_list(req, app),
        "provider/models" => handle_provider_models(req, app).await,
        other => {
            warn!("Unknown method: {other}");
            error_response(req.id, RpcError::method_not_found(other))
        }
    };

    if let Ok(jsonl) = encode_jsonl(&response) {
        let _ = out_tx.send(jsonl).await;
    }
}

// MARK: - Helpers

fn success_response<T: serde::Serialize>(id: i64, result: T) -> Response {
    Response {
        id,
        result: Some(serde_json::to_value(result).unwrap()),
        error: None,
    }
}

fn error_response(id: i64, error: RpcError) -> Response {
    Response {
        id,
        result: None,
        error: Some(error),
    }
}

// MARK: - Handlers

fn handle_initialize(req: &Request) -> Response {
    let _params: InitializeParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => return error_response(req.id, RpcError::invalid_params(&e.to_string())),
    };

    let result = InitializeResult {
        daemon_version: env!("CARGO_PKG_VERSION").to_string(),
        protocol_version: "v1".to_string(),
    };

    info!(
        "Client initialized (protocol {})",
        result.protocol_version
    );
    success_response(req.id, result)
}

fn handle_shutdown(req: &Request, app: &Arc<AppState>) -> Response {
    info!("Shutdown requested");
    app.shutdown.cancel();
    success_response(req.id, ShutdownResult {})
}

async fn handle_run_start(
    req: &Request,
    app: &Arc<AppState>,
    out_tx: &Sender<String>,
) -> Response {
    let params: RunStartParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => return error_response(req.id, RpcError::invalid_params(&e.to_string())),
    };

    let run_id = Uuid::new_v4();
    let session_id = params.session_id;
    let cancel = CancellationToken::new();

    // Register the run
    app.active_runs.lock().await.insert(run_id, cancel.clone());

    // Look up the session to get the vendor
    let vendor = app
        .db
        .get_session(session_id)
        .ok()
        .flatten()
        .map(|s| s.vendor);

    // Get the appropriate provider
    let provider = match app.get_provider(vendor).await {
        Some(p) => p,
        None => {
            app.active_runs.lock().await.remove(&run_id);
            return error_response(
                req.id,
                RpcError::internal("未配置模型服务商：请在设置中配置（或设置 OPENAI_API_KEY 环境变量）"),
            );
        }
    };

    // Save the user message to the database
    if let Err(e) = app.db.add_message(session_id, "user", &params.text) {
        app.active_runs.lock().await.remove(&run_id);
        return error_response(req.id, RpcError::internal(&format!("Failed to save message: {e}")));
    }

    // Load message history from the database
    let stored_messages = match app.db.list_messages(session_id) {
        Ok(msgs) => msgs,
        Err(e) => {
            app.active_runs.lock().await.remove(&run_id);
            return error_response(
                req.id,
                RpcError::internal(&format!("Failed to load messages: {e}")),
            );
        }
    };

    // Convert to ChatMessage format, handling tool calls and results
    let chat_messages: Vec<ChatMessage> = stored_messages
        .iter()
        .filter_map(|m| {
            if m.role == "tool_call" {
                // Parse tool call from JSON
                if let Ok(tc) = serde_json::from_str::<ToolCallInfo>(&m.text) {
                    return Some(ChatMessage {
                        role: "assistant".to_string(),
                        text: String::new(),
                        tool_calls: Some(vec![tc]),
                        ..Default::default()
                    });
                }
                None
            } else if m.role == "tool_result" {
                // Parse tool result from JSON
                if let Ok(info) = serde_json::from_str::<serde_json::Value>(&m.text) {
                    return Some(ChatMessage {
                        role: "user".to_string(),
                        text: info["output"].as_str().unwrap_or("").to_string(),
                        tool_call_id: info["call_id"].as_str().map(String::from),
                        tool_name: info["name"].as_str().map(String::from),
                        ..Default::default()
                    });
                }
                None
            } else {
                Some(ChatMessage {
                    role: m.role.clone(),
                    text: m.text.clone(),
                    ..Default::default()
                })
            }
        })
        .collect();

    debug!(
        "Starting run {run_id} for session {session_id} with {} messages",
        chat_messages.len()
    );

    // Send run state event: connecting
    send_event(
        out_tx,
        &Event::run_state(RunStateData {
            run_id,
            session_id,
            state: RunState::Connecting,
        }),
    );

    // Create approval manager for this run
    let session_approved = Arc::new(tokio::sync::Mutex::new(Vec::<String>::new()));
    let approval_manager = Arc::new(ApprovalManager::new(session_approved));

    // Register the approval manager
    app.active_approval
        .lock()
        .await
        .insert(run_id, approval_manager.clone());

    // Create agent loop
    let agent = AgentLoop::new(provider, app.executor.clone(), approval_manager);

    // Spawn the agent task
    let out_tx_clone = out_tx.clone();
    let app_clone = Arc::clone(app);

    tokio::spawn(async move {
        // Send run state: running
        send_event(
            &out_tx_clone,
            &Event::run_state(RunStateData {
                run_id,
                session_id,
                state: RunState::Running,
            }),
        );

        let mut stream = agent
            .run(chat_messages, cancel.clone(), run_id, session_id, None)
            .await;
        let mut full_response = String::new();
        let mut accumulated_usage: Option<TokenUsage> = None;

        while let Some(output) = stream.next().await {
            match output {
                AgentOutput::TextDelta(delta) => {
                    full_response.push_str(&delta);
                    send_event(
                        &out_tx_clone,
                        &Event::message_delta(MessageDeltaData {
                            run_id,
                            session_id,
                            delta,
                        }),
                    );
                }
                AgentOutput::ReasoningDelta(delta) => {
                    send_event(
                        &out_tx_clone,
                        &Event::reasoning_delta(ReasoningDeltaData {
                            run_id,
                            session_id,
                            delta,
                        }),
                    );
                }
                AgentOutput::Usage(usage) => {
                    accumulated_usage = Some(accumulate_usage(&accumulated_usage, &usage));

                    send_event(
                        &out_tx_clone,
                        &Event::context_usage(ContextUsageData {
                            run_id,
                            session_id,
                            current: usage,
                            accumulated: accumulated_usage.clone(),
                            context_window: None,
                            source: UsageSource::Provider,
                        }),
                    );
                }
                AgentOutput::ToolStarted {
                    tool_call_id,
                    tool_name,
                    arguments,
                } => {
                    // Send waiting_for_tool state
                    send_event(
                        &out_tx_clone,
                        &Event::run_state(RunStateData {
                            run_id,
                            session_id,
                            state: RunState::WaitingForTool,
                        }),
                    );
                    send_event(
                        &out_tx_clone,
                        &Event::tool_started(ToolStartedData {
                            run_id,
                            session_id,
                            tool_call_id,
                            tool_name,
                            arguments,
                        }),
                    );
                }
                AgentOutput::ToolCompleted {
                    tool_call_id,
                    tool_name,
                    output,
                } => {
                    send_event(
                        &out_tx_clone,
                        &Event::tool_completed(ToolCompletedData {
                            run_id,
                            session_id,
                            tool_call_id,
                            tool_name,
                            output,
                        }),
                    );
                    // Back to running
                    send_event(
                        &out_tx_clone,
                        &Event::run_state(RunStateData {
                            run_id,
                            session_id,
                            state: RunState::Running,
                        }),
                    );
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
                    send_event(
                        &out_tx_clone,
                        &Event::run_state(RunStateData {
                            run_id,
                            session_id,
                            state: RunState::WaitingForApproval,
                        }),
                    );
                    send_event(
                        &out_tx_clone,
                        &Event::approval_requested(ApprovalRequestedData {
                            run_id,
                            session_id,
                            approval_id,
                            kind: approval_kind,
                            title,
                            reason: None,
                            impact,
                            fingerprint,
                            allows_session_approval,
                        }),
                    );
                }
                AgentOutput::ApprovalResolved {
                    approval_id,
                    decision,
                } => {
                    send_event(
                        &out_tx_clone,
                        &Event::approval_resolved(ApprovalResolvedData {
                            run_id,
                            approval_id,
                            decision,
                        }),
                    );
                }
                AgentOutput::Completed => {
                    save_assistant_message(&app_clone, session_id, &full_response).await;
                    // Clean up approval manager
                    app_clone.active_approval.lock().await.remove(&run_id);
                    send_event(
                        &out_tx_clone,
                        &Event::run_completed(RunCompletedData {
                            run_id,
                            session_id,
                        }),
                    );
                    app_clone.active_runs.lock().await.remove(&run_id);
                    return;
                }
                AgentOutput::Failed(error) => {
                    save_assistant_message(&app_clone, session_id, &full_response).await;
                    app_clone.active_approval.lock().await.remove(&run_id);
                    send_event(
                        &out_tx_clone,
                        &Event::run_failed(RunFailedData {
                            run_id,
                            session_id,
                            error: RunError {
                                code: ErrorCode::Generic,
                                message: error,
                                recovery_suggestion: None,
                                retryable: false,
                            },
                        }),
                    );
                    app_clone.active_runs.lock().await.remove(&run_id);
                    return;
                }
                AgentOutput::Cancelled => {
                    save_assistant_message(&app_clone, session_id, &full_response).await;
                    app_clone.active_approval.lock().await.remove(&run_id);
                    send_event(
                        &out_tx_clone,
                        &Event::run_cancelled(RunCancelledData {
                            run_id,
                            session_id,
                        }),
                    );
                    app_clone.active_runs.lock().await.remove(&run_id);
                    return;
                }
            }
        }

        // Stream ended without explicit terminal event
        save_assistant_message(&app_clone, session_id, &full_response).await;
        app_clone.active_approval.lock().await.remove(&run_id);
        send_event(
            &out_tx_clone,
            &Event::run_completed(RunCompletedData {
                run_id,
                session_id,
            }),
        );
        app_clone.active_runs.lock().await.remove(&run_id);
    });

    success_response(req.id, RunStartResult { run_id })
}

fn handle_run_cancel(req: &Request, app: &Arc<AppState>) -> Response {
    let params: RunCancelParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => return error_response(req.id, RpcError::invalid_params(&e.to_string())),
    };

    let active_runs = app.active_runs.try_lock();
    match active_runs {
        Ok(runs) => {
            if let Some(cancel) = runs.get(&params.run_id) {
                info!("Cancelling run {}", params.run_id);
                cancel.cancel();
                success_response(req.id, RunCancelResult {})
            } else {
                error_response(
                    req.id,
                    RpcError::invalid_params(&format!("Run {} not found", params.run_id)),
                )
            }
        }
        Err(_) => {
            warn!("Could not acquire active_runs lock for cancel");
            error_response(req.id, RpcError::internal("Could not cancel run"))
        }
    }
}

async fn handle_run_approve(req: &Request, app: &Arc<AppState>) -> Response {
    let params: RunApproveParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => return error_response(req.id, RpcError::invalid_params(&e.to_string())),
    };

    // Find the approval manager for this approval by searching all active runs
    let managers = app.active_approval.lock().await;
    for (_run_id, manager) in managers.iter() {
        if manager.respond(params.approval_id, params.decision).await {
            info!("Approval {} resolved: {:?}", params.approval_id, params.decision);
            return success_response(req.id, RunApproveResult {});
        }
    }

    error_response(
        req.id,
        RpcError::invalid_params(&format!(
            "Approval {} not found",
            params.approval_id
        )),
    )
}

async fn handle_run_compact(
    req: &Request,
    app: &Arc<AppState>,
    out_tx: &Sender<String>,
) -> Response {
    let params: RunCompactParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => return error_response(req.id, RpcError::invalid_params(&e.to_string())),
    };

    let session_id = params.session_id;

    let stored_messages = match app.db.list_messages(session_id) {
        Ok(msgs) => msgs,
        Err(e) => {
            return error_response(
                req.id,
                RpcError::internal(&format!("Failed to load messages: {e}")),
            );
        }
    };

    if stored_messages.is_empty() {
        return error_response(
            req.id,
            RpcError::invalid_params("No messages to compact"),
        );
    }

    let chat_messages: Vec<ChatMessage> = stored_messages
        .iter()
        .map(|m| ChatMessage {
            role: m.role.clone(),
            text: m.text.clone(),
            ..Default::default()
        })
        .collect();

    let provider = match app.get_provider(None).await {
        Some(p) => p,
        None => {
            return error_response(
                req.id,
                RpcError::internal("未配置模型服务商：请在设置中配置（或设置 OPENAI_API_KEY 环境变量）"),
            );
        }
    };
    let compactor = disco_core::ContextCompactor::new(128000);

    let compaction_id = uuid::Uuid::new_v4().to_string();
    let _ = send_event(
        out_tx,
        &Event::context_compaction(ContextCompactionData {
            run_id: Uuid::nil(),
            session_id,
            id: compaction_id.clone(),
            runtime_kind: RuntimeKind::Generic,
            trigger: CompactionTrigger::Manual,
            status: CompactionStatus::Running,
            started_at: disco_persist::Database::now_iso8601(),
            completed_at: None,
            before_tokens: Some(compactor.estimate_tokens(&chat_messages)),
            after_tokens: None,
            error_message: None,
        }),
    );

    let result = compactor.compact(&chat_messages, &provider).await;

    let status = result.status;
    let before_tokens = result.before_tokens;
    let after_tokens = result.after_tokens;
    let error_message = result.error_message.clone();

    let _ = send_event(
        out_tx,
        &Event::context_compaction(ContextCompactionData {
            run_id: Uuid::nil(),
            session_id,
            id: result.id.clone(),
            runtime_kind: RuntimeKind::Generic,
            trigger: CompactionTrigger::Manual,
            status,
            started_at: disco_persist::Database::now_iso8601(),
            completed_at: Some(disco_persist::Database::now_iso8601()),
            before_tokens,
            after_tokens,
            error_message,
        }),
    );

    success_response(
        req.id,
        RunCompactResult {
            compaction: CompactionInfo {
                id: result.id,
                status: result.status,
                before_tokens: result.before_tokens,
                after_tokens: result.after_tokens,
            },
        },
    )
}

fn handle_session_create(req: &Request, app: &Arc<AppState>) -> Response {
    let params: SessionCreateParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => return error_response(req.id, RpcError::invalid_params(&e.to_string())),
    };

    match app.db.create_session(params.project_id, params.vendor, &params.model, None) {
        Ok(session) => success_response(req.id, SessionCreateResult { session }),
        Err(e) => error_response(req.id, RpcError::internal(&e.to_string())),
    }
}

fn handle_session_list(req: &Request, app: &Arc<AppState>) -> Response {
    let params: SessionListParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => return error_response(req.id, RpcError::invalid_params(&e.to_string())),
    };

    match app.db.list_sessions(params.project_id) {
        Ok(sessions) => success_response(req.id, SessionListResult { sessions }),
        Err(e) => error_response(req.id, RpcError::internal(&e.to_string())),
    }
}

fn handle_session_delete(req: &Request, app: &Arc<AppState>) -> Response {
    let params: SessionDeleteParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => return error_response(req.id, RpcError::invalid_params(&e.to_string())),
    };

    match app.db.delete_session(params.session_id) {
        Ok(()) => success_response(req.id, SessionDeleteResult {}),
        Err(e) => error_response(req.id, RpcError::internal(&e.to_string())),
    }
}

fn handle_session_projects(req: &Request, app: &Arc<AppState>) -> Response {
    match app.db.list_projects() {
        Ok(projects) => success_response(req.id, SessionProjectsResult { projects }),
        Err(e) => error_response(req.id, RpcError::internal(&e.to_string())),
    }
}

fn handle_session_project_create(req: &Request, app: &Arc<AppState>) -> Response {
    let params: SessionProjectCreateParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => return error_response(req.id, RpcError::invalid_params(&e.to_string())),
    };

    match app.db.create_project(&params.name, &params.path) {
        Ok(project) => success_response(req.id, SessionProjectCreateResult { project }),
        Err(e) => error_response(req.id, RpcError::internal(&e.to_string())),
    }
}

// MARK: - Provider handlers

async fn handle_provider_configure(req: &Request, app: &Arc<AppState>) -> Response {
    let params: ProviderConfigureParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => return error_response(req.id, RpcError::invalid_params(&e.to_string())),
    };

    let config = disco_persist::provider_configs::ProviderConfig {
        vendor: params.vendor,
        base_url: params.base_url.clone(),
        api_key: params.api_key.clone(),
        model: params.model.clone(),
        thinking_enabled: params.thinking_enabled,
        updated_at: String::new(),
    };

    if let Err(e) = app.db.save_provider_config(&config) {
        return error_response(req.id, RpcError::internal(&format!("Failed to save config: {e}")));
    }

    // Codex 走本地 codex app-server（ChatGPT 订阅，无需 API Key）；
    // 其余服务商走 OpenAI 兼容 API。
    let provider: Arc<dyn ModelProvider> = match params.vendor {
        Vendor::Codex => Arc::new(CodexProvider::new(
            CodexProvider::find_codex(),
            params.model,
            None,
            None,
        )),
        _ => Arc::new(OpenAIResponsesProvider::new(
            params.base_url,
            params.api_key,
            params.model,
        )),
    };

    app.set_provider(params.vendor, provider).await;

    info!("Provider configured: {:?}", params.vendor);

    success_response(
        req.id,
        ProviderConfigureResult {
            vendor: params.vendor,
        },
    )
}

fn handle_provider_list(req: &Request, app: &Arc<AppState>) -> Response {
    match app.db.list_provider_configs() {
        Ok(configs) => {
            let providers: Vec<ProviderEntry> = configs
                .into_iter()
                .map(|c| ProviderEntry {
                    vendor: c.vendor,
                    base_url: c.base_url,
                    model: c.model,
                    thinking_enabled: c.thinking_enabled,
                })
                .collect();
            success_response(req.id, ProviderListResult { providers })
        }
        Err(e) => error_response(req.id, RpcError::internal(&e.to_string())),
    }
}

async fn handle_provider_models(req: &Request, app: &Arc<AppState>) -> Response {
    let params: ProviderModelsParams = match serde_json::from_value(req.params.clone()) {
        Ok(p) => p,
        Err(e) => return error_response(req.id, RpcError::invalid_params(&e.to_string())),
    };

    let _provider = app.get_provider(Some(params.vendor)).await;
    let models = get_default_models(params.vendor);

    success_response(req.id, ProviderModelsResult { models })
}

fn get_default_models(vendor: Vendor) -> Vec<ModelCatalogEntry> {
    match vendor {
        Vendor::Openai => vec![
            ModelCatalogEntry {
                id: "gpt-4o".to_string(),
                display_name: Some("GPT-4o".to_string()),
                context_window: Some(128000),
                supported_reasoning_efforts: None,
                default_reasoning_effort: None,
            },
            ModelCatalogEntry {
                id: "gpt-4o-mini".to_string(),
                display_name: Some("GPT-4o mini".to_string()),
                context_window: Some(128000),
                supported_reasoning_efforts: None,
                default_reasoning_effort: None,
            },
            ModelCatalogEntry {
                id: "o4-mini".to_string(),
                display_name: Some("o4-mini".to_string()),
                context_window: Some(200000),
                supported_reasoning_efforts: Some(vec![
                    "low".to_string(),
                    "medium".to_string(),
                    "high".to_string(),
                ]),
                default_reasoning_effort: Some("medium".to_string()),
            },
        ],
        Vendor::Deepseek => vec![
            ModelCatalogEntry {
                id: "deepseek-chat".to_string(),
                display_name: Some("DeepSeek Chat".to_string()),
                context_window: Some(64000),
                supported_reasoning_efforts: None,
                default_reasoning_effort: None,
            },
            ModelCatalogEntry {
                id: "deepseek-reasoner".to_string(),
                display_name: Some("DeepSeek Reasoner".to_string()),
                context_window: Some(64000),
                supported_reasoning_efforts: None,
                default_reasoning_effort: None,
            },
        ],
        Vendor::MoonshotKimi | Vendor::KimiCode => vec![ModelCatalogEntry {
            id: "kimi-latest".to_string(),
            display_name: Some("Kimi".to_string()),
            context_window: Some(128000),
            supported_reasoning_efforts: Some(vec![
                "none".to_string(),
                "low".to_string(),
                "high".to_string(),
            ]),
            default_reasoning_effort: Some("high".to_string()),
        }],
        Vendor::Glm => vec![ModelCatalogEntry {
            id: "glm-4-plus".to_string(),
            display_name: Some("GLM-4 Plus".to_string()),
            context_window: Some(128000),
            supported_reasoning_efforts: None,
            default_reasoning_effort: None,
        }],
        Vendor::Codex => vec![ModelCatalogEntry {
            id: "codex".to_string(),
            display_name: Some("Codex".to_string()),
            context_window: Some(200000),
            supported_reasoning_efforts: Some(vec![
                "low".to_string(),
                "medium".to_string(),
                "high".to_string(),
            ]),
            default_reasoning_effort: Some("medium".to_string()),
        }],
    }
}

fn send_event(out_tx: &Sender<String>, event: &serde_json::Result<Event>) {
    match event {
        Ok(event) => {
            if let Ok(jsonl) = encode_jsonl(event) {
                if out_tx.try_send(jsonl).is_err() {
                    warn!("Failed to send event (channel full or closed)");
                }
            }
        }
        Err(e) => {
            error!("Failed to construct event: {e}");
        }
    }
}

async fn save_assistant_message(app: &AppState, session_id: Uuid, text: &str) {
    if text.is_empty() {
        return;
    }
    if let Err(e) = app.db.add_message(session_id, "assistant", text) {
        tracing::error!("Failed to save assistant message: {e}");
    }
}

fn accumulate_usage(prev: &Option<TokenUsage>, current: &TokenUsage) -> TokenUsage {
    match prev {
        Some(p) => TokenUsage {
            input: p.input + current.input,
            output: p.output + current.output,
            total: p.total + current.total,
            cached_input: match (p.cached_input, current.cached_input) {
                (Some(a), Some(b)) => Some(a + b),
                (Some(a), None) => Some(a),
                (None, Some(b)) => Some(b),
                (None, None) => None,
            },
            reasoning_output: match (p.reasoning_output, current.reasoning_output) {
                (Some(a), Some(b)) => Some(a + b),
                (Some(a), None) => Some(a),
                (None, Some(b)) => Some(b),
                (None, None) => None,
            },
        },
        None => current.clone(),
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use disco_protocol::types::Vendor;
    use disco_providers::OpenAIResponsesProvider;
    use disco_tools::CompositeExecutor;
    use std::collections::HashMap;
    use std::sync::Arc;
    use tokio::sync::Mutex;
    use tokio_util::sync::CancellationToken;

    fn make_test_app() -> Arc<AppState> {
        let dir = std::env::temp_dir().join(format!("disco-router-test-{}", Uuid::new_v4()));
        let db = disco_persist::Database::open(&dir.join("test.db")).unwrap();
        let provider: Arc<dyn ModelProvider> = Arc::new(OpenAIResponsesProvider::new(
            "https://api.openai.com/v1".to_string(),
            "test-key".to_string(),
            "gpt-4".to_string(),
        ));

        Arc::new(AppState {
            db,
            provider: Some(provider),
            providers: Mutex::new(HashMap::new()),
            active_runs: Mutex::new(HashMap::new()),
            active_approval: Mutex::new(HashMap::new()),
            executor: Arc::new(CompositeExecutor::new()),
            shutdown: CancellationToken::new(),
        })
    }

    #[test]
    fn test_initialize() {
        let req = Request {
            id: 1,
            method: "initialize".to_string(),
            params: serde_json::to_value(InitializeParams {
                client_info: ClientInfo {
                    name: "test".to_string(),
                    version: "0.1.0".to_string(),
                },
                protocol_version: "v1".to_string(),
            })
            .unwrap(),
        };

        let resp = handle_initialize(&req);
        assert!(resp.error.is_none());
        assert!(resp.result.is_some());

        let result: InitializeResult = serde_json::from_value(resp.result.unwrap()).unwrap();
        assert_eq!(result.protocol_version, "v1");
    }

    #[test]
    fn test_unknown_method() {
        let req = Request {
            id: 1,
            method: "unknown/method".to_string(),
            params: serde_json::Value::Null,
        };

        let resp = error_response(req.id, RpcError::method_not_found("unknown/method"));
        assert!(resp.result.is_none());
        assert_eq!(resp.error.as_ref().unwrap().code, -32601);
    }

    #[test]
    fn test_session_project_create_and_list() {
        let app = make_test_app();

        let req = Request {
            id: 1,
            method: "session/project/create".to_string(),
            params: serde_json::to_value(SessionProjectCreateParams {
                name: "Test Project".to_string(),
                path: "/tmp/test-project".to_string(),
            })
            .unwrap(),
        };

        let resp = handle_session_project_create(&req, &app);
        assert!(resp.error.is_none());
        let result: SessionProjectCreateResult =
            serde_json::from_value(resp.result.unwrap()).unwrap();
        assert_eq!(result.project.name, "Test Project");

        let req = Request {
            id: 2,
            method: "session/projects".to_string(),
            params: serde_json::Value::Null,
        };

        let resp = handle_session_projects(&req, &app);
        assert!(resp.error.is_none());
        let result: SessionProjectsResult =
            serde_json::from_value(resp.result.unwrap()).unwrap();
        assert_eq!(result.projects.len(), 1);
    }

    #[test]
    fn test_session_create_and_list() {
        let app = make_test_app();
        let project = app.db.create_project("Test", "/tmp/test").unwrap();

        let req = Request {
            id: 1,
            method: "session/create".to_string(),
            params: serde_json::to_value(SessionCreateParams {
                project_id: project.id,
                vendor: Vendor::Openai,
                model: "gpt-4".to_string(),
            })
            .unwrap(),
        };

        let resp = handle_session_create(&req, &app);
        assert!(resp.error.is_none());
        let result: SessionCreateResult =
            serde_json::from_value(resp.result.unwrap()).unwrap();
        assert_eq!(result.session.model, "gpt-4");

        let req = Request {
            id: 2,
            method: "session/list".to_string(),
            params: serde_json::to_value(SessionListParams {
                project_id: project.id,
            })
            .unwrap(),
        };

        let resp = handle_session_list(&req, &app);
        assert!(resp.error.is_none());
        let result: SessionListResult =
            serde_json::from_value(resp.result.unwrap()).unwrap();
        assert_eq!(result.sessions.len(), 1);
    }

    #[test]
    fn test_session_delete() {
        let app = make_test_app();
        let project = app.db.create_project("Test", "/tmp/test-del").unwrap();
        let session = app
            .db
            .create_session(project.id, Vendor::Openai, "gpt-4", None)
            .unwrap();

        let req = Request {
            id: 1,
            method: "session/delete".to_string(),
            params: serde_json::to_value(SessionDeleteParams {
                session_id: session.id,
            })
            .unwrap(),
        };

        let resp = handle_session_delete(&req, &app);
        assert!(resp.error.is_none());

        let sessions = app.db.list_sessions(project.id).unwrap();
        assert!(sessions.is_empty());
    }

    #[test]
    fn test_run_cancel_nonexistent() {
        let app = make_test_app();

        let req = Request {
            id: 1,
            method: "run/cancel".to_string(),
            params: serde_json::to_value(RunCancelParams {
                run_id: Uuid::new_v4(),
            })
            .unwrap(),
        };

        let resp = handle_run_cancel(&req, &app);
        assert!(resp.error.is_some());
    }

    #[test]
    fn test_invalid_params() {
        let app = make_test_app();

        let req = Request {
            id: 1,
            method: "session/create".to_string(),
            params: serde_json::json!({"bad": "params"}),
        };

        let resp = handle_session_create(&req, &app);
        assert!(resp.error.is_some());
        assert_eq!(resp.error.as_ref().unwrap().code, -32602);
    }

    #[tokio::test]
    async fn test_provider_configure_and_list() {
        let app = make_test_app();

        let req = Request {
            id: 1,
            method: "provider/configure".to_string(),
            params: serde_json::to_value(ProviderConfigureParams {
                vendor: Vendor::Deepseek,
                base_url: "https://api.deepseek.com/v1".to_string(),
                api_key: "sk-test".to_string(),
                model: "deepseek-chat".to_string(),
                thinking_enabled: false,
            })
            .unwrap(),
        };

        let resp = handle_provider_configure(&req, &app).await;
        assert!(resp.error.is_none());
        let result: ProviderConfigureResult =
            serde_json::from_value(resp.result.unwrap()).unwrap();
        assert_eq!(result.vendor, Vendor::Deepseek);

        let req = Request {
            id: 2,
            method: "provider/list".to_string(),
            params: serde_json::Value::Null,
        };

        let resp = handle_provider_list(&req, &app);
        assert!(resp.error.is_none());
        let result: ProviderListResult =
            serde_json::from_value(resp.result.unwrap()).unwrap();
        assert_eq!(result.providers.len(), 1);
        assert_eq!(result.providers[0].vendor, Vendor::Deepseek);
        assert_eq!(result.providers[0].model, "deepseek-chat");
    }

    #[tokio::test]
    async fn test_provider_models() {
        let app = make_test_app();

        let req = Request {
            id: 1,
            method: "provider/models".to_string(),
            params: serde_json::to_value(ProviderModelsParams {
                vendor: Vendor::Openai,
            })
            .unwrap(),
        };

        let resp = handle_provider_models(&req, &app).await;
        assert!(resp.error.is_none());
        let result: ProviderModelsResult =
            serde_json::from_value(resp.result.unwrap()).unwrap();
        assert!(!result.models.is_empty());
        assert!(result.models.iter().any(|m| m.id == "gpt-4o"));
    }

    #[test]
    fn test_get_default_models() {
        let models = get_default_models(Vendor::Openai);
        assert!(!models.is_empty());
        assert!(models.iter().any(|m| m.id == "gpt-4o"));

        let models = get_default_models(Vendor::Deepseek);
        assert!(!models.is_empty());
        assert!(models.iter().any(|m| m.id == "deepseek-chat"));

        let models = get_default_models(Vendor::Codex);
        assert!(!models.is_empty());
    }

    #[tokio::test]
    async fn test_run_approve_not_found() {
        let app = make_test_app();

        let req = Request {
            id: 1,
            method: "run/approve".to_string(),
            params: serde_json::to_value(RunApproveParams {
                approval_id: Uuid::new_v4(),
                decision: ApprovalDecision::ApproveOnce,
            })
            .unwrap(),
        };

        let resp = handle_run_approve(&req, &app).await;
        assert!(resp.error.is_some());
    }
}
