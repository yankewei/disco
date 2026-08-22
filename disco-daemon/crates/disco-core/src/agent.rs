use disco_protocol::types::{ApprovalDecision, ApprovalImpact, TokenUsage};
use uuid::Uuid;

use crate::approval::ApprovalRequest;

/// 后端运行产生的事件,由 daemon 转发给客户端。
#[derive(Debug, Clone)]
pub enum AgentOutput {
    TextDelta(String),
    ReasoningDelta(String),
    Usage(TokenUsage),
    /// ACP 标准 `usage_update` 的当前上下文占用和窗口大小。
    ///
    /// 这与 `Usage` 的请求 token 统计不同：ACP 的 `used` 是上下文快照，
    /// 不能被当作累计用量再次相加。
    ContextUsage {
        used: i64,
        size: i64,
    },
    ToolStarted {
        tool_call_id: String,
        tool_name: String,
        arguments: String,
    },
    ToolCompleted {
        tool_call_id: String,
        tool_name: String,
        output: String,
    },
    ApprovalWaiting {
        approval_id: Uuid,
        kind: String,
        title: String,
        impact: ApprovalImpact,
        fingerprint: String,
        allows_session_approval: bool,
    },
    ApprovalResolved {
        approval_id: Uuid,
        decision: ApprovalDecision,
    },
    Completed,
    Failed(String),
    Cancelled,
}

impl AgentOutput {
    /// 将领域审批请求转换为等待用户响应的事件。
    pub fn approval_waiting(request: &ApprovalRequest) -> Self {
        Self::ApprovalWaiting {
            approval_id: request.id,
            kind: request.kind.clone(),
            title: request.title.clone(),
            impact: request.impact.clone(),
            fingerprint: request.fingerprint.clone(),
            allows_session_approval: request.allows_session_approval,
        }
    }
}
