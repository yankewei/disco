use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::Arc;

use anyhow::Result;
use async_trait::async_trait;
use disco_core::{
    AgentBackend, AgentOutput, ApprovalManager, ApprovalRequest, BackendCapabilities, BackendRun,
    BackendRunRequest, BackendSession, CollaborationMode, CompactionMode, CompactionUpdate,
    PlanStep, PreparedApproval,
};
use disco_protocol::types::{ApprovalDecision, ApprovalImpact};
#[cfg(test)]
use disco_providers::codex::CodexRequestId;
use disco_providers::{
    CodexApprovalDecision, CodexApprovalKind, CodexApprovalRequest, CodexProvider,
    CodexProviderEvent,
};
use tokio::sync::{Mutex, mpsc};
use tokio_stream::StreamExt;
use tokio_stream::wrappers::ReceiverStream;
use uuid::Uuid;

/// Codex app-server Adapter。
///
/// 每个 Disco session 拥有独立的 CodexProvider，从而拥有独立 thread。Provider profile
/// 只共享可执行文件和模型配置，不共享运行状态。
pub struct CodexAdapter {
    executable: String,
    reasoning_effort: Option<String>,
    sessions: Mutex<HashMap<Uuid, Arc<CodexProvider>>>,
}

impl CodexAdapter {
    pub fn new(executable: String, reasoning_effort: Option<String>) -> Self {
        Self {
            executable,
            reasoning_effort,
            sessions: Mutex::new(HashMap::new()),
        }
    }

    async fn provider_for(
        &self,
        session: &BackendSession,
        workspace_path: Option<String>,
    ) -> Arc<CodexProvider> {
        let mut sessions = self.sessions.lock().await;
        sessions
            .entry(session.id)
            .or_insert_with(|| {
                Arc::new(CodexProvider::new(
                    self.executable.clone(),
                    session.model.clone(),
                    self.reasoning_effort.clone(),
                    session.backend_handle.clone(),
                    workspace_path,
                ))
            })
            .clone()
    }
}

#[async_trait]
impl AgentBackend for CodexAdapter {
    fn capabilities(&self) -> BackendCapabilities {
        BackendCapabilities {
            has_persistent_sessions: true,
            can_delete_session: true,
            compaction: CompactionMode::Native,
        }
    }

    async fn collaboration_modes(
        &self,
        session: &BackendSession,
        workspace_path: Option<String>,
    ) -> Result<Vec<CollaborationMode>> {
        let provider = self.provider_for(session, workspace_path).await;
        let modes = provider.collaboration_modes().await?;
        Ok(modes
            .into_iter()
            .filter_map(|mode| match mode.id.as_str() {
                "default" => Some(CollaborationMode::Default),
                "plan" => Some(CollaborationMode::Plan),
                _ => None,
            })
            .collect())
    }

    async fn set_collaboration_mode(
        &self,
        session: &BackendSession,
        workspace_path: Option<String>,
        mode: CollaborationMode,
    ) -> Result<()> {
        let provider = self.provider_for(session, workspace_path).await;
        let supported_modes = provider.collaboration_modes().await?;
        if !supported_modes
            .iter()
            .any(|candidate| candidate.id == mode.as_str())
        {
            anyhow::bail!("Codex 当前不提供 {} 模式", mode.as_str());
        }
        provider.set_collaboration_mode(mode.as_str()).await
    }

    async fn load_session(
        &self,
        session: &BackendSession,
        workspace_path: Option<String>,
    ) -> Result<()> {
        if session.backend_handle.is_none() {
            return Ok(());
        }
        let provider = self.provider_for(session, workspace_path).await;
        provider.ensure_session().await?;
        Ok(())
    }

