//! Versioned NDJSON protocol shared with the isolated tool runtime.

use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ToolRequest {
    pub version: u32,
    pub request_id: String,
    pub workspace_root: String,
    pub operation: ToolOperation,
}

impl ToolRequest {
    #[must_use]
    pub fn new(
        request_id: impl Into<String>,
        workspace_root: impl Into<String>,
        operation: ToolOperation,
    ) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id: request_id.into(),
            workspace_root: workspace_root.into(),
            operation,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "name", content = "arguments", rename_all = "snake_case")]
pub enum ToolOperation {
    Ping,
    ListDirectory { path: String, max_entries: usize },
    ReadFile { path: String, max_bytes: usize },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DirectoryEntry {
    pub name: String,
    pub relative_path: String,
    pub kind: EntryKind,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    File,
    Directory,
    Symlink,
    Other,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ToolResponse {
    pub version: u32,
    pub request_id: String,
    pub result: Result<ToolOutput, ToolFailure>,
}

impl ToolResponse {
    #[must_use]
    pub fn success(request_id: impl Into<String>, output: ToolOutput) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id: request_id.into(),
            result: Ok(output),
        }
    }

    #[must_use]
    pub fn failure(
        request_id: impl Into<String>,
        code: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id: request_id.into(),
            result: Err(ToolFailure {
                code: code.into(),
                message: message.into(),
            }),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "type", content = "data", rename_all = "snake_case")]
pub enum ToolOutput {
    Pong,
    Directory {
        entries: Vec<DirectoryEntry>,
        truncated: bool,
    },
    File {
        content: String,
        truncated: bool,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ToolFailure {
    pub code: String,
    pub message: String,
}
