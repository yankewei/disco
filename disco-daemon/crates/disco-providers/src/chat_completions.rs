//! Chat Completions API provider adapter.
//!
//! Supports the standard OpenAI-compatible `/v1/chat/completions` endpoint
//! with streaming SSE. Handles Kimi-specific `reasoning_content` field.
//! Supports function calling via tool definitions.

use anyhow::{Context, Result};
use eventsource_stream::Eventsource;
use futures_core::Stream;
use reqwest::Client;
use serde::Deserialize;
use tokio_stream::StreamExt;
use tracing::{debug, warn};

use disco_protocol::types::TokenUsage;

use crate::openai_responses::{ChatMessage, ProviderEvent, StreamOptions};

/// Chat Completions API streaming provider.
pub struct ChatCompletionsProvider {
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    /// If true, use Kimi dialect (thinking parameter instead of reasoning_effort).
    pub kimi_dialect: bool,
    http_client: Client,
}

impl ChatCompletionsProvider {
    /// Create a new provider instance.
    pub fn new(base_url: String, api_key: String, model: String) -> Self {
        Self {
            base_url,
            api_key,
            model,
            kimi_dialect: false,
            http_client: Client::new(),
        }
    }

    /// Create with Kimi dialect enabled.
    pub fn new_kimi(base_url: String, api_key: String, model: String) -> Self {
        Self {
            base_url,
            api_key,
            model,
            kimi_dialect: true,
            http_client: Client::new(),
        }
    }

    /// Stream a chat completion.
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
        let url = format!("{}/chat/completions", self.base_url.trim_end_matches('/'));

        // Build messages array
        let msgs: Vec<serde_json::Value> = options
            .messages
            .iter()
            .map(|m| {
                let mut msg = serde_json::json!({
                    "role": m.role,
                    "content": m.text,
                });
                // Include reasoning_content for assistant messages if present (Kimi)
                if m.role == "assistant" {
                    if let Some(ref reasoning) = m.reasoning_content {
                        if !reasoning.is_empty() {
                            msg.as_object_mut().unwrap().insert(
                                "reasoning_content".to_string(),
                                serde_json::Value::String(reasoning.clone()),
                            );
                        }
                    }
                }
                msg
            })
            .collect();

        let mut body = serde_json::json!({
            "model": self.model,
            "stream": true,
            "messages": msgs,
            "stream_options": {"include_usage": true},
        });

        // Add thinking/reasoning parameter based on dialect
        if self.kimi_dialect {
            body.as_object_mut().unwrap().insert(
                "thinking".to_string(),
                serde_json::json!({"type": "enabled", "effort": "high"}),
            );
        }

