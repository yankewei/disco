use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::Database;

/// A persisted chat message.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StoredMessage {
    pub id: Uuid,
    pub session_id: Uuid,
    pub role: String,
    pub text: String,
    pub created_at: String,
}

impl Database {
    /// Add a message to a session.
    pub fn add_message(&self, session_id: Uuid, role: &str, text: &str) -> Result<StoredMessage> {
        let id = Uuid::new_v4();
        let created_at = Self::now_iso8601();

        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO messages (id, session_id, role, text, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![
                id.to_string(),
                session_id.to_string(),
                role,
                text,
                &created_at,
            ],
        )
        .with_context(|| "Failed to insert message".to_string())?;

        // Update session's updated_at
        let now = Self::now_iso8601();
        conn.execute(
            "UPDATE sessions SET updated_at = ?1 WHERE id = ?2",
            rusqlite::params![&now, session_id.to_string()],
        )
        .context("Failed to update session timestamp")?;

        Ok(StoredMessage {
            id,
            session_id,
            role: role.to_string(),
            text: text.to_string(),
            created_at,
        })
    }

    /// List messages for a session, ordered by creation time.
    pub fn list_messages(&self, session_id: Uuid) -> Result<Vec<StoredMessage>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id, session_id, role, text, created_at
                 FROM messages
                 WHERE session_id = ?1
                 ORDER BY created_at ASC",
            )
            .context("Failed to prepare list_messages query")?;

        let rows = stmt
            .query_map(rusqlite::params![session_id.to_string()], |row| {
                let id_str: String = row.get(0)?;
                let sid_str: String = row.get(1)?;
                Ok(StoredMessage {
                    id: Uuid::parse_str(&id_str).unwrap_or(Uuid::nil()),
                    session_id: Uuid::parse_str(&sid_str).unwrap_or(Uuid::nil()),
                    role: row.get(2)?,
                    text: row.get(3)?,
                    created_at: row.get(4)?,
                })
            })
            .context("Failed to query messages")?;

        let mut messages = Vec::new();
        for row in rows {
            messages.push(row.context("Failed to read message row")?);
        }
        Ok(messages)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Database;
    use disco_protocol::types::Vendor;

    fn temp_db() -> Database {
        let dir = std::env::temp_dir().join(format!("disco-test-{}", Uuid::new_v4()));
        Database::open(&dir.join("test.db")).unwrap()
    }

    #[test]
    fn add_and_list_messages() {
        let db = temp_db();
        let project = db.create_project("Test", "/tmp/test-msg").unwrap();
        let session = db
            .create_session(project.id, Vendor::Openai, "gpt-4", None)
            .unwrap();

        db.add_message(session.id, "user", "hello").unwrap();
        db.add_message(session.id, "assistant", "hi there").unwrap();
        db.add_message(session.id, "user", "how are you?").unwrap();

        let messages = db.list_messages(session.id).unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[0].role, "user");
        assert_eq!(messages[0].text, "hello");
        assert_eq!(messages[1].role, "assistant");
        assert_eq!(messages[1].text, "hi there");
        assert_eq!(messages[2].role, "user");
        assert_eq!(messages[2].text, "how are you?");
    }

    #[test]
    fn invalid_role_rejected() {
        let db = temp_db();
        let project = db.create_project("Test", "/tmp/test-role").unwrap();
        let session = db
            .create_session(project.id, Vendor::Openai, "gpt-4", None)
            .unwrap();

        let result = db.add_message(session.id, "system", "not allowed");
        assert!(result.is_err());
    }

    #[test]
    fn messages_ordered_by_creation() {
        let db = temp_db();
        let project = db.create_project("Test", "/tmp/test-order").unwrap();
        let session = db
            .create_session(project.id, Vendor::Openai, "gpt-4", None)
            .unwrap();

        for i in 0..5 {
            db.add_message(session.id, "user", &format!("msg {i}")).unwrap();
        }

        let messages = db.list_messages(session.id).unwrap();
        for (i, msg) in messages.iter().enumerate() {
            assert_eq!(msg.text, format!("msg {i}"));
        }
    }
}
