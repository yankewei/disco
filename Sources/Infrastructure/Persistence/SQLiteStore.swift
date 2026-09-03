import Foundation
import SQLite3

final class SQLiteStore {
    private let databaseLock = NSRecursiveLock()
    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) != SQLITE_OK {
            let message = databaseErrorMessage
            sqlite3_close(database)
            database = nil
            throw SQLiteStoreError.openFailed(message)
        }
        try execute("PRAGMA journal_mode = WAL;")
        try createSchema()
    }

    deinit {
        close()
    }

    func close() {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        guard let database else { return }
        sqlite3_close(database)
        self.database = nil
    }

    func listProjects() throws -> [ProjectInfo] {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            "SELECT project_id, name, project_path, created_at, activated_at FROM projects ORDER BY activated_at DESC, created_at DESC"
        )
        defer { sqlite3_finalize(statement) }
        var projects: [ProjectInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            projects.append(
                ProjectInfo(
                    projectID: text(statement, column: 0),
                    name: text(statement, column: 1),
                    projectPath: text(statement, column: 2),
                    createdAt: text(statement, column: 3),
                    activatedAt: nullableText(statement, column: 4)
                )
            )
        }
        try throwIfStepFailed(statement)
        return projects
    }

    func project(id: String) throws -> ProjectInfo? {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            "SELECT project_id, name, project_path, created_at, activated_at FROM projects WHERE project_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            try throwIfStepFailed(statement)
            return nil
        }
        return ProjectInfo(
            projectID: text(statement, column: 0),
            name: text(statement, column: 1),
            projectPath: text(statement, column: 2),
            createdAt: text(statement, column: 3),
            activatedAt: nullableText(statement, column: 4)
        )
    }

    func project(projectPath: String) throws -> ProjectInfo? {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            "SELECT project_id, name, project_path, created_at, activated_at FROM projects WHERE project_path = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(projectPath, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            try throwIfStepFailed(statement)
            return nil
        }
        return ProjectInfo(
            projectID: text(statement, column: 0),
            name: text(statement, column: 1),
            projectPath: text(statement, column: 2),
            createdAt: text(statement, column: 3),
            activatedAt: nullableText(statement, column: 4)
        )
    }

    func createProject(_ project: ProjectInfo) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            "INSERT INTO projects (project_id, name, project_path, created_at, activated_at) VALUES (?, ?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(project.projectID, at: 1, in: statement)
        try bind(project.name, at: 2, in: statement)
        try bind(project.projectPath, at: 3, in: statement)
        try bind(project.createdAt, at: 4, in: statement)
        try bind(project.activatedAt, at: 5, in: statement)
        try step(statement)
    }

    func touchProject(projectID: String) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare("UPDATE projects SET activated_at = ? WHERE project_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(.timestamp(), at: 1, in: statement)
        try bind(projectID, at: 2, in: statement)
        try step(statement)
    }

    func listSessions(projectID: String) throws -> [SessionInfo] {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            """
            SELECT session_id, project_id, agent, model_id, reasoning_effort,
                   sandbox_mode, agent_thread_id, title, created_at, activated_at
            FROM sessions
            WHERE project_id = ?
            ORDER BY activated_at DESC, created_at DESC, rowid DESC
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(projectID, at: 1, in: statement)
        var sessions: [SessionInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let session = session(from: statement) {
                sessions.append(session)
            }
        }
        try throwIfStepFailed(statement)
        return sessions
    }

    func session(id: String) throws -> SessionInfo? {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            """
            SELECT session_id, project_id, agent, model_id, reasoning_effort,
                   sandbox_mode, agent_thread_id, title, created_at, activated_at
            FROM sessions
            WHERE session_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            try throwIfStepFailed(statement)
            return nil
        }
        return session(from: statement)
    }

    func createSession(_ session: SessionInfo) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            """
            INSERT INTO sessions (
                session_id, project_id, agent, model_id, reasoning_effort,
                sandbox_mode, agent_thread_id, title, created_at, activated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(session.sessionID, at: 1, in: statement)
        try bind(session.projectID, at: 2, in: statement)
        try bind(session.agent.rawValue, at: 3, in: statement)
        try bind(session.modelID, at: 4, in: statement)
        try bind(session.reasoningEffort?.rawValue, at: 5, in: statement)
        try bind(session.sandboxMode?.rawValue, at: 6, in: statement)
        try bind(session.agentThreadID, at: 7, in: statement)
        try bind(session.title, at: 8, in: statement)
        try bind(session.createdAt, at: 9, in: statement)
        try bind(session.activatedAt, at: 10, in: statement)
        try step(statement)
    }

    func deleteSession(sessionID: String) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare("DELETE FROM sessions WHERE session_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(sessionID, at: 1, in: statement)
        try step(statement)
    }

    func deleteProject(projectID: String) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare("DELETE FROM projects WHERE project_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(projectID, at: 1, in: statement)
        try step(statement)
    }

    func updateAgentThreadID(sessionID: String, agentThreadID: String) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            "UPDATE sessions SET agent_thread_id = ?, activated_at = ? WHERE session_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(agentThreadID, at: 1, in: statement)
        try bind(.timestamp(), at: 2, in: statement)
        try bind(sessionID, at: 3, in: statement)
        try step(statement)
    }

    func updateSessionTitle(sessionID: String, title: String) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            "UPDATE sessions SET title = ? WHERE session_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(title, at: 1, in: statement)
        try bind(sessionID, at: 2, in: statement)
        try step(statement)
    }

    func touchSession(sessionID: String) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare("UPDATE sessions SET activated_at = ? WHERE session_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(.timestamp(), at: 1, in: statement)
        try bind(sessionID, at: 2, in: statement)
        try step(statement)
    }

    func loadMessages(sessionID: String) throws -> [ConversationMessage] {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            "SELECT payload_json FROM conversation_messages WHERE session_id = ? ORDER BY position ASC"
        )
        defer { sqlite3_finalize(statement) }
        try bind(sessionID, at: 1, in: statement)

        var messages: [ConversationMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let payload = text(statement, column: 0)
            guard let data = payload.data(using: .utf8) else {
                throw SQLiteStoreError.invalidData("无法读取本地消息")
            }
            do {
                messages.append(try JSONDecoder().decode(ConversationMessage.self, from: data))
            } catch {
                throw SQLiteStoreError.invalidData("本地消息格式无效：\(error.localizedDescription)")
            }
        }
        try throwIfStepFailed(statement)
        return messages
    }

    func replaceMessages(_ messages: [ConversationMessage], sessionID: String) throws {
        let payloads = try messages.enumerated().map { index, message in
            let data = try JSONEncoder().encode(message)
            guard let payload = String(data: data, encoding: .utf8) else {
                throw SQLiteStoreError.invalidData("无法编码本地消息")
            }
            return (index, message.id, payload)
        }

        databaseLock.lock()
        defer { databaseLock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let deleteStatement = try prepare(
                "DELETE FROM conversation_messages WHERE session_id = ?"
            )
            defer { sqlite3_finalize(deleteStatement) }
            try bind(sessionID, at: 1, in: deleteStatement)
            try step(deleteStatement)

            let insertStatement = try prepare(
                """
                INSERT INTO conversation_messages (
                    message_id, session_id, position, payload_json
                ) VALUES (?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(insertStatement) }
            for (index, messageID, payload) in payloads {
                sqlite3_reset(insertStatement)
                sqlite3_clear_bindings(insertStatement)
                try bind(messageID, at: 1, in: insertStatement)
                try bind(sessionID, at: 2, in: insertStatement)
                try bind(index, at: 3, in: insertStatement)
                try bind(payload, at: 4, in: insertStatement)
                try step(insertStatement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func createSchema() throws {
        try execute("PRAGMA foreign_keys = ON;")
        let projectColumns = try tableColumns(for: "projects")
        let sessionColumns = try tableColumns(for: "sessions")
        let hasLegacySchema = (!projectColumns.isEmpty && !projectColumns.contains("project_id"))
            || (!sessionColumns.isEmpty && !sessionColumns.contains("session_id"))

        if hasLegacySchema {
            try migrateLegacySchema(
                projectColumns: projectColumns,
                sessionColumns: sessionColumns
            )
        }

        try execute(
            """
            CREATE TABLE IF NOT EXISTS projects (
                project_id TEXT PRIMARY KEY,
                project_path TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                created_at TEXT NOT NULL,
                activated_at TEXT
            );
            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                agent TEXT NOT NULL,
                model_id TEXT,
                reasoning_effort TEXT,
                sandbox_mode TEXT,
                agent_thread_id TEXT,
                title TEXT NOT NULL,
                created_at TEXT NOT NULL,
                activated_at TEXT,
                FOREIGN KEY (project_id)
                    REFERENCES projects(project_id)
                    ON DELETE CASCADE,
                UNIQUE (agent, agent_thread_id)
            );
            CREATE INDEX IF NOT EXISTS sessions_project_activated_idx
                ON sessions (project_id, activated_at DESC, created_at DESC);
            CREATE TABLE IF NOT EXISTS conversation_messages (
                message_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                payload_json TEXT NOT NULL,
                FOREIGN KEY (session_id)
                    REFERENCES sessions(session_id)
                    ON DELETE CASCADE,
                UNIQUE (session_id, position)
            );
            CREATE INDEX IF NOT EXISTS conversation_messages_session_position_idx
                ON conversation_messages (session_id, position ASC);
            DROP TABLE IF EXISTS dismissed_sessions;
            PRAGMA user_version = 5;
            """
        )
        try execute("DROP TABLE IF EXISTS messages")
    }

    private func migrateLegacySchema(
        projectColumns: Set<String>,
        sessionColumns: Set<String>
    ) throws {
        if !projectColumns.isEmpty {
            try execute("ALTER TABLE projects RENAME TO projects_legacy")
        }
        if !sessionColumns.isEmpty {
            try execute("ALTER TABLE sessions RENAME TO sessions_legacy")
        }

        try execute(
            """
            CREATE TABLE projects (
                project_id TEXT PRIMARY KEY,
                project_path TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                created_at TEXT NOT NULL,
                activated_at TEXT
            );
            CREATE TABLE sessions (
                session_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                agent TEXT NOT NULL,
                model_id TEXT,
                reasoning_effort TEXT,
                sandbox_mode TEXT,
                agent_thread_id TEXT,
                title TEXT NOT NULL,
                created_at TEXT NOT NULL,
                activated_at TEXT,
                FOREIGN KEY (project_id)
                    REFERENCES projects(project_id)
                    ON DELETE CASCADE,
                UNIQUE (agent, agent_thread_id)
            );
            """
        )

        if !projectColumns.isEmpty {
            let projectID = projectColumns.contains("project_id") ? "project_id" : "id"
            let projectPath = projectColumns.contains("project_path") ? "project_path" : "path"
            let name = projectColumns.contains("name") ? "name" : projectPath
            let createdAt = projectColumns.contains("created_at") ? "created_at" : "NULL"
            let activatedAt = projectColumns.contains("activated_at") ? "activated_at" : "NULL"
            try execute(
                """
                INSERT OR IGNORE INTO projects (
                    project_id, project_path, name, created_at, activated_at
                )
                SELECT \(projectID), \(projectPath), \(name), \(createdAt), \(activatedAt)
                FROM projects_legacy
                """
            )
        }

        if !sessionColumns.isEmpty {
            let sessionID = sessionColumns.contains("session_id") ? "session_id" : "id"
            let projectID = "project_id"
            let agent = sessionColumns.contains("agent") ? "agent" : "backend"
            let modelID = sessionColumns.contains("model_id") ? "model_id" : "NULL"
            let reasoningEffort = sessionColumns.contains("reasoning_effort") ? "reasoning_effort" : "NULL"
            let sandboxMode = sessionColumns.contains("sandbox_mode") ? "sandbox_mode" : "NULL"
            let agentThreadID = sessionColumns.contains("agent_thread_id")
                ? "agent_thread_id"
                : sessionColumns.contains("backend_session_id") ? "backend_session_id" : "NULL"
            let title = sessionColumns.contains("title") ? "title" : "'新对话'"
            let createdAt = if sessionColumns.contains("created_at") {
                "created_at"
            } else if sessionColumns.contains("updated_at") {
                "updated_at"
            } else {
                "datetime('now')"
            }
            let activatedAt = if sessionColumns.contains("activated_at") {
                "activated_at"
            } else if sessionColumns.contains("updated_at") {
                "updated_at"
            } else {
                "NULL"
            }
            try execute(
                """
                INSERT OR IGNORE INTO sessions (
                    session_id, project_id, agent, model_id, reasoning_effort,
                    sandbox_mode, agent_thread_id, title, created_at, activated_at
                )
                SELECT \(sessionID), \(projectID), \(agent), \(modelID), \(reasoningEffort),
                       \(sandboxMode), \(agentThreadID), \(title), \(createdAt), \(activatedAt)
                FROM sessions_legacy
                WHERE EXISTS (
                    SELECT 1 FROM projects WHERE projects.project_id = sessions_legacy.project_id
                )
                """
            )
        }

        try execute("DROP TABLE IF EXISTS messages")
        if !projectColumns.isEmpty {
            try execute("DROP TABLE projects_legacy")
        }
        if !sessionColumns.isEmpty {
            try execute("DROP TABLE sessions_legacy")
        }
    }

    private func tableColumns(for table: String) throws -> Set<String> {
        guard try tableExists(table) else { return [] }
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(text(statement, column: 1))
        }
        try throwIfStepFailed(statement)
        return columns
    }

    private func tableExists(_ table: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(table, at: 1, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return true
        }
        try throwIfStepFailed(statement)
        return false
    }

    private func session(from statement: OpaquePointer) -> SessionInfo? {
        guard
            let agent = BackendKind(rawValue: text(statement, column: 2))
        else {
            return nil
        }
        return SessionInfo(
            sessionID: text(statement, column: 0),
            projectID: text(statement, column: 1),
            agent: agent,
            modelID: nullableText(statement, column: 3),
            reasoningEffort: nullableText(statement, column: 4).flatMap(ReasoningEffort.init(rawValue:)),
            sandboxMode: nullableText(statement, column: 5).flatMap(SandboxMode.init(rawValue:)),
            agentThreadID: nullableText(statement, column: 6),
            title: text(statement, column: 7),
            createdAt: text(statement, column: 8),
            activatedAt: nullableText(statement, column: 9)
        )
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? databaseErrorMessage
            sqlite3_free(errorMessage)
            throw SQLiteStoreError.queryFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteStoreError.queryFailed(databaseErrorMessage)
        }
        return statement
    }

    private func bind(
        _ value: String?,
        at index: Int32,
        in statement: OpaquePointer
    ) throws {
        let result: Int32 = if let value {
            sqlite3_bind_text(
                statement,
                index,
                value,
                -1,
                SQLiteTransient
            )
        } else {
            sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw SQLiteStoreError.queryFailed(databaseErrorMessage)
        }
    }

    private func bind(
        _ value: Int,
        at index: Int32,
        in statement: OpaquePointer
    ) throws {
        let result = sqlite3_bind_int64(statement, index, Int64(value))
        guard result == SQLITE_OK else {
            throw SQLiteStoreError.queryFailed(databaseErrorMessage)
        }
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.queryFailed(databaseErrorMessage)
        }
    }

    private func throwIfStepFailed(_: OpaquePointer) throws {
        let result = sqlite3_errcode(database)
        guard result == SQLITE_OK || result == SQLITE_DONE else {
            throw SQLiteStoreError.queryFailed(databaseErrorMessage)
        }
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func nullableText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column: column)
    }

    private var databaseErrorMessage: String {
        guard let database else { return "SQLite 未知错误" }
        return String(cString: sqlite3_errmsg(database))
    }
}

enum SQLiteStoreError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message):
            "无法打开本地数据库：\(message)"
        case let .queryFailed(message):
            "本地数据库操作失败：\(message)"
        case let .invalidData(message):
            message
        }
    }
}

private let SQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
