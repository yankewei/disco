//! Shell command execution tool.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use tokio::io::AsyncReadExt;
use tokio::process::Child;
use tracing::{debug, warn};
use uuid::Uuid;

use crate::{ToolCall, ToolContext, ToolDefinition, ToolExecutor, ToolResult, truncate_output};

/// Default command timeout in seconds.
const DEFAULT_TIMEOUT_SECS: u64 = 30;
/// Maximum allowed timeout in seconds.
const MAX_TIMEOUT_SECS: u64 = 120;

pub struct ShellExecutor {
    active_processes: Mutex<HashMap<Uuid, Vec<Child>>>,
}

impl ShellExecutor {
    pub fn new() -> Self {
        Self {
            active_processes: Mutex::new(HashMap::new()),
        }
    }
}

impl Default for ShellExecutor {
    fn default() -> Self {
        Self::new()
    }
}

fn tool_definition() -> ToolDefinition {
    ToolDefinition {
        name: "shell".to_string(),
        description: "Execute a shell command in the workspace directory. Use for listing files, running scripts, checking git status, etc.".to_string(),
        input_schema: serde_json::json!({
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The shell command to execute"
                },
                "timeout": {
                    "type": "integer",
                    "description": "Timeout in seconds (default 30)"
                }
            },
            "required": ["command"]
        }),
    }
}

#[async_trait::async_trait]
impl ToolExecutor for ShellExecutor {
    fn definitions(&self) -> Vec<ToolDefinition> {
        vec![tool_definition()]
    }

    async fn execute(&self, call: &ToolCall, context: &ToolContext) -> Result<ToolResult, String> {
        // Parse arguments
        let args: serde_json::Value = serde_json::from_str(&call.arguments)
            .map_err(|e| format!("Invalid arguments JSON: {e}"))?;

        let command = args["command"]
            .as_str()
            .ok_or_else(|| "Missing 'command' argument".to_string())?;

        let timeout_secs = args["timeout"]
            .as_u64()
            .unwrap_or(DEFAULT_TIMEOUT_SECS)
            .min(MAX_TIMEOUT_SECS);

        debug!(
            "Shell execute: {} (timeout={}s, run_id={})",
            command, timeout_secs, context.run_id
        );

        // Build the command
        let mut cmd = tokio::process::Command::new("/bin/zsh");
        cmd.arg("-c").arg(command);

        // Set working directory
        if let Some(ref workspace) = context.workspace_path {
            cmd.current_dir(workspace);
        }

        // Capture stdout and stderr separately, combine later
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        // Detach from parent process group so cancellation kills children
        cmd.kill_on_drop(true);

        // Spawn the process
        let child = cmd.spawn().map_err(|e| format!("Failed to spawn command: {e}"))?;

        // Track the child process for cancellation
        {
            let mut processes = self.active_processes.lock().unwrap();
            processes
                .entry(context.run_id)
                .or_default()
                .push(child);
        }

        // Wait for the child with timeout.
        // We need to take the child out of the map to wait on it.
        let child = {
            let mut processes = self.active_processes.lock().unwrap();
            let entry = processes.entry(context.run_id).or_default();
            entry.pop().expect("child was just inserted")
        };

        let result = tokio::time::timeout(
            Duration::from_secs(timeout_secs),
            wait_for_child(child),
        )
        .await;

        match result {
            Ok(Ok(output)) => {
                let output = truncate_output(&output);
                Ok(ToolResult {
                    call_id: call.call_id.clone(),
                    output,
                })
            }
            Ok(Err(e)) => Err(format!("Command error: {e}")),
            Err(_) => {
                // Timeout: kill the process
                warn!(
                    "Command timed out after {}s: {}",
                    timeout_secs, command
                );
                // Kill any remaining processes for this run
                self.cancel(context.run_id).await;
                Err(format!(
                    "Command timed out after {timeout_secs}s: {command}"
                ))
            }
        }
    }

    async fn cancel(&self, run_id: Uuid) {
        let children = {
            let mut processes = self.active_processes.lock().unwrap();
            processes.remove(&run_id)
        };

        if let Some(mut children) = children {
            for child in &mut children {
                let _ = child.kill().await;
            }
            debug!("Cancelled {} processes for run {}", children.len(), run_id);
        }
    }
}

