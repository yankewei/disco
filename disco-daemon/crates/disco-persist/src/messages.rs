use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::Database;

/// A persisted chat message.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StoredToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
}

/// A persisted chat message.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StoredMessage {
    pub id: Uuid,
    pub session_id: Uuid,
    pub role: String,
    pub text: String,
    #[serde(default)]
    pub reasoning: String,
    #[serde(default)]
    pub tool_calls: Vec<StoredToolCall>,
    #[serde(default)]
    pub tool_call_id: Option<String>,
    #[serde(default)]
    pub tool_name: Option<String>,
    pub created_at: String,
}

impl Database {
    /// Add a message to a session.
    pub fn add_message(&self, session_id: Uuid, role: &str, text: &str) -> Result<StoredMessage> {
        self.add_message_with_metadata(session_id, role, text, "", &[], None, None)
    }

    /// Add an assistant message with the complete reasoning/tool transcript.
    pub fn add_assistant_message(
        &self,
        session_id: Uuid,
        text: &str,
        reasoning: &str,
        tool_calls: &[StoredToolCall],
    ) -> Result<StoredMessage> {
        self.add_message_with_metadata(
            session_id,
            "assistant",
            text,
            reasoning,
            tool_calls,
            None,
            None,
        )
    }

    /// Add a tool result as a model-history message. The UI merges this record into
    /// the corresponding assistant tool call instead of displaying it as a user turn.
    pub fn add_tool_result_message(
        &self,
        session_id: Uuid,
        call_id: &str,
        tool_name: &str,
        output: &str,
    ) -> Result<StoredMessage> {
        self.add_message_with_metadata(
            session_id,
            "user",
            output,
            "",
            &[],
            Some(call_id),
            Some(tool_name),
        )
    }

    fn add_message_with_metadata(
        &self,
        session_id: Uuid,
        role: &str,
        text: &str,
        reasoning: &str,
        tool_calls: &[StoredToolCall],
        tool_call_id: Option<&str>,
        tool_name: Option<&str>,
    ) -> Result<StoredMessage> {
        let id = Uuid::new_v4();
        let created_at = Self::now_iso8601();
        let tool_calls_json = if tool_calls.is_empty() {
            None
        } else {
            Some(serde_json::to_string(tool_calls).context("Failed to encode tool calls")?)
        };

        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO messages
             (id, session_id, role, text, reasoning, tool_calls_json, tool_call_id, tool_name, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            rusqlite::params![
                id.to_string(),
                session_id.to_string(),
                role,
                text,
                reasoning,
                tool_calls_json,
                tool_call_id,
                tool_name,
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
            reasoning: reasoning.to_string(),
            tool_calls: tool_calls.to_vec(),
            tool_call_id: tool_call_id.map(str::to_string),
            tool_name: tool_name.map(str::to_string),
            created_at,
        })
    }

    /// List messages for a session, ordered by creation time.
    pub fn list_messages(&self, session_id: Uuid) -> Result<Vec<StoredMessage>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id, session_id, role, text, reasoning, tool_calls_json,
                        tool_call_id, tool_name, created_at
                 FROM messages
                 WHERE session_id = ?1
                 ORDER BY created_at ASC",
            )
            .context("Failed to prepare list_messages query")?;

        let rows = stmt
            .query_map(rusqlite::params![session_id.to_string()], |row| {
                let id_str: String = row.get(0)?;
                let sid_str: String = row.get(1)?;
                let tool_calls_json: Option<String> = row.get(5)?;
                Ok(StoredMessage {
                    id: Uuid::parse_str(&id_str).unwrap_or(Uuid::nil()),
                    session_id: Uuid::parse_str(&sid_str).unwrap_or(Uuid::nil()),
                    role: row.get(2)?,
                    text: row.get(3)?,
                    reasoning: row.get(4)?,
                    tool_calls: tool_calls_json
                        .and_then(|value| serde_json::from_str(&value).ok())
                        .unwrap_or_default(),
                    tool_call_id: row.get(6)?,
                    tool_name: row.get(7)?,
                    created_at: row.get(8)?,
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
            .create_session(
                project.id,
                disco_protocol::types::ProviderId::legacy_default_for_vendor(Vendor::Openai),
                Vendor::Openai,
                "gpt-4",
                None,
            )
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
            .create_session(
                project.id,
                disco_protocol::types::ProviderId::legacy_default_for_vendor(Vendor::Openai),
                Vendor::Openai,
                "gpt-4",
                None,
            )
            .unwrap();

        let result = db.add_message(session.id, "system", "not allowed");
        assert!(result.is_err());
    }

    #[test]
    fn messages_ordered_by_creation() {
        let db = temp_db();
        let project = db.create_project("Test", "/tmp/test-order").unwrap();
        let session = db
            .create_session(
                project.id,
                disco_protocol::types::ProviderId::legacy_default_for_vendor(Vendor::Openai),
                Vendor::Openai,
                "gpt-4",
                None,
            )
            .unwrap();

        for i in 0..5 {
            db.add_message(session.id, "user", &format!("msg {i}"))
                .unwrap();
        }

        let messages = db.list_messages(session.id).unwrap();
        for (i, msg) in messages.iter().enumerate() {
            assert_eq!(msg.text, format!("msg {i}"));
        }
    }

    #[test]
    fn rich_assistant_transcript_round_trips() {
        let db = temp_db();
        let project = db.create_project("Test", "/tmp/test-rich-message").unwrap();
        let session = db
            .create_session(
                project.id,
                disco_protocol::types::ProviderId::new("opencode_app_server"),
                Vendor::OpenCode,
                "model",
                None,
            )
            .unwrap();

        let tool_call = StoredToolCall {
            id: "call-1".to_string(),
            name: "shell".to_string(),
            arguments: r#"{"command":"pwd"}"#.to_string(),
            status: "completed".to_string(),
            output: Some("/tmp/disco".to_string()),
        };
        db.add_assistant_message(session.id, "完成", "先检查目录", &[tool_call.clone()])
            .unwrap();
        db.add_tool_result_message(session.id, &tool_call.id, &tool_call.name, "/tmp/disco")
            .unwrap();

        let messages = db.list_messages(session.id).unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].reasoning, "先检查目录");
        assert_eq!(messages[0].tool_calls, vec![tool_call]);
        assert_eq!(messages[1].tool_call_id.as_deref(), Some("call-1"));
        assert_eq!(messages[1].text, "/tmp/disco");
    }
}
