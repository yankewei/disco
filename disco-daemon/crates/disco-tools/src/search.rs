//! Code search tool using ripgrep (with grep fallback).

use std::path::Path;

use tokio::io::AsyncReadExt;
use tracing::debug;

use crate::{ToolCall, ToolContext, ToolDefinition, ToolExecutor, ToolResult, truncate_output};

/// Executor providing the `search` tool backed by ripgrep.
pub struct SearchExecutor;

impl SearchExecutor {
    pub fn new() -> Self {
        Self
    }
}

impl Default for SearchExecutor {
    fn default() -> Self {
        Self::new()
    }
}

fn tool_definition() -> ToolDefinition {
    ToolDefinition {
        name: "search".to_string(),
        description: "Search for a pattern in files using ripgrep. Returns matching lines with file paths and line numbers.".to_string(),
        input_schema: serde_json::json!({
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Regex pattern to search for"
                },
                "path": {
                    "type": "string",
                    "description": "Relative path to search in (default: workspace root)"
                },
                "file_pattern": {
                    "type": "string",
                    "description": "Glob pattern to filter files (e.g. '*.rs')"
                }
            },
            "required": ["pattern"]
        }),
    }
}

#[async_trait::async_trait]
impl ToolExecutor for SearchExecutor {
    fn definitions(&self) -> Vec<ToolDefinition> {
        vec![tool_definition()]
    }

    async fn execute(&self, call: &ToolCall, context: &ToolContext) -> Result<ToolResult, String> {
        let args: serde_json::Value = serde_json::from_str(&call.arguments)
            .map_err(|e| format!("Invalid arguments JSON: {e}"))?;

        let pattern = args["pattern"]
            .as_str()
            .ok_or_else(|| "Missing 'pattern' argument".to_string())?;

        let rel_path = args["path"].as_str();
        let file_pattern = args["file_pattern"].as_str();

        let workspace = context
            .workspace_path
            .as_ref()
            .ok_or_else(|| "No workspace path set".to_string())?;

        let search_path = if let Some(rel) = rel_path {
            let full = Path::new(workspace).join(rel);
            if !full.exists() {
                return Err(format!("Search path does not exist: {rel}"));
            }
            full
        } else {
            Path::new(workspace).to_path_buf()
        };

        debug!(
            "search: pattern='{}' path={} file_pattern={:?}",
            pattern,
            search_path.display(),
            file_pattern
        );

        // Try ripgrep first, fall back to grep
        match run_rg(pattern, &search_path, file_pattern).await {
            Ok(output) => {
                let output = truncate_output(&output);
                Ok(ToolResult {
                    call_id: call.call_id.clone(),
                    output,
                })
            }
            Err(rg_err) => {
                // Check if rg is not found -> fall back to grep
                if rg_err.contains("not found") || rg_err.contains("No such file") {
                    debug!("ripgrep not found, falling back to grep");
                    match run_grep(pattern, &search_path, file_pattern).await {
                        Ok(output) => {
                            let output = truncate_output(&output);
                            Ok(ToolResult {
                                call_id: call.call_id.clone(),
                                output,
                            })
                        }
                        Err(grep_err) => Err(format!("Search failed: {grep_err}")),
                    }
                } else {
                    Err(format!("Search failed: {rg_err}"))
                }
            }
        }
    }

    async fn cancel(&self, _run_id: uuid::Uuid) {
        // Search processes are short-lived; nothing to cancel.
    }
}

/// Run ripgrep search.
async fn run_rg(
    pattern: &str,
    search_path: &Path,
    file_pattern: Option<&str>,
) -> Result<String, String> {
    let mut cmd = crate::command_env::command("rg");
    cmd.arg("--line-number")
        .arg("--no-heading")
        .arg("--color=never")
        .arg(pattern)
        .arg(search_path);

    if let Some(glob) = file_pattern {
        cmd.arg("--glob").arg(glob);
    }

    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("ripgrep not found or failed to start: {e}"))?;

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
        .map_err(|e| format!("Failed to wait for ripgrep: {e}"))?;

    // rg exit code 0 = matches found, 1 = no matches, 2 = error
    let output = String::from_utf8_lossy(&stdout_buf).to_string();

    if status.success() {
        Ok(output)
    } else if status.code() == Some(1) {
        // No matches found
        Ok("No matches found.".to_string())
    } else {
        let stderr = String::from_utf8_lossy(&stderr_buf);
        Err(format!("ripgrep error: {stderr}"))
    }
}

