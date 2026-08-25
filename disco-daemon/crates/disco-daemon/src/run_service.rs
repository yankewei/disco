use std::sync::Arc;

use disco_core::{AgentOutput, BackendRunRequest, BackendSession, BeginRunError, CompactionMode};
use disco_persist::messages::{StoredMessage, StoredToolCall};
use disco_protocol::types::TokenUsage;
use disco_providers::openai_responses::{ChatMessage, ToolCallInfo};
use tokio::sync::mpsc;
use tokio_stream::StreamExt;
use uuid::Uuid;

use crate::daemon::AppState;

/// 启动运行时的协议无关错误。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StartRunError {
    InvalidParams(String),
    Internal(String),
}

/// 已经注册到 `RunCoordinator` 的运行，以及协议 facade 消费的事件流。
pub struct ManagedRun {
    pub run_id: Uuid,
    pub events: mpsc::Receiver<AgentOutput>,
}

/// 共享的 agent run service。
///
/// ACP facade 只负责把 `AgentOutput` 映射到 wire event；session 校验、历史加载、
/// backend 启动、assistant 消息持久化和 run 终止语义全部在这里完成。
pub async fn start_run(
    app: &Arc<AppState>,
    session_id: Uuid,
    text: String,
) -> Result<ManagedRun, StartRunError> {
    let session = match app.db.get_session(session_id) {
        Ok(Some(session)) => session,
        Ok(None) => {
            return Err(StartRunError::InvalidParams(format!(
                "会话 {session_id} 不存在"
            )));
        }
        Err(error) => return Err(StartRunError::Internal(error.to_string())),
    };

    let started_run = match app.run_coordinator.begin_run(session_id).await {
        Ok(started_run) => started_run,
        Err(BeginRunError::SessionBusy { active_run_id }) => {
            return Err(StartRunError::InvalidParams(format!(
                "会话 {session_id} 已有活动任务 {active_run_id}"
            )));
        }
    };
    let run_id = started_run.run_id;

    let workspace_path = app
        .db
        .get_project(session.project_id)
        .ok()
        .flatten()
        .map(|project| project.path);

    let backend = match app.get_backend(&session.provider_id).await {
        Some(backend) => backend,
        None => {
            app.run_coordinator.finish_run(run_id).await;
            return Err(StartRunError::Internal(
                "未配置 Agent Backend：请先在设置中配置该 Provider".to_string(),
            ));
        }
    };

    let user_message_result = {
        let _state_guard = app.state_lock.lock().await;
        let result = app.db.add_message(session_id, "user", &text);
        if result.is_ok() {
            app.bump_state_revision();
        }
        result
    };
    if let Err(error) = user_message_result {
        app.run_coordinator.finish_run(run_id).await;
        return Err(StartRunError::Internal(format!(
            "保存用户消息失败：{error}"
        )));
    }

    let stored_messages = match app.db.list_messages(session_id) {
        Ok(messages) => messages,
        Err(error) => {
            app.run_coordinator.finish_run(run_id).await;
            return Err(StartRunError::Internal(format!(
                "读取消息历史失败：{error}"
            )));
        }
    };
    let chat_messages = match backend.capabilities().compaction {
        CompactionMode::Local => messages_for_local_context(app, session_id, &stored_messages),
        CompactionMode::Native | CompactionMode::Unsupported => stored_messages
            .iter()
            .map(stored_message_to_chat_message)
            .collect::<Vec<_>>(),
    };

    let backend_handle = match app.db.get_session_backend_handle(session_id) {
        Ok(handle) => handle,
        Err(error) => {
            app.run_coordinator.finish_run(run_id).await;
            return Err(StartRunError::Internal(error.to_string()));
        }
    };

    let backend_request = BackendRunRequest {
        run_id,
        session: BackendSession {
            id: session_id,
            model: session.model,
            backend_handle,
        },
        messages: chat_messages,
        workspace_path,
        cancellation: started_run.cancellation.clone(),
        approval_manager: started_run.approval_manager,
    };
    let cancellation = started_run.cancellation;
    let (event_tx, event_rx) = mpsc::channel(256);
    let app = Arc::clone(app);

    tokio::spawn(async move {
        let backend_run = match backend.start_run(backend_request).await {
            Ok(run) => run,
            Err(error) => {
                let output = if cancellation.is_cancelled() {
                    AgentOutput::Cancelled
                } else {
                    AgentOutput::Failed(error.to_string())
                };
                let _ = event_tx.send(output).await;
                app.run_coordinator.finish_run(run_id).await;
                return;
            }
        };

        let backend_handle_result = if let Some(handle) = backend_run.backend_handle.as_deref() {
            let _state_guard = app.state_lock.lock().await;
            let result = app.db.set_session_backend_handle(session_id, handle);
            if result.is_ok() {
                app.bump_state_revision();
            }
            result
        } else {
            Ok(())
        };
        if let Err(error) = backend_handle_result {
            app.run_coordinator.cancel_run(run_id).await;
            let _ = event_tx.send(AgentOutput::Failed(error.to_string())).await;
            app.run_coordinator.finish_run(run_id).await;
            return;
        }

        let mut events = backend_run.events;
        let mut full_response = String::new();
        let mut reasoning = String::new();
        let mut tool_calls: Vec<StoredToolCall> = Vec::new();
        while let Some(output) = events.next().await {
            match &output {
                AgentOutput::TextDelta(delta) => full_response.push_str(delta),
                AgentOutput::ReasoningDelta(delta) => reasoning.push_str(delta),
                AgentOutput::ToolStarted {
                    tool_call_id,
                    tool_name,
                    arguments,
                } => {
                    if !tool_calls.iter().any(|call| call.id == *tool_call_id) {
                        tool_calls.push(StoredToolCall {
                            id: tool_call_id.clone(),
                            name: tool_name.clone(),
                            arguments: arguments.clone(),
                            status: "running".to_string(),
                            output: None,
                        });
                    }
                }
                AgentOutput::ToolCompleted {
                    tool_call_id,
                    tool_name,
                    output,
                } => {
                    if let Some(call) = tool_calls.iter_mut().find(|call| call.id == *tool_call_id)
                    {
                        call.status = "completed".to_string();
                        call.output = Some(output.clone());
                    } else {
                        tool_calls.push(StoredToolCall {
                            id: tool_call_id.clone(),
                            name: tool_name.clone(),
                            arguments: String::new(),
                            status: "completed".to_string(),
                            output: Some(output.clone()),
                        });
                    }
                }
                _ => {}
            }
            let terminal = is_terminal(&output);
            if terminal {
                save_run_transcript(&app, session_id, &full_response, &reasoning, &tool_calls)
                    .await;
                let _ = event_tx.send(output).await;
                app.run_coordinator.finish_run(run_id).await;
                return;
            }
            if event_tx.send(output).await.is_err() {
                app.run_coordinator.finish_run(run_id).await;
                return;
            }
        }

        save_run_transcript(&app, session_id, &full_response, &reasoning, &tool_calls).await;
        let _ = event_tx.send(AgentOutput::Completed).await;
        app.run_coordinator.finish_run(run_id).await;
    });

    Ok(ManagedRun {
        run_id,
        events: event_rx,
    })
}

