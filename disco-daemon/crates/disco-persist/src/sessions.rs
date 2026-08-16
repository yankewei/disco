use anyhow::{Context, Result};
use disco_protocol::types::{ProviderId, Session, Vendor};
use uuid::Uuid;

use crate::Database;

impl Database {
    /// Create a new session for the given project.
    pub fn create_session(
        &self,
        project_id: Uuid,
        provider_id: ProviderId,
        vendor: Vendor,
        model: &str,
        title: Option<&str>,
    ) -> Result<Session> {
        let id = Uuid::new_v4();
        let now = Self::now_iso8601();
        let vendor_str = serde_json::to_string(&vendor)
            .context("Failed to serialize vendor")?
            .trim_matches('"')
            .to_string();

        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO sessions
             (id, project_id, provider_id, vendor, model, title, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            rusqlite::params![
                id.to_string(),
                project_id.to_string(),
                provider_id.as_str(),
                vendor_str,
                model,
                title,
                &now,
                &now,
            ],
        )
        .with_context(|| "Failed to insert session".to_string())?;

        Ok(Session {
            id,
            project_id,
            provider_id,
            vendor,
            model: model.to_string(),
            title: title.map(|s| s.to_string()),
            created_at: now.clone(),
            updated_at: now,
        })
    }

    /// List sessions for a project, ordered by updated_at descending.
    pub fn list_sessions(&self, project_id: Uuid) -> Result<Vec<Session>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id, project_id, provider_id, vendor, model, title, created_at, updated_at
                 FROM sessions
                 WHERE project_id = ?1
                 ORDER BY updated_at DESC",
            )
            .context("Failed to prepare list_sessions query")?;

        let rows = stmt
            .query_map(rusqlite::params![project_id.to_string()], |row| {
                let id_str: String = row.get(0)?;
                let pid_str: String = row.get(1)?;
                let provider_id = ProviderId::new(row.get::<_, String>(2)?);
                let vendor_str: String = row.get(3)?;
                let vendor: Vendor =
                    serde_json::from_str(&format!("\"{vendor_str}\"")).unwrap_or(Vendor::Openai);
                Ok(Session {
                    id: Uuid::parse_str(&id_str).unwrap_or(Uuid::nil()),
                    project_id: Uuid::parse_str(&pid_str).unwrap_or(Uuid::nil()),
                    provider_id,
                    vendor,
                    model: row.get(4)?,
                    title: row.get(5)?,
                    created_at: row.get(6)?,
                    updated_at: row.get(7)?,
                })
            })
            .context("Failed to query sessions")?;

        let mut sessions = Vec::new();
        for row in rows {
            sessions.push(row.context("Failed to read session row")?);
        }
        Ok(sessions)
    }

    /// Get a single session by ID.
    pub fn get_session(&self, session_id: Uuid) -> Result<Option<Session>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id, project_id, provider_id, vendor, model, title, created_at, updated_at
                 FROM sessions
                 WHERE id = ?1",
            )
            .context("Failed to prepare get_session query")?;

        let mut rows = stmt
            .query_map(rusqlite::params![session_id.to_string()], |row| {
                let id_str: String = row.get(0)?;
                let pid_str: String = row.get(1)?;
                let provider_id = ProviderId::new(row.get::<_, String>(2)?);
                let vendor_str: String = row.get(3)?;
                let vendor: Vendor =
                    serde_json::from_str(&format!("\"{vendor_str}\"")).unwrap_or(Vendor::Openai);
                Ok(Session {
                    id: Uuid::parse_str(&id_str).unwrap_or(Uuid::nil()),
                    project_id: Uuid::parse_str(&pid_str).unwrap_or(Uuid::nil()),
                    provider_id,
                    vendor,
                    model: row.get(4)?,
                    title: row.get(5)?,
                    created_at: row.get(6)?,
                    updated_at: row.get(7)?,
                })
            })
            .context("Failed to query session")?;

        match rows.next() {
            Some(Ok(session)) => Ok(Some(session)),
            Some(Err(e)) => Err(e.into()),
            None => Ok(None),
        }
    }

    /// 读取后端持有的原生会话句柄。该值只在 daemon 内部使用，不进入 App 协议 DTO。
    pub fn get_session_backend_handle(&self, session_id: Uuid) -> Result<Option<String>> {
        let conn = self.conn.lock().unwrap();
        let mut statement = conn
            .prepare("SELECT backend_handle FROM sessions WHERE id = ?1")
            .context("Failed to prepare backend handle query")?;
        let mut rows = statement
            .query(rusqlite::params![session_id.to_string()])
            .context("Failed to query backend handle")?;
        match rows.next().context("Failed to read backend handle row")? {
            Some(row) => row.get(0).context("Failed to decode backend handle"),
            None => Ok(None),
        }
    }

    /// 保存后端为 Disco 会话分配的不透明恢复句柄。
    pub fn set_session_backend_handle(&self, session_id: Uuid, handle: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let updated = conn
            .execute(
                "UPDATE sessions SET backend_handle = ?1, updated_at = ?2 WHERE id = ?3",
                rusqlite::params![handle, Self::now_iso8601(), session_id.to_string()],
            )
            .context("Failed to update backend handle")?;
        if updated == 0 {
            anyhow::bail!("会话 {session_id} 不存在");
        }
        Ok(())
    }

    /// Delete a session and all its messages.
    pub fn delete_session(&self, session_id: Uuid) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        // Delete messages first (foreign key)
        conn.execute(
            "DELETE FROM messages WHERE session_id = ?1",
            rusqlite::params![session_id.to_string()],
        )
        .context("Failed to delete messages for session")?;

        conn.execute(
            "DELETE FROM sessions WHERE id = ?1",
            rusqlite::params![session_id.to_string()],
        )
        .context("Failed to delete session")?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Database;

    fn temp_db() -> Database {
        let dir = std::env::temp_dir().join(format!("disco-test-{}", Uuid::new_v4()));
        Database::open(&dir.join("test.db")).unwrap()
    }

    #[test]
    fn create_and_list_sessions() {
        let db = temp_db();
        let project = db.create_project("Test", "/tmp/test").unwrap();
        let s1 = db
            .create_session(
                project.id,
                ProviderId::legacy_default_for_vendor(Vendor::Openai),
                Vendor::Openai,
                "gpt-4",
                Some("Chat 1"),
            )
            .unwrap();
        let _s2 = db
            .create_session(
                project.id,
                ProviderId::legacy_default_for_vendor(Vendor::Deepseek),
                Vendor::Deepseek,
                "deepseek-chat",
                None,
            )
            .unwrap();

        let sessions = db.list_sessions(project.id).unwrap();
        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].id, s1.id);
        assert_eq!(sessions[0].provider_id.as_str(), "openai_api");
        assert_eq!(sessions[0].vendor, Vendor::Openai);
    }

    #[test]
    fn delete_session_cascades_messages() {
        let db = temp_db();
        let project = db.create_project("Test", "/tmp/test2").unwrap();
        let session = db
            .create_session(
                project.id,
                ProviderId::legacy_default_for_vendor(Vendor::Openai),
                Vendor::Openai,
                "gpt-4",
                None,
            )
            .unwrap();

        db.add_message(session.id, "user", "hello").unwrap();
        db.add_message(session.id, "assistant", "hi").unwrap();

        db.delete_session(session.id).unwrap();

        let sessions = db.list_sessions(project.id).unwrap();
        assert!(sessions.is_empty());

        // Messages should also be gone
        let messages = db.list_messages(session.id).unwrap();
        assert!(messages.is_empty());
    }

    #[test]
    fn backend_handle_is_internal_and_persists_for_resume() {
        let db = temp_db();
        let project = db.create_project("Test", "/tmp/backend-handle").unwrap();
        let session = db
            .create_session(
                project.id,
                ProviderId::new(ProviderId::CODEX_APP_SERVER),
                Vendor::Codex,
                "gpt-5-codex",
                None,
            )
            .unwrap();

        assert_eq!(db.get_session_backend_handle(session.id).unwrap(), None);
        db.set_session_backend_handle(session.id, "thread-123")
            .unwrap();
        assert_eq!(
            db.get_session_backend_handle(session.id)
                .unwrap()
                .as_deref(),
            Some("thread-123")
        );

        let serialized = serde_json::to_value(db.get_session(session.id).unwrap()).unwrap();
        assert!(serialized.get("backend_handle").is_none());
    }
}
