//! Context compaction: summarize and truncate conversation history.
//!
//! When the conversation exceeds a soft threshold of the context window,
//! the compactor sends a summarization request to the model and replaces
//! the history with the summary.

use std::sync::Arc;

use disco_protocol::types::CompactionStatus;
use disco_providers::ModelProvider;
use disco_providers::openai_responses::{ChatMessage, ProviderEvent};
use tokio_stream::StreamExt;
use tracing::{info, warn};
use uuid::Uuid;

/// 模型目录未收录上下文窗口时的默认值（128k tokens）。
pub const DEFAULT_CONTEXT_WINDOW: i64 = 128_000;

const ASCII_CHARACTERS_PER_TOKEN: usize = 4;
const MESSAGE_OVERHEAD_TOKENS: i64 = 4;

/// Result of a compaction operation.
#[derive(Debug, Clone)]
pub struct CompactionResult {
    /// Unique ID for this compaction.
    pub id: String,
    /// The compacted summary text.
    pub summary: String,
    /// Status of the compaction.
    pub status: CompactionStatus,
    /// Estimated tokens before compaction.
    pub before_tokens: Option<i64>,
    /// Estimated tokens after compaction.
    pub after_tokens: Option<i64>,
    /// Error message if compaction failed.
    pub error_message: Option<String>,
}

/// Context compactor that summarizes conversation history.
pub struct ContextCompactor {
    /// Soft threshold as a fraction of context window (default 0.8).
    pub soft_threshold: f64,
    /// The context window size in tokens.
    pub context_window: i64,
}

impl ContextCompactor {
    /// Create a new compactor with the given context window.
    pub fn new(context_window: i64) -> Self {
        Self {
            soft_threshold: 0.8,
            context_window,
        }
    }

    /// 根据估算的 token 数判断是否需要压缩上下文。
    ///
    /// 服务商尚未上报用量时，使用与服务商无关的启发式估算。
    pub fn should_compact(&self, messages: &[ChatMessage]) -> bool {
        let estimated_tokens = self.estimate_tokens(messages);
        let threshold = (self.context_window as f64 * self.soft_threshold) as i64;
        estimated_tokens > threshold
    }

    /// 服务商尚未上报用量时，估算消息所占的 token 数。
    ///
    /// ASCII 文本按约四个字符一个 token 估算，非 ASCII 字符按字符计数，避免中文和
    /// emoji 因 UTF-8 字节长度而被严重低估；消息封装、推理、工具调用和工具结果也会计入。
    pub fn estimate_tokens(&self, messages: &[ChatMessage]) -> i64 {
        messages.iter().fold(0_i64, |total, message| {
            total.saturating_add(estimate_message_tokens(message))
        })
    }

    /// Compact the conversation by summarizing it.
    ///
    /// Sends the conversation history to the model with a summarization prompt.
    pub async fn compact(
        &self,
        messages: &[ChatMessage],
        provider: &Arc<dyn ModelProvider>,
    ) -> CompactionResult {
        self.compact_with_id(Uuid::new_v4().to_string(), messages, provider)
            .await
    }

