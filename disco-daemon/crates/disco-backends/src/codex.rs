use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Result;
use async_trait::async_trait;
use disco_core::{
    AgentBackend, AgentOutput, BackendCapabilities, BackendRun, BackendRunRequest, BackendSession,
};
use disco_providers::{CodexProvider, ProviderEvent};
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

    async fn provider_for(&self, session: &BackendSession) -> Arc<CodexProvider> {
        let mut sessions = self.sessions.lock().await;
        sessions
            .entry(session.id)
            .or_insert_with(|| {
                Arc::new(CodexProvider::new(
                    self.executable.clone(),
                    session.model.clone(),
                    self.reasoning_effort.clone(),
                    session.backend_handle.clone(),
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
        let provider = self.provider_for(&request.session).await;
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

            loop {
                tokio::select! {
                    _ = request.cancellation.cancelled() => {
                        let _ = provider.interrupt().await;
                        let _ = event_tx.send(AgentOutput::Cancelled).await;
                        return;
                    }
                    event = stream.next() => {
                        let output = match event {
                            Some(Ok(ProviderEvent::TextDelta(delta))) => AgentOutput::TextDelta(delta),
                            Some(Ok(ProviderEvent::ReasoningDelta(delta))) => AgentOutput::ReasoningDelta(delta),
                            Some(Ok(ProviderEvent::Usage(usage))) => AgentOutput::Usage(usage),
                            Some(Ok(ProviderEvent::Completed)) => AgentOutput::Completed,
                            Some(Ok(ProviderEvent::Cancelled)) => AgentOutput::Cancelled,
                            Some(Ok(ProviderEvent::Failed(error))) => AgentOutput::Failed(error),
                            Some(Ok(ProviderEvent::ToolCallDelta { .. } | ProviderEvent::ToolCallCompleted { .. })) => {
                                continue;
                            }
                            Some(Err(error)) => AgentOutput::Failed(error.to_string()),
                            None => AgentOutput::Failed("Codex 事件流意外结束".to_string()),
                        };
                        let terminal = matches!(
                            output,
                            AgentOutput::Completed | AgentOutput::Cancelled | AgentOutput::Failed(_)
                        );
                        if event_tx.send(output).await.is_err() || terminal {
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
            )),
            (None, None) => return Ok(()),
        };

        provider.ensure_session().await?;
        provider.delete_thread().await?;
        provider.stop().await;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

        let first = adapter.provider_for(&first_session).await;
        let first_again = adapter.provider_for(&first_session).await;
        let second = adapter.provider_for(&second_session).await;

        assert!(Arc::ptr_eq(&first, &first_again));
        assert!(!Arc::ptr_eq(&first, &second));
    }
}
