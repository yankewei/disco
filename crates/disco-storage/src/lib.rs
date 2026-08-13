//! SQLite-backed event journal.

use disco_domain::{Project, RunEvent, RunId};
use disco_kernel::{EventJournal, JournalError, ProjectStore, ProjectStoreError};
use rusqlite::{Connection, OptionalExtension, params};
use rusqlite_migration::{M, Migrations};
use std::path::Path;
use std::sync::Mutex;
use thiserror::Error;

fn migrations() -> Migrations<'static> {
    Migrations::new(vec![
        M::up(
            "CREATE TABLE run_events (
            event_id TEXT PRIMARY KEY NOT NULL,
            run_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            occurred_at TEXT NOT NULL,
            event_json TEXT NOT NULL,
            UNIQUE(run_id, sequence)
        );
        CREATE INDEX run_events_by_run ON run_events(run_id, sequence);",
        ),
        M::up(
            "CREATE TABLE projects (
                project_id TEXT PRIMARY KEY NOT NULL,
                root_path TEXT NOT NULL UNIQUE,
                last_opened_at TEXT NOT NULL,
                project_json TEXT NOT NULL
            );
            CREATE INDEX projects_by_last_opened ON projects(last_opened_at DESC);",
        ),
    ])
}

pub struct SqliteJournal {
    connection: Mutex<Connection>,
}

impl SqliteJournal {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, StorageError> {
        Self::from_connection(Connection::open(path)?)
    }

    pub fn open_in_memory() -> Result<Self, StorageError> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(mut connection: Connection) -> Result<Self, StorageError> {
        Self::configure(&mut connection)?;
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }

    fn configure(connection: &mut Connection) -> Result<(), StorageError> {
        connection.pragma_update(None, "foreign_keys", true)?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "busy_timeout", 5_000_i64)?;
        migrations().to_latest(connection)?;
        Ok(())
    }

    fn append_event(&self, event: &RunEvent) -> Result<(), StorageError> {
        let event_json = serde_json::to_string(event)?;
        let sequence = i64::try_from(event.sequence)
            .map_err(|_| StorageError::SequenceTooLarge(event.sequence))?;
        let connection = self.connection.lock().map_err(|_| StorageError::Poisoned)?;
        connection.execute(
            "INSERT INTO run_events(event_id, run_id, sequence, occurred_at, event_json)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                event.id.to_string(),
                event.run_id.to_string(),
                sequence,
                event.occurred_at.to_rfc3339(),
                event_json,
            ],
        )?;
        Ok(())
    }

    fn load_events(&self, run_id: RunId) -> Result<Vec<RunEvent>, StorageError> {
        let connection = self.connection.lock().map_err(|_| StorageError::Poisoned)?;
        let mut statement = connection
            .prepare("SELECT event_json FROM run_events WHERE run_id = ?1 ORDER BY sequence ASC")?;
        let rows = statement.query_map([run_id.to_string()], |row| row.get::<_, String>(0))?;
        let mut events = Vec::new();
        for row in rows {
            events.push(serde_json::from_str(&row?)?);
        }
        Ok(events)
    }
}

impl EventJournal for SqliteJournal {
    fn append(&self, event: &RunEvent) -> Result<(), JournalError> {
        self.append_event(event)
            .map_err(|error| JournalError::new(error.to_string()))
    }

    fn load_run(&self, run_id: RunId) -> Result<Vec<RunEvent>, JournalError> {
        self.load_events(run_id)
            .map_err(|error| JournalError::new(error.to_string()))
    }

    fn list_run_ids(&self) -> Result<Vec<RunId>, JournalError> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| JournalError::new("database lock was poisoned"))?;
        let mut statement = connection
            .prepare(
                "SELECT run_id FROM run_events GROUP BY run_id ORDER BY MIN(occurred_at), run_id",
            )
            .map_err(|error| JournalError::new(error.to_string()))?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|error| JournalError::new(error.to_string()))?;
        let mut run_ids = Vec::new();
        for row in rows {
            let run_id = row.map_err(|error| JournalError::new(error.to_string()))?;
            run_ids.push(
                run_id
                    .parse::<RunId>()
                    .map_err(|error| JournalError::new(error.to_string()))?,
            );
        }
        Ok(run_ids)
    }
}

