use std::sync::Arc;

use disco_core::BackendSession;
use uuid::Uuid;

use crate::daemon::AppState;

/// session 删除的协议无关错误。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionDeleteError {
    /// session 不存在；ACP 语义视为删除成功。
    NotFound,
    SessionBusy(Uuid),
    BackendUnavailable,
    BackendCannotDelete,
    BackendDeleteFailed(String),
    Internal(String),
}

impl SessionDeleteError {
    pub fn into_acp_error(self) -> agent_client_protocol::Error {
        match self {
            SessionDeleteError::NotFound => {
                agent_client_protocol::Error::resource_not_found(None).data("session 不存在")
            }
            SessionDeleteError::SessionBusy(_) => agent_client_protocol::Error::invalid_params()
                .data("会话仍有活动任务，请先取消任务"),
            SessionDeleteError::BackendUnavailable => {
                agent_client_protocol::Error::internal_error()
                    .data("无法连接原始 Agent Backend，本地会话未删除")
            }
            SessionDeleteError::BackendCannotDelete => {
                agent_client_protocol::Error::invalid_params()
                    .data("该 Agent Backend 不支持删除原始会话，本地会话未删除")
            }
            SessionDeleteError::BackendDeleteFailed(message) => {
                agent_client_protocol::Error::internal_error().data(format!(
                    "删除原始 Agent 会话失败，本地会话已保留：{message}"
                ))
            }
            SessionDeleteError::Internal(message) => {
                agent_client_protocol::Error::internal_error().data(message)
            }
        }
    }
}

/// 删除 Disco session 及其权威后端会话。
///
/// 先请求 backend 删除权威会话，成功后才删除本地记录；backend 删除失败时保留本地记录。
pub async fn delete_session(
    app: &Arc<AppState>,
    session_id: Uuid,
) -> Result<(), SessionDeleteError> {
    let session = match app.db.get_session(session_id) {
        Ok(Some(session)) => session,
        Ok(None) => return Err(SessionDeleteError::NotFound),
        Err(error) => return Err(SessionDeleteError::Internal(error.to_string())),
    };

    if let Some(active_run_id) = app.run_coordinator.active_run_id(session.id).await {
        return Err(SessionDeleteError::SessionBusy(active_run_id));
    }

    let backend = match app.get_backend(&session.provider_id).await {
        Some(backend) => backend,
        None => return Err(SessionDeleteError::BackendUnavailable),
    };
    if !backend.capabilities().can_delete_session {
        return Err(SessionDeleteError::BackendCannotDelete);
    }
    let backend_handle = app
        .db
        .get_session_backend_handle(session.id)
        .map_err(|error| SessionDeleteError::Internal(error.to_string()))?;
    let workspace_path = app
        .db
        .get_project(session.project_id)
        .map_err(|error| SessionDeleteError::Internal(error.to_string()))?
        .map(|project| project.path);
    let backend_session = BackendSession {
        id: session.id,
        model: session.model,
        backend_handle,
    };
    backend
        .delete_session(&backend_session, workspace_path)
        .await
        .map_err(|error| SessionDeleteError::BackendDeleteFailed(error.to_string()))?;

    {
        let _state_guard = app.state_lock.lock().await;
        app.db
            .delete_session(session_id)
            .map_err(|error| SessionDeleteError::Internal(error.to_string()))?;
        app.bump_state_revision();
    }
    app.event_journal.clear_session(session_id).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::ProviderRuntime;
    use crate::run_service::test_support::{ScriptedBackend, make_test_app};
    use disco_core::{
        AgentBackend, BackendCapabilities, BackendRun, BackendRunRequest, CompactionMode,
    };

    struct FailingDeleteBackend;

    #[async_trait::async_trait]
    impl AgentBackend for FailingDeleteBackend {
        fn capabilities(&self) -> BackendCapabilities {
            BackendCapabilities {
                has_persistent_sessions: true,
                can_delete_session: true,
                compaction: CompactionMode::Unsupported,
            }
        }

        async fn start_run(&self, _request: BackendRunRequest) -> anyhow::Result<BackendRun> {
            Err(anyhow::anyhow!("测试后端不运行任务"))
        }

        async fn delete_session(
            &self,
            _session: &BackendSession,
            _workspace_path: Option<String>,
        ) -> anyhow::Result<()> {
            Err(anyhow::anyhow!("上游不可用"))
        }
    }

    #[tokio::test]
    async fn delete_session_removes_local_record() {
        let (app, session_id) = make_test_app(Arc::new(ScriptedBackend {
            outputs: vec![],
            backend_handle: None,
        }));

        delete_session(&app, session_id).await.unwrap();
        assert!(app.db.get_session(session_id).unwrap().is_none());

        let repeated = delete_session(&app, session_id).await.unwrap_err();
        assert_eq!(repeated, SessionDeleteError::NotFound);
    }

    #[tokio::test]
    async fn upstream_delete_failure_preserves_local_session() {
        let (app, session_id) = make_test_app(Arc::new(ScriptedBackend {
            outputs: vec![],
            backend_handle: None,
        }));
        let session = app.db.get_session(session_id).unwrap().unwrap();
        let compaction_provider = app
            .get_compaction_provider(&session.provider_id)
            .await
            .unwrap();
        app.set_provider_runtime_locked(
            session.provider_id.clone(),
            ProviderRuntime {
                backend: Arc::new(FailingDeleteBackend),
                compaction_provider,
            },
        )
        .await;
        app.db.add_message(session_id, "user", "保留我").unwrap();

        let error = delete_session(&app, session_id).await.unwrap_err();
        assert!(matches!(error, SessionDeleteError::BackendDeleteFailed(_)));
        assert!(app.db.get_session(session_id).unwrap().is_some());
        assert_eq!(app.db.list_messages(session_id).unwrap().len(), 1);
    }
}