    async fn start_run(&self, request: BackendRunRequest) -> Result<BackendRun> {
        let provider = self
            .provider_for(&request.session, request.workspace_path.clone())
            .await;
        let backend_handle = provider.ensure_session().await?;
        let (event_tx, event_rx) = mpsc::channel(64);

        tokio::spawn(async move {
            if request.cancellation.is_cancelled() {
                let _ = event_tx.send(AgentOutput::Cancelled).await;
                return;
            }
            let stream = match provider.stream_turn(&request.messages).await {
                Ok(stream) => stream,
                Err(error) => {
                    let output = if request.cancellation.is_cancelled() {
                        provider.abort_active_transport().await;
                        AgentOutput::Cancelled
                    } else {
                        AgentOutput::Failed(error.to_string())
                    };
                    let _ = event_tx.send(output).await;
                    return;
                }
            };
            tokio::pin!(stream);
            let mut tool_arguments_by_id = HashMap::new();

            loop {
                tokio::select! {
                    _ = request.cancellation.cancelled() => {
                        request.approval_manager.cancel_all().await;
                        if let Err(error) = provider.interrupt_when_ready().await {
                            tracing::warn!(%error, "Codex turn 无法按协议中断，终止 transport");
                            provider.abort_active_transport().await;
                        }
                        let _ = event_tx.send(AgentOutput::Cancelled).await;
                        return;
                    }
                    event = stream.next() => {
                        let output = match event {
                            Some(Ok(CodexProviderEvent::TextDelta(delta))) => AgentOutput::TextDelta(delta),
                            Some(Ok(CodexProviderEvent::PlanUpdate(plan))) => AgentOutput::PlanUpdate {
                                explanation: plan.explanation,
                                steps: plan.steps.into_iter().map(|step| PlanStep {
                                    step: step.step,
                                    status: step.status,
                                }).collect(),
                            },
                            Some(Ok(CodexProviderEvent::ReasoningDelta(delta))) => AgentOutput::ReasoningDelta(delta),
                            Some(Ok(CodexProviderEvent::Usage(usage))) => AgentOutput::Usage(usage),
                            Some(Ok(CodexProviderEvent::ContextUsage { tokens, window })) => {
                                AgentOutput::ContextUsage { tokens, window }
                            }
                            Some(Ok(CodexProviderEvent::Compaction(update))) => {
                                AgentOutput::CompactionUpdate(CompactionUpdate {
                                    id: update.id,
                                    status: match update.status.as_str() {
                                        "running" => disco_protocol::types::CompactionStatus::Running,
                                        "completed" => disco_protocol::types::CompactionStatus::Completed,
                                        _ => disco_protocol::types::CompactionStatus::Failed,
                                    },
                                    before_tokens: update.before_tokens,
                                    after_tokens: update.after_tokens,
                                    summary: update.summary,
                                    error_message: update.error_message,
                                })
                            }
                            Some(Ok(CodexProviderEvent::ToolStarted(tool))) => {
                                tool_arguments_by_id.insert(tool.id.clone(), tool.arguments.clone());
                                AgentOutput::ToolStarted {
                                    tool_call_id: tool.id,
                                    tool_name: tool.name,
                                    arguments: tool.arguments,
                                }
                            }
                            Some(Ok(CodexProviderEvent::ToolCompleted(tool))) => AgentOutput::ToolCompleted {
                                tool_call_id: tool.id,
                                tool_name: tool.name,
                                output: tool.output,
                            },
                            Some(Ok(CodexProviderEvent::ApprovalRequested(approval))) => {
                                let tool_arguments =
                                    tool_arguments_by_id.get(&approval.item_id).cloned();
                                spawn_approval_forwarding(
                                    request.run_id,
                                    approval,
                                    tool_arguments.as_deref(),
                                    request.approval_manager.clone(),
                                    request.cancellation.clone(),
                                    provider.clone(),
                                    event_tx.clone(),
                                );
                                continue;
                            }
                            Some(Ok(CodexProviderEvent::Completed)) => AgentOutput::Completed,
                            Some(Ok(CodexProviderEvent::Cancelled)) => AgentOutput::Cancelled,
                            Some(Ok(CodexProviderEvent::Failed(error))) => AgentOutput::Failed(error),
                            Some(Err(error)) => AgentOutput::Failed(error.to_string()),
                            None => AgentOutput::Failed("Codex 事件流意外结束".to_string()),
                        };
                        let terminal = matches!(
                            output,
                            AgentOutput::Completed | AgentOutput::Cancelled | AgentOutput::Failed(_)
                        );
                        if terminal {
                            request.approval_manager.cancel_all().await;
                        }
                        if event_tx.send(output).await.is_err() {
                            request.approval_manager.cancel_all().await;
                            return;
                        }
                        if terminal {
                            return;
                        }
                    }
                }
            }
        });

        Ok(BackendRun {
            events: Box::pin(ReceiverStream::new(event_rx)),
            backend_handle: Some(backend_handle),
        })
    }

