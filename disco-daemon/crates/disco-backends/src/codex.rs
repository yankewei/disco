use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Result;
use async_trait::async_trait;
use disco_core::{
    AgentBackend, AgentOutput, ApprovalManager, ApprovalRequest, BackendCapabilities, BackendRun,
    BackendRunRequest, BackendSession,
};
use disco_protocol::types::{ApprovalDecision, ApprovalImpact};
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
        }
    }

    async fn start_run(&self, request: BackendRunRequest) -> Result<BackendRun> {
        let provider = self
            .provider_for(&request.session, request.workspace_path.clone())
            .await;
        let backend_handle = provider.ensure_session().await?;
        let (event_tx, event_rx) = mpsc::channel(64);

        tokio::spawn(async move {
            let stream = match provider.stream_turn(&request.messages).await {
                Ok(stream) => stream,
                Err(error) => {
                    let _ = event_tx.send(AgentOutput::Failed(error.to_string())).await;
                    return;
                }
            };
            tokio::pin!(stream);
            let mut tool_arguments_by_id = HashMap::new();

            loop {
                tokio::select! {
                    _ = request.cancellation.cancelled() => {
                        request.approval_manager.cancel_all().await;
                        let _ = provider.interrupt().await;
                        let _ = event_tx.send(AgentOutput::Cancelled).await;
                        return;
                    }
                    event = stream.next() => {
                        let output = match event {
                            Some(Ok(CodexProviderEvent::TextDelta(delta))) => AgentOutput::TextDelta(delta),
                            Some(Ok(CodexProviderEvent::ReasoningDelta(delta))) => AgentOutput::ReasoningDelta(delta),
                            Some(Ok(CodexProviderEvent::Usage(usage))) => AgentOutput::Usage(usage),
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

    async fn delete_session(&self, session: &BackendSession) -> Result<()> {
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
        if event_tx
            .send(AgentOutput::ApprovalWaiting {
                approval_id: approval.id,
                kind: approval.kind.clone(),
                title: approval.title.clone(),
                impact: approval.impact.clone(),
                fingerprint: approval.fingerprint.clone(),
                allows_session_approval: approval.allows_session_approval,
            })
            .await
            .is_err()
        {
            let _ = provider
                .respond_to_approval(&request, CodexApprovalDecision::Cancel)
                .await;
            return;
        }

        let decision = tokio::select! {
            biased;
            _ = cancellation.cancelled() => {
                let _ = provider
                    .respond_to_approval(&request, CodexApprovalDecision::Cancel)
                    .await;
                return;
            }
            decision = approval_manager.request_approval(&approval) => decision,
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
    let (kind, impact, fingerprint) = match request.kind {
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
            )
        }
        CodexApprovalKind::FileChange => {
            let (paths, diff) = file_change_details(request, tool_arguments);
            (
                "file_change".to_string(),
                ApprovalImpact::FileChange {
                    paths: paths.clone(),
                    summary: request.title.clone(),
                    diff,
                },
                if paths.is_empty() {
                    format!("codex:file_change:item:{}", request.item_id)
                } else {
                    format!("codex:file_change:{}", paths.join("|"))
                },
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
        allows_session_approval: request.allows_session_approval,
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
printf '%s\n' '{"id":2,"result":{}}'
printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-test","turn":{"id":"turn-test"}}}'
printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-test","turnId":"turn-test","item":{"type":"commandExecution","id":"tool-test","command":"echo hello","cwd":"/tmp/codex-workspace","status":"inProgress"}}}'
printf '%s\n' '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-test","turnId":"turn-test","itemId":"tool-test","startedAtMs":1,"command":"echo hello","cwd":"/tmp/codex-workspace","availableDecisions":["accept","acceptForSession","decline","cancel"]}}'
read -r approval
case "$approval" in
  *'"id":"approval-1"'*'"decision":"acceptForSession"'*) ;;
  *) exit 42 ;;
esac
printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-test","turnId":"turn-test","item":{"type":"commandExecution","id":"tool-test","command":"echo hello","cwd":"/tmp/codex-workspace","status":"completed","aggregatedOutput":"hello\n","exitCode":0}}}'
printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-test","turnId":"turn-test","delta":"已完成"}}'
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
                let mut responded = approval_manager
                    .respond(*approval_id, ApprovalDecision::ApproveForSession)
                    .await;
                for _ in 0..100 {
                    if responded {
                        break;
                    }
                    tokio::task::yield_now().await;
                    responded = approval_manager
                        .respond(*approval_id, ApprovalDecision::ApproveForSession)
                        .await;
                }
                assert!(responded);
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
        assert!(matches!(&events[5], AgentOutput::Completed));

        adapter
            .delete_session(&BackendSession {
                backend_handle: run.backend_handle,
                ..session
            })
            .await
            .unwrap();
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
            .delete_session(&BackendSession {
                id: Uuid::new_v4(),
                model: "gpt-5-codex".to_string(),
                backend_handle: Some("missing-thread".to_string()),
            })
            .await
            .unwrap();
    }
}
