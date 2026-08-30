use disco_protocol::types::{ApprovalDecision, ApprovalImpact, CompactionStatus, TokenUsage};
use uuid::Uuid;

use crate::approval::ApprovalRequest;

/// 后端运行产生的事件,由 daemon 转发给客户端。
#[derive(Debug, Clone)]
pub enum AgentOutput {
    TextDelta(String),
    /// Agent 提交的可展示计划快照。每次更新都代表完整计划，而非增量。
    PlanUpdate {
        explanation: Option<String>,
        steps: Vec<PlanStep>,
    },
    ReasoningDelta(String),
    Usage(TokenUsage),
    /// Provider 报告的当前上下文占用和窗口大小。
    ///
    /// 这与 `Usage` 的请求 token 统计不同：`tokens` 是当前上下文快照，
    /// 不能被当作累计用量再次相加。窗口未知时仍然转发 token 数。
    ContextUsage {
        tokens: i64,
        window: Option<i64>,
    },
    /// 上下文压缩生命周期事件。压缩由具体 Backend 负责，daemon 只转发。
    CompactionUpdate(CompactionUpdate),
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

/// Agent 计划中的单个步骤。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanStep {
    pub step: String,
    pub status: String,
}

impl disco_providers::PlanStepView for PlanStep {
    fn step_text(&self) -> &str {
        &self.step
    }

    fn status(&self) -> &str {
        &self.status
    }
}

/// Backend 报告的一次上下文压缩状态变化。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompactionUpdate {
    pub id: String,
    pub status: CompactionStatus,
    pub before_tokens: Option<i64>,
    pub after_tokens: Option<i64>,
    pub summary: Option<String>,
    pub error_message: Option<String>,
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