/// Fallback grep search when ripgrep is not available.
async fn run_grep(
    pattern: &str,
    search_path: &Path,
    file_pattern: Option<&str>,
) -> Result<String, String> {
    let mut cmd = crate::command_env::command("grep");
    cmd.arg("-rn")
        .arg("--color=never")
        .arg(pattern)
        .arg(search_path);

    if let Some(glob) = file_pattern {
        cmd.arg("--include").arg(glob);
    }

    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());

    let mut child = cmd.spawn().map_err(|e| format!("grep not found: {e}"))?;

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
        .map_err(|e| format!("Failed to wait for grep: {e}"))?;

    let output = String::from_utf8_lossy(&stdout_buf).to_string();

    if status.success() {
        Ok(output)
    } else if status.code() == Some(1) {
        Ok("No matches found.".to_string())
    } else {
        let stderr = String::from_utf8_lossy(&stderr_buf);
        Err(format!("grep error: {stderr}"))
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::fs;
    use uuid::Uuid;

    /// RAII temp directory that cleans up on drop.
    struct TempDir(std::path::PathBuf);
    impl TempDir {
        fn path(&self) -> &std::path::Path {
            &self.0
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    async fn setup_workspace() -> (TempDir, SearchExecutor) {
        let tmp = std::env::temp_dir().join(format!("disco_search_test_{}", Uuid::new_v4()));
        fs::create_dir_all(&tmp).await.unwrap();

        fs::write(
            tmp.join("hello.rs"),
            "fn main() {\n    println!(\"hello\");\n}\n",
        )
        .await
        .unwrap();
        fs::write(
            tmp.join("world.rs"),
            "fn world() {\n    println!(\"world\");\n}\n",
        )
        .await
        .unwrap();
        fs::write(tmp.join("notes.txt"), "hello world\nsome notes\n")
            .await
            .unwrap();

        fs::create_dir_all(tmp.join("sub")).await.unwrap();
        fs::write(
            tmp.join("sub").join("deep.rs"),
            "fn deep() { /* hello */ }\n",
        )
        .await
        .unwrap();

        (TempDir(tmp), SearchExecutor::new())
    }

    fn make_context(workspace: &str) -> ToolContext {
        ToolContext {
            run_id: Uuid::new_v4(),
            workspace_path: Some(workspace.to_string()),
        }
    }

    #[tokio::test]
    async fn search_pattern_matching() {
        let (tmp, executor) = setup_workspace().await;
        let context = make_context(tmp.path().to_str().unwrap());

        let call = ToolCall {
            call_id: "tc_1".to_string(),
            name: "search".to_string(),
            arguments: serde_json::json!({
                "pattern": "hello"
            })
            .to_string(),
        };
        let result = executor.execute(&call, &context).await.unwrap();
        assert!(result.output.contains("hello"));
        // Should find matches in multiple files
        assert!(result.output.contains("hello.rs") || result.output.contains("notes.txt"));
    }

    #[tokio::test]
    async fn search_with_file_glob() {
        let (tmp, executor) = setup_workspace().await;
        let context = make_context(tmp.path().to_str().unwrap());

        let call = ToolCall {
            call_id: "tc_2".to_string(),
            name: "search".to_string(),
            arguments: serde_json::json!({
                "pattern": "hello",
                "file_pattern": "*.rs"
            })
            .to_string(),
        };
        let result = executor.execute(&call, &context).await.unwrap();
        assert!(result.output.contains("hello"));
        // Should NOT contain matches from .txt files
        assert!(!result.output.contains("notes.txt"));
    }

    #[tokio::test]
    async fn search_no_matches() {
        let (tmp, executor) = setup_workspace().await;
        let context = make_context(tmp.path().to_str().unwrap());

        let call = ToolCall {
            call_id: "tc_3".to_string(),
            name: "search".to_string(),
            arguments: serde_json::json!({
                "pattern": "zzzznotfound"
            })
            .to_string(),
        };
        let result = executor.execute(&call, &context).await.unwrap();
        assert!(result.output.contains("No matches"));
    }

    #[tokio::test]
    async fn search_with_subpath() {
        let (tmp, executor) = setup_workspace().await;
        let context = make_context(tmp.path().to_str().unwrap());

        let call = ToolCall {
            call_id: "tc_4".to_string(),
            name: "search".to_string(),
            arguments: serde_json::json!({
                "pattern": "hello",
                "path": "sub"
            })
            .to_string(),
        };
        let result = executor.execute(&call, &context).await.unwrap();
        assert!(result.output.contains("hello"));
        assert!(result.output.contains("deep.rs"));
    }

    #[tokio::test]
    async fn search_missing_pattern() {
        let (tmp, executor) = setup_workspace().await;
        let context = make_context(tmp.path().to_str().unwrap());

        let call = ToolCall {
            call_id: "tc_5".to_string(),
            name: "search".to_string(),
            arguments: serde_json::json!({}).to_string(),
        };
        let result = executor.execute(&call, &context).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("pattern"));
    }

    #[test]
    fn tool_definition_structure() {
        let def = tool_definition();
        assert_eq!(def.name, "search");
        assert!(def.input_schema["properties"]["pattern"].is_object());
        assert!(
            def.input_schema["required"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v.as_str() == Some("pattern"))
        );
    }
}
