use std::pin::Pin;
use std::sync::Arc;

use anyhow::{Context, Result};
use async_trait::async_trait;
use eventsource_stream::Eventsource;
use futures_core::Stream;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tokio_stream::StreamExt;
use tracing::{debug, warn};

use disco_protocol::types::TokenUsage;
use disco_tools::ToolDefinition;

use crate::ModelProvider;

/// A tool call made by the model.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCallInfo {
    pub call_id: String,
    pub name: String,
    pub arguments: String,
}

/// A simple chat message for provider communication.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    #[serde(default)]
    pub text: String,
    /// Optional reasoning content from a previous assistant turn.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_content: Option<String>,
    /// Tool calls made by the assistant (role = "assistant").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ToolCallInfo>>,
    /// Tool call ID this message is a result for (role = "user").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    /// Tool name (role = "user" for tool results).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
}

/// Events emitted by the provider during streaming.
#[derive(Debug, Clone)]
pub enum ProviderEvent {
    /// A text delta from the model.
    TextDelta(String),
    /// A reasoning/thinking delta from the model.
    ReasoningDelta(String),
    /// Token usage information.
    Usage(TokenUsage),
    /// A streaming tool call argument delta.
    ToolCallDelta {
        call_id: String,
        name: String,
        arguments_delta: String,
    },
    /// A tool call has completed with full arguments.
    ToolCallCompleted {
        call_id: String,
        name: String,
        arguments: String,
    },
    /// The response completed successfully.
    Completed,
    /// The response was cancelled by the backend.
    Cancelled,
    /// The response failed with an error message.
    Failed(String),
}

/// Options for a streaming request, including optional tool definitions.
#[derive(Debug, Clone, Default)]
pub struct StreamOptions<'a> {
    pub messages: &'a [ChatMessage],
    pub tools: Option<&'a [ToolDefinition]>,
}

/// OpenAI Responses API streaming provider.
pub struct OpenAIResponsesProvider {
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    http_client: Client,
}

impl OpenAIResponsesProvider {
    /// Create a new provider instance.
    pub fn new(base_url: String, api_key: String, model: String) -> Self {
        Self {
            base_url,
            api_key,
            model,
            http_client: Client::new(),
        }
    }

    /// Create from environment variables.
    /// - `OPENAI_API_KEY` (required)
    /// - `OPENAI_BASE_URL` (optional, defaults to `https://api.openai.com/v1`)
    /// - `OPENAI_MODEL` (optional, defaults to `gpt-4o`)
    pub fn from_env() -> Result<Arc<Self>> {
        let api_key = std::env::var("OPENAI_API_KEY")
            .context("OPENAI_API_KEY environment variable not set")?;
        let base_url = std::env::var("OPENAI_BASE_URL")
            .unwrap_or_else(|_| "https://api.openai.com/v1".to_string());
        let model = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "gpt-4o".to_string());

