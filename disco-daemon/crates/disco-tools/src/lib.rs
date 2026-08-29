use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub mod command_env;
pub mod file_edit;
pub mod search;
pub mod shell;

// MARK: - Tool types

/// Definition of a tool that can be called by the model.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub input_schema: serde_json::Value,
}

/// A tool call request from the model.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCall {
    pub call_id: String,
    pub name: String,
    /// JSON string of arguments.
    pub arguments: String,
}

/// The result of executing a tool call.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolResult {
    pub call_id: String,
    pub output: String,
}

/// Context for tool execution.
#[derive(Debug, Clone)]
pub struct ToolContext {
    pub run_id: Uuid,
    pub workspace_path: Option<String>,
}

// MARK: - ToolExecutor trait

#[async_trait::async_trait]
pub trait ToolExecutor: Send + Sync {
    /// Return the tool definitions this executor provides.
    fn definitions(&self) -> Vec<ToolDefinition>;

    /// Execute a tool call. The call's `name` is guaranteed to match one of
    /// the definitions returned by `definitions()`.
    async fn execute(&self, call: &ToolCall, context: &ToolContext) -> Result<ToolResult, String>;

    /// Cancel all running processes for the given run.
    async fn cancel(&self, run_id: Uuid);
}

// MARK: - CompositeExecutor

/// Composite executor that routes tool calls to the appropriate sub-executor
/// based on tool name.
pub struct CompositeExecutor {
    tools: Vec<Box<dyn ToolExecutor>>,
    /// Maps tool name -> index in `tools` for fast routing.
    name_index: HashMap<String, usize>,
}

impl CompositeExecutor {
    pub fn new() -> Self {
        Self {
            tools: Vec::new(),
            name_index: HashMap::new(),
        }
    }

    /// Register a tool executor. All definitions from this executor will be
    /// available through the composite.
    pub fn register(&mut self, executor: Box<dyn ToolExecutor>) {
        let idx = self.tools.len();
        for def in executor.definitions() {
            self.name_index.insert(def.name.clone(), idx);
        }
        self.tools.push(executor);
    }

    /// Return all tool definitions from all registered executors.
    pub fn all_definitions(&self) -> Vec<ToolDefinition> {
        self.tools.iter().flat_map(|t| t.definitions()).collect()
    }
}

impl Default for CompositeExecutor {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl ToolExecutor for CompositeExecutor {
    fn definitions(&self) -> Vec<ToolDefinition> {
        self.all_definitions()
    }

    async fn execute(&self, call: &ToolCall, context: &ToolContext) -> Result<ToolResult, String> {
        let idx = self
            .name_index
            .get(&call.name)
            .copied()
            .ok_or_else(|| format!("Unknown tool: {}", call.name))?;
        self.tools[idx].execute(call, context).await
    }

    async fn cancel(&self, run_id: Uuid) {
        for tool in &self.tools {
            tool.cancel(run_id).await;
        }
    }
}

// MARK: - Helpers

/// Maximum output size (100 KB).
pub const MAX_OUTPUT_SIZE: usize = 100 * 1024;

/// Truncate output to MAX_OUTPUT_SIZE, appending a note if truncated.
pub fn truncate_output(output: &str) -> String {
    if output.len() <= MAX_OUTPUT_SIZE {
        output.to_string()
    } else {
        let mut kept_bytes = MAX_OUTPUT_SIZE;
        while !output.is_char_boundary(kept_bytes) {
            kept_bytes -= 1;
        }
        let truncated_bytes = output.len() - kept_bytes;
        format!(
            "{}\n\n[... {} bytes truncated]",
            &output[..kept_bytes],
            truncated_bytes
        )
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_definition_serialization() {
        let def = ToolDefinition {
            name: "shell".to_string(),
            description: "Execute a shell command".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "command": {"type": "string"}
                },
                "required": ["command"]
            }),
        };
        let json = serde_json::to_string(&def).unwrap();
        assert!(json.contains("\"name\":\"shell\""));
        let decoded: ToolDefinition = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.name, "shell");
    }

    #[test]
    fn tool_call_serialization() {
        let call = ToolCall {
            call_id: "tc_1".to_string(),
            name: "shell".to_string(),
            arguments: r#"{"command":"ls"}"#.to_string(),
        };
        let json = serde_json::to_string(&call).unwrap();
        let decoded: ToolCall = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.call_id, "tc_1");
        assert_eq!(decoded.name, "shell");
    }

    #[test]
    fn tool_result_serialization() {
        let result = ToolResult {
            call_id: "tc_1".to_string(),
            output: "hello\n".to_string(),
        };
        let json = serde_json::to_string(&result).unwrap();
        let decoded: ToolResult = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.call_id, "tc_1");
        assert_eq!(decoded.output, "hello\n");
    }

    #[test]
    fn truncate_short_output() {
        let output = "short output";
        assert_eq!(truncate_output(output), output);
    }

    #[test]
    fn truncate_long_output() {
        let output = "a".repeat(MAX_OUTPUT_SIZE + 1000);
        let truncated = truncate_output(&output);
        assert!(truncated.len() < output.len());
        assert!(truncated.contains("bytes truncated"));
    }

    #[test]
    fn truncate_multibyte_output_at_character_boundary() {
        let output = format!("{}中rest", "x".repeat(MAX_OUTPUT_SIZE - 1));
        let truncated = truncate_output(&output);
        let (kept, note) = truncated.split_once("\n\n[...").unwrap();

        assert_eq!(kept.len(), MAX_OUTPUT_SIZE - 1);
        assert!(kept.is_char_boundary(kept.len()));
        assert!(note.contains("bytes truncated"));
    }

    #[test]
    fn composite_executor_default() {
        let composite = CompositeExecutor::default();
        assert!(composite.definitions().is_empty());
    }

    #[tokio::test]
    async fn composite_executor_unknown_tool() {
        let composite = CompositeExecutor::new();
        let call = ToolCall {
            call_id: "tc_1".to_string(),
            name: "nonexistent".to_string(),
            arguments: "{}".to_string(),
        };
        let context = ToolContext {
            run_id: Uuid::new_v4(),
            workspace_path: None,
        };
        let result = composite.execute(&call, &context).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Unknown tool"));
    }
}
