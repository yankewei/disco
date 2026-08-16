use std::sync::Arc;

use anyhow::Result;
use async_trait::async_trait;
use disco_core::{
    AgentBackend, AgentLoop, BackendCapabilities, BackendRun, BackendRunRequest, BackendSession,
};
use disco_providers::ModelProvider;
use disco_tools::CompositeExecutor;

/// 迁移期的模型 API Adapter。
///
/// 它把现有手写 `ModelProvider` 与 Disco agent loop 收敛到 AgentBackend seam。RigBackend
/// 完成后会替换其内部实现，daemon 和协议层无需再次改动。
pub struct ModelApiBackend {
    provider: Arc<dyn ModelProvider>,
    executor: Arc<CompositeExecutor>,
}

impl ModelApiBackend {
    pub fn new(provider: Arc<dyn ModelProvider>, executor: Arc<CompositeExecutor>) -> Self {
        Self { provider, executor }
    }
}

#[async_trait]
impl AgentBackend for ModelApiBackend {
    fn capabilities(&self) -> BackendCapabilities {
        BackendCapabilities {
            has_persistent_sessions: false,
            can_delete_session: true,
        }
    }

    async fn start_run(&self, request: BackendRunRequest) -> Result<BackendRun> {
        let agent = AgentLoop::new(
            self.provider.clone(),
            self.executor.clone(),
            request.approval_manager,
        );
        let events = agent
            .run(
                request.messages,
                request.cancellation,
                request.run_id,
                request.session.id,
                request.workspace_path,
            )
            .await;

        Ok(BackendRun {
            events: Box::pin(events),
            backend_handle: None,
        })
    }

    async fn delete_session(&self, _session: &BackendSession) -> Result<()> {
        // 模型 API 会话的权威状态就在 Disco 数据库中，没有远端会话需要删除。
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::pin::Pin;

    use disco_core::{AgentOutput, ApprovalManager};
    use disco_providers::{ChatMessage, ProviderEvent};
    use disco_tools::ToolDefinition;
    use futures_core::Stream;
    use tokio::sync::Mutex;
    use tokio_stream::StreamExt;
    use tokio_util::sync::CancellationToken;
    use uuid::Uuid;

    use super::*;

    struct TextProvider;

    #[async_trait]
    impl ModelProvider for TextProvider {
        fn vendor_name(&self) -> &'static str {
            "test"
        }

        async fn stream<'a>(
            &'a self,
            _messages: &'a [ChatMessage],
            _tools: Option<&'a [ToolDefinition]>,
        ) -> Result<Pin<Box<dyn Stream<Item = Result<ProviderEvent>> + Send + 'a>>> {
            Ok(Box::pin(tokio_stream::iter(vec![
                Ok(ProviderEvent::TextDelta("你好".to_string())),
                Ok(ProviderEvent::Completed),
            ])))
        }
    }

    #[tokio::test]
    async fn model_api_backend_exposes_the_common_run_contract() {
        let backend =
            ModelApiBackend::new(Arc::new(TextProvider), Arc::new(CompositeExecutor::new()));
        let request = BackendRunRequest {
            run_id: Uuid::new_v4(),
            session: BackendSession {
                id: Uuid::new_v4(),
                model: "test-model".to_string(),
                backend_handle: None,
            },
            messages: vec![ChatMessage {
                role: "user".to_string(),
                text: "测试".to_string(),
                ..Default::default()
            }],
            workspace_path: None,
            cancellation: CancellationToken::new(),
            approval_manager: Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new())))),
        };

        let run = backend.start_run(request).await.unwrap();
        assert_eq!(run.backend_handle, None);
        let events = run.events.collect::<Vec<_>>().await;
        assert!(matches!(&events[0], AgentOutput::TextDelta(text) if text == "你好"));
        assert!(matches!(&events[1], AgentOutput::Completed));
    }
}
