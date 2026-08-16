use std::collections::HashMap;
use std::sync::Arc;

use disco_protocol::types::ApprovalDecision;
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::ApprovalManager;

/// daemon 启动一次运行后所需的控制句柄。
pub struct StartedRun {
    pub run_id: Uuid,
    pub cancellation: CancellationToken,
    pub approval_manager: Arc<ApprovalManager>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BeginRunError {
    SessionBusy { active_run_id: Uuid },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CancelRunOutcome {
    Signalled,
    NoActiveRun,
}

/// 统一管理活动 run、会话互斥、取消和审批路由。
///
/// 同一会话最多只能注册一个活动 run。会话级审批指纹在 run 结束后
/// 仍然保留，但不会跨会话共享。
#[derive(Default)]
pub struct RunCoordinator {
    state: Mutex<CoordinatorState>,
}

#[derive(Default)]
struct CoordinatorState {
    runs: HashMap<Uuid, ActiveRun>,
    run_by_session: HashMap<Uuid, Uuid>,
    approved_fingerprints_by_session: HashMap<Uuid, Arc<Mutex<Vec<String>>>>,
}

struct ActiveRun {
    session_id: Uuid,
    cancellation: CancellationToken,
    approval_manager: Arc<ApprovalManager>,
}

impl RunCoordinator {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn begin_run(&self, session_id: Uuid) -> Result<StartedRun, BeginRunError> {
        let mut state = self.state.lock().await;
        if let Some(active_run_id) = state.run_by_session.get(&session_id) {
            return Err(BeginRunError::SessionBusy {
                active_run_id: *active_run_id,
            });
        }

        let run_id = Uuid::new_v4();
        let cancellation = CancellationToken::new();
        let approved_fingerprints = state
            .approved_fingerprints_by_session
            .entry(session_id)
            .or_insert_with(|| Arc::new(Mutex::new(Vec::new())))
            .clone();
        let approval_manager = Arc::new(ApprovalManager::new(approved_fingerprints));

        state.run_by_session.insert(session_id, run_id);
        state.runs.insert(
            run_id,
            ActiveRun {
                session_id,
                cancellation: cancellation.clone(),
                approval_manager: approval_manager.clone(),
            },
        );

        Ok(StartedRun {
            run_id,
            cancellation,
            approval_manager,
        })
    }

    pub async fn finish_run(&self, run_id: Uuid) {
        let finished_run = {
            let mut state = self.state.lock().await;
            let Some(active) = state.runs.remove(&run_id) else {
                return;
            };
            if state.run_by_session.get(&active.session_id) == Some(&run_id) {
                state.run_by_session.remove(&active.session_id);
            }
            active
        };

        finished_run.approval_manager.cancel_all().await;
    }

    pub async fn active_run_id(&self, session_id: Uuid) -> Option<Uuid> {
        self.state
            .lock()
            .await
            .run_by_session
            .get(&session_id)
            .copied()
    }

    pub async fn cancel_run(&self, run_id: Uuid) -> CancelRunOutcome {
        let run_controls = {
            let state = self.state.lock().await;
            state
                .runs
                .get(&run_id)
                .map(|active| (active.cancellation.clone(), active.approval_manager.clone()))
        };

        let Some((cancellation, approval_manager)) = run_controls else {
            return CancelRunOutcome::NoActiveRun;
        };

        cancellation.cancel();
        approval_manager.cancel_all().await;
        CancelRunOutcome::Signalled
    }

    pub async fn respond_approval(&self, approval_id: Uuid, decision: ApprovalDecision) -> bool {
        let approval_managers = {
            let state = self.state.lock().await;
            state
                .runs
                .values()
                .map(|active| active.approval_manager.clone())
                .collect::<Vec<_>>()
        };

        for manager in approval_managers {
            if manager.respond(approval_id, decision).await {
                return true;
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use disco_protocol::types::ApprovalImpact;

    use super::*;
    use crate::approval::ApprovalRequest;

    #[tokio::test]
    async fn prevents_two_active_runs_in_one_session() {
        let coordinator = RunCoordinator::new();
        let session_id = Uuid::new_v4();
        let first = coordinator.begin_run(session_id).await.unwrap();

        match coordinator.begin_run(session_id).await {
            Err(BeginRunError::SessionBusy { active_run_id }) => {
                assert_eq!(active_run_id, first.run_id);
            }
            Ok(_) => panic!("同一会话不应启动第二个 run"),
        }
    }

    #[tokio::test]
    async fn permits_runs_in_different_sessions() {
        let coordinator = RunCoordinator::new();

        coordinator.begin_run(Uuid::new_v4()).await.unwrap();
        coordinator.begin_run(Uuid::new_v4()).await.unwrap();
    }

    #[tokio::test]
    async fn finishing_releases_the_session() {
        let coordinator = RunCoordinator::new();
        let session_id = Uuid::new_v4();
        let first = coordinator.begin_run(session_id).await.unwrap();

        coordinator.finish_run(first.run_id).await;

        coordinator.begin_run(session_id).await.unwrap();
    }

    #[tokio::test]
    async fn exposes_the_active_run_for_session_lifecycle_operations() {
        let coordinator = RunCoordinator::new();
        let session_id = Uuid::new_v4();
        let run = coordinator.begin_run(session_id).await.unwrap();

        assert_eq!(
            coordinator.active_run_id(session_id).await,
            Some(run.run_id)
        );
        coordinator.finish_run(run.run_id).await;
        assert_eq!(coordinator.active_run_id(session_id).await, None);
    }

    #[tokio::test]
    async fn cancellation_is_idempotent() {
        let coordinator = RunCoordinator::new();
        let run = coordinator.begin_run(Uuid::new_v4()).await.unwrap();

        assert_eq!(
            coordinator.cancel_run(run.run_id).await,
            CancelRunOutcome::Signalled
        );
        assert!(run.cancellation.is_cancelled());

        coordinator.finish_run(run.run_id).await;
        assert_eq!(
            coordinator.cancel_run(run.run_id).await,
            CancelRunOutcome::NoActiveRun
        );
    }

    #[tokio::test]
    async fn session_approval_survives_between_runs() {
        let coordinator = RunCoordinator::new();
        let session_id = Uuid::new_v4();
        let first = coordinator.begin_run(session_id).await.unwrap();
        let approval_id = Uuid::new_v4();
        let request = approval_request(approval_id, "same-command");
        let manager = first.approval_manager.clone();
        let waiting = tokio::spawn(async move { manager.request_approval(&request).await });
        tokio::task::yield_now().await;

        assert!(
            coordinator
                .respond_approval(approval_id, ApprovalDecision::ApproveForSession)
                .await
        );
        assert_eq!(waiting.await.unwrap(), ApprovalDecision::ApproveForSession);
        coordinator.finish_run(first.run_id).await;

        let second = coordinator.begin_run(session_id).await.unwrap();
        let decision = second
            .approval_manager
            .request_approval(&approval_request(Uuid::new_v4(), "same-command"))
            .await;
        assert_eq!(decision, ApprovalDecision::ApproveOnce);
    }

    fn approval_request(id: Uuid, fingerprint: &str) -> ApprovalRequest {
        ApprovalRequest {
            id,
            run_id: Uuid::new_v4(),
            kind: "command".to_string(),
            title: "执行命令".to_string(),
            reason: None,
            impact: ApprovalImpact::Permission {
                scope: "shell".to_string(),
                description: "执行测试命令".to_string(),
            },
            fingerprint: fingerprint.to_string(),
            allows_session_approval: true,
        }
    }
}