        // Add tools if provided
        if let Some(tools) = options.tools {
            if !tools.is_empty() {
                let tools_json: Vec<serde_json::Value> = tools
                    .iter()
                    .map(|t| {
                        serde_json::json!({
                            "type": "function",
                            "function": {
                                "name": t.name,
                                "description": t.description,
                                "parameters": t.input_schema,
                            }
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
            .context("Failed to send request to Chat Completions API")?;

        if !response.status().is_success() {
            let status = response.status();
            let body_text = response
                .text()
                .await
                .unwrap_or_else(|_| "<failed to read body>".to_string());
            anyhow::bail!("Chat Completions API error {status}: {body_text}");
        }

        let byte_stream = response.bytes_stream();
        let event_stream = byte_stream.eventsource();

        let stream = async_stream::try_stream! {
            let mut event_stream = event_stream;
            while let Some(event) = event_stream.next().await {
                let event = event.map_err(|e| anyhow::anyhow!("SSE stream error: {e}"))?;

                if event.data.is_empty() {
                    continue;
                }

                if event.data == "[DONE]" {
                    yield ProviderEvent::Completed;
                    break;
                }

                match parse_chat_completion_chunk(&event.data) {
                    Ok(events) => {
                        for evt in events {
                            yield evt;
                        }
                    }
                    Err(e) => {
                        warn!("Failed to parse chat completion chunk: {e}");
                    }
                }
            }
        };

        Ok(stream)
    }
}

/// Parse a single SSE chunk from the Chat Completions stream.
/// Returns a vec of events because a single chunk may contain both usage and delta.
pub fn parse_chat_completion_chunk(data: &str) -> Result<Vec<ProviderEvent>> {
    let json: serde_json::Value =
        serde_json::from_str(data).context("Failed to parse chunk JSON")?;

    let mut events = Vec::new();

    // Check for error in response
    if let Some(error) = json.get("error") {
        let msg = error["message"]
            .as_str()
            .unwrap_or("Unknown error")
            .to_string();
        events.push(ProviderEvent::Failed(msg));
        return Ok(events);
    }

    // Extract usage if present (typically in the last chunk with stream_options.include_usage)
    if let Some(usage_val) = json.get("usage") {
        if let Some(usage) = parse_chat_usage(usage_val) {
            events.push(ProviderEvent::Usage(usage));
        }
    }

    // Extract delta from choices[0]
    if let Some(choice) = json["choices"].as_array().and_then(|arr| arr.first()) {
        let delta = &choice["delta"];

        // Check for reasoning_content (Kimi-specific) first
        if let Some(reasoning) = delta.get("reasoning_content").and_then(|v| v.as_str()) {
            if !reasoning.is_empty() {
                events.push(ProviderEvent::ReasoningDelta(reasoning.to_string()));
            }
        }
        // Also check "reasoning" field (alternative Kimi field name)
        if let Some(reasoning) = delta.get("reasoning").and_then(|v| v.as_str()) {
            if !reasoning.is_empty() {
                events.push(ProviderEvent::ReasoningDelta(reasoning.to_string()));
            }
        }

        // Text content
        if let Some(content) = delta.get("content").and_then(|v| v.as_str()) {
            if !content.is_empty() {
                events.push(ProviderEvent::TextDelta(content.to_string()));
            }
        }

        // Tool calls
        if let Some(tool_calls) = delta.get("tool_calls").and_then(|v| v.as_array()) {
            for tc in tool_calls {
                let index = tc["index"].as_u64().unwrap_or(0);
                let call_id = tc["id"].as_str().unwrap_or("").to_string();
                let name = tc["function"]["name"].as_str().unwrap_or("").to_string();
                let arguments = tc["function"]["arguments"]
                    .as_str()
                    .unwrap_or("")
                    .to_string();

                // Emit a tool call delta for each tool call in the delta array
                events.push(ProviderEvent::ToolCallDelta {
                    call_id,
                    name,
                    arguments_delta: arguments,
                });

                // Track index for debugging (not emitted as event)
                let _ = index;
            }
        }

        // Check finish_reason
        if let Some(finish_reason) = choice.get("finish_reason").and_then(|v| v.as_str()) {
            match finish_reason {
                "stop" => {
                    events.push(ProviderEvent::Completed);
                }
                "tool_calls" => {
                    // Tool calls are complete - the accumulated arguments from
                    // ToolCallDelta events form the full call. We emit Completed
                    // to signal the end of this turn.
                    events.push(ProviderEvent::Completed);
                }
                _ => {}
            }
        }
    }

    Ok(events)
}

/// Parse usage data from Chat Completions API format.
fn parse_chat_usage(usage: &serde_json::Value) -> Option<TokenUsage> {
    let input = usage.get("prompt_tokens")?.as_i64()?;
    let output = usage.get("completion_tokens")?.as_i64()?;
    let total = usage
        .get("total_tokens")
        .and_then(|v| v.as_i64())
        .unwrap_or(input + output);

    let cached_input = usage
        .get("prompt_tokens_details")
        .and_then(|d| d.get("cached_tokens"))
        .and_then(|v| v.as_i64())
        .or_else(|| usage.get("cached_tokens").and_then(|v| v.as_i64()));

    let reasoning_output = usage
        .get("completion_tokens_details")
        .and_then(|d| d.get("reasoning_tokens"))
        .and_then(|v| v.as_i64())
        .or_else(|| usage.get("reasoning_tokens").and_then(|v| v.as_i64()));

    Some(TokenUsage {
        input,
        output,
        total,
        cached_input,
        reasoning_output,
    })
}

/// Fetch model catalog from the Chat Completions API.
pub async fn fetch_model_catalog(
    base_url: &str,
    api_key: &str,
) -> Result<Vec<disco_protocol::types::ModelCatalogEntry>> {
    let url = format!("{}/models", base_url.trim_end_matches('/'));
    let client = Client::new();

    let response = client
        .get(&url)
        .bearer_auth(api_key)
        .header("accept", "application/json")
        .send()
        .await
        .context("Failed to fetch model catalog")?;

    if !response.status().is_success() {
        let status = response.status();
        anyhow::bail!("Model catalog error {status}");
    }

    #[derive(Deserialize)]
    struct ModelList {
        data: Vec<ModelEntry>,
    }

    #[derive(Deserialize)]
    struct ModelEntry {
        id: String,
        context_length: Option<i64>,
    }

    let list: ModelList = response
        .json()
        .await
        .context("Failed to parse model list")?;

    let mut entries: Vec<_> = list
        .data
        .into_iter()
        .map(|m| disco_protocol::types::ModelCatalogEntry {
            id: m.id,
            display_name: None,
            context_window: m.context_length.filter(|&c| c > 0),
            supported_reasoning_efforts: None,
            default_reasoning_effort: None,
        })
        .collect();

    entries.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_text_delta_chunk() {
        let data = r#"{"id":"chatcmpl-123","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        assert_eq!(events.len(), 1);
        match &events[0] {
            ProviderEvent::TextDelta(d) => assert_eq!(d, "Hello"),
            _ => panic!("Expected TextDelta"),
        }
    }

    #[test]
    fn parse_reasoning_content_chunk() {
        let data = r#"{"id":"chatcmpl-123","choices":[{"index":0,"delta":{"reasoning_content":"Let me think..."},"finish_reason":null}]}"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        assert_eq!(events.len(), 1);
        match &events[0] {
            ProviderEvent::ReasoningDelta(d) => assert_eq!(d, "Let me think..."),
            _ => panic!("Expected ReasoningDelta"),
        }
    }

    #[test]
    fn parse_reasoning_field_chunk() {
        // Alternative Kimi field name
        let data = r#"{"id":"chatcmpl-123","choices":[{"index":0,"delta":{"reasoning":"Thinking..."},"finish_reason":null}]}"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        assert_eq!(events.len(), 1);
        match &events[0] {
            ProviderEvent::ReasoningDelta(d) => assert_eq!(d, "Thinking..."),
            _ => panic!("Expected ReasoningDelta"),
        }
    }

    #[test]
    fn parse_finish_reason_stop() {
        let data =
            r#"{"id":"chatcmpl-123","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        assert!(events.iter().any(|e| matches!(e, ProviderEvent::Completed)));
    }

    #[test]
    fn parse_usage_chunk() {
        let data = r#"{"id":"chatcmpl-123","choices":[],"usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150,"prompt_tokens_details":{"cached_tokens":30},"completion_tokens_details":{"reasoning_tokens":20}}}"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        assert_eq!(events.len(), 1);
        match &events[0] {
            ProviderEvent::Usage(u) => {
                assert_eq!(u.input, 100);
                assert_eq!(u.output, 50);
                assert_eq!(u.total, 150);
                assert_eq!(u.cached_input, Some(30));
                assert_eq!(u.reasoning_output, Some(20));
            }
            _ => panic!("Expected Usage"),
        }
    }

    #[test]
    fn parse_combined_reasoning_and_text() {
        // A chunk with both reasoning_content and content
        let data = r#"{"id":"chatcmpl-123","choices":[{"index":0,"delta":{"reasoning_content":"hmm","content":"answer"},"finish_reason":null}]}"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        assert_eq!(events.len(), 2);
        assert!(matches!(&events[0], ProviderEvent::ReasoningDelta(d) if d == "hmm"));
        assert!(matches!(&events[1], ProviderEvent::TextDelta(d) if d == "answer"));
    }

    #[test]
    fn parse_error_chunk() {
        let data = r#"{"error":{"message":"Rate limit exceeded","type":"rate_limit","code":"rate_limit_exceeded"}}"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        assert_eq!(events.len(), 1);
        match &events[0] {
            ProviderEvent::Failed(msg) => assert_eq!(msg, "Rate limit exceeded"),
            _ => panic!("Expected Failed"),
        }
    }

    #[test]
    fn parse_usage_with_cached_tokens_top_level() {
        let data = r#"{"usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150,"cached_tokens":25,"reasoning_tokens":10}}"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        match &events[0] {
            ProviderEvent::Usage(u) => {
                assert_eq!(u.cached_input, Some(25));
                assert_eq!(u.reasoning_output, Some(10));
            }
            _ => panic!("Expected Usage"),
        }
    }

    #[test]
    fn parse_empty_delta() {
        // Usage-only trailing chunk with empty choices
        let data = r#"{"id":"chatcmpl-123","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150}}"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        // Should have Usage + Completed
        assert!(events.iter().any(|e| matches!(e, ProviderEvent::Usage(_))));
        assert!(events.iter().any(|e| matches!(e, ProviderEvent::Completed)));
    }

    #[test]
    fn parse_invalid_json() {
        let result = parse_chat_completion_chunk("not json");
        assert!(result.is_err());
    }

    // MARK: - Tool call parsing tests

    #[test]
    fn parse_tool_call_with_id_and_name() {
        let data = r#"{
            "id": "chatcmpl-123",
            "choices": [{
                "index": 0,
                "delta": {
                    "tool_calls": [{
                        "index": 0,
                        "id": "call_abc123",
                        "type": "function",
                        "function": {
                            "name": "shell",
                            "arguments": ""
                        }
                    }]
                },
                "finish_reason": null
            }]
        }"#;
        let events = parse_chat_completion_chunk(data).unwrap();
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
    fn parse_tool_call_arguments_delta() {
        let data = r#"{
            "id": "chatcmpl-123",
            "choices": [{
                "index": 0,
                "delta": {
                    "tool_calls": [{
                        "index": 0,
                        "function": {
                            "arguments": "{\"command\":"
                        }
                    }]
                },
                "finish_reason": null
            }]
        }"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        assert_eq!(events.len(), 1);
        match &events[0] {
            ProviderEvent::ToolCallDelta {
                arguments_delta, ..
            } => {
                assert_eq!(arguments_delta, "{\"command\":");
            }
            _ => panic!("Expected ToolCallDelta"),
        }
    }

    #[test]
    fn parse_tool_call_finish_reason() {
        let data = r#"{
            "id": "chatcmpl-123",
            "choices": [{
                "index": 0,
                "delta": {},
                "finish_reason": "tool_calls"
            }]
        }"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        assert!(events.iter().any(|e| matches!(e, ProviderEvent::Completed)));
    }

    #[test]
    fn parse_tool_call_partial_arguments_across_chunks() {
        // Simulate a tool call being streamed across multiple chunks
        // Using simple string arguments to avoid JSON escaping complexity
        let chunk1 = r#"{"id":"chatcmpl-123","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"shell","arguments":"echo"}}]},"finish_reason":null}]}"#;
        let chunk2 = r#"{"id":"chatcmpl-123","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":" hello"}}]},"finish_reason":null}]}"#;
        let chunk3 = r#"{"id":"chatcmpl-123","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#;

        let events1 = parse_chat_completion_chunk(chunk1).unwrap();
        let events2 = parse_chat_completion_chunk(chunk2).unwrap();
        let events3 = parse_chat_completion_chunk(chunk3).unwrap();

        // Accumulate arguments from deltas
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
        assert!(
            events3
                .iter()
                .any(|e| matches!(e, ProviderEvent::Completed))
        );
    }

    #[test]
    fn parse_multiple_tool_calls() {
        // A chunk with two tool calls in the delta
        let data = r#"{
            "id": "chatcmpl-123",
            "choices": [{
                "index": 0,
                "delta": {
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": "call_1",
                            "function": {"name": "shell", "arguments": ""}
                        },
                        {
                            "index": 1,
                            "id": "call_2",
                            "function": {"name": "read_file", "arguments": ""}
                        }
                    ]
                },
                "finish_reason": null
            }]
        }"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        assert_eq!(events.len(), 2);