        Ok(Arc::new(Self::new(base_url, api_key, model)))
    }

    /// Stream a chat completion using the OpenAI Responses API.
    ///
    /// Returns a stream of `ProviderEvent` items.
    pub async fn stream(
        &self,
        messages: &[ChatMessage],
    ) -> Result<impl Stream<Item = Result<ProviderEvent>>> {
        self.stream_with_options(StreamOptions {
            messages,
            tools: None,
        })
        .await
    }

    /// Stream with optional tool definitions.
    pub async fn stream_with_options(
        &self,
        options: StreamOptions<'_>,
    ) -> Result<impl Stream<Item = Result<ProviderEvent>>> {
        let url = format!("{}/responses", self.base_url.trim_end_matches('/'));

        // Build the input array for the Responses API
        let input: Vec<serde_json::Value> = options
            .messages
            .iter()
            .flat_map(|m| {
                let mut items = Vec::new();

                // Tool result messages become function_call_output items
                if m.role == "user" && m.tool_call_id.is_some() {
                    items.push(serde_json::json!({
                        "type": "function_call_output",
                        "call_id": m.tool_call_id,
                        "output": m.text,
                    }));
                } else {
                    // Regular message content
                    let content = if m.role == "assistant" && m.tool_calls.is_some() {
                        // Assistant message with tool calls: text + function_call items
                        let mut parts = Vec::new();
                        if !m.text.is_empty() {
                            parts.push(serde_json::json!({
                                "type": "output_text",
                                "text": m.text,
                            }));
                        }
                        if let Some(tool_calls) = &m.tool_calls {
                            for tc in tool_calls {
                                parts.push(serde_json::json!({
                                    "type": "function_call",
                                    "call_id": tc.call_id,
                                    "name": tc.name,
                                    "arguments": tc.arguments,
                                }));
                            }
                        }
                        serde_json::Value::Array(parts)
                    } else {
                        serde_json::Value::String(m.text.clone())
                    };

                    items.push(serde_json::json!({
                        "role": m.role,
                        "content": content,
                    }));
                }

                items
            })
            .collect();

        let mut body = serde_json::json!({
            "model": self.model,
            "stream": true,
            "input": input,
        });

        // Add tools if provided
        if let Some(tools) = options.tools {
            if !tools.is_empty() {
                let tools_json: Vec<serde_json::Value> = tools
                    .iter()
                    .map(|t| {
                        serde_json::json!({
                            "type": "function",
                            "name": t.name,
                            "description": t.description,
                            "parameters": t.input_schema,
                        })
                    })
                    .collect();
                body.as_object_mut()
                    .unwrap()
                    .insert("tools".to_string(), serde_json::Value::Array(tools_json));
            }
        }

        debug!("POST {url} model={}", self.model);

        let response = self
            .http_client
            .post(&url)
            .bearer_auth(&self.api_key)
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .await
            .context("Failed to send request to OpenAI Responses API")?;

        if !response.status().is_success() {
            let status = response.status();
            let body_text = response
                .text()
                .await
                .unwrap_or_else(|_| "<failed to read body>".to_string());
            anyhow::bail!("OpenAI API error {status}: {body_text}");
        }

        let byte_stream = response.bytes_stream();
        let event_stream = byte_stream.eventsource();

        let stream = async_stream::try_stream! {
            let mut event_stream = event_stream;
            while let Some(event) = event_stream.next().await {
                let event = event.map_err(|e| anyhow::anyhow!("SSE stream error: {e}"))?;

                // Skip empty events (keep-alive, etc.)
                if event.data.is_empty() {
                    continue;
                }

                // The last SSE event before stream end is "[DONE]"
                if event.data == "[DONE]" {
                    yield ProviderEvent::Completed;
                    break;
                }

                let json: serde_json::Value = serde_json::from_str(&event.data)
                    .map_err(|e| anyhow::anyhow!("Failed to parse SSE data: {e}"))?;

                let event_type = json["type"].as_str().unwrap_or("");

                match event_type {
                    "response.output_text.delta" => {
                        if let Some(delta) = json["delta"].as_str() {
                            yield ProviderEvent::TextDelta(delta.to_string());
                        }
                    }
                    "response.reasoning_summary_text.delta" => {
                        if let Some(delta) = json["delta"].as_str() {
                            yield ProviderEvent::ReasoningDelta(delta.to_string());
                        }
                    }
                    "response.output_item.added" => {
                        // Check if this is a function_call item
                        if let Some(item) = json["item"].as_object() {
                            if item.get("type").and_then(|t| t.as_str()) == Some("function_call") {
                                let call_id = item.get("call_id")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                let name = item.get("name")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                let arguments = item.get("arguments")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                if !call_id.is_empty() {
                                    yield ProviderEvent::ToolCallDelta {
                                        call_id,
                                        name: name.clone(),
                                        arguments_delta: arguments,
                                    };
                                }
                            }
                        }
                    }
                    "response.function_call_arguments.delta" => {
                        let call_id = json["item_id"].as_str().unwrap_or("").to_string();
                        let delta = json["delta"].as_str().unwrap_or("").to_string();
                        if !delta.is_empty() {
                            yield ProviderEvent::ToolCallDelta {
                                call_id,
                                name: String::new(), // Name not available in delta events
                                arguments_delta: delta,
                            };
                        }
                    }
                    "response.function_call_arguments.done" => {
                        let call_id = json["item_id"].as_str().unwrap_or("").to_string();
                        let name = json["name"].as_str().unwrap_or("").to_string();
                        let arguments = json["arguments"].as_str().unwrap_or("").to_string();
                        if !call_id.is_empty() {
                            yield ProviderEvent::ToolCallCompleted {
                                call_id,
                                name,
                                arguments,
                            };
                        }
                    }
                    "response.completed" => {
                        // Extract usage data if available
                        if let Some(usage_val) = json["response"]["usage"].as_object() {
                            if let Some(usage) = parse_responses_usage(usage_val) {
                                yield ProviderEvent::Usage(usage);
                            }
                        }
                        yield ProviderEvent::Completed;
                        break;
                    }
                    "response.failed" => {
                        let error_msg = json["error"]["message"]
                            .as_str()
                            .unwrap_or("Unknown error")
                            .to_string();
                        yield ProviderEvent::Failed(error_msg);
                        break;
                    }
                    _ => {
                        // Ignore other event types (response.created, etc.)
                        debug!("Ignoring SSE event type: {event_type}");
                    }
                }
            }
        };

        Ok(stream)
    }
}