/// 将持久化的消息转换为模型历史。
fn stored_message_to_chat_message(message: &disco_persist::messages::StoredMessage) -> ChatMessage {
    ChatMessage {
        role: message.role.clone(),
        text: message.text.clone(),
        reasoning_content: (!message.reasoning.is_empty()).then(|| message.reasoning.clone()),
        tool_calls: (!message.tool_calls.is_empty()).then(|| {
            message
                .tool_calls
                .iter()
                .map(|call| ToolCallInfo {
                    call_id: call.id.clone(),
                    name: call.name.clone(),
                    arguments: call.arguments.clone(),
                })
                .collect()
        }),
        tool_call_id: message.tool_call_id.clone(),
        tool_name: message.tool_name.clone(),
        ..Default::default()
    }
}

/// Rig 只把 checkpoint 作为模型上下文前缀使用，原始消息仍由 UI/数据库完整保留。
fn messages_for_local_context(
    db: &AppState,
    session_id: Uuid,
    stored_messages: &[StoredMessage],
) -> Vec<ChatMessage> {
    let Ok(Some(checkpoint)) = db.db.get_context_checkpoint(session_id) else {
        return stored_messages
            .iter()
            .map(stored_message_to_chat_message)
            .collect();
    };
    let Some(boundary_index) = stored_messages
        .iter()
        .position(|message| message.id == checkpoint.boundary_message_id)
    else {
        return stored_messages
            .iter()
            .map(stored_message_to_chat_message)
            .collect();
    };

    let mut messages = vec![ChatMessage {
        role: "system".to_string(),
        text: format!(
            "Previous conversation summary:\n{}\n\nContinue the conversation from where it left off.",
            checkpoint.summary
        ),
        ..Default::default()
    }];
    messages.extend(
        stored_messages
            .iter()
            .skip(boundary_index + 1)
            .map(stored_message_to_chat_message),
    );
    messages
}