        match &events[0] {
            ProviderEvent::ToolCallDelta { call_id, name, .. } => {
                assert_eq!(call_id, "call_1");
                assert_eq!(name, "shell");
            }
            _ => panic!("Expected first ToolCallDelta"),
        }
        match &events[1] {
            ProviderEvent::ToolCallDelta { call_id, name, .. } => {
                assert_eq!(call_id, "call_2");
                assert_eq!(name, "read_file");
            }
            _ => panic!("Expected second ToolCallDelta"),
        }
    }

    #[test]
    fn parse_text_and_tool_call_combined() {
        // A chunk with both text content and tool calls
        let data = r#"{
            "id": "chatcmpl-123",
            "choices": [{
                "index": 0,
                "delta": {
                    "content": "Let me run that for you.",
                    "tool_calls": [{
                        "index": 0,
                        "id": "call_1",
                        "function": {"name": "shell", "arguments": "{}"}
                    }]
                },
                "finish_reason": null
            }]
        }"#;
        let events = parse_chat_completion_chunk(data).unwrap();
        assert_eq!(events.len(), 2);
        assert!(
            matches!(&events[0], ProviderEvent::TextDelta(d) if d == "Let me run that for you.")
        );
        assert!(matches!(&events[1], ProviderEvent::ToolCallDelta { name, .. } if name == "shell"));
    }
}
