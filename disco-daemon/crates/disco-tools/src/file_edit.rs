//! File read/write tool executor.

use std::path::{Path, PathBuf};

use tokio::fs;
use tracing::debug;

use crate::{ToolCall, ToolContext, ToolDefinition, ToolExecutor, ToolResult, truncate_output};

/// Executor providing `read_file` and `write_file` tools.
pub struct FileEditExecutor;

impl FileEditExecutor {
    pub fn new() -> Self {
        Self
    }
}

impl Default for FileEditExecutor {
    fn default() -> Self {
        Self::new()
    }
}

fn read_file_definition() -> ToolDefinition {
    ToolDefinition {
        name: "read_file".to_string(),
        description: "Read the contents of a file.".to_string(),
        input_schema: serde_json::json!({
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Relative path within workspace"
                }
            },
            "required": ["path"]
        }),
    }
}

fn write_file_definition() -> ToolDefinition {
    ToolDefinition {
        name: "write_file".to_string(),
        description: "Write content to a file. Creates parent directories if needed.".to_string(),
        input_schema: serde_json::json!({
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Relative path within workspace"
                },
                "content": {
                    "type": "string",
                    "description": "The complete file content to write"
                }
            },
            "required": ["path", "content"]
        }),
    }
}

#[async_trait::async_trait]
impl ToolExecutor for FileEditExecutor {
    fn definitions(&self) -> Vec<ToolDefinition> {
        vec![read_file_definition(), write_file_definition()]
    }

    async fn execute(&self, call: &ToolCall, context: &ToolContext) -> Result<ToolResult, String> {
        match call.name.as_str() {
            "read_file" => self.read_file(call, context).await,
            "write_file" => self.write_file(call, context).await,
            other => Err(format!("FileEditExecutor: unknown tool '{other}'")),
        }
    }

    async fn cancel(&self, _run_id: uuid::Uuid) {
        // Nothing to cancel for file operations.
    }
}

impl FileEditExecutor {
    async fn read_file(
        &self,
        call: &ToolCall,
        context: &ToolContext,
    ) -> Result<ToolResult, String> {
        let args: serde_json::Value = serde_json::from_str(&call.arguments)
            .map_err(|e| format!("Invalid arguments JSON: {e}"))?;

        let rel_path = args["path"]
            .as_str()
            .ok_or_else(|| "Missing 'path' argument".to_string())?;

        let workspace = context
            .workspace_path
            .as_ref()
            .ok_or_else(|| "No workspace path set".to_string())?;

        let resolved = resolve_safe_path(workspace, rel_path)?;
        debug!("read_file: {} -> {}", rel_path, resolved.display());

        let content = fs::read_to_string(&resolved)
            .await
            .map_err(|e| format!("Failed to read file '{}': {e}", resolved.display()))?;

        let content = truncate_output(&content);

        Ok(ToolResult {
            call_id: call.call_id.clone(),
            output: content,
        })
    }

    async fn write_file(
        &self,
        call: &ToolCall,
        context: &ToolContext,
    ) -> Result<ToolResult, String> {
        let args: serde_json::Value = serde_json::from_str(&call.arguments)
            .map_err(|e| format!("Invalid arguments JSON: {e}"))?;

        let rel_path = args["path"]
            .as_str()
            .ok_or_else(|| "Missing 'path' argument".to_string())?;

        let content = args["content"]
            .as_str()
            .ok_or_else(|| "Missing 'content' argument".to_string())?;

        let workspace = context
            .workspace_path
            .as_ref()
            .ok_or_else(|| "No workspace path set".to_string())?;

        let resolved = resolve_safe_path(workspace, rel_path)?;
        debug!(
            "write_file: {} -> {} ({} bytes)",
            rel_path,
            resolved.display(),
            content.len()
        );

        // Create parent directories
        if let Some(parent) = resolved.parent() {
            fs::create_dir_all(parent)
                .await
                .map_err(|e| format!("Failed to create directories: {e}"))?;
        }

        // Atomic write: write to temp file, then rename
        let tmp_path = resolved.with_extension("tmp");
        fs::write(&tmp_path, content).await.map_err(|e| {
            let _ = std::fs::remove_file(&tmp_path);
            format!("Failed to write temp file: {e}")
        })?;

        fs::rename(&tmp_path, &resolved).await.map_err(|e| {
            let _ = std::fs::remove_file(&tmp_path);
            format!("Failed to rename temp file: {e}")
        })?;

        let output = format!("Successfully wrote {} bytes to {}", content.len(), rel_path);

        Ok(ToolResult {
            call_id: call.call_id.clone(),
            output,
        })
    }
}