/// Wait for a child process to exit and return combined stdout + stderr.
async fn wait_for_child(mut child: Child) -> Result<String, String> {
    let mut stdout_buf = Vec::new();
    let mut stderr_buf = Vec::new();

    if let Some(mut stdout) = child.stdout.take() {
        let _ = stdout.read_to_end(&mut stdout_buf).await;
    }
    if let Some(mut stderr) = child.stderr.take() {
        let _ = stderr.read_to_end(&mut stderr_buf).await;
    }

    let status = child
        .wait()
        .await
        .map_err(|e| format!("Failed to wait for command: {e}"))?;

    let stdout_str = String::from_utf8_lossy(&stdout_buf);
    let stderr_str = String::from_utf8_lossy(&stderr_buf);

    let mut output = stdout_str.to_string();
    if !stderr_str.is_empty() {
        if !output.is_empty() {
            output.push('\n');
        }
        output.push_str(&stderr_str);
    }

    if !status.success() {
        let code = status.code().unwrap_or(-1);
        if output.is_empty() {
            output = format!("Command exited with code {code}");
        } else {
            output = format!("{output}\n[exit code: {code}]");
        }
    }

    Ok(output)
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn make_context(workspace: Option<&str>) -> ToolContext {
        ToolContext {
            run_id: Uuid::new_v4(),
            workspace_path: workspace.map(String::from),
        }
    }

    #[tokio::test]
    async fn execute_echo_command() {
        let executor = ShellExecutor::new();
        let call = ToolCall {
            call_id: "tc_1".to_string(),
            name: "shell".to_string(),
            arguments: r#"{"command":"echo hello"}"#.to_string(),
        };
        let context = make_context(None);
        let result = executor.execute(&call, &context).await.unwrap();
        assert_eq!(result.call_id, "tc_1");
        assert!(result.output.contains("hello"));
    }

    #[tokio::test]
    async fn execute_with_workspace() {
        let executor = ShellExecutor::new();
        let call = ToolCall {
            call_id: "tc_2".to_string(),
            name: "shell".to_string(),
            arguments: r#"{"command":"pwd"}"#.to_string(),
        };
        let tmp = std::env::temp_dir();
        let context = make_context(Some(tmp.to_str().unwrap()));
        let result = executor.execute(&call, &context).await.unwrap();
        // pwd should return the workspace path (or its canonical form)
        assert!(!result.output.is_empty());
    }

    #[tokio::test]
    async fn execute_timeout() {
        let executor = ShellExecutor::new();
        let call = ToolCall {
            call_id: "tc_3".to_string(),
            name: "shell".to_string(),
            arguments: r#"{"command":"sleep 60","timeout":1}"#.to_string(),
        };
        let context = make_context(None);
        let result = executor.execute(&call, &context).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("timed out"));
    }

    #[tokio::test]
    async fn execute_command_failure() {
        let executor = ShellExecutor::new();
        let call = ToolCall {
            call_id: "tc_4".to_string(),
            name: "shell".to_string(),
            arguments: r#"{"command":"exit 42"}"#.to_string(),
        };
        let context = make_context(None);
        let result = executor.execute(&call, &context).await.unwrap();
        // Should still return output (with exit code note)
        assert!(result.output.contains("42"));
    }

    #[tokio::test]
    async fn execute_output_truncation() {
        let executor = ShellExecutor::new();
        // Generate > 100KB output
        let call = ToolCall {
            call_id: "tc_5".to_string(),
            name: "shell".to_string(),
            arguments: r#"{"command":"python3 -c \"print('x' * 200000)\""}"#.to_string(),
        };
        let context = make_context(None);
        let result = executor.execute(&call, &context).await.unwrap();
        assert!(result.output.len() <= crate::MAX_OUTPUT_SIZE + 200); // some margin for truncation note
    }

    #[tokio::test]
    async fn cancel_running_process() {
        let executor = ShellExecutor::new();
        let run_id = Uuid::new_v4();
        let call = ToolCall {
            call_id: "tc_6".to_string(),
            name: "shell".to_string(),
            arguments: r#"{"command":"sleep 60","timeout":30}"#.to_string(),
        };
        let context = ToolContext {
            run_id,
            workspace_path: None,
        };

        // Start execution in a background task
        let exec = std::sync::Arc::new(executor);
        let exec2 = exec.clone();
        let call2 = call.clone();
        let handle = tokio::spawn(async move {
            exec2.execute(&call2, &context).await
        });

        // Give it a moment to start
        tokio::time::sleep(Duration::from_millis(100)).await;

        // Cancel
        exec.cancel(run_id).await;

        // The execution should complete (with error due to cancellation)
        let result = handle.await.unwrap();
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn invalid_arguments_json() {
        let executor = ShellExecutor::new();
        let call = ToolCall {
            call_id: "tc_7".to_string(),
            name: "shell".to_string(),
            arguments: "not json".to_string(),
        };
        let context = make_context(None);
        let result = executor.execute(&call, &context).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Invalid arguments"));
    }

    #[tokio::test]
    async fn missing_command_argument() {
        let executor = ShellExecutor::new();
        let call = ToolCall {
            call_id: "tc_8".to_string(),
            name: "shell".to_string(),
            arguments: r#"{"timeout":5}"#.to_string(),
        };
        let context = make_context(None);
        let result = executor.execute(&call, &context).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("command"));
    }

    #[test]
    fn tool_definition_structure() {
        let def = tool_definition();
        assert_eq!(def.name, "shell");
        assert!(def.input_schema["properties"]["command"].is_object());
        assert!(def.input_schema["required"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v.as_str() == Some("command")));
    }
}
