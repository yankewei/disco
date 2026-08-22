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

    /// Check if compaction is needed based on estimated token count.
    ///
    /// Uses a simple character-based estimation: ~4 characters per token.
    pub fn should_compact(&self, messages: &[ChatMessage]) -> bool {
        let estimated_tokens = self.estimate_tokens(messages);
        let threshold = (self.context_window as f64 * self.soft_threshold) as i64;
        estimated_tokens > threshold
    }

    /// Estimate the token count of messages.
    ///
    /// Uses a simple heuristic: ~4 characters per token.
    pub fn estimate_tokens(&self, messages: &[ChatMessage]) -> i64 {
        let total_chars: usize = messages.iter().map(|m| m.text.len()).sum();
        (total_chars / 4) as i64
    }

    /// Compact the conversation by summarizing it.
    ///
    /// Sends the conversation history to the model with a summarization prompt.
    pub async fn compact(
        &self,
        messages: &[ChatMessage],
        provider: &Arc<dyn ModelProvider>,
    ) -> CompactionResult {
        let compaction_id = Uuid::new_v4().to_string();
        let before_tokens = Some(self.estimate_tokens(messages));

        info!(
            "Starting context compaction {} (before: ~{} tokens)",
            compaction_id,
            before_tokens.unwrap_or(0)
        );

        // Build the summarization request
        let conversation_text = messages
            .iter()
            .map(|m| format!("{}: {}", m.role, m.text))
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
        // "Hello, how are you?" = 20 chars, "I'm doing well, thank you!" = 27 chars
        // Total = 47 chars / 4 = ~11 tokens
        assert!(tokens > 0);
        assert!(tokens < 100);
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