fn is_terminal(output: &AgentOutput) -> bool {
    matches!(
        output,
        AgentOutput::Completed | AgentOutput::Failed(_) | AgentOutput::Cancelled
    )
}

async fn save_run_transcript(
    app: &AppState,
    session_id: Uuid,
    text: &str,
    reasoning: &str,
    tool_calls: &[StoredToolCall],
) {
    if text.is_empty() && reasoning.is_empty() && tool_calls.is_empty() {
        return;
    }
    let mut changed = false;
    {
        let _state_guard = app.state_lock.lock().await;
        if let Err(error) = app
            .db
            .add_assistant_message(session_id, text, reasoning, tool_calls)
        {
            tracing::error!(%error, "保存 assistant 消息失败");
        } else {
            changed = true;
        }
        for call in tool_calls {
            let Some(output) = call.output.as_deref() else {
                continue;
            };
            if let Err(error) = app
                .db
                .add_tool_result_message(session_id, &call.id, &call.name, output)
            {
                tracing::error!(%error, call_id = %call.id, "保存 tool result 失败");
            } else {
                changed = true;
            }
        }
        if changed {
            app.bump_state_revision();
        }
    }
}

/// 累计 token 用量。
pub(crate) fn accumulate_usage(prev: &Option<TokenUsage>, current: &TokenUsage) -> TokenUsage {
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

/// 供 daemon 内部测试共享的 fake backend 与 AppState 构造器。
#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use async_trait::async_trait;
    use disco_core::{AgentBackend, BackendCapabilities, BackendRun, CompactionMode};
    use disco_protocol::types::{ProviderId, Vendor};
    use disco_providers::{ModelProvider, ProviderEvent};
    use disco_tools::{CompositeExecutor, ToolDefinition};
    use futures_core::Stream;
    use std::collections::HashMap;
    use std::pin::Pin;
    use tokio::sync::Mutex;
    use tokio::time::{Duration, timeout};
    use tokio_util::sync::CancellationToken;

    pub struct NoopModelProvider;

    #[async_trait]
    impl ModelProvider for NoopModelProvider {
        fn vendor_name(&self) -> &'static str {
            "test"
        }

        async fn stream<'a>(
            &'a self,
            _messages: &'a [ChatMessage],
            _tools: Option<&'a [ToolDefinition]>,
        ) -> anyhow::Result<Pin<Box<dyn Stream<Item = anyhow::Result<ProviderEvent>> + Send + 'a>>>
        {
            Ok(Box::pin(tokio_stream::empty()))
        }
    }

    pub struct ScriptedBackend {
        pub outputs: Vec<AgentOutput>,
        pub backend_handle: Option<String>,
    }

    #[async_trait]
    impl AgentBackend for ScriptedBackend {
        fn capabilities(&self) -> BackendCapabilities {
            BackendCapabilities {
                has_persistent_sessions: false,
                can_delete_session: true,
                compaction: CompactionMode::Unsupported,
            }
        }

        async fn start_run(&self, _request: BackendRunRequest) -> anyhow::Result<BackendRun> {
            Ok(BackendRun {
                events: Box::pin(tokio_stream::iter(self.outputs.clone())),
                backend_handle: self.backend_handle.clone(),
            })
        }

        async fn delete_session(
            &self,
            _session: &BackendSession,
            _workspace_path: Option<String>,
        ) -> anyhow::Result<()> {
            Ok(())
        }
    }

    pub struct CancellationBackend;

    #[async_trait]
    impl AgentBackend for CancellationBackend {
        fn capabilities(&self) -> BackendCapabilities {
            BackendCapabilities {
                has_persistent_sessions: false,
                can_delete_session: true,
                compaction: CompactionMode::Unsupported,
            }
        }

        async fn start_run(&self, request: BackendRunRequest) -> anyhow::Result<BackendRun> {
            let (event_tx, event_rx) = tokio::sync::mpsc::channel(1);
            tokio::spawn(async move {
                request.cancellation.cancelled().await;
                let _ = event_tx.send(AgentOutput::Cancelled).await;
            });
            Ok(BackendRun {
                events: Box::pin(tokio_stream::wrappers::ReceiverStream::new(event_rx)),
                backend_handle: None,
            })
        }

        async fn delete_session(
            &self,
            _session: &BackendSession,
            _workspace_path: Option<String>,
        ) -> anyhow::Result<()> {
            Ok(())
        }
    }

    /// 创建测试 AppState：注册 fake backend、provider 配置和一条测试 session。
    pub fn make_test_app(backend: Arc<dyn AgentBackend>) -> (Arc<AppState>, Uuid) {
        let directory = std::env::temp_dir().join(format!("disco-run-service-{}", Uuid::new_v4()));
        let database = disco_persist::Database::open(&directory.join("test.db")).unwrap();
        let project = database
            .create_project("Test", "/tmp/disco-run-service")
            .unwrap();
        let session = database
            .create_session(
                project.id,
                ProviderId::new("test_provider"),
                Vendor::Openai,
                "test-model",
                None,
            )
            .unwrap();
        database
            .save_provider_config(&disco_persist::provider_configs::ProviderConfig {
                provider_id: ProviderId::new("test_provider"),
                vendor: Vendor::Openai,
                base_url: String::new(),
                api_key: String::new(),
                model: "test-model".to_string(),
                thinking_enabled: false,
                reasoning_effort: None,
                updated_at: String::new(),
            })
            .unwrap();
        let executor = Arc::new(CompositeExecutor::new());
        let runtime = crate::daemon::ProviderRuntime {
            backend,
            compaction_provider: Arc::new(NoopModelProvider),
        };
        let mut runtimes = HashMap::new();
        runtimes.insert(ProviderId::new("test_provider"), runtime);
        let app = Arc::new(AppState {
            db: database,
            runtime_by_provider_id: Mutex::new(runtimes),
            opencode_model_catalog: Mutex::new(HashMap::new()),
            opencode_server_manager: Arc::new(disco_backends::OpenCodeServerManager::new(
                "opencode".to_string(),
            )),
            run_coordinator: disco_core::RunCoordinator::new(),
            executor,
            shutdown: CancellationToken::new(),
            state_lock: Mutex::new(()),
            state_revision: std::sync::atomic::AtomicU64::new(0),
            event_journal: crate::daemon::EventJournal::new(),
        });
        (app, session.id)
    }

    pub async fn wait_for_run_to_finish(app: &Arc<AppState>, session_id: Uuid) {
        timeout(Duration::from_secs(1), async {
            loop {
                if app
                    .run_coordinator
                    .active_run_id(session_id)
                    .await
                    .is_none()
                {
                    return;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{
        CancellationBackend, ScriptedBackend, make_test_app, wait_for_run_to_finish,
    };
    use super::*;
    use async_trait::async_trait;
    use disco_core::{AgentBackend, BackendCapabilities, BackendRun, CompactionMode};
    use disco_protocol::types::ApprovalDecision;
    use std::sync::Arc;
    use tokio::sync::Notify;
    use tokio::time::{Duration, timeout};

    struct BlockingStartBackend {
        entered: Arc<Notify>,
        release: Arc<Notify>,
    }

    #[async_trait]
    impl AgentBackend for BlockingStartBackend {
        fn capabilities(&self) -> BackendCapabilities {
            BackendCapabilities {
                has_persistent_sessions: true,
                can_delete_session: true,
                compaction: CompactionMode::Unsupported,
            }
        }

        async fn start_run(&self, request: BackendRunRequest) -> anyhow::Result<BackendRun> {
            self.entered.notify_one();
            self.release.notified().await;
            let (event_tx, event_rx) = tokio::sync::mpsc::channel(1);
            let terminal = if request.cancellation.is_cancelled() {
                AgentOutput::Cancelled
            } else {
                AgentOutput::Completed
            };
            event_tx.send(terminal).await.unwrap();
            Ok(BackendRun {
                events: Box::pin(tokio_stream::wrappers::ReceiverStream::new(event_rx)),
                backend_handle: Some("blocking-session".to_string()),
            })
        }

        async fn delete_session(
            &self,
            _session: &BackendSession,
            _workspace_path: Option<String>,
        ) -> anyhow::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn terminal_outputs_are_classified() {
        assert!(is_terminal(&AgentOutput::Completed));
        assert!(is_terminal(&AgentOutput::Cancelled));
        assert!(is_terminal(&AgentOutput::Failed("error".to_string())));
        assert!(!is_terminal(&AgentOutput::TextDelta("text".to_string())));
    }

    #[test]
    fn regular_messages_are_converted_without_losing_roles() {
        let message = disco_persist::messages::StoredMessage {
            id: Uuid::new_v4(),
            session_id: Uuid::new_v4(),
            role: "user".to_string(),
            text: "hello".to_string(),
            reasoning: String::new(),
            tool_calls: vec![],
            tool_call_id: None,
            tool_name: None,
            created_at: "1".to_string(),
        };
        let converted = stored_message_to_chat_message(&message);
        assert_eq!(converted.role, "user");
        assert_eq!(converted.text, "hello");
    }

    #[tokio::test]
    async fn shared_run_service_persists_history_and_stops_at_one_terminal_event() {
        let backend = Arc::new(ScriptedBackend {
            outputs: vec![
                AgentOutput::TextDelta("hello".to_string()),
                AgentOutput::Completed,
                AgentOutput::TextDelta("must not be forwarded".to_string()),
            ],
            backend_handle: Some("test-handle".to_string()),
        });
        let (app, session_id) = make_test_app(backend);
        let managed = start_run(&app, session_id, "question".to_string())
            .await
            .unwrap();
        let mut events = managed.events;
        let mut outputs = Vec::new();
        while let Some(output) = timeout(Duration::from_secs(1), events.recv())
            .await
            .unwrap()
        {
            outputs.push(output);
        }

        assert_eq!(outputs.len(), 2);
        assert!(matches!(outputs[0], AgentOutput::TextDelta(ref text) if text == "hello"));
        assert!(matches!(outputs[1], AgentOutput::Completed));
        assert_eq!(
            app.db
                .get_session_backend_handle(session_id)
                .unwrap()
                .as_deref(),
            Some("test-handle")
        );
        let messages = app.db.list_messages(session_id).unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].role, "user");
        assert_eq!(messages[1].role, "assistant");
        assert_eq!(messages[1].text, "hello");
        wait_for_run_to_finish(&app, session_id).await;
    }

    #[tokio::test]
    async fn shared_run_service_propagates_cancellation_to_backend() {
        let (app, session_id) = make_test_app(Arc::new(CancellationBackend));
        let managed = start_run(&app, session_id, "cancel me".to_string())
            .await
            .unwrap();
        app.run_coordinator.cancel_run(managed.run_id).await;

        let mut events = managed.events;
        let output = timeout(Duration::from_secs(1), events.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(output, AgentOutput::Cancelled));
        wait_for_run_to_finish(&app, session_id).await;
    }

    #[tokio::test]
    async fn start_run_returns_before_backend_connects_and_can_be_cancelled() {
        let entered = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let (app, session_id) = make_test_app(Arc::new(BlockingStartBackend {
            entered: entered.clone(),
            release: release.clone(),
        }));

        let managed = timeout(
            Duration::from_millis(100),
            start_run(&app, session_id, "开始".to_string()),
        )
        .await
        .expect("start_run 不应等待 backend 连接完成")
        .unwrap();
        timeout(Duration::from_secs(1), entered.notified())
            .await
            .unwrap();

        app.run_coordinator.cancel_run(managed.run_id).await;
        release.notify_one();

        let mut events = managed.events;
        let output = timeout(Duration::from_secs(1), events.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(output, AgentOutput::Cancelled));
        wait_for_run_to_finish(&app, session_id).await;
    }

    #[tokio::test]
    async fn approving_unknown_approval_is_rejected() {
        let (app, _session_id) = make_test_app(Arc::new(ScriptedBackend {
            outputs: vec![],
            backend_handle: None,
        }));
        assert!(
            !app.run_coordinator
                .respond_approval(Uuid::new_v4(), ApprovalDecision::ApproveOnce)
                .await
        );
    }
}