    /// 使用调用方分配的 ID 执行压缩，以便 facade 在开始前发送生命周期事件。
    pub async fn compact_with_id(
        &self,
        compaction_id: String,
        messages: &[ChatMessage],
        provider: &Arc<dyn ModelProvider>,
    ) -> CompactionResult {
        let before_tokens = Some(self.estimate_tokens(messages));

        info!(
            "Starting context compaction {} (before: ~{} tokens)",
            compaction_id,
            before_tokens.unwrap_or(0)
        );

        // Build the summarization request
        let conversation_text = messages
            .iter()
            .map(format_message_for_summary)
            .collect::<Vec<_>>()
            .join("\n");

        let summary_messages = vec![
            ChatMessage {
                role: "system".to_string(),
                text: "You are a conversation summarizer. Summarize the following conversation concisely, preserving key decisions, context, and important details. Output only the summary, no preamble.".to_string(),
                reasoning_content: None,
                ..Default::default()
            },
            ChatMessage {
                role: "user".to_string(),
                text: format!("Summarize this conversation:\n\n{conversation_text}"),
                reasoning_content: None,
                ..Default::default()
            },
        ];

        // Stream the summarization
        let event_stream = match provider.stream(&summary_messages, None).await {
            Ok(stream) => stream,
            Err(e) => {
                warn!("Compaction {} failed: {e}", compaction_id);
                return CompactionResult {
                    id: compaction_id,
                    summary: String::new(),
                    status: CompactionStatus::Failed,
                    before_tokens,
                    after_tokens: None,
                    error_message: Some(e.to_string()),
                };
            }
        };

        tokio::pin!(event_stream);

        let mut summary = String::new();
        let mut failed = false;
        let mut error_msg = None;

        while let Some(event) = event_stream.next().await {
            match event {
                Ok(ProviderEvent::TextDelta(delta)) => {
                    summary.push_str(&delta);
                }
                Ok(ProviderEvent::Completed) => {
                    break;
                }
                Ok(ProviderEvent::Failed(msg)) => {
                    failed = true;
                    error_msg = Some(msg);
                    break;
                }
                Ok(ProviderEvent::Cancelled) => {
                    failed = true;
                    error_msg = Some("上下文压缩已取消".to_string());
                    break;
                }
                Err(e) => {
                    failed = true;
                    error_msg = Some(e.to_string());
                    break;
                }
                _ => {}
            }
        }

        if failed || summary.is_empty() {
            let err = error_msg.unwrap_or_else(|| "Empty summary".to_string());
            warn!("Compaction {} failed: {err}", compaction_id);
            return CompactionResult {
                id: compaction_id,
                summary: String::new(),
                status: CompactionStatus::Failed,
                before_tokens,
                after_tokens: None,
                error_message: Some(err),
            };
        }

        let after_tokens = Some(self.estimate_tokens(&[ChatMessage {
            role: "assistant".to_string(),
            text: summary.clone(),
            reasoning_content: None,
            ..Default::default()
        }]));

        info!(
            "Compaction {} completed (before: ~{}, after: ~{} tokens)",
            compaction_id,
            before_tokens.unwrap_or(0),
            after_tokens.unwrap_or(0)
        );

        CompactionResult {
            id: compaction_id,
            summary,
            status: CompactionStatus::Completed,
            before_tokens,
            after_tokens,
            error_message: None,
        }
    }
}

fn estimate_message_tokens(message: &ChatMessage) -> i64 {
    let mut tokens = MESSAGE_OVERHEAD_TOKENS
        .saturating_add(estimate_text_tokens(&message.role))
        .saturating_add(estimate_text_tokens(&message.text));

    if let Some(reasoning) = &message.reasoning_content {
        tokens = tokens.saturating_add(estimate_text_tokens(reasoning));
    }
    if let Some(tool_calls) = &message.tool_calls {
        for tool_call in tool_calls {
            tokens = tokens
                .saturating_add(estimate_text_tokens(&tool_call.call_id))
                .saturating_add(estimate_text_tokens(&tool_call.name))
                .saturating_add(estimate_text_tokens(&tool_call.arguments));
        }
    }
    if let Some(tool_call_id) = &message.tool_call_id {
        tokens = tokens.saturating_add(estimate_text_tokens(tool_call_id));
    }
    if let Some(tool_name) = &message.tool_name {
        tokens = tokens.saturating_add(estimate_text_tokens(tool_name));
    }

    tokens
}

fn format_message_for_summary(message: &ChatMessage) -> String {
    serde_json::to_string(message).unwrap_or_else(|_| format!("{}: {}", message.role, message.text))
}

fn estimate_text_tokens(text: &str) -> i64 {
    let mut tokens = 0_usize;
    let mut ascii_run = 0_usize;

    for character in text.chars() {
        if character.is_ascii() {
            ascii_run += 1;
            continue;
        }

        tokens += ascii_run.div_ceil(ASCII_CHARACTERS_PER_TOKEN);
        ascii_run = 0;
        tokens += 1;
    }

    tokens += ascii_run.div_ceil(ASCII_CHARACTERS_PER_TOKEN);
    i64::try_from(tokens).unwrap_or(i64::MAX)
}

