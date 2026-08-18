use std::collections::HashMap;
use std::sync::Arc;

use disco_backends::{deepseek_runtime, openai_chat_runtime, openai_responses_runtime};
use disco_core::{AgentBackend, RunCoordinator};
use disco_persist::Database;
use disco_protocol::types::{ProviderId, Vendor};
use disco_providers::ModelProvider;
use disco_tools::CompositeExecutor;
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;

/// 一个 Provider profile 对应的运行时依赖。
pub struct ProviderRuntime {
    pub backend: Arc<dyn AgentBackend>,
    /// 迁移期仅供上下文压缩使用；后续由 Backend 自己实现 compact capability。
    pub compaction_provider: Arc<dyn ModelProvider>,
}

/// 根据产品层的 Vendor 选择 Rig provider 协议，并组装 API Key 后端。
pub fn api_key_provider_runtime(
    vendor: Vendor,
    base_url: String,
    api_key: String,
    model: String,
    executor: Arc<CompositeExecutor>,
) -> anyhow::Result<ProviderRuntime> {
    let runtime = match vendor {
        Vendor::Openai | Vendor::Codex => {
            openai_responses_runtime(base_url, api_key, model, executor)?
        }
        Vendor::Deepseek => deepseek_runtime(base_url, api_key, model, executor)?,
        Vendor::MoonshotKimi | Vendor::KimiCode | Vendor::Glm => {
            openai_chat_runtime(base_url, api_key, model, executor)?
        }
    };
    Ok(ProviderRuntime {
        backend: runtime.backend,
        compaction_provider: runtime.compaction_provider,
    })
}

/// Shared application state accessible from all connection handlers.
pub struct AppState {
    pub db: Database,
    /// Provider 配置对应的运行时依赖，配置更新时原子替换。
    pub runtime_by_provider_id: Mutex<HashMap<ProviderId, ProviderRuntime>>,
    /// 活动运行、会话互斥、取消和审批路由。
    pub run_coordinator: RunCoordinator,
    /// Tool executor composite.
    pub executor: Arc<CompositeExecutor>,
    /// Shutdown signal.
    pub shutdown: CancellationToken,
}

impl AppState {
    pub async fn get_backend(&self, provider_id: &ProviderId) -> Option<Arc<dyn AgentBackend>> {
        self.runtime_by_provider_id
            .lock()
            .await
            .get(provider_id)
            .map(|runtime| runtime.backend.clone())
    }

    pub async fn get_compaction_provider(
        &self,
        provider_id: &ProviderId,
    ) -> Option<Arc<dyn ModelProvider>> {
        self.runtime_by_provider_id
            .lock()
            .await
            .get(provider_id)
            .map(|runtime| runtime.compaction_provider.clone())
    }

    pub async fn set_provider_runtime(&self, provider_id: ProviderId, runtime: ProviderRuntime) {
        self.runtime_by_provider_id
            .lock()
            .await
            .insert(provider_id, runtime);
    }
}
