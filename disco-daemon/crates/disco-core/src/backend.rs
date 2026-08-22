use std::pin::Pin;
use std::sync::Arc;

use anyhow::Result;
use async_trait::async_trait;
use disco_providers::ChatMessage;
use futures_core::Stream;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{AgentOutput, ApprovalManager};

/// 后端对 Disco 暴露的稳定能力。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BackendCapabilities {
    /// 后端是否持有可跨 daemon 重启恢复的原生会话。
    pub has_persistent_sessions: bool,
    /// 后端是否支持删除其权威会话。
    pub can_delete_session: bool,
}

/// 启动一次后端运行所需的会话快照。
#[derive(Debug, Clone)]
pub struct BackendSession {
    pub id: Uuid,
    pub model: String,
    pub backend_handle: Option<String>,
}

/// 后端启动一次运行所需的公共输入。
pub struct BackendRunRequest {
    pub run_id: Uuid,
    pub session: BackendSession,
    pub messages: Vec<ChatMessage>,
    pub workspace_path: Option<String>,
    pub cancellation: CancellationToken,
    pub approval_manager: Arc<ApprovalManager>,
}

pub type BackendEventStream = Pin<Box<dyn Stream<Item = AgentOutput> + Send>>;

/// 已启动的运行以及后端为该会话分配的不透明句柄。
pub struct BackendRun {
    pub events: BackendEventStream,
    pub backend_handle: Option<String>,
}

/// Disco agent host 与具体 agent 实现之间的 seam。
///
/// 会话互斥、协议输出和本地持久化不属于 Adapter；后端原始协议、原生会话与运行循环属于
/// Adapter。调用方只需要理解启动运行和删除权威会话两项操作。
#[async_trait]
pub trait AgentBackend: Send + Sync {
    fn capabilities(&self) -> BackendCapabilities;

    /// 恢复一个已经存在的原生会话。
    ///
    /// 没有原生持久化会话的后端（例如 Rig）可以使用默认实现；调用方仍然会从
    /// Disco 自己保存的 transcript 恢复模型上下文。
    async fn load_session(
        &self,
        _session: &BackendSession,
        _workspace_path: Option<String>,
    ) -> Result<()> {
        Ok(())
    }

    async fn start_run(&self, request: BackendRunRequest) -> Result<BackendRun>;

    /// 删除权威会话。Adapter 应在内部把“已经不存在”归一化为成功。
    async fn delete_session(&self, session: &BackendSession) -> Result<()>;
}