/// Apply compaction: replace message history with a summary checkpoint.
///
/// Returns a new message list with the summary as a system message
/// followed by any recent messages that should be preserved.
pub fn apply_compaction(
    messages: &[ChatMessage],
    summary: &str,
    preserve_recent: usize,
) -> Vec<ChatMessage> {
    let mut result = Vec::new();

    // Add the summary as a system message
    result.push(ChatMessage {
        role: "system".to_string(),
        text: format!(
            "Previous conversation summary:\n{summary}\n\nContinue the conversation from where it left off."
        ),
        reasoning_content: None,
        ..Default::default()
    });

    // Preserve the most recent messages
    let start = messages.len().saturating_sub(preserve_recent);
    for msg in &messages[start..] {
        result.push(msg.clone());
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use disco_providers::openai_responses::ToolCallInfo;

    #[test]
    fn estimate_tokens_basic() {
        let compactor = ContextCompactor::new(128000);
        let messages = vec![
            ChatMessage {
                role: "user".to_string(),
                text: "Hello, how are you?".to_string(),
                reasoning_content: None,
                ..Default::default()
            },
            ChatMessage {
                role: "assistant".to_string(),
                text: "I'm doing well, thank you!".to_string(),
                reasoning_content: None,
                ..Default::default()
            },
        ];

        let tokens = compactor.estimate_tokens(&messages);
        assert!(tokens > 0);
        assert!(tokens < 100);
    }

    #[test]
    fn estimate_tokens_counts_non_ascii_text_by_character() {
        assert_eq!(estimate_text_tokens("中"), 1);
        assert_eq!(estimate_text_tokens("你好世界"), 4);
        assert!(estimate_text_tokens("你好世界") > estimate_text_tokens("abcd"));
    }

    #[test]
    fn estimate_tokens_includes_reasoning_and_tool_payloads() {
        let plain_message = ChatMessage {
            role: "assistant".to_string(),
            text: "完成".to_string(),
            ..Default::default()
        };
        let rich_message = ChatMessage {
            reasoning_content: Some("先检查状态".to_string()),
            tool_calls: Some(vec![ToolCallInfo {
                call_id: "call-1".to_string(),
                name: "shell".to_string(),
                arguments: r#"{"command":"cargo test"}"#.to_string(),
            }]),
            ..plain_message.clone()
        };

        assert!(estimate_message_tokens(&rich_message) > estimate_message_tokens(&plain_message));
    }

    #[test]
    fn should_compact_below_threshold() {
        let compactor = ContextCompactor::new(128000);
        let messages = vec![ChatMessage {
            role: "user".to_string(),
            text: "Short message".to_string(),
            reasoning_content: None,
            ..Default::default()
        }];

        assert!(!compactor.should_compact(&messages));
    }

    #[test]
    fn should_compact_above_threshold() {
        // Small context window to trigger compaction easily
        let compactor = ContextCompactor::new(10);
        let messages = vec![ChatMessage {
            role: "user".to_string(),
            text: "A".repeat(100), // 100 chars / 4 = 25 tokens > 80% of 10
            reasoning_content: None,
            ..Default::default()
        }];

        assert!(compactor.should_compact(&messages));
    }

    #[test]
    fn apply_compaction_preserves_recent() {
        let messages = vec![
            ChatMessage {
                role: "user".to_string(),
                text: "First message".to_string(),
                reasoning_content: None,
                ..Default::default()
            },
            ChatMessage {
                role: "assistant".to_string(),
                text: "First response".to_string(),
                reasoning_content: None,
                ..Default::default()
            },
            ChatMessage {
                role: "user".to_string(),
                text: "Second message".to_string(),
                reasoning_content: None,
                ..Default::default()
            },
            ChatMessage {
                role: "assistant".to_string(),
                text: "Second response".to_string(),
                reasoning_content: None,
                ..Default::default()
            },
        ];

        let result = apply_compaction(&messages, "Summary of conversation", 2);

        // Should have summary + 2 recent messages
        assert_eq!(result.len(), 3);
        assert_eq!(result[0].role, "system");
        assert!(result[0].text.contains("Summary of conversation"));
        assert_eq!(result[1].text, "Second message");
        assert_eq!(result[2].text, "Second response");
    }

    #[test]
    fn apply_compaction_empty_history() {
        let result = apply_compaction(&[], "Summary", 5);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].role, "system");
    }

    #[test]
    fn apply_compaction_preserve_more_than_available() {
        let messages = vec![ChatMessage {
            role: "user".to_string(),
            text: "Only message".to_string(),
            reasoning_content: None,
            ..Default::default()
        }];

        let result = apply_compaction(&messages, "Summary", 10);
        // Summary + 1 message (all available)
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn compaction_result_failed() {
        let result = CompactionResult {
            id: "test-id".to_string(),
            summary: String::new(),
            status: CompactionStatus::Failed,
            before_tokens: Some(1000),
            after_tokens: None,
            error_message: Some("API error".to_string()),
        };

        assert_eq!(result.status, CompactionStatus::Failed);
        assert!(result.error_message.is_some());
        assert!(result.summary.is_empty());
    }
}
