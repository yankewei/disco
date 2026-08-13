//! Stable domain language shared by the kernel, engines, storage, and UI.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;
use uuid::Uuid;

macro_rules! identifier {
    ($name:ident) => {
        #[derive(
            Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize,
        )]
        #[serde(transparent)]
        pub struct $name(Uuid);

        impl $name {
            #[must_use]
            pub fn new() -> Self {
                Self(Uuid::now_v7())
            }

            #[must_use]
            pub const fn from_uuid(value: Uuid) -> Self {
                Self(value)
            }

            #[must_use]
            pub const fn as_uuid(self) -> Uuid {
                self.0
            }
        }

        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                self.0.fmt(formatter)
            }
        }

        impl std::str::FromStr for $name {
            type Err = uuid::Error;

            fn from_str(value: &str) -> Result<Self, Self::Err> {
                Uuid::parse_str(value).map(Self)
            }
        }
    };
}

identifier!(EventId);
identifier!(ProjectId);
identifier!(RunId);
identifier!(SessionId);

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Project {
    pub id: ProjectId,
    pub name: String,
    pub root_path: PathBuf,
    pub created_at: DateTime<Utc>,
    pub last_opened_at: DateTime<Utc>,
}

impl Project {
    #[must_use]
    pub fn new(name: impl Into<String>, root_path: PathBuf) -> Self {
        let now = Utc::now();
        Self {
            id: ProjectId::new(),
            name: name.into(),
            root_path,
            created_at: now,
            last_opened_at: now,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EngineKind {
    Rig,
    Codex,
    Acp { implementation: String },
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Queued,
    Running,
    WaitingForTool,
    WaitingForApproval,
    WaitingForUserInput,
    Completed,
    Failed,
    Cancelled,
}

impl RunStatus {
    #[must_use]
    pub const fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct TokenUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub total_tokens: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ToolCall {
    pub call_id: String,
    pub name: String,
    pub arguments: Value,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ApprovalRequest {
    pub approval_id: String,
    pub title: String,
    pub reason: Option<String>,
    pub fingerprint: String,
    pub tool_call: ToolCall,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalDecision {
    ApproveOnce,
    ApproveForSession,
    Decline,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "type", content = "data", rename_all = "snake_case")]
pub enum RunEventPayload {
    RunStarted {
        #[serde(default)]
        project_id: Option<ProjectId>,
        session_id: SessionId,
        engine: EngineKind,
        workspace: Option<String>,
        prompt: String,
    },
    CodexThreadAttached {
        thread_id: String,
    },
    AssistantContentDelta {
        text: String,
    },
    ReasoningDelta {
        text: String,
    },
    PlanUpdated {
        steps: Vec<String>,
    },
    ToolRequested {
        call: ToolCall,
    },
    ToolStarted {
        call_id: String,
    },
    ToolOutputDelta {
        call_id: String,
        output: String,
    },
    ToolCompleted {
        call_id: String,
        success: bool,
        output: String,
    },
    ApprovalRequested {
        request: ApprovalRequest,
    },
    ApprovalResolved {
        approval_id: String,
        decision: ApprovalDecision,
    },
    UsageUpdated {
        usage: TokenUsage,
    },
    RunCompleted,
    RunFailed {
        code: String,
        message: String,
        retryable: bool,
    },
    RunCancelled,
}

impl RunEventPayload {
    #[must_use]
    pub const fn terminal_status(&self) -> Option<RunStatus> {
        match self {
            Self::RunCompleted => Some(RunStatus::Completed),
            Self::RunFailed { .. } => Some(RunStatus::Failed),
            Self::RunCancelled => Some(RunStatus::Cancelled),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RunEvent {
    pub id: EventId,
    pub run_id: RunId,
    pub sequence: u64,
    pub occurred_at: DateTime<Utc>,
    pub payload: RunEventPayload,
}

impl RunEvent {
    #[must_use]
    pub fn new(run_id: RunId, sequence: u64, payload: RunEventPayload) -> Self {
        Self {
            id: EventId::new(),
            run_id,
            sequence,
            occurred_at: Utc::now(),
            payload,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_round_trips_without_losing_identity() {
        let event = RunEvent::new(
            RunId::new(),
            0,
            RunEventPayload::RunStarted {
                project_id: Some(ProjectId::new()),
                session_id: SessionId::new(),
                engine: EngineKind::Rig,
                workspace: Some("/tmp/disco".into()),
                prompt: "Inspect the failing tests".into(),
            },
        );

        let encoded = serde_json::to_string(&event).expect("event should encode");
        let decoded: RunEvent = serde_json::from_str(&encoded).expect("event should decode");
        assert_eq!(decoded, event);
    }

    #[test]
    fn only_terminal_payloads_report_a_terminal_status() {
        assert_eq!(
            RunEventPayload::RunCompleted.terminal_status(),
            Some(RunStatus::Completed)
        );
        assert_eq!(
            RunEventPayload::AssistantContentDelta { text: "x".into() }.terminal_status(),
            None
        );
    }
}