impl ProjectStore for SqliteJournal {
    fn list_projects(&self) -> Result<Vec<Project>, ProjectStoreError> {
        self.load_projects()
            .map_err(|error| ProjectStoreError::new(error.to_string()))
    }

    fn register_project(&self, project: Project) -> Result<Project, ProjectStoreError> {
        self.upsert_project(project)
            .map_err(|error| ProjectStoreError::new(error.to_string()))
    }
}

impl SqliteJournal {
    fn load_projects(&self) -> Result<Vec<Project>, StorageError> {
        let connection = self.connection.lock().map_err(|_| StorageError::Poisoned)?;
        let mut statement =
            connection.prepare("SELECT project_json FROM projects ORDER BY last_opened_at DESC")?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        let mut projects = Vec::new();
        for row in rows {
            projects.push(serde_json::from_str(&row?)?);
        }
        Ok(projects)
    }

    fn upsert_project(&self, mut project: Project) -> Result<Project, StorageError> {
        let root_path = project.root_path.to_string_lossy().into_owned();
        let connection = self.connection.lock().map_err(|_| StorageError::Poisoned)?;
        let existing = connection
            .query_row(
                "SELECT project_json FROM projects WHERE root_path = ?1",
                [&root_path],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if let Some(existing) = existing {
            let existing: Project = serde_json::from_str(&existing)?;
            project.id = existing.id;
            project.created_at = existing.created_at;
        }
        let project_json = serde_json::to_string(&project)?;
        connection.execute(
            "INSERT INTO projects(project_id, root_path, last_opened_at, project_json)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(root_path) DO UPDATE SET
                last_opened_at = excluded.last_opened_at,
                project_json = excluded.project_json",
            params![
                project.id.to_string(),
                root_path,
                project.last_opened_at.to_rfc3339(),
                project_json,
            ],
        )?;
        Ok(project)
    }
}

#[derive(Debug, Error)]
pub enum StorageError {
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error(transparent)]
    Migration(#[from] rusqlite_migration::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("database lock was poisoned")]
    Poisoned,
    #[error("event sequence {0} exceeds SQLite's signed integer range")]
    SequenceTooLarge(u64),
}

#[cfg(test)]
mod tests {
    use super::*;
    use disco_domain::{EngineKind, ProjectId, RunEventPayload, SessionId};
    use std::path::PathBuf;

    #[test]
    fn journal_round_trips_ordered_events() {
        let journal = SqliteJournal::open_in_memory().expect("journal should open");
        let run_id = RunId::new();
        let started = RunEvent::new(
            run_id,
            0,
            RunEventPayload::RunStarted {
                project_id: Some(ProjectId::new()),
                session_id: SessionId::new(),
                engine: EngineKind::Rig,
                workspace: Some("/tmp/project".into()),
                prompt: "Inspect the project".into(),
            },
        );
        let completed = RunEvent::new(run_id, 1, RunEventPayload::RunCompleted);

        journal.append(&started).expect("start should persist");
        journal
            .append(&completed)
            .expect("completion should persist");

        assert_eq!(
            journal.load_run(run_id).expect("events should load"),
            vec![started, completed]
        );
        assert_eq!(
            journal.list_run_ids().expect("run ids should load"),
            vec![run_id]
        );
    }

    #[test]
    fn journal_rejects_duplicate_sequence_numbers() {
        let journal = SqliteJournal::open_in_memory().expect("journal should open");
        let run_id = RunId::new();
        let first = RunEvent::new(run_id, 0, RunEventPayload::RunCompleted);
        let duplicate = RunEvent::new(run_id, 0, RunEventPayload::RunCancelled);

        journal.append(&first).expect("first event should persist");
        assert!(journal.append(&duplicate).is_err());
    }

    #[test]
    fn project_catalog_reuses_identity_for_the_same_root() {
        let journal = SqliteJournal::open_in_memory().expect("journal should open");
        let root = PathBuf::from("/tmp/disco-project");
        let first = journal
            .register_project(Project::new("disco", root.clone()))
            .expect("project should register");
        let reopened = journal
            .register_project(Project::new("Disco", root))
            .expect("project should reopen");
        let projects = journal.list_projects().expect("projects should load");

        assert_eq!(reopened.id, first.id);
        assert_eq!(reopened.name, "Disco");
        assert_eq!(projects, vec![reopened]);
    }
}
