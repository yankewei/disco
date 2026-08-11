//! Run coordination and deterministic UI projections.

mod scripted;

pub use scripted::{ScriptedBatch, ScriptedEngine};

use disco_domain::{
    ApprovalRequest, EngineKind, RunEvent, RunEventPayload, RunId, RunStatus, SessionId,
    TokenUsage, ToolCall,
};
use std::collections::HashMap;
use std::sync::Mutex;
use thiserror::Error;

#[derive(Debug, Error)]
#[error("event journal failed: {message}")]
pub struct JournalError {
    message: String,
}

impl JournalError {
    #[must_use]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

pub trait EventJournal: Send + Sync + 'static {
    fn append(&self, event: &RunEvent) -> Result<(), JournalError>;
    fn load_run(&self, run_id: RunId) -> Result<Vec<RunEvent>, JournalError>;
}

#[derive(Default)]
pub struct MemoryJournal(Mutex<Vec<RunEvent>>);

impl EventJournal for MemoryJournal {
    fn append(&self, event: &RunEvent) -> Result<(), JournalError> {
        self.0
            .lock()
            .map_err(|_| JournalError::new("memory journal lock was poisoned"))?
            .push(event.clone());
        Ok(())
    }

    fn load_run(&self, run_id: RunId) -> Result<Vec<RunEvent>, JournalError> {
        Ok(self
            .0
            .lock()
            .map_err(|_| JournalError::new("memory journal lock was poisoned"))?
            .iter()
            .filter(|event| event.run_id == run_id)
            .cloned()
            .collect())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ActivityKind {
    Plan,
    Tool,
    Approval,
    Failure,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActivityItem {
    pub id: String,
    pub kind: ActivityKind,
    pub title: String,
    pub detail: String,
    pub completed: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunProjection {
    pub run_id: RunId,
    pub session_id: Option<SessionId>,
    pub engine: Option<EngineKind>,
    pub workspace: Option<String>,
    pub prompt: Option<String>,
    pub status: RunStatus,
    pub assistant_text: String,
    pub reasoning_text: String,
    pub usage: TokenUsage,
    pub activities: Vec<ActivityItem>,
    pub pending_approval: Option<ApprovalRequest>,
    pub failure_message: Option<String>,
    next_sequence: u64,
}

impl RunProjection {
    #[must_use]
    pub fn empty(run_id: RunId) -> Self {
        Self {
            run_id,
            session_id: None,
            engine: None,
            workspace: None,
            prompt: None,
            status: RunStatus::Queued,
            assistant_text: String::new(),
            reasoning_text: String::new(),
            usage: TokenUsage::default(),
            activities: Vec::new(),
            pending_approval: None,
            failure_message: None,
            next_sequence: 0,
        }
    }

    pub fn apply(&mut self, event: &RunEvent) -> Result<(), ProjectionError> {
        if event.run_id != self.run_id {
            return Err(ProjectionError::WrongRun {
                expected: self.run_id,
                actual: event.run_id,
            });
        }
        if self.status.is_terminal() {
            return Err(ProjectionError::EventAfterTerminal(self.status));
        }
        if event.sequence != self.next_sequence {
            return Err(ProjectionError::OutOfOrder {
                expected: self.next_sequence,
                actual: event.sequence,
            });
        }

        match &event.payload {
            RunEventPayload::RunStarted {
                session_id,
                engine,
                workspace,
                prompt,
            } => {
                if self.next_sequence != 0 {
                    return Err(ProjectionError::DuplicateStart);
                }
                self.session_id = Some(*session_id);
                self.engine = Some(engine.clone());
                self.workspace.clone_from(workspace);
                self.prompt = Some(prompt.clone());
                self.status = RunStatus::Running;
            }
            RunEventPayload::AssistantContentDelta { text } => {
                self.assistant_text.push_str(text);
                self.status = RunStatus::Running;
            }
            RunEventPayload::ReasoningDelta { text } => {
                self.reasoning_text.push_str(text);
                self.status = RunStatus::Running;
            }
            RunEventPayload::PlanUpdated { steps } => {
                self.upsert_activity(ActivityItem {
                    id: "plan".into(),
                    kind: ActivityKind::Plan,
                    title: "Execution plan".into(),
                    detail: steps.join("\n"),
                    completed: false,
                });
            }
            RunEventPayload::ToolRequested { call } => {
                self.status = RunStatus::WaitingForTool;
                self.upsert_tool(call, "Waiting to start", false);
            }
            RunEventPayload::ToolStarted { call_id } => {
                self.status = RunStatus::WaitingForTool;
                self.update_tool(call_id, "Running", false);
            }
            RunEventPayload::ToolOutputDelta { call_id, output } => {
                self.status = RunStatus::WaitingForTool;
                self.update_tool(call_id, output, false);
            }
            RunEventPayload::ToolCompleted {
                call_id,
                success,
                output,
            } => {
                self.status = RunStatus::Running;
                let detail = if *success {
                    output.clone()
                } else {
                    format!("Failed: {output}")
                };
                self.update_tool(call_id, detail, true);
            }
            RunEventPayload::ApprovalRequested { request } => {
                self.status = RunStatus::WaitingForApproval;
                self.pending_approval = Some(request.clone());
                self.upsert_activity(ActivityItem {
                    id: request.approval_id.clone(),
                    kind: ActivityKind::Approval,
                    title: request.title.clone(),
                    detail: request
                        .reason
                        .clone()
                        .unwrap_or_else(|| "Decision required".into()),
                    completed: false,
                });
            }
            RunEventPayload::ApprovalResolved {
                approval_id,
                decision,
            } => {
                self.status = RunStatus::Running;
                self.pending_approval = None;
                if let Some(item) = self
                    .activities
                    .iter_mut()
                    .find(|item| item.id == *approval_id)
                {
                    item.detail = format!("Resolved: {decision:?}");
                    item.completed = true;
                }
            }
            RunEventPayload::UsageUpdated { usage } => self.usage = usage.clone(),
            RunEventPayload::RunCompleted => {
                self.status = RunStatus::Completed;
                for item in &mut self.activities {
                    item.completed = true;
                }
            }
            RunEventPayload::RunFailed { message, .. } => {
                self.status = RunStatus::Failed;
                self.failure_message = Some(message.clone());
                self.activities.push(ActivityItem {
                    id: format!("failure-{}", event.sequence),
                    kind: ActivityKind::Failure,
                    title: "Run failed".into(),
                    detail: message.clone(),
                    completed: true,
                });
            }
            RunEventPayload::RunCancelled => self.status = RunStatus::Cancelled,
        }

        self.next_sequence += 1;
        Ok(())
    }

    fn upsert_tool(&mut self, call: &ToolCall, detail: &str, completed: bool) {
        self.upsert_activity(ActivityItem {
            id: call.call_id.clone(),
            kind: ActivityKind::Tool,
            title: call.name.clone(),
            detail: detail.into(),
            completed,
        });
    }

    fn update_tool(&mut self, call_id: &str, detail: impl Into<String>, completed: bool) {
        if let Some(item) = self.activities.iter_mut().find(|item| item.id == call_id) {
            item.detail = detail.into();
            item.completed = completed;
        }
    }

    fn upsert_activity(&mut self, item: ActivityItem) {
        if let Some(current) = self
            .activities
            .iter_mut()
            .find(|current| current.id == item.id)
        {
            *current = item;
        } else {
            self.activities.push(item);
        }
    }
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum ProjectionError {
    #[error("event belongs to run {actual}, expected {expected}")]
    WrongRun { expected: RunId, actual: RunId },
    #[error("event sequence {actual} is out of order, expected {expected}")]
    OutOfOrder { expected: u64, actual: u64 },
    #[error("received an event after terminal state {0:?}")]
    EventAfterTerminal(RunStatus),
    #[error("a run can only start once")]
    DuplicateStart,
}

#[derive(Debug, Error)]
pub enum KernelError {
    #[error("run {0} already exists")]
    RunAlreadyExists(RunId),
    #[error("run {0} does not exist")]
    RunNotFound(RunId),
    #[error(transparent)]
    Projection(#[from] ProjectionError),
    #[error(transparent)]
    Journal(#[from] JournalError),
    #[error("kernel state lock was poisoned")]
    Poisoned,
}

pub struct Kernel<J: EventJournal> {
    journal: J,
    projections: Mutex<HashMap<RunId, RunProjection>>,
}

impl<J: EventJournal> Kernel<J> {
    #[must_use]
    pub fn new(journal: J) -> Self {
        Self {
            journal,
            projections: Mutex::new(HashMap::new()),
        }
    }

    pub fn start_run(
        &self,
        run_id: RunId,
        session_id: SessionId,
        engine: EngineKind,
        workspace: Option<String>,
        prompt: impl Into<String>,
    ) -> Result<RunProjection, KernelError> {
        let mut projections = self.projections.lock().map_err(|_| KernelError::Poisoned)?;
        if projections.contains_key(&run_id) {
            return Err(KernelError::RunAlreadyExists(run_id));
        }

        let event = RunEvent::new(
            run_id,
            0,
            RunEventPayload::RunStarted {
                session_id,
                engine,
                workspace,
                prompt: prompt.into(),
            },
        );
        let mut projection = RunProjection::empty(run_id);
        projection.apply(&event)?;
        self.journal.append(&event)?;
        projections.insert(run_id, projection.clone());
        Ok(projection)
    }

    pub fn record(
        &self,
        run_id: RunId,
        payload: RunEventPayload,
    ) -> Result<RunProjection, KernelError> {
        let mut projections = self.projections.lock().map_err(|_| KernelError::Poisoned)?;
        let current = projections
            .get(&run_id)
            .ok_or(KernelError::RunNotFound(run_id))?;
        let event = RunEvent::new(run_id, current.next_sequence, payload);
        let mut next = current.clone();
        next.apply(&event)?;
        self.journal.append(&event)?;
        projections.insert(run_id, next.clone());
        Ok(next)
    }

    pub fn restore(&self, run_id: RunId) -> Result<RunProjection, KernelError> {
        let events = self.journal.load_run(run_id)?;
        if events.is_empty() {
            return Err(KernelError::RunNotFound(run_id));
        }
        let mut projection = RunProjection::empty(run_id);
        for event in &events {
            projection.apply(event)?;
        }
        self.projections
            .lock()
            .map_err(|_| KernelError::Poisoned)?
            .insert(run_id, projection.clone());
        Ok(projection)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use disco_domain::{ApprovalDecision, RunEventPayload};

    #[test]
    fn kernel_builds_a_projection_and_rejects_events_after_completion() {
        let kernel = Kernel::new(MemoryJournal::default());
        let run_id = RunId::new();
        kernel
            .start_run(
                run_id,
                SessionId::new(),
                EngineKind::Rig,
                Some("/workspace".into()),
                "Run the tests",
            )
            .expect("run should start");
        kernel
            .record(
                run_id,
                RunEventPayload::AssistantContentDelta {
                    text: "Tests are green.".into(),
                },
            )
            .expect("delta should be recorded");
        let completed = kernel
            .record(run_id, RunEventPayload::RunCompleted)
            .expect("run should complete");

        assert_eq!(completed.status, RunStatus::Completed);
        assert_eq!(completed.assistant_text, "Tests are green.");
        assert!(matches!(
            kernel.record(run_id, RunEventPayload::RunCancelled),
            Err(KernelError::Projection(
                ProjectionError::EventAfterTerminal(RunStatus::Completed)
            ))
        ));
    }

    #[test]
    fn approval_updates_the_existing_activity_in_place() {
        let run_id = RunId::new();
        let mut projection = RunProjection::empty(run_id);
        projection
            .apply(&RunEvent::new(
                run_id,
                0,
                RunEventPayload::RunStarted {
                    session_id: SessionId::new(),
                    engine: EngineKind::Rig,
                    workspace: None,
                    prompt: "Edit the file".into(),
                },
            ))
            .expect("run should start");
        let request = ApprovalRequest {
            approval_id: "approval-1".into(),
            title: "Write src/main.rs".into(),
            reason: Some("The requested fix changes this file".into()),
            fingerprint: "sha256:example".into(),
            tool_call: ToolCall {
                call_id: "call-1".into(),
                name: "apply_patch".into(),
                arguments: serde_json::json!({"path": "src/main.rs"}),
            },
        };
        projection
            .apply(&RunEvent::new(
                run_id,
                1,
                RunEventPayload::ApprovalRequested { request },
            ))
            .expect("approval should be requested");
        projection
            .apply(&RunEvent::new(
                run_id,
                2,
                RunEventPayload::ApprovalResolved {
                    approval_id: "approval-1".into(),
                    decision: ApprovalDecision::ApproveOnce,
                },
            ))
            .expect("approval should resolve");

        assert_eq!(projection.activities.len(), 1);
        assert!(projection.activities[0].completed);
        assert_eq!(projection.status, RunStatus::Running);
    }
}