/// Resolve a relative path against the workspace, ensuring it doesn't escape.
///
/// Security: rejects paths that would resolve outside the workspace directory.
fn resolve_safe_path(workspace: &str, rel_path: &str) -> Result<PathBuf, String> {
    let workspace_path = Path::new(workspace);

    // Canonicalize workspace (resolves symlinks, .., etc.)
    let canonical_workspace = workspace_path
        .canonicalize()
        .map_err(|e| format!("Invalid workspace path '{workspace}': {e}"))?;

    // Join the relative path with workspace
    let joined = if Path::new(rel_path).is_absolute() {
        // If absolute, check it's within workspace
        PathBuf::from(rel_path)
    } else {
        canonical_workspace.join(rel_path)
    };

    // Normalize the path (resolve . and .. components without requiring existence)
    let normalized = normalize_path(&joined);

    // For existing paths, also check via canonicalize to catch symlinks
    if normalized.exists() {
        let canonical = normalized
            .canonicalize()
            .map_err(|e| format!("Cannot resolve path: {e}"))?;
        if !canonical.starts_with(&canonical_workspace) {
            return Err(format!("Path '{}' escapes workspace directory", rel_path));
        }
        return Ok(canonical);
    }

    // For non-existing paths, check the normalized parent
    // (the file itself doesn't exist yet, but the parent should be valid)
    if let Some(parent) = normalized.parent() {
        if parent.exists() {
            let canonical_parent = parent
                .canonicalize()
                .map_err(|e| format!("Cannot resolve parent path: {e}"))?;
            if !canonical_parent.starts_with(&canonical_workspace) {
                return Err(format!("Path '{}' escapes workspace directory", rel_path));
            }
        }
    }

    // Also do a string-based check for obvious traversal
    let joined_str = normalized.to_string_lossy();
    let workspace_str = canonical_workspace.to_string_lossy();
    if !joined_str.starts_with(workspace_str.as_ref()) {
        return Err(format!("Path '{}' escapes workspace directory", rel_path));
    }

    Ok(normalized)
}

