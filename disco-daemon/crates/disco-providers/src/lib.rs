pub mod chat_completions;
pub mod codex;
pub mod openai_responses;

pub use chat_completions::ChatCompletionsProvider;
pub use codex::{
    CodexApprovalDecision, CodexApprovalKind, CodexApprovalRequest, CodexProvider,
    CodexProviderEvent, CodexToolCall, CodexToolResult,
};
pub use openai_responses::{ChatMessage, OpenAIResponsesProvider, ProviderEvent, StreamOptions};

use std::pin::Pin;

use anyhow::Result;
use async_trait::async_trait;
use futures_core::Stream;

use disco_tools::ToolDefinition;

/// 在 PATH 与常见安装位置中查找 opencode CLI 可执行文件。
///
/// 从 app bundle 启动的 daemon 继承的 PATH 很精简（不含 `~/.opencode/bin`），
/// 因此不能依赖裸命令名解析。
pub fn find_opencode() -> String {
    if let Ok(path) = std::env::var("PATH") {
        for dir in path.split(':') {
            let candidate = format!("{dir}/opencode");
            if std::path::Path::new(&candidate).exists() {
                return candidate;
            }
        }
    }

    if let Ok(home) = std::env::var("HOME") {
        let home_candidates = [
            format!("{home}/.opencode/bin/opencode"),
            format!("{home}/.local/bin/opencode"),
        ];
        for candidate in &home_candidates {
            if std::path::Path::new(candidate).exists() {
                return candidate.clone();
            }
        }
    }

    let system_candidates = ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"];
    for candidate in system_candidates {
        if std::path::Path::new(candidate).exists() {
            return candidate.to_string();
        }
    }

    "opencode".to_string()
}

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

/// 占位 ModelProvider：用于没有模型 API 能力的后端（如外部 ACP agent）。
///
/// 任何调用都会返回明确错误，避免压缩等依赖模型调用的功能静默失败。
pub struct UnavailableModelProvider {
    reason: &'static str,
}

impl UnavailableModelProvider {
    pub fn new(reason: &'static str) -> Self {
        Self { reason }
    }
}

#[async_trait]
impl ModelProvider for UnavailableModelProvider {
    fn vendor_name(&self) -> &'static str {
        "unavailable"
    }

    async fn stream<'a>(
        &'a self,
        _messages: &'a [ChatMessage],
        _tools: Option<&'a [ToolDefinition]>,
    ) -> Result<Pin<Box<dyn Stream<Item = Result<ProviderEvent>> + Send + 'a>>> {
        anyhow::bail!("{}", self.reason)
    }
}