/// Parse usage data from OpenAI Responses API format.
fn parse_responses_usage(usage: &serde_json::Map<String, serde_json::Value>) -> Option<TokenUsage> {
    let input = usage.get("input_tokens")?.as_i64()?;
    let output = usage.get("output_tokens")?.as_i64()?;
    let total = usage
        .get("total_tokens")
        .and_then(|v| v.as_i64())
        .unwrap_or(input + output);
    let cached_input = usage
        .get("input_tokens_details")
        .and_then(|d| d.get("cached_tokens"))
        .and_then(|v| v.as_i64());
    let reasoning_output = usage
        .get("output_tokens_details")
        .and_then(|d| d.get("reasoning_tokens"))
        .and_then(|v| v.as_i64());

    Some(TokenUsage {
        input,
        output,
        total,
        cached_input,
        reasoning_output,
    })
}

/// Parse a single SSE data line into a Vec of ProviderEvents (for testing).
/// Returns a vec because some events may produce multiple provider events.
pub fn parse_sse_data(data: &str) -> Result<Vec<ProviderEvent>> {
    if data == "[DONE]" {
        return Ok(vec![ProviderEvent::Completed]);
    }

    let json: serde_json::Value = serde_json::from_str(data).context("Failed to parse SSE JSON")?;
    let event_type = json["type"].as_str().unwrap_or("");

    let mut events = Vec::new();

    match event_type {
        "response.output_text.delta" => {
            let delta = json["delta"].as_str().unwrap_or("").to_string();
            events.push(ProviderEvent::TextDelta(delta));
        }
        "response.reasoning_summary_text.delta" => {
            let delta = json["delta"].as_str().unwrap_or("").to_string();
            events.push(ProviderEvent::ReasoningDelta(delta));
        }
        "response.output_item.added" => {
            if let Some(item) = json["item"].as_object() {
                if item.get("type").and_then(|t| t.as_str()) == Some("function_call") {
                    let call_id = item
                        .get("call_id")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let name = item
                        .get("name")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let arguments = item
                        .get("arguments")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    if !call_id.is_empty() {
                        events.push(ProviderEvent::ToolCallDelta {
                            call_id,
                            name,
                            arguments_delta: arguments,
                        });
                    }
                }
            }
        }
        "response.function_call_arguments.delta" => {
            let call_id = json["item_id"].as_str().unwrap_or("").to_string();
            let delta = json["delta"].as_str().unwrap_or("").to_string();
            if !delta.is_empty() {
                events.push(ProviderEvent::ToolCallDelta {
                    call_id,
                    name: String::new(),
                    arguments_delta: delta,
                });
            }
        }
        "response.function_call_arguments.done" => {
            let call_id = json["item_id"].as_str().unwrap_or("").to_string();
            let name = json["name"].as_str().unwrap_or("").to_string();
            let arguments = json["arguments"].as_str().unwrap_or("").to_string();
            if !call_id.is_empty() {
                events.push(ProviderEvent::ToolCallCompleted {
                    call_id,
                    name,
                    arguments,
                });
            }
        }
        "response.completed" => {
            events.push(ProviderEvent::Completed);
        }
        "response.failed" => {
            let error_msg = json["error"]["message"]
                .as_str()
                .unwrap_or("Unknown error")
                .to_string();
            events.push(ProviderEvent::Failed(error_msg));
        }
        other => {
            warn!("Unknown SSE event type: {other}");
            events.push(ProviderEvent::TextDelta(String::new()));
        }
    }

    Ok(events)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_text_delta() {
        let data = r#"{"type":"response.output_text.delta","delta":"Hello, world!"}"#;
        let events = parse_sse_data(data).unwrap();
        assert_eq!(events.len(), 1);
        match &events[0] {
            ProviderEvent::TextDelta(d) => assert_eq!(d, "Hello, world!"),
            _ => panic!("Expected TextDelta"),
        }
    }

    #[test]
    fn parse_reasoning_delta() {
        let data = r#"{"type":"response.reasoning_summary_text.delta","delta":"Let me think..."}"#;
        let events = parse_sse_data(data).unwrap();
        assert_eq!(events.len(), 1);
        match &events[0] {
            ProviderEvent::ReasoningDelta(d) => assert_eq!(d, "Let me think..."),
            _ => panic!("Expected ReasoningDelta"),
        }
    }

    #[test]
    fn parse_completed() {
        let data = r#"{"type":"response.completed","response":{"id":"resp_123"}}"#;
        let events = parse_sse_data(data).unwrap();
        assert!(events.iter().any(|e| matches!(e, ProviderEvent::Completed)));
    }

    #[test]
    fn parse_failed() {
        let data = r#"{"type":"response.failed","error":{"message":"Rate limit exceeded"}}"#;
        let events = parse_sse_data(data).unwrap();
        match &events[0] {
            ProviderEvent::Failed(msg) => assert_eq!(msg, "Rate limit exceeded"),
            _ => panic!("Expected Failed"),
        }
    }

    #[test]
    fn parse_done_sentinel() {
        let events = parse_sse_data("[DONE]").unwrap();
        assert!(events.iter().any(|e| matches!(e, ProviderEvent::Completed)));
    }

    #[test]
    fn parse_unknown_event_type() {
        let data = r#"{"type":"response.created","response":{"id":"resp_123"}}"#;
        let events = parse_sse_data(data).unwrap();
        // Unknown types produce empty TextDelta
        match &events[0] {
            ProviderEvent::TextDelta(d) => assert!(d.is_empty()),
            _ => panic!("Expected empty TextDelta for unknown event"),
        }
    }

    #[test]
    fn parse_invalid_json() {
        let result = parse_sse_data("not json at all");
        assert!(result.is_err());
    }

    #[test]
    fn chat_message_serialization() {
        let msg = ChatMessage {
            role: "user".to_string(),
            text: "hello".to_string(),
            reasoning_content: None,
            tool_calls: None,
            tool_call_id: None,
            tool_name: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"role\":\"user\""));
        assert!(json.contains("\"text\":\"hello\""));
        // reasoning_content should be omitted when None
        assert!(!json.contains("reasoning_content"));
    }

    #[test]
    fn chat_message_with_reasoning_serialization() {
        let msg = ChatMessage {
            role: "assistant".to_string(),
            text: "answer".to_string(),
            reasoning_content: Some("thinking...".to_string()),
            tool_calls: None,
            tool_call_id: None,
            tool_name: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"reasoning_content\":\"thinking...\""));
    }

    #[test]
    fn parse_responses_usage_data() {
        let usage_json = serde_json::json!({
            "input_tokens": 100,
            "output_tokens": 50,
            "total_tokens": 150,
            "input_tokens_details": {"cached_tokens": 30},
            "output_tokens_details": {"reasoning_tokens": 20}
        });
        let usage_map = usage_json.as_object().unwrap();
        let usage = parse_responses_usage(usage_map).unwrap();
        assert_eq!(usage.input, 100);
        assert_eq!(usage.output, 50);
        assert_eq!(usage.total, 150);
        assert_eq!(usage.cached_input, Some(30));
        assert_eq!(usage.reasoning_output, Some(20));
    }

    #[test]
    fn parse_responses_usage_missing_fields() {
        let usage_json = serde_json::json!({
            "input_tokens": 100,
            "output_tokens": 50
        });
        let usage_map = usage_json.as_object().unwrap();
        let usage = parse_responses_usage(usage_map).unwrap();
        assert_eq!(usage.input, 100);
        assert_eq!(usage.output, 50);
        assert_eq!(usage.total, 150); // computed
        assert_eq!(usage.cached_input, None);
        assert_eq!(usage.reasoning_output, None);
    }

    // MARK: - Tool call parsing tests

    #[test]
    fn parse_function_call_output_item_added() {
        let data = r#"{
            "type": "response.output_item.added",
            "output_index": 0,
            "item": {
                "type": "function_call",
                "call_id": "call_abc123",
                "name": "shell",
                "arguments": ""
            }
        }"#;
        let events = parse_sse_data(data).unwrap();
        assert_eq!(events.len(), 1);
        match &events[0] {
            ProviderEvent::ToolCallDelta {
                call_id,
                name,
                arguments_delta,
            } => {
                assert_eq!(call_id, "call_abc123");
                assert_eq!(name, "shell");
                assert_eq!(arguments_delta, "");
            }
            _ => panic!("Expected ToolCallDelta"),
        }
    }

    #[test]
    fn parse_function_call_arguments_delta() {
        let data = r#"{
            "type": "response.function_call_arguments.delta",
            "item_id": "call_abc123",
            "delta": "{\"command\":"
        }"#;
        let events = parse_sse_data(data).unwrap();
        assert_eq!(events.len(), 1);
        match &events[0] {
            ProviderEvent::ToolCallDelta {
                call_id,
                arguments_delta,
                ..
            } => {
                assert_eq!(call_id, "call_abc123");
                assert_eq!(arguments_delta, "{\"command\":");
            }
            _ => panic!("Expected ToolCallDelta"),
        }
    }

    #[test]
    fn parse_function_call_arguments_done() {
        let data = r#"{
            "type": "response.function_call_arguments.done",
            "item_id": "call_abc123",
            "name": "shell",
            "arguments": "{\"command\":\"ls -la\"}"
        }"#;
        let events = parse_sse_data(data).unwrap();
        assert_eq!(events.len(), 1);
        match &events[0] {
            ProviderEvent::ToolCallCompleted {
                call_id,
                name,
                arguments,
            } => {
                assert_eq!(call_id, "call_abc123");
                assert_eq!(name, "shell");
                assert_eq!(arguments, "{\"command\":\"ls -la\"}");
            }
            _ => panic!("Expected ToolCallCompleted"),
        }
    }

    #[test]
    fn parse_tool_call_partial_arguments_across_deltas() {
        // Simulate a tool call being streamed across multiple SSE events
        // Using simple arguments to avoid JSON escaping complexity
        let event1 = r#"{"type":"response.function_call_arguments.delta","item_id":"call_1","delta":"echo "}"#;
        let event2 = r#"{"type":"response.function_call_arguments.delta","item_id":"call_1","delta":"hello"}"#;
        let event3 = r#"{"type":"response.function_call_arguments.done","item_id":"call_1","name":"shell","arguments":"echo hello"}"#;

        let events1 = parse_sse_data(event1).unwrap();
        let events2 = parse_sse_data(event2).unwrap();
        let events3 = parse_sse_data(event3).unwrap();

        // Accumulate arguments
        let mut full_args = String::new();
        for event in events1.iter().chain(events2.iter()) {
            if let ProviderEvent::ToolCallDelta {
                arguments_delta, ..
            } = event
            {
                full_args.push_str(arguments_delta);
            }
        }
        assert_eq!(full_args, "echo hello");

        // Verify completion
        match &events3[0] {
            ProviderEvent::ToolCallCompleted { arguments, .. } => {
                assert_eq!(arguments, &full_args);
            }
            _ => panic!("Expected ToolCallCompleted"),
        }
    }

    #[test]
    fn parse_non_function_output_item_added() {
        // A non-function_call item should be ignored (no events)
        let data = r#"{
            "type": "response.output_item.added",
            "output_index": 0,
            "item": {
                "type": "message",
                "role": "assistant"
            }
        }"#;
        let events = parse_sse_data(data).unwrap();
        // Non-function items are silently ignored
        assert!(
            events.is_empty(),
            "Expected no events for non-function item, got {:?}",
            events
        );
    }
}

// MARK: - ModelProvider 统一接口实现

#[async_trait]
impl ModelProvider for OpenAIResponsesProvider {
    fn vendor_name(&self) -> &'static str {
        "openai-compatible"
    }

    async fn stream<'a>(
        &'a self,
        messages: &'a [ChatMessage],
        tools: Option<&'a [ToolDefinition]>,
    ) -> Result<Pin<Box<dyn Stream<Item = Result<ProviderEvent>> + Send + 'a>>> {
        let stream = self
            .stream_with_options(StreamOptions { messages, tools })
            .await?;
        Ok(Box::pin(stream))
    }
}
