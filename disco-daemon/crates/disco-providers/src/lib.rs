pub mod chat_completions;
pub mod codex;
pub mod openai_responses;

pub use chat_completions::ChatCompletionsProvider;
pub use codex::CodexProvider;
pub use openai_responses::{ChatMessage, OpenAIResponsesProvider, ProviderEvent, StreamOptions};

use std::pin::Pin;

use anyhow::Result;
use async_trait::async_trait;
use futures_core::Stream;

use disco_tools::ToolDefinition;

/// 统一模型服务商接口。
///
/// OpenAI 兼容 API（`OpenAIResponsesProvider`）与 Codex app-server
/// （`CodexProvider`）都实现该接口，agent loop 与上下文压缩器
/// 只依赖此 trait，不再耦合具体服务商。
#[async_trait]
pub trait ModelProvider: Send + Sync {
    /// 服务商名称（日志与调试用）。
    fn vendor_name(&self) -> &'static str;

    /// 流式执行一次模型调用。
    ///
    /// - `messages`：统一格式的对话历史（`ChatMessage`）
    /// - `tools`：工具定义；服务商不支持时忽略
    async fn stream<'a>(
        &'a self,
        messages: &'a [ChatMessage],
        tools: Option<&'a [ToolDefinition]>,
    ) -> Result<Pin<Box<dyn Stream<Item = Result<ProviderEvent>> + Send + 'a>>>;
}
