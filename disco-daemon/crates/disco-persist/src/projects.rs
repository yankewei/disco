use anyhow::{Context, Result};
use disco_protocol::types::Project;
use uuid::Uuid;

use crate::Database;

impl Database {
    /// Create a new project and persist it.
    pub fn create_project(&self, name: &str, path: &str) -> Result<Project> {
        let id = Uuid::new_v4();
        let created_at = Self::now_iso8601();

        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO projects (id, name, path, created_at) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![id.to_string(), name, path, &created_at],
        )
        .with_context(|| format!("Failed to insert project '{name}'"))?;

        Ok(Project {
            id,
            name: name.to_string(),
            path: path.to_string(),
            created_at,
        })
    }

    /// Get a single project by ID.
    pub fn get_project(&self, project_id: Uuid) -> Result<Option<Project>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT id, name, path, created_at FROM projects WHERE id = ?1")
            .context("Failed to prepare get_project query")?;

        let mut rows = stmt
            .query_map(rusqlite::params![project_id.to_string()], |row| {
                let id_str: String = row.get(0)?;
                Ok(Project {
                    id: Uuid::parse_str(&id_str).unwrap_or(Uuid::nil()),
                    name: row.get(1)?,
                    path: row.get(2)?,
                    created_at: row.get(3)?,
                })
            })
            .context("Failed to query project")?;

        match rows.next() {
            Some(Ok(project)) => Ok(Some(project)),
            Some(Err(e)) => Err(e.into()),
            None => Ok(None),
        }
    }

    /// List all projects ordered by creation date (newest first).
    pub fn list_projects(&self) -> Result<Vec<Project>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT id, name, path, created_at FROM projects ORDER BY created_at DESC")
            .context("Failed to prepare list_projects query")?;

        let rows = stmt
            .query_map([], |row| {
                let id_str: String = row.get(0)?;
                Ok(Project {
                    id: Uuid::parse_str(&id_str).unwrap_or(Uuid::nil()),
                    name: row.get(1)?,
                    path: row.get(2)?,
                    created_at: row.get(3)?,
                })
            })
            .context("Failed to query projects")?;

        let mut projects = Vec::new();
        for row in rows {
            projects.push(row.context("Failed to read project row")?);
        }
        Ok(projects)
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
    fn create_and_list_projects() {
        let db = temp_db();
        let p1 = db.create_project("Project A", "/tmp/a").unwrap();
        let p2 = db.create_project("Project B", "/tmp/b").unwrap();

        let projects = db.list_projects().unwrap();
        assert_eq!(projects.len(), 2);
        // Both projects should be present (order may vary if timestamps are identical)
        let names: Vec<&str> = projects.iter().map(|p| p.name.as_str()).collect();
        assert!(names.contains(&"Project A"));
        assert!(names.contains(&"Project B"));
        let ids: Vec<uuid::Uuid> = projects.iter().map(|p| p.id).collect();
        assert!(ids.contains(&p1.id));
        assert!(ids.contains(&p2.id));
    }

    #[test]
    fn duplicate_path_fails() {
        let db = temp_db();
        db.create_project("P1", "/tmp/same").unwrap();
        let result = db.create_project("P2", "/tmp/same");
        assert!(result.is_err());
    }
}
