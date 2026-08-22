pub mod agent;
pub mod approval;
pub mod backend;
pub mod context;
pub mod run;
pub mod session;

pub use agent::AgentOutput;
pub use approval::{
    ApprovalManager, ApprovalRequest, PendingApproval, PreparedApproval, tool_approval_request,
};
pub use backend::{
    AgentBackend, BackendCapabilities, BackendEventStream, BackendRun, BackendRunRequest,
    BackendSession,
};
pub use context::{CompactionResult, ContextCompactor, DEFAULT_CONTEXT_WINDOW, apply_compaction};
pub use run::{BeginRunError, CancelRunOutcome, RunCoordinator, StartedRun};