/// Normalize a path by resolving `.` and `..` components without requiring
/// the path to exist. Does NOT resolve symlinks.
fn normalize_path(path: &Path) -> PathBuf {
    let mut components = Vec::new();
    for component in path.components() {
        match component {
            std::path::Component::ParentDir => {
                components.pop();
            }
            std::path::Component::CurDir => {
                // Skip .
            }
            other => {
                components.push(other);
            }
        }
    }
    components.iter().collect()
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn make_context(workspace: &str) -> ToolContext {
        ToolContext {
            run_id: Uuid::new_v4(),
            workspace_path: Some(workspace.to_string()),
        }
    }

    #[tokio::test]
    async fn write_and_read_file() {
        let tmp = std::env::temp_dir().join(format!("disco_test_{}", Uuid::new_v4()));
        fs::create_dir_all(&tmp).await.unwrap();
        let workspace = tmp.to_str().unwrap();
        let executor = FileEditExecutor::new();
        let context = make_context(workspace);

        // Write a file
        let write_call = ToolCall {
            call_id: "tc_1".to_string(),
            name: "write_file".to_string(),
            arguments: serde_json::json!({
                "path": "test.txt",
                "content": "Hello, Disco!"
            })
            .to_string(),
        };
        let result = executor.execute(&write_call, &context).await.unwrap();
        assert!(result.output.contains("Successfully wrote"));
        assert!(result.output.contains("test.txt"));

        // Read it back
        let read_call = ToolCall {
            call_id: "tc_2".to_string(),
            name: "read_file".to_string(),
            arguments: serde_json::json!({
                "path": "test.txt"
            })
            .to_string(),
        };
        let result = executor.execute(&read_call, &context).await.unwrap();
        assert_eq!(result.output, "Hello, Disco!");

        // Cleanup
        let _ = fs::remove_dir_all(&tmp).await;
    }

    #[tokio::test]
    async fn write_creates_parent_directories() {
        let tmp = std::env::temp_dir().join(format!("disco_test_{}", Uuid::new_v4()));
        fs::create_dir_all(&tmp).await.unwrap();
        let workspace = tmp.to_str().unwrap();
        let executor = FileEditExecutor::new();
        let context = make_context(workspace);

        let call = ToolCall {
            call_id: "tc_3".to_string(),
            name: "write_file".to_string(),
            arguments: serde_json::json!({
                "path": "sub/dir/file.txt",
                "content": "nested"
            })
            .to_string(),
        };
        let result = executor.execute(&call, &context).await.unwrap();
        assert!(result.output.contains("Successfully wrote"));

        // Read it back
        let read_call = ToolCall {
            call_id: "tc_4".to_string(),
            name: "read_file".to_string(),
            arguments: serde_json::json!({"path": "sub/dir/file.txt"}).to_string(),
        };
        let result = executor.execute(&read_call, &context).await.unwrap();
        assert_eq!(result.output, "nested");

        // Cleanup
        let _ = fs::remove_dir_all(&tmp).await;
    }

    #[tokio::test]
    async fn read_nonexistent_file() {
        let tmp = std::env::temp_dir().join(format!("disco_test_{}", Uuid::new_v4()));
        fs::create_dir_all(&tmp).await.unwrap();
        let workspace = tmp.to_str().unwrap();
        let executor = FileEditExecutor::new();
        let context = make_context(workspace);

        let call = ToolCall {
            call_id: "tc_5".to_string(),
            name: "read_file".to_string(),
            arguments: serde_json::json!({"path": "nonexistent.txt"}).to_string(),
        };
        let result = executor.execute(&call, &context).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Failed to read"));

        // Cleanup
        let _ = fs::remove_dir_all(&tmp).await;
    }

    #[test]
    fn path_traversal_rejected() {
        let tmp = std::env::temp_dir().join(format!("disco_test_{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).unwrap();
        let workspace = tmp.to_str().unwrap();

        let result = resolve_safe_path(workspace, "../../../etc/passwd");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("escapes workspace"));

        // Cleanup
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn path_traversal_with_dots() {
        let tmp = std::env::temp_dir().join(format!("disco_test_{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).unwrap();
        let workspace = tmp.to_str().unwrap();

        // Create a subdirectory
        std::fs::create_dir_all(tmp.join("sub")).unwrap();

        // This should be fine - stays within workspace
        let result = resolve_safe_path(workspace, "sub/../sub/file.txt");
        assert!(result.is_ok());

        // This should fail - escapes workspace
        let result = resolve_safe_path(workspace, "sub/../../etc/passwd");
        assert!(result.is_err());

        // Cleanup
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn normalize_path_components() {
        let path = Path::new("/a/b/../c/./d");
        let normalized = normalize_path(path);
        assert_eq!(normalized, PathBuf::from("/a/c/d"));
    }

    #[test]
    fn definitions_include_both_tools() {
        let executor = FileEditExecutor::new();
        let defs = executor.definitions();
        assert_eq!(defs.len(), 2);
        assert_eq!(defs[0].name, "read_file");
        assert_eq!(defs[1].name, "write_file");
    }

    #[tokio::test]
    async fn missing_path_argument() {
        let executor = FileEditExecutor::new();
        let context = ToolContext {
            run_id: Uuid::new_v4(),
            workspace_path: Some("/tmp".to_string()),
        };
        let call = ToolCall {
            call_id: "tc_6".to_string(),
            name: "read_file".to_string(),
            arguments: serde_json::json!({}).to_string(),
        };
        let result = executor.execute(&call, &context).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("path"));
    }

    #[tokio::test]
    async fn no_workspace_path() {
        let executor = FileEditExecutor::new();
        let context = ToolContext {
            run_id: Uuid::new_v4(),
            workspace_path: None,
        };
        let call = ToolCall {
            call_id: "tc_7".to_string(),
            name: "read_file".to_string(),
            arguments: serde_json::json!({"path": "file.txt"}).to_string(),
        };
        let result = executor.execute(&call, &context).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("workspace"));
    }
}
