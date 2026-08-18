use std::sync::Arc;

use disco_core::ContextCompactor;
use disco_protocol::types::CompactionStatus;
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
    pub before_tokens: Option<i64>,
    pub after_tokens: Option<i64>,
    pub error_message: Option<String>,
}

/// 对 session 的消息历史执行上下文压缩。
pub async fn compact_session(
    app: &Arc<AppState>,
    session_id: Uuid,
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

    let compactor = ContextCompactor::new(128000);
    let result = compactor.compact(&chat_messages, &provider).await;

    Ok(CompactionOutcome {
        id: result.id,
        status: result.status,
        before_tokens: result.before_tokens,
        after_tokens: result.after_tokens,
        error_message: result.error_message.clone(),
    })
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
        let error = compact_session(&app, session_id).await.unwrap_err();
        assert!(matches!(error, CompactionError::InvalidParams(_)));
    }

    #[tokio::test]
    async fn compaction_returns_failed_outcome_when_summary_stream_is_empty() {
        let (app, session_id) = make_test_app(Arc::new(ScriptedBackend {
            outputs: vec![],
            backend_handle: None,
        }));
        app.db.add_message(session_id, "user", "hello").unwrap();

        let outcome = compact_session(&app, session_id).await.unwrap();
        assert_eq!(outcome.status, CompactionStatus::Failed);
        assert!(outcome.before_tokens.is_some());
        assert!(outcome.error_message.is_some());
    }
}
