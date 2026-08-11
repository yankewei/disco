//! Bounded, workspace-scoped tool execution.

use disco_protocol::{
    DirectoryEntry, EntryKind, PROTOCOL_VERSION, ToolOperation, ToolOutput, ToolRequest,
    ToolResponse,
};
use std::fs;
use std::path::{Component, Path, PathBuf};
use thiserror::Error;

const MAX_DIRECTORY_ENTRIES: usize = 2_000;
const MAX_FILE_BYTES: usize = 1_048_576;

#[must_use]
pub fn execute(request: ToolRequest) -> ToolResponse {
    let request_id = request.request_id.clone();
    match execute_checked(request) {
        Ok(output) => ToolResponse::success(request_id, output),
        Err(error) => ToolResponse::failure(request_id, error.code(), error.to_string()),
    }
}

fn execute_checked(request: ToolRequest) -> Result<ToolOutput, ToolRuntimeError> {
    if request.version != PROTOCOL_VERSION {
        return Err(ToolRuntimeError::UnsupportedVersion(request.version));
    }

    let workspace = fs::canonicalize(&request.workspace_root)
        .map_err(|source| ToolRuntimeError::WorkspaceUnavailable { source })?;
    if !workspace.is_dir() {
        return Err(ToolRuntimeError::WorkspaceIsNotDirectory);
    }

    match request.operation {
        ToolOperation::Ping => Ok(ToolOutput::Pong),
        ToolOperation::ListDirectory { path, max_entries } => {
            list_directory(&workspace, path, max_entries)
        }
        ToolOperation::ReadFile { path, max_bytes } => read_file(&workspace, path, max_bytes),
    }
}

fn list_directory(
    workspace: &Path,
    requested_path: String,
    max_entries: usize,
) -> Result<ToolOutput, ToolRuntimeError> {
    let directory = resolve_existing(workspace, &requested_path)?;
    if !directory.is_dir() {
        return Err(ToolRuntimeError::NotDirectory(requested_path));
    }

    let mut entries = fs::read_dir(directory)?
        .map(|entry| {
            let entry = entry?;
            let path = entry.path();
            let file_type = fs::symlink_metadata(&path)?.file_type();
            let kind = if file_type.is_symlink() {
                EntryKind::Symlink
            } else if file_type.is_dir() {
                EntryKind::Directory
            } else if file_type.is_file() {
                EntryKind::File
            } else {
                EntryKind::Other
            };
            let relative_path = path
                .strip_prefix(workspace)
                .map_err(|_| ToolRuntimeError::EscapesWorkspace)?
                .to_string_lossy()
                .into_owned();
            Ok(DirectoryEntry {
                name: entry.file_name().to_string_lossy().into_owned(),
                relative_path,
                kind,
            })
        })
        .collect::<Result<Vec<_>, ToolRuntimeError>>()?;
    entries.sort_by(|left, right| left.name.cmp(&right.name));

    let limit = max_entries.clamp(1, MAX_DIRECTORY_ENTRIES);
    let truncated = entries.len() > limit;
    entries.truncate(limit);
    Ok(ToolOutput::Directory { entries, truncated })
}

fn read_file(
    workspace: &Path,
    requested_path: String,
    max_bytes: usize,
) -> Result<ToolOutput, ToolRuntimeError> {
    let file = resolve_existing(workspace, &requested_path)?;
    if !file.metadata()?.is_file() {
        return Err(ToolRuntimeError::NotRegularFile(requested_path));
    }

    let bytes = fs::read(file)?;
    let limit = max_bytes.clamp(1, MAX_FILE_BYTES);
    let truncated = bytes.len() > limit;
    let visible = &bytes[..bytes.len().min(limit)];
    let content = std::str::from_utf8(visible)
        .map_err(|_| ToolRuntimeError::NotUtf8)?
        .to_owned();
    Ok(ToolOutput::File { content, truncated })
}

fn resolve_existing(workspace: &Path, requested: &str) -> Result<PathBuf, ToolRuntimeError> {
    let relative = Path::new(requested);
    if relative.is_absolute()
        || relative
            .components()
            .any(|component| matches!(component, Component::ParentDir))
    {
        return Err(ToolRuntimeError::EscapesWorkspace);
    }
    let canonical = fs::canonicalize(workspace.join(relative))?;
    if !canonical.starts_with(workspace) {
        return Err(ToolRuntimeError::EscapesWorkspace);
    }
    Ok(canonical)
}

#[derive(Debug, Error)]
enum ToolRuntimeError {
    #[error("protocol version {0} is unsupported")]
    UnsupportedVersion(u32),
    #[error("workspace is unavailable: {source}")]
    WorkspaceUnavailable { source: std::io::Error },
    #[error("workspace root is not a directory")]
    WorkspaceIsNotDirectory,
    #[error("requested path escapes the workspace")]
    EscapesWorkspace,
    #[error("path is not a directory: {0}")]
    NotDirectory(String),
    #[error("path is not a regular file: {0}")]
    NotRegularFile(String),
    #[error("file content is not UTF-8")]
    NotUtf8,
    #[error("I/O failed: {0}")]
    Io(#[from] std::io::Error),
}

impl ToolRuntimeError {
    const fn code(&self) -> &'static str {
        match self {
            Self::UnsupportedVersion(_) => "unsupported_version",
            Self::WorkspaceUnavailable { .. } | Self::WorkspaceIsNotDirectory => {
                "workspace_unavailable"
            }
            Self::EscapesWorkspace => "outside_workspace",
            Self::NotDirectory(_) => "not_directory",
            Self::NotRegularFile(_) => "not_regular_file",
            Self::NotUtf8 => "not_utf8",
            Self::Io(_) => "io_error",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use disco_protocol::ToolOperation;
    use std::fs;

    #[test]
    fn lists_and_reads_workspace_files() {
        let workspace = tempfile::tempdir().expect("workspace should exist");
        fs::write(workspace.path().join("notes.txt"), "kernel ready")
            .expect("fixture should write");

        let listed = execute(ToolRequest::new(
            "list-1",
            workspace.path().to_string_lossy(),
            ToolOperation::ListDirectory {
                path: ".".into(),
                max_entries: 20,
            },
        ));
        let ToolOutput::Directory { entries, .. } = listed.result.expect("list should succeed")
        else {
            panic!("expected a directory response");
        };
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "notes.txt");

        let read = execute(ToolRequest::new(
            "read-1",
            workspace.path().to_string_lossy(),
            ToolOperation::ReadFile {
                path: "notes.txt".into(),
                max_bytes: 64,
            },
        ));
        assert_eq!(
            read.result.expect("read should succeed"),
            ToolOutput::File {
                content: "kernel ready".into(),
                truncated: false,
            }
        );
    }

    #[cfg(unix)]
    #[test]
    fn rejects_parent_paths_and_symlinks_that_escape_workspace() {
        use std::os::unix::fs::symlink;

        let workspace = tempfile::tempdir().expect("workspace should exist");
        let outside = tempfile::tempdir().expect("outside should exist");
        fs::write(outside.path().join("secret.txt"), "not visible").expect("fixture should write");
        symlink(outside.path(), workspace.path().join("outside"))
            .expect("symlink should be created");

        for path in ["../secret.txt", "outside/secret.txt"] {
            let response = execute(ToolRequest::new(
                format!("read-{path}"),
                workspace.path().to_string_lossy(),
                ToolOperation::ReadFile {
                    path: path.into(),
                    max_bytes: 64,
                },
            ));
            assert_eq!(
                response.result.expect_err("escape should fail").code,
                "outside_workspace"
            );
        }
    }
}
