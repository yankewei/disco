use anyhow::{Context, Result};
use uuid::Uuid;

use crate::Database;

/// Rig 本地上下文压缩后的摘要 checkpoint。原始消息仍保留在 messages 表中。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredContextCheckpoint {
    pub session_id: Uuid,
    pub checkpoint_id: String,
    pub boundary_message_id: Uuid,
    pub summary: String,
    pub created_at: String,
}

impl Database {
    /// 保存会话最新 checkpoint；旧 checkpoint 只作为派生缓存被替换。
    pub fn save_context_checkpoint(
        &self,
        session_id: Uuid,
        boundary_message_id: Uuid,
        summary: &str,
    ) -> Result<StoredContextCheckpoint> {
        let checkpoint = StoredContextCheckpoint {
            session_id,
            checkpoint_id: Uuid::new_v4().to_string(),
            boundary_message_id,
            summary: summary.to_string(),
            created_at: Self::now_iso8601(),
        };
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO context_checkpoints
             (session_id, checkpoint_id, boundary_message_id, summary, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(session_id) DO UPDATE SET
                checkpoint_id = excluded.checkpoint_id,
                boundary_message_id = excluded.boundary_message_id,
                summary = excluded.summary,
                created_at = excluded.created_at",
            rusqlite::params![
                session_id.to_string(),
                checkpoint.checkpoint_id,
                boundary_message_id.to_string(),
                summary,
                checkpoint.created_at,
            ],
        )
        .context("Failed to save context checkpoint")?;
        Ok(checkpoint)
    }

    /// 读取会话最新的本地上下文 checkpoint。
    pub fn get_context_checkpoint(
        &self,
        session_id: Uuid,
    ) -> Result<Option<StoredContextCheckpoint>> {
        let conn = self.conn.lock().unwrap();
        let mut statement = conn
            .prepare(
                "SELECT checkpoint_id, boundary_message_id, summary, created_at
                 FROM context_checkpoints WHERE session_id = ?1",
            )
            .context("Failed to prepare context checkpoint query")?;
        let mut rows = statement
            .query(rusqlite::params![session_id.to_string()])
            .context("Failed to query context checkpoint")?;
        let Some(row) = rows.next().context("Failed to read context checkpoint")? else {
            return Ok(None);
        };
        let checkpoint_id: String = row.get(0)?;
        let boundary_message_id = Uuid::parse_str(&row.get::<_, String>(1)?)
            .context("Invalid context checkpoint boundary message ID")?;
        Ok(Some(StoredContextCheckpoint {
            session_id,
            checkpoint_id,
            boundary_message_id,
            summary: row.get(2)?,
            created_at: row.get(3)?,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use disco_protocol::types::{ProviderId, Vendor};

    #[test]
    fn checkpoint_round_trips_and_replaces_previous_value() {
        let directory = std::env::temp_dir().join(format!("disco-checkpoint-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("test.db");
        let db = Database::open(&path).unwrap();
        let project = db.create_project("Test", "/tmp/disco-checkpoint").unwrap();
        let session = db
            .create_session(
                project.id,
                ProviderId::legacy_default_for_vendor(Vendor::Openai),
                Vendor::Openai,
                "model",
                None,
            )
            .unwrap();
        let boundary = db.add_message(session.id, "user", "hello").unwrap();

        let first = db
            .save_context_checkpoint(session.id, boundary.id, "first")
            .unwrap();
        let second = db
            .save_context_checkpoint(session.id, boundary.id, "second")
            .unwrap();

        assert_ne!(first.checkpoint_id, second.checkpoint_id);
        assert_eq!(
            db.get_context_checkpoint(session.id)
                .unwrap()
                .unwrap()
                .summary,
            "second"
        );
    }
}
