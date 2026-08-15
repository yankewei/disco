#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{Context, Result};
use rusqlite::Connection;
use tracing::debug;

pub mod auth;
pub mod messages;
pub mod projects;
pub mod provider_configs;
pub mod sessions;

/// SQLite-backed persistence layer for Disco.
///
/// Uses WAL mode for better concurrent read performance.
/// The inner `Connection` is protected by a `std::sync::Mutex` so the
/// `Database` can be shared across async tasks via `Arc<Database>`.
pub struct Database {
    conn: Mutex<Connection>,
    pub path: PathBuf,
}

impl Database {
    /// Open (or create) the database at the given path.
    /// Tables are created automatically.
    pub fn open(db_path: &Path) -> Result<Self> {
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("Failed to create directory {}", parent.display()))?;
            // 目录内保存明文 API Key（provider_configs），仅允许当前用户访问。
            #[cfg(unix)]
            std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700)).with_context(
                || format!("Failed to set directory permissions {}", parent.display()),
            )?;
        }

        debug!("Opening database at {}", db_path.display());
        let conn = Connection::open(db_path)
            .with_context(|| format!("Failed to open SQLite at {}", db_path.display()))?;
        // 与客户端 auth.json（0600）的凭据权限约定保持一致。
        #[cfg(unix)]
        std::fs::set_permissions(db_path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("Failed to set database permissions {}", db_path.display()))?;

        // Enable WAL mode for better concurrent read performance
        conn.execute_batch("PRAGMA journal_mode=WAL;")
            .context("Failed to set WAL mode")?;

        let db = Self {
            conn: Mutex::new(conn),
            path: db_path.to_path_buf(),
        };
        db.init_tables()?;
        Ok(db)
    }

    fn init_tables(&self) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL REFERENCES projects(id),
                vendor TEXT NOT NULL,
                model TEXT NOT NULL,
                title TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id),
                role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
                text TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS provider_configs (
                vendor TEXT PRIMARY KEY,
                base_url TEXT NOT NULL,
                api_key TEXT NOT NULL,
                model TEXT NOT NULL,
                thinking_enabled INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL
            );
            ",
        )
        .context("Failed to create tables")?;
        Ok(())
    }

    /// Helper: get the current UTC timestamp as ISO 8601.
    pub fn now_iso8601() -> String {
        // Use a simple approach without chrono dependency
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            .to_string()
    }
}

/// Return the default database path: ~/Library/Application Support/disco/disco.db
pub fn default_db_path() -> PathBuf {
    let home = std::env::var("HOME").expect("HOME environment variable not set");
    PathBuf::from(home)
        .join("Library/Application Support/disco")
        .join("disco.db")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_creates_tables() {
        let dir = std::env::temp_dir().join(format!("disco-test-{}", uuid::Uuid::new_v4()));
        let db_path = dir.join("test.db");
        let db = Database::open(&db_path).unwrap();

        // Verify tables exist by running a query
        let conn = db.conn.lock().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('projects','sessions','messages','provider_configs')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 4);
    }
}