    async fn delete_session(
        &self,
        session: &BackendSession,
        _workspace_path: Option<String>,
    ) -> Result<()> {
        let provider = self.sessions.lock().await.remove(&session.id);
        let provider = match (provider, session.backend_handle.as_ref()) {
            (Some(provider), _) => provider,
            (None, Some(handle)) => Arc::new(CodexProvider::new(
                self.executable.clone(),
                session.model.clone(),
                self.reasoning_effort.clone(),
                Some(handle.clone()),
                None,
            )),
            (None, None) => return Ok(()),
        };

        let result = match provider.ensure_session().await {
            Ok(thread_id) => provider.delete_thread_by_id(&thread_id).await,
            Err(error) => match session.backend_handle.as_deref() {
                Some(thread_id) => provider.delete_thread_by_id(thread_id).await,
                None => Err(error),
            },
        };
        provider.stop().await;
        result
    }
}

fn spawn_approval_forwarding(
    run_id: Uuid,
    request: CodexApprovalRequest,
    tool_arguments: Option<&str>,
    approval_manager: Arc<ApprovalManager>,
    cancellation: tokio_util::sync::CancellationToken,
    provider: Arc<CodexProvider>,
    event_tx: mpsc::Sender<AgentOutput>,
) {
    let approval = approval_request_from_codex(run_id, &request, tool_arguments);
    tokio::spawn(async move {
        let decision = match approval_manager.prepare_approval(&approval).await {
            PreparedApproval::SessionApproved => ApprovalDecision::ApproveOnce,
            PreparedApproval::Pending(pending) => {
                if cancellation.is_cancelled()
                    || event_tx
                        .send(AgentOutput::approval_waiting(&approval))
                        .await
                        .is_err()
                {
                    let _ = provider
                        .respond_to_approval(&request, CodexApprovalDecision::Cancel)
                        .await;
                    return;
                }
                tokio::select! {
                    biased;
                    _ = cancellation.cancelled() => {
                        let _ = provider
                            .respond_to_approval(&request, CodexApprovalDecision::Cancel)
                            .await;
                        return;
                    }
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
        let response = match decision {
            ApprovalDecision::ApproveOnce => CodexApprovalDecision::Accept,
            ApprovalDecision::ApproveForSession if request.allows_session_approval => {
                CodexApprovalDecision::AcceptForSession
            }
            ApprovalDecision::ApproveForSession => CodexApprovalDecision::Accept,
            ApprovalDecision::Decline => CodexApprovalDecision::Decline,
        };
        if let Err(error) = provider.respond_to_approval(&request, response).await {
            tracing::warn!(%error, "无法回应 Codex approval request");
        }
    });
}

fn approval_request_from_codex(
    run_id: Uuid,
    request: &CodexApprovalRequest,
    tool_arguments: Option<&str>,
) -> ApprovalRequest {
    let (kind, impact, fingerprint, allows_session_approval) = match request.kind {
        CodexApprovalKind::CommandExecution => {
            let command = request.command.as_deref().unwrap_or_default();
            let mut parts = command.split_whitespace();
            let executable = parts.next().unwrap_or(command).to_string();
            let cwd = request.cwd.clone().unwrap_or_else(|| ".".to_string());
            (
                "command".to_string(),
                ApprovalImpact::Command {
                    executable,
                    arguments: parts.map(ToString::to_string).collect(),
                    cwd: cwd.clone(),
                },
                if command.is_empty() {
                    format!("codex:command:item:{}", request.item_id)
                } else {
                    format!("codex:command:{cwd}:{command}")
                },
                request.allows_session_approval && !command.is_empty(),
            )
        }
        CodexApprovalKind::FileChange => {
            let (paths, diff) = file_change_details(request, tool_arguments);
            let has_complete_snapshot = diff.as_ref().is_some_and(|value| !value.is_empty());
            let fingerprint = if has_complete_snapshot {
                let mut hasher = DefaultHasher::new();
                paths.hash(&mut hasher);
                diff.hash(&mut hasher);
                format!("codex:file_change:{:016x}", hasher.finish())
            } else {
                format!("codex:file_change:item:{}", request.item_id)
            };
            (
                "file_change".to_string(),
                ApprovalImpact::FileChange {
                    paths,
                    summary: request.title.clone(),
                    diff,
                },
                fingerprint,
                request.allows_session_approval && has_complete_snapshot,
            )
        }
    };

    ApprovalRequest {
        id: Uuid::new_v4(),
        run_id,
        kind,
        title: request.title.clone(),
        reason: request.reason.clone(),
        impact,
        fingerprint,
        allows_session_approval,
    }
}

fn file_change_details(
    request: &CodexApprovalRequest,
    tool_arguments: Option<&str>,
) -> (Vec<String>, Option<String>) {
    let changes = tool_arguments
        .and_then(|arguments| serde_json::from_str::<Vec<serde_json::Value>>(arguments).ok())
        .unwrap_or_default();
    let mut paths = changes
        .iter()
        .filter_map(|change| change.get("path").and_then(serde_json::Value::as_str))
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    if paths.is_empty()
        && let Some(grant_root) = request.grant_root.clone()
    {
        paths.push(grant_root);
    }
    let diffs = changes
        .iter()
        .filter_map(|change| change.get("diff").and_then(serde_json::Value::as_str))
        .collect::<Vec<_>>();
    let diff = (!diffs.is_empty()).then(|| diffs.join("\n"));
    (paths, diff)
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    use disco_providers::ChatMessage;
    use tokio::time::{Duration, timeout};
    use tokio_util::sync::CancellationToken;

    use super::*;

    #[cfg(unix)]
    struct FakeCodexExecutable {
        directory: std::path::PathBuf,
        path: std::path::PathBuf,
    }

    #[cfg(unix)]
    impl FakeCodexExecutable {
        fn new(script: &str) -> Self {
            let directory = std::env::temp_dir().join(format!("disco-codex-{}", Uuid::new_v4()));
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
    impl Drop for FakeCodexExecutable {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
            let _ = std::fs::remove_dir(&self.directory);
        }
    }

    fn backend_request(
        cancellation: CancellationToken,
        approval_manager: Arc<ApprovalManager>,
    ) -> BackendRunRequest {
        BackendRunRequest {
            run_id: Uuid::new_v4(),
            session: BackendSession {
                id: Uuid::new_v4(),
                model: "gpt-5-codex".to_string(),
                backend_handle: None,
            },
            messages: vec![ChatMessage {
                role: "user".to_string(),
                text: "执行测试".to_string(),
                ..Default::default()
            }],
            workspace_path: Some("/tmp/codex-workspace".to_string()),
            cancellation,
            approval_manager,
        }
    }

    #[tokio::test]
    async fn isolates_codex_threads_by_disco_session() {
        let adapter = CodexAdapter::new("codex".to_string(), None);
        let first_session = BackendSession {
            id: Uuid::new_v4(),
            model: "gpt-5-codex".to_string(),
            backend_handle: Some("thread-a".to_string()),
        };
        let second_session = BackendSession {
            id: Uuid::new_v4(),
            model: "gpt-5-codex".to_string(),
            backend_handle: Some("thread-b".to_string()),
        };

        let first = adapter.provider_for(&first_session, None).await;
        let first_again = adapter.provider_for(&first_session, None).await;
        let second = adapter.provider_for(&second_session, None).await;

        assert!(Arc::ptr_eq(&first, &first_again));
        assert!(!Arc::ptr_eq(&first, &second));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn maps_fake_app_server_tools_approval_and_deletion() {
        let executable = FakeCodexExecutable::new(
            r###"#!/bin/sh
read -r initialize
printf '%s\n' '{"id":0,"result":{}}'
read -r initialized
read -r thread_start
case "$thread_start" in
  *'"method":"thread/start"'*'"cwd":"/tmp/codex-workspace"'*'"approvalsReviewer":"user"'*) ;;
  *) exit 41 ;;
esac
printf '%s\n' '{"id":1,"result":{"thread":{"id":"thread-test"}}}'
read -r turn_start
printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-test","turn":{"id":"turn-test"}}}'
printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-test","turnId":"turn-test","item":{"type":"commandExecution","id":"tool-test","command":"echo hello","cwd":"/tmp/codex-workspace","status":"inProgress"}}}'
printf '%s\n' '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-test","turnId":"turn-test","itemId":"tool-test","startedAtMs":1,"command":"echo hello","cwd":"/tmp/codex-workspace","availableDecisions":["accept","acceptForSession","decline","cancel"]}}'
read -r approval
case "$approval" in
  *'"id":"approval-1"'*'"decision":"acceptForSession"'*) ;;
  *) exit 42 ;;
esac
printf '%s\n' '{"id":2,"result":{}}'
printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-test","turnId":"turn-test","item":{"type":"commandExecution","id":"tool-test","command":"echo hello","cwd":"/tmp/codex-workspace","status":"completed","aggregatedOutput":"hello\n","exitCode":0}}}'
printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-test","turnId":"turn-test","delta":"已完成"}}'
printf '%s\n' '{"method":"turn/plan/updated","params":{"threadId":"thread-test","turnId":"turn-test","explanation":"先确认范围","plan":[{"step":"检查现状","status":"completed"},{"step":"实现方案","status":"pending"}]}}'
printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-test","turn":{"id":"turn-test","status":"completed"}}}'
read -r thread_delete
case "$thread_delete" in
  *'"id":3'*'"method":"thread/delete"'*'"threadId":"thread-test"'*) ;;
  *) exit 43 ;;
esac
printf '%s\n' '{"id":3,"result":{}}'
printf '%s\n' '{"method":"thread/deleted","params":{"threadId":"thread-test"}}'
while read -r ignored; do :; done
"###,
        );
        let adapter = CodexAdapter::new(executable.path(), None);
        let approval_manager = Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new()))));
        let request = backend_request(CancellationToken::new(), approval_manager.clone());
        let session = request.session.clone();
        let mut run = adapter.start_run(request).await.unwrap();
        assert_eq!(run.backend_handle.as_deref(), Some("thread-test"));

        let mut events = Vec::new();
        while let Some(event) = run.events.next().await {
            if let AgentOutput::ApprovalWaiting { approval_id, .. } = &event {
                assert!(
                    approval_manager
                        .respond(*approval_id, ApprovalDecision::ApproveForSession)
                        .await
                );
            }
            events.push(event);
        }

        assert!(
            matches!(&events[0], AgentOutput::ToolStarted { tool_call_id, tool_name, arguments } if tool_call_id == "tool-test" && tool_name == "shell" && arguments.contains("echo hello"))
        );
        assert!(
            matches!(&events[1], AgentOutput::ApprovalWaiting { allows_session_approval: true, impact: ApprovalImpact::Command { executable, cwd, .. }, .. } if executable == "echo" && cwd == "/tmp/codex-workspace")
        );
        assert!(matches!(
            &events[2],
            AgentOutput::ApprovalResolved {
                decision: ApprovalDecision::ApproveForSession,
                ..
            }
        ));
        assert!(
            matches!(&events[3], AgentOutput::ToolCompleted { output, .. } if output == "hello\n")
        );
        assert!(matches!(&events[4], AgentOutput::TextDelta(text) if text == "已完成"));
        assert!(matches!(
            &events[5],
            AgentOutput::PlanUpdate { explanation: Some(explanation), steps }
                if explanation == "先确认范围"
                    && steps.len() == 2
                    && steps[0].step == "检查现状"
                    && steps[0].status == "completed"
        ));
        assert!(matches!(&events[6], AgentOutput::Completed));

        adapter
            .delete_session(
                &BackendSession {
                    backend_handle: run.backend_handle,
                    ..session
                },
                None,
            )
            .await
            .unwrap();
    }

    #[test]
    fn file_change_session_approval_is_bound_to_the_diff_snapshot() {
        let request = CodexApprovalRequest {
            request_id: CodexRequestId::Number(1),
            kind: CodexApprovalKind::FileChange,
            item_id: "file-change-1".to_string(),
            title: "应用文件修改".to_string(),
            reason: None,
            command: None,
            cwd: None,
            grant_root: None,
            allows_session_approval: true,
        };
        let first = approval_request_from_codex(
            Uuid::new_v4(),
            &request,
            Some(r#"[{"path":"src/main.rs","diff":"+safe"}]"#),
        );
        let second = approval_request_from_codex(
            Uuid::new_v4(),
            &request,
            Some(r#"[{"path":"src/main.rs","diff":"+dangerous"}]"#),
        );
        let incomplete = approval_request_from_codex(
            Uuid::new_v4(),
            &request,
            Some(r#"[{"path":"src/main.rs"}]"#),
        );

        assert_ne!(first.fingerprint, second.fingerprint);
        assert!(first.allows_session_approval);
        assert!(!incomplete.allows_session_approval);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cancelling_a_codex_run_interrupts_the_active_turn_once() {
        let directory = std::env::temp_dir().join(format!("disco-codex-marker-{}", Uuid::new_v4()));
        let marker = directory.join("interrupted");
        let marker_text = marker.display().to_string();
        let script = r###"#!/bin/sh
read -r initialize
printf '%s\n' '{"id":0,"result":{}}'
read -r initialized
read -r thread_start
printf '%s\n' '{"id":1,"result":{"thread":{"id":"thread-cancel"}}}'
read -r turn_start
printf '%s\n' '{"id":2,"result":{}}'
printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-cancel","turn":{"id":"turn-cancel"}}}'
printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-cancel","turnId":"turn-cancel","item":{"type":"commandExecution","id":"tool-cancel","command":"sleep 10","cwd":"/tmp/codex-workspace","status":"inProgress"}}}'
read -r interrupt
case "$interrupt" in
  *'"method":"turn/interrupt"'*'"turnId":"turn-cancel"'*) ;;
  *) exit 51 ;;
esac
printf '%s' interrupted > __MARKER__
printf '%s\n' '{"id":3,"result":{}}'
printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-cancel","turn":{"id":"turn-cancel","status":"interrupted"}}}'
while read -r ignored; do :; done
"###.replace("__MARKER__", &marker_text);
        let executable = FakeCodexExecutable::new(&script);
        std::fs::create_dir_all(&directory).unwrap();
        let adapter = CodexAdapter::new(executable.path(), None);
        let cancellation = CancellationToken::new();
        let mut run = adapter
            .start_run(backend_request(
                cancellation.clone(),
                Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new())))),
            ))
            .await
            .unwrap();

        assert!(matches!(
            run.events.next().await,
            Some(AgentOutput::ToolStarted { .. })
        ));
        cancellation.cancel();
        assert!(matches!(
            run.events.next().await,
            Some(AgentOutput::Cancelled)
        ));
        assert!(run.events.next().await.is_none());
        for _ in 0..100 {
            if marker.exists() {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert!(marker.exists(), "adapter 应发送 turn/interrupt");
        let _ = std::fs::remove_file(marker);
        let _ = std::fs::remove_dir(directory);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cancelling_before_turn_started_does_not_leave_a_hidden_turn() {
        let directory =
            std::env::temp_dir().join(format!("disco-codex-early-cancel-{}", Uuid::new_v4()));
        let started = directory.join("turn-start-requested");
        let release = directory.join("release-turn-start");
        let continued = directory.join("turn-start-continued");
        let interrupted = directory.join("interrupted");
        let script = r###"#!/bin/sh
read -r initialize
printf '%s\n' '{"id":0,"result":{}}'
read -r initialized
read -r thread_start
printf '%s\n' '{"id":1,"result":{"thread":{"id":"thread-early-cancel"}}}'
read -r turn_start
printf '%s' started > __STARTED__
while [ ! -f __RELEASE__ ]; do sleep 0.01; done
printf '%s\n' '{"id":2,"result":{"turn":{"id":"turn-early-cancel"}}}'
printf '%s' continued > __CONTINUED__
printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-early-cancel","turn":{"id":"turn-early-cancel"}}}'
read -r interrupt
case "$interrupt" in
  *'"method":"turn/interrupt"'*'"turnId":"turn-early-cancel"'*) ;;
  *) exit 71 ;;
esac
printf '%s' interrupted > __INTERRUPTED__
printf '%s\n' '{"id":3,"result":{}}'
printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-early-cancel","turn":{"id":"turn-early-cancel","status":"interrupted"}}}'
while read -r ignored; do :; done
"###
        .replace("__STARTED__", &started.display().to_string())
        .replace("__RELEASE__", &release.display().to_string())
        .replace("__CONTINUED__", &continued.display().to_string())
        .replace("__INTERRUPTED__", &interrupted.display().to_string());
        let executable = FakeCodexExecutable::new(&script);
        std::fs::create_dir_all(&directory).unwrap();
        let adapter = CodexAdapter::new(executable.path(), None);
        let cancellation = CancellationToken::new();
        let mut run = adapter
            .start_run(backend_request(
                cancellation.clone(),
                Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new())))),
            ))
            .await
            .unwrap();

        for _ in 0..1000 {
            if started.exists() {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert!(started.exists(), "测试 app-server 应已收到 turn/start");
        cancellation.cancel();
        std::fs::write(&release, b"release").unwrap();

        assert!(matches!(
            timeout(Duration::from_secs(1), run.events.next())
                .await
                .unwrap(),
            Some(AgentOutput::Cancelled)
        ));
        assert!(
            !continued.exists() || interrupted.exists(),
            "已继续启动的 Codex turn 必须收到 interrupt，否则应终止 transport"
        );
        assert!(run.events.next().await.is_none());
        let _ = std::fs::remove_dir_all(directory);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn deleting_an_already_missing_restored_thread_is_idempotent() {
        let executable = FakeCodexExecutable::new(
            r###"#!/bin/sh
read -r initialize
printf '%s\n' '{"id":0,"result":{}}'
read -r initialized
read -r thread_resume
case "$thread_resume" in
  *'"id":1'*'"method":"thread/resume"'*'"threadId":"missing-thread"'*) ;;
  *) exit 61 ;;
esac
printf '%s\n' '{"id":1,"error":{"code":-32600,"message":"thread not found"}}'
read -r thread_delete
case "$thread_delete" in
  *'"id":2'*'"method":"thread/delete"'*'"threadId":"missing-thread"'*) ;;
  *) exit 62 ;;
esac
printf '%s\n' '{"id":2,"result":{}}'
while read -r ignored; do :; done
"###,
        );
        let adapter = CodexAdapter::new(executable.path(), None);
        adapter
            .delete_session(
                &BackendSession {
                    id: Uuid::new_v4(),
                    model: "gpt-5-codex".to_string(),
                    backend_handle: Some("missing-thread".to_string()),
                },
                None,
            )
            .await
            .unwrap();
    }
}
