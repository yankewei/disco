//! Shell command execution tool.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use tokio::io::AsyncReadExt;
use tokio::process::Child;
use tokio::sync::oneshot;
use tracing::{debug, warn};
use uuid::Uuid;

use crate::{ToolCall, ToolContext, ToolDefinition, ToolExecutor, ToolResult, truncate_output};

/// Default command timeout in seconds.
const DEFAULT_TIMEOUT_SECS: u64 = 30;
/// Maximum allowed timeout in seconds.
const MAX_TIMEOUT_SECS: u64 = 120;

struct ProcessControl {
    control_id: Uuid,
    cancel_signal: oneshot::Sender<()>,
}

pub struct ShellExecutor {
    active_processes: Mutex<HashMap<Uuid, Vec<ProcessControl>>>,
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

        // Build the command。用补全后的 PATH（含用户 shell 配置目录），
        // 使 GUI 启动的 daemon 也能在 shell 中找到用户工具链（bun 等）。
        let mut cmd = crate::command_env::command("/bin/zsh");
        cmd.arg("-c").arg(command);

        // Set working directory
        if let Some(ref workspace) = context.workspace_path {
            cmd.current_dir(workspace);
        }

        // Capture stdout and stderr separately, combine later
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        // Put the command in its own process group so cancellation also kills
        // descendants started by the shell.
        #[cfg(unix)]
        cmd.process_group(0);
        cmd.kill_on_drop(true);

        // Spawn the process
        let mut child = cmd
            .spawn()
            .map_err(|e| format!("Failed to spawn command: {e}"))?;

        let control_id = Uuid::new_v4();
        let (cancel_tx, cancel_rx) = oneshot::channel();

        // Track a cancellation signal while the execution task owns the child.
        {
            let mut processes = self.active_processes.lock().unwrap();
            processes
                .entry(context.run_id)
                .or_default()
                .push(ProcessControl {
                    control_id,
                    cancel_signal: cancel_tx,
                });
        }

        let outcome = tokio::select! {
            result = wait_for_child(&mut child) => ChildOutcome::Completed(result),
            _ = cancel_rx => ChildOutcome::Cancelled,
            _ = tokio::time::sleep(Duration::from_secs(timeout_secs)) => ChildOutcome::TimedOut,
        };

        let result = match outcome {
            ChildOutcome::Completed(result) => result,
            ChildOutcome::Cancelled => {
                terminate_process_tree(&mut child).await;
                let _ = child.wait().await;
                Err("Command cancelled".to_string())
            }
            ChildOutcome::TimedOut => {
                warn!("Command timed out after {}s: {}", timeout_secs, command);
                // Preserve the previous behavior of cancelling any other
                // shell commands associated with the same run.
                self.cancel(context.run_id).await;
                terminate_process_tree(&mut child).await;
                let _ = child.wait().await;
                Err(format!(
                    "Command timed out after {timeout_secs}s: {command}"
                ))
            }
        };

        self.remove_process(context.run_id, control_id);

        match result {
            Ok(output) => {
                let output = truncate_output(&output);
                Ok(ToolResult {
                    call_id: call.call_id.clone(),
                    output,
                })
            }
            Err(e) => Err(format!("Command error: {e}")),
        }
    }

    async fn cancel(&self, run_id: Uuid) {
        let process_controls = {
            let mut processes = self.active_processes.lock().unwrap();
            processes.remove(&run_id)
        };

        if let Some(process_controls) = process_controls {
            let process_count = process_controls.len();
            for process_control in process_controls {
                let _ = process_control.cancel_signal.send(());
            }
            debug!(
                "Cancellation requested for {} processes in run {}",
                process_count, run_id
            );
        }
    }
}

impl ShellExecutor {
    fn remove_process(&self, run_id: Uuid, control_id: Uuid) {
        let mut processes = self.active_processes.lock().unwrap();
        let Some(run_processes) = processes.get_mut(&run_id) else {
            return;
        };

        run_processes.retain(|process| process.control_id != control_id);
        if run_processes.is_empty() {
            processes.remove(&run_id);
        }
    }
}

enum ChildOutcome {
    Completed(Result<String, String>),
    Cancelled,
    TimedOut,
}

async fn terminate_process_tree(child: &mut Child) {
    #[cfg(unix)]
    if let Some(pid) = child.id() {
        let group_killed = unsafe { libc::killpg(pid as libc::pid_t, libc::SIGKILL) } == 0;
        if group_killed {
            return;
        }
    }

    let _ = child.kill().await;
}

/// Wait for a child process to exit and return combined stdout + stderr.
async fn wait_for_child(child: &mut Child) -> Result<String, String> {
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
    async fn shell_child_inherits_enriched_path() {
        let Ok(home) = std::env::var("HOME") else {
            return; // 无 HOME 的环境（罕见）跳过断言
        };
        let executor = ShellExecutor::new();
        let call = ToolCall {
            call_id: "tc_path".to_string(),
            name: "shell".to_string(),
            arguments: r#"{"command":"printf '%s' \"$PATH\""}"#.to_string(),
        };
        let context = make_context(None);
        let result = executor.execute(&call, &context).await.unwrap();
        // command_env 补全的 PATH 应包含 ~/.local/bin 等用户目录
        assert!(
            result.output.contains(&format!("{home}/.local/bin")),
            "shell 子进程应继承补全后的 PATH（含 ~/.local/bin），实际: {}",
            result.output
        );
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
            // Keep a descendant alive and holding the output pipes so this
            // test also verifies that cancellation reaches the process group.
            arguments: r#"{"command":"sleep 60 & wait","timeout":30}"#.to_string(),
        };
        let context = ToolContext {
            run_id,
            workspace_path: None,
        };

        // Start execution in a background task
        let exec = std::sync::Arc::new(executor);
        let exec2 = exec.clone();
        let call2 = call.clone();
        let handle = tokio::spawn(async move { exec2.execute(&call2, &context).await });

        // Give it a moment to start
        tokio::time::sleep(Duration::from_millis(100)).await;

        // Cancel
        exec.cancel(run_id).await;

        // The execution should complete (with error due to cancellation)
        let result = tokio::time::timeout(Duration::from_secs(2), handle)
            .await
            .expect("cancelling a running process should not wait for the command timeout")
            .unwrap();
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
        assert!(
            def.input_schema["required"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v.as_str() == Some("command"))
        );
    }
}
