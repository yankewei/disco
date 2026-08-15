use serde::{Deserialize, Serialize};
use uuid::Uuid;

// MARK: - 服务商

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Vendor {
    Openai,
    Deepseek,
    MoonshotKimi,
    KimiCode,
    Glm,
    Codex,
}

// MARK: - 运行状态

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunState {
    Connecting,
    Running,
    WaitingForTool,
    WaitingForApproval,
    WaitingForUserInput,
    Cancelling,
}

// MARK: - 审批

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalKind {
    Command,
    FileChange,
    Network,
    Permission,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ApprovalImpact {
    Command {
        executable: String,
        arguments: Vec<String>,
        cwd: String,
    },
    FileChange {
        paths: Vec<String>,
        summary: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        diff: Option<String>,
    },
    Network {
        host: String,
        scheme: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        port: Option<u16>,
    },
    Permission {
        scope: String,
        description: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalDecision {
    ApproveOnce,
    ApproveForSession,
    Decline,
}

// MARK: - 用户输入

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UserInputOption {
    pub id: String,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UserInputQuestion {
    pub id: String,
    pub header: String,
    pub question: String,
    pub options: Vec<UserInputOption>,
    pub allows_other: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UserInputAnswer {
    pub question_id: String,
    pub answers: Vec<String>,
}

// MARK: - Token 用量

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenUsage {
    pub input: i64,
    pub output: i64,
    pub total: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cached_input: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_output: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageSource {
    Provider,
    Estimate,
    Codex,
}

// MARK: - 上下文压缩

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeKind {
    Generic,
    Codex,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompactionTrigger {
    Automatic,
    Manual,
    OverflowRecovery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompactionStatus {
    Running,
    Completed,
    Failed,
}

// MARK: - 错误

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    Generic,
    NoTextOutput,
    ContextOverflow,
    ContextCompactionFailed,
}

// MARK: - 模型目录

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelCatalogEntry {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_window: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub supported_reasoning_efforts: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_reasoning_effort: Option<String>,
}

// MARK: - 项目与会话

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Project {
    pub id: Uuid,
    pub name: String,
    pub path: String,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Session {
    pub id: Uuid,
    pub project_id: Uuid,
    pub vendor: Vendor,
    pub model: String,
    pub created_at: String,
    pub updated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

// MARK: - Codex 账户

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CodexAccount {
    pub r#type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan_type: Option<String>,
}
