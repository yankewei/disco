use anyhow::{Context, Result};
use disco_protocol::types::{BackendResumeCursor, ProviderId, Session, Vendor};
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
        self.create_session_with_id(
            Uuid::new_v4(),
            project_id,
            provider_id,
            vendor,
            model,
            title,
        )
    }

    /// 使用调用方提供的稳定 Disco session ID 创建会话。
    pub fn create_session_with_id(
        &self,
        id: Uuid,
        project_id: Uuid,
        provider_id: ProviderId,
        vendor: Vendor,
        model: &str,
        title: Option<&str>,
    ) -> Result<Session> {
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

    /// 读取后端持有的原生会话恢复游标。
    ///
    /// 旧数据库保存的是纯字符串 handle。读取时将其按 session 的 Provider 解释；下次成功
    /// 运行写回时会自动升级为带 Provider 归属的 cursor。
    pub fn get_session_backend_resume_cursor(
        &self,
        session_id: Uuid,
        expected_provider_id: &ProviderId,
    ) -> Result<Option<BackendResumeCursor>> {
        let conn = self.conn.lock().unwrap();
        let mut statement = conn
            .prepare("SELECT provider_id, backend_handle FROM sessions WHERE id = ?1")
            .context("Failed to prepare backend resume cursor query")?;
        let mut rows = statement
            .query(rusqlite::params![session_id.to_string()])
            .context("Failed to query backend resume cursor")?;
        match rows.next().context("Failed to read backend handle row")? {
            Some(row) => {
                let stored_provider_id = ProviderId::new(row.get::<_, String>(0)?);
                if &stored_provider_id != expected_provider_id {
                    anyhow::bail!(
                        "会话 {session_id} 的 Provider {} 与恢复请求的 Provider {} 不一致",
                        stored_provider_id,
                        expected_provider_id
                    );
                }
                let stored_value: Option<String> = row.get(1)?;
                let Some(stored_value) = stored_value else {
                    return Ok(None);
                };
                match serde_json::from_str::<BackendResumeCursor>(&stored_value) {
                    Ok(cursor) => {
                        if cursor.provider_id != *expected_provider_id {
                            anyhow::bail!(
                                "会话 {session_id} 的原生恢复游标属于 Provider {}，不能由 {} 恢复",
                                cursor.provider_id,
                                expected_provider_id
                            );
                        }
                        Ok(Some(cursor))
                    }
                    Err(error) if stored_value.trim_start().starts_with('{') => {
                        anyhow::bail!("会话 {session_id} 的原生恢复游标格式无效：{error}");
                    }
                    Err(_) => Ok(Some(BackendResumeCursor {
                        provider_id: expected_provider_id.clone(),
                        handle: stored_value,
                    })),
                }
            }
            None => Ok(None),
        }
    }

    /// 保存后端为 Disco 会话分配的原生恢复游标。
    pub fn set_session_backend_resume_cursor(
        &self,
        session_id: Uuid,
        cursor: &BackendResumeCursor,
    ) -> Result<()> {
        let serialized_cursor =
            serde_json::to_string(cursor).context("Failed to serialize backend resume cursor")?;
        let conn = self.conn.lock().unwrap();
        let updated = conn
            .execute(
                "UPDATE sessions
                 SET backend_handle = ?1, updated_at = ?2
                 WHERE id = ?3 AND provider_id = ?4",
                rusqlite::params![
                    serialized_cursor,
                    Self::now_iso8601(),
                    session_id.to_string(),
                    cursor.provider_id.as_str(),
                ],
            )
            .context("Failed to update backend resume cursor")?;
        if updated == 0 {
            anyhow::bail!("会话 {session_id} 不存在，或其 Provider 与原生恢复游标不一致");
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
            "DELETE FROM context_checkpoints WHERE session_id = ?1",
            rusqlite::params![session_id.to_string()],
        )
        .context("Failed to delete context checkpoint for session")?;

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
    fn backend_resume_cursor_is_internal_and_persists_provider_ownership() {
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

        assert_eq!(
            db.get_session_backend_resume_cursor(session.id, &session.provider_id)
                .unwrap(),
            None
        );
        db.set_session_backend_resume_cursor(
            session.id,
            &BackendResumeCursor {
                provider_id: session.provider_id.clone(),
                handle: "thread-123".to_string(),
            },
        )
        .unwrap();
        assert_eq!(
            db.get_session_backend_resume_cursor(session.id, &session.provider_id)
                .unwrap(),
            Some(BackendResumeCursor {
                provider_id: session.provider_id.clone(),
                handle: "thread-123".to_string(),
            })
        );

        let serialized = serde_json::to_value(db.get_session(session.id).unwrap()).unwrap();
        assert!(serialized.get("backend_handle").is_none());
    }

    #[test]
    fn legacy_handle_is_read_as_the_session_provider_cursor() {
        let db = temp_db();
        let project = db
            .create_project("Test", "/tmp/legacy-backend-handle")
            .unwrap();
        let session = db
            .create_session(
                project.id,
                ProviderId::new(ProviderId::CODEX_APP_SERVER),
                Vendor::Codex,
                "gpt-5-codex",
                None,
            )
            .unwrap();
        db.conn
            .lock()
            .unwrap()
            .execute(
                "UPDATE sessions SET backend_handle = ?1 WHERE id = ?2",
                rusqlite::params!["legacy-thread", session.id.to_string()],
            )
            .unwrap();

        assert_eq!(
            db.get_session_backend_resume_cursor(session.id, &session.provider_id)
                .unwrap(),
            Some(BackendResumeCursor {
                provider_id: session.provider_id,
                handle: "legacy-thread".to_string(),
            })
        );
    }

    #[test]
    fn resume_cursor_from_another_provider_is_rejected() {
        let db = temp_db();
        let project = db
            .create_project("Test", "/tmp/mismatched-backend-cursor")
            .unwrap();
        let session = db
            .create_session(
                project.id,
                ProviderId::new(ProviderId::CODEX_APP_SERVER),
                Vendor::Codex,
                "gpt-5-codex",
                None,
            )
            .unwrap();
        let mismatched_cursor = serde_json::to_string(&BackendResumeCursor {
            provider_id: ProviderId::new(ProviderId::CLAUDE_CODE),
            handle: "claude-session".to_string(),
        })
        .unwrap();
        db.conn
            .lock()
            .unwrap()
            .execute(
                "UPDATE sessions SET backend_handle = ?1 WHERE id = ?2",
                rusqlite::params![mismatched_cursor, session.id.to_string()],
            )
            .unwrap();

        let error = db
            .get_session_backend_resume_cursor(session.id, &session.provider_id)
            .unwrap_err();
        assert!(error.to_string().contains("不能由"));
    }

    #[test]
    fn malformed_serialized_resume_cursor_is_rejected() {
        let db = temp_db();
        let project = db
            .create_project("Test", "/tmp/malformed-backend-cursor")
            .unwrap();
        let session = db
            .create_session(
                project.id,
                ProviderId::new(ProviderId::CODEX_APP_SERVER),
                Vendor::Codex,
                "gpt-5-codex",
                None,
            )
            .unwrap();
        db.conn
            .lock()
            .unwrap()
            .execute(
                "UPDATE sessions SET backend_handle = ?1 WHERE id = ?2",
                rusqlite::params!["{not-valid-json", session.id.to_string()],
            )
            .unwrap();

        let error = db
            .get_session_backend_resume_cursor(session.id, &session.provider_id)
            .unwrap_err();
        assert!(error.to_string().contains("格式无效"));
    }
}
