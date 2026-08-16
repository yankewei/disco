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
                provider_id TEXT NOT NULL,
                vendor TEXT NOT NULL,
                model TEXT NOT NULL,
                backend_handle TEXT,
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

            CREATE TABLE IF NOT EXISTS provider_profiles (
                id TEXT PRIMARY KEY,
                vendor TEXT NOT NULL,
                base_url TEXT NOT NULL,
                api_key TEXT NOT NULL,
                model TEXT NOT NULL,
                thinking_enabled INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL
            );

            INSERT OR IGNORE INTO provider_profiles
                (id, vendor, base_url, api_key, model, thinking_enabled, updated_at)
            SELECT
                CASE vendor
                    WHEN 'openai' THEN 'openai_api'
                    WHEN 'deepseek' THEN 'deepseek_api'
                    WHEN 'moonshot_kimi' THEN 'moonshot_kimi_api'
                    WHEN 'kimi_code' THEN 'kimi_code_api'
                    WHEN 'glm' THEN 'glm_api'
                    WHEN 'codex' THEN 'codex_app_server'
                END,
                vendor, base_url, api_key, model, thinking_enabled, updated_at
            FROM provider_configs;

            DELETE FROM provider_configs;
            ",
        )
        .context("Failed to create tables")?;

        let session_columns = {
            let mut statement = conn
                .prepare("PRAGMA table_info(sessions)")
                .context("Failed to inspect sessions schema")?;
            let columns = statement
                .query_map([], |row| row.get::<_, String>(1))
                .context("Failed to list sessions columns")?;
            let mut names = Vec::new();
            for column in columns {
                names.push(column.context("Failed to read sessions column")?);
            }
            names
        };

        if !session_columns.iter().any(|name| name == "provider_id") {
            conn.execute_batch(
                "
                ALTER TABLE sessions ADD COLUMN provider_id TEXT;
                UPDATE sessions
                SET provider_id = CASE vendor
                    WHEN 'openai' THEN 'openai_api'
                    WHEN 'deepseek' THEN 'deepseek_api'
                    WHEN 'moonshot_kimi' THEN 'moonshot_kimi_api'
                    WHEN 'kimi_code' THEN 'kimi_code_api'
                    WHEN 'glm' THEN 'glm_api'
                    WHEN 'codex' THEN 'codex_app_server'
                END
                WHERE provider_id IS NULL;
                ",
            )
            .context("Failed to migrate sessions provider_id")?;
        }
        if !session_columns.iter().any(|name| name == "backend_handle") {
            conn.execute_batch("ALTER TABLE sessions ADD COLUMN backend_handle TEXT;")
                .context("Failed to migrate sessions backend_handle")?;
        }
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
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('projects','sessions','messages','provider_configs','provider_profiles')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 5);
    }

    #[test]
    fn open_migrates_legacy_vendor_records_to_provider_ids() {
        let dir = std::env::temp_dir().join(format!("disco-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("legacy.db");
        let project_id = uuid::Uuid::new_v4();
        let session_id = uuid::Uuid::new_v4();

        let connection = Connection::open(&db_path).unwrap();
        connection
            .execute_batch(&format!(
                "
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    path TEXT NOT NULL UNIQUE,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE sessions (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    vendor TEXT NOT NULL,
                    model TEXT NOT NULL,
                    title TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE provider_configs (
                    vendor TEXT PRIMARY KEY,
                    base_url TEXT NOT NULL,
                    api_key TEXT NOT NULL,
                    model TEXT NOT NULL,
                    thinking_enabled INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL
                );
                INSERT INTO projects VALUES ('{project_id}', 'Test', '/tmp/legacy', '1');
                INSERT INTO sessions VALUES ('{session_id}', '{project_id}', 'codex', 'o4-mini', NULL, '1', '1');
                INSERT INTO provider_configs VALUES ('codex', '', '', 'o4-mini', 0, '1');
                "
            ))
            .unwrap();
        drop(connection);

        let db = Database::open(&db_path).unwrap();
        let session = db.get_session(session_id).unwrap().unwrap();
        assert_eq!(
            session.provider_id.as_str(),
            disco_protocol::types::ProviderId::CODEX_APP_SERVER
        );

        let configs = db.list_provider_configs().unwrap();
        assert_eq!(configs.len(), 1);
        assert_eq!(
            configs[0].provider_id.as_str(),
            disco_protocol::types::ProviderId::CODEX_APP_SERVER
        );
    }
}
