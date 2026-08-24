use std::sync::Arc;

use disco_core::ContextCompactor;
use disco_protocol::types::{CompactionStatus, Vendor};
use disco_providers::openai_responses::ChatMessage;
use uuid::Uuid;

use crate::daemon::AppState;

/// 上下文压缩的协议无关错误。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompactionError {
    InvalidParams(String),
    Internal(String),
}

impl CompactionError {
    pub fn into_acp_error(self) -> agent_client_protocol::Error {
        match self {
            CompactionError::InvalidParams(message) => {
                agent_client_protocol::Error::invalid_params().data(message)
            }
            CompactionError::Internal(message) => {
                agent_client_protocol::Error::internal_error().data(message)
            }
        }
    }
}

/// 一次压缩的结果;facade 负责把它映射为各自协议的事件/响应。
#[derive(Debug, Clone)]
pub struct CompactionOutcome {
    pub id: String,
    pub status: CompactionStatus,
    pub summary: Option<String>,
    pub before_tokens: Option<i64>,
    pub after_tokens: Option<i64>,
    pub error_message: Option<String>,
}

/// 执行本地压缩；ID 由 facade 提前分配，用于发送 running/completed 事件。
pub async fn compact_session_with_id(
    app: &Arc<AppState>,
    session_id: Uuid,
    compaction_id: String,
) -> Result<CompactionOutcome, CompactionError> {
    let stored_messages = app
        .db
        .list_messages(session_id)
        .map_err(|error| CompactionError::Internal(format!("读取消息历史失败：{error}")))?;
    if stored_messages.is_empty() {
        return Err(CompactionError::InvalidParams(
            "没有可压缩的消息。".to_string(),
        ));
    }

    let chat_messages: Vec<ChatMessage> = stored_messages
        .iter()
        .map(|message| ChatMessage {
            role: message.role.clone(),
            text: message.text.clone(),
            ..Default::default()
        })
        .collect();

    let session = app
        .db
        .get_session(session_id)
        .map_err(|error| CompactionError::Internal(error.to_string()))?
        .ok_or_else(|| CompactionError::InvalidParams(format!("会话 {session_id} 不存在")))?;
    let provider = app
        .get_compaction_provider(&session.provider_id)
        .await
        .ok_or_else(|| {
            CompactionError::Internal(
                "未配置模型服务商：请在设置中配置（或设置 OPENAI_API_KEY 环境变量）。".to_string(),
            )
        })?;

    let context_window = context_window_for(app, &session).await;
    let compactor = ContextCompactor::new(context_window);
    let result = compactor
        .compact_with_id(compaction_id, &chat_messages, &provider)
        .await;
    if result.status == CompactionStatus::Completed {
        if let Some(boundary) = stored_messages
            .get(stored_messages.len().saturating_sub(7))
            .or_else(|| stored_messages.last())
        {
            let _state_guard = app.state_lock.lock().await;
            app.db
                .save_context_checkpoint(session_id, boundary.id, &result.summary)
                .map_err(|error| {
                    CompactionError::Internal(format!("保存上下文 checkpoint 失败：{error}"))
                })?;
            app.bump_state_revision();
        }
    }

    Ok(CompactionOutcome {
        id: result.id,
        status: result.status,
        summary: (!result.summary.is_empty()).then_some(result.summary),
        before_tokens: result.before_tokens,
        after_tokens: result.after_tokens,
        error_message: result.error_message.clone(),
    })
}

/// 解析会话模型的上下文窗口。
///
/// API Key 服务商优先使用内置模型目录的 context_window；OpenCode 的目录来自
/// ACP agent 的 session configOptions 缓存。模型未收录时回退到默认窗口，
/// 阈值偏保守，不影响正确性。
async fn context_window_for(app: &Arc<AppState>, session: &disco_protocol::types::Session) -> i64 {
    let entries = if session.vendor == Vendor::OpenCode {
        app.opencode_model_catalog
            .lock()
            .await
            .clone()
            .unwrap_or_default()
    } else {
        crate::provider_service::get_default_models(session.vendor)
    };
    entries
        .into_iter()
        .find(|entry| entry.id == session.model)
        .and_then(|entry| entry.context_window)
        .unwrap_or(disco_core::DEFAULT_CONTEXT_WINDOW)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::run_service::test_support::{ScriptedBackend, make_test_app};
    use std::sync::Arc;

    #[tokio::test]
    async fn compaction_rejects_empty_history() {
        let (app, session_id) = make_test_app(Arc::new(ScriptedBackend {
            outputs: vec![],
            backend_handle: None,
        }));
        let error = compact_session_with_id(&app, session_id, "cmp-empty".to_string())
            .await
            .unwrap_err();
        assert!(matches!(error, CompactionError::InvalidParams(_)));
    }

    #[tokio::test]
    async fn compaction_returns_failed_outcome_when_summary_stream_is_empty() {
        let (app, session_id) = make_test_app(Arc::new(ScriptedBackend {
            outputs: vec![],
            backend_handle: None,
        }));
        app.db.add_message(session_id, "user", "hello").unwrap();

        let outcome = compact_session_with_id(&app, session_id, "cmp-empty-summary".to_string())
            .await
            .unwrap();
        assert_eq!(outcome.status, CompactionStatus::Failed);
        assert!(outcome.before_tokens.is_some());
        assert!(outcome.error_message.is_some());
    }
}
