import Foundation
import SQLite3

final class SQLiteStore {
    private let databaseLock = NSRecursiveLock()
    private var database: OpaquePointer?
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

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
            "SELECT id, name, path, created_at FROM projects ORDER BY created_at DESC"
        )
        defer { sqlite3_finalize(statement) }
        var projects: [ProjectInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            projects.append(
                ProjectInfo(
                    id: text(statement, column: 0),
                    name: text(statement, column: 1),
                    path: text(statement, column: 2),
                    createdAt: text(statement, column: 3)
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
            "SELECT id, name, path, created_at FROM projects WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            try throwIfStepFailed(statement)
            return nil
        }
        return ProjectInfo(
            id: text(statement, column: 0),
            name: text(statement, column: 1),
            path: text(statement, column: 2),
            createdAt: text(statement, column: 3)
        )
    }

    func project(path: String) throws -> ProjectInfo? {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            "SELECT id, name, path, created_at FROM projects WHERE path = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(path, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            try throwIfStepFailed(statement)
            return nil
        }
        return ProjectInfo(
            id: text(statement, column: 0),
            name: text(statement, column: 1),
            path: text(statement, column: 2),
            createdAt: text(statement, column: 3)
        )
    }

    func createProject(_ project: ProjectInfo) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            "INSERT INTO projects (id, name, path, created_at) VALUES (?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(project.id, at: 1, in: statement)
        try bind(project.name, at: 2, in: statement)
        try bind(project.path, at: 3, in: statement)
        try bind(project.createdAt, at: 4, in: statement)
        try step(statement)
    }

    func listSessions(projectID: String) throws -> [SessionInfo] {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            """
            SELECT id, project_id, backend, model_id, reasoning_effort,
                   sandbox_mode, backend_session_id, title, updated_at
            FROM sessions
            WHERE project_id = ?
            ORDER BY updated_at DESC, rowid DESC
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
            SELECT id, project_id, backend, model_id, reasoning_effort,
                   sandbox_mode, backend_session_id, title, updated_at
            FROM sessions
            WHERE id = ?
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
                id, project_id, backend, model_id, reasoning_effort,
                sandbox_mode, backend_session_id, title, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(session.sessionID, at: 1, in: statement)
        try bind(session.projectID, at: 2, in: statement)
        try bind(session.backend.rawValue, at: 3, in: statement)
        try bind(session.modelID, at: 4, in: statement)
        try bind(session.reasoningEffort?.rawValue, at: 5, in: statement)
        try bind(session.sandboxMode?.rawValue, at: 6, in: statement)
        try bind(session.backendSessionID, at: 7, in: statement)
        try bind(session.title, at: 8, in: statement)
        try bind(session.updatedAt, at: 9, in: statement)
        try step(statement)
    }

    func updateBackendSessionID(sessionID: String, backendSessionID: String) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            "UPDATE sessions SET backend_session_id = ?, updated_at = ? WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(backendSessionID, at: 1, in: statement)
        try bind(.timestamp(), at: 2, in: statement)
        try bind(sessionID, at: 3, in: statement)
        try step(statement)
    }

    func updateSessionTitle(sessionID: String, title: String) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            "UPDATE sessions SET title = ? WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(title, at: 1, in: statement)
        try bind(sessionID, at: 2, in: statement)
        try step(statement)
    }

    func appendMessage(sessionID: String, message: StoredMessage) throws {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let messageStatement = try prepare(
            """
            INSERT INTO messages (
                id, session_id, role, text, reasoning, tools_json,
                items_json, timeline_json, status, error, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(messageStatement) }
        let toolsJSON = try encoded(message.toolCalls)
        let itemsJSON = try encoded(message.items)
        let timelineJSON = try encoded(message.timeline)
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try bind(message.id, at: 1, in: messageStatement)
            try bind(sessionID, at: 2, in: messageStatement)
            try bind(message.role.rawValue, at: 3, in: messageStatement)
            try bind(message.text, at: 4, in: messageStatement)
            try bind(message.reasoning, at: 5, in: messageStatement)
            try bind(toolsJSON, at: 6, in: messageStatement)
            try bind(itemsJSON, at: 7, in: messageStatement)
            try bind(timelineJSON, at: 8, in: messageStatement)
            try bind(message.status?.rawValue, at: 9, in: messageStatement)
            try bind(message.error, at: 10, in: messageStatement)
            try bind(message.createdAt, at: 11, in: messageStatement)
            try step(messageStatement)

            let updateStatement = try prepare(
                "UPDATE sessions SET updated_at = ? WHERE id = ?"
            )
            defer { sqlite3_finalize(updateStatement) }
            try bind(message.createdAt, at: 1, in: updateStatement)
            try bind(sessionID, at: 2, in: updateStatement)
            try step(updateStatement)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func messages(sessionID: String) throws -> [StoredMessage] {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let statement = try prepare(
            """
            SELECT id, role, text, reasoning, tools_json, items_json,
                   timeline_json, status, error, created_at
            FROM messages
            WHERE session_id = ?
            ORDER BY created_at, rowid
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(sessionID, at: 1, in: statement)
        var messages: [StoredMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try messages.append(message(from: statement))
        }
        try throwIfStepFailed(statement)
        return messages
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                backend TEXT NOT NULL,
                model_id TEXT,
                reasoning_effort TEXT,
                sandbox_mode TEXT,
                backend_session_id TEXT,
                title TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                reasoning TEXT,
                tools_json TEXT,
                items_json TEXT,
                timeline_json TEXT,
                status TEXT,
                error TEXT,
                created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS sessions_project_updated_idx
                ON sessions (project_id, updated_at DESC);
            CREATE INDEX IF NOT EXISTS messages_session_created_idx
                ON messages (session_id, created_at);
            """
        )
        try addColumnIfMissing("model_id", to: "sessions", definition: "TEXT")
        try addColumnIfMissing("reasoning_effort", to: "sessions", definition: "TEXT")
        try addColumnIfMissing("sandbox_mode", to: "sessions", definition: "TEXT")
        try addColumnIfMissing("items_json", to: "messages", definition: "TEXT")
        try addColumnIfMissing("timeline_json", to: "messages", definition: "TEXT")
        try addColumnIfMissing("status", to: "messages", definition: "TEXT")
        try addColumnIfMissing("error", to: "messages", definition: "TEXT")
    }

    private func addColumnIfMissing(
        _ column: String,
        to table: String,
        definition: String
    ) throws {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(text(statement, column: 1))
        }
        try throwIfStepFailed(statement)
        if !columns.contains(column) {
            try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
        }
    }

    private func session(from statement: OpaquePointer) -> SessionInfo? {
        guard
            let backend = BackendKind(rawValue: text(statement, column: 2))
        else {
            return nil
        }
        return SessionInfo(
            sessionID: text(statement, column: 0),
            projectID: text(statement, column: 1),
            backend: backend,
            modelID: nullableText(statement, column: 3),
            reasoningEffort: nullableText(statement, column: 4).flatMap(ReasoningEffort.init(rawValue:)),
            sandboxMode: nullableText(statement, column: 5).flatMap(SandboxMode.init(rawValue:)),
            backendSessionID: nullableText(statement, column: 6),
            title: text(statement, column: 7),
            updatedAt: text(statement, column: 8)
        )
    }

    private func message(from statement: OpaquePointer) throws -> StoredMessage {
        guard let role = MessageRole(rawValue: text(statement, column: 1)) else {
            throw SQLiteStoreError.invalidData("未知消息角色")
        }
        return try StoredMessage(
            id: text(statement, column: 0),
            role: role,
            text: text(statement, column: 2),
            reasoning: nullableText(statement, column: 3),
            toolCalls: decode(ToolCall.self, column: 4, from: statement),
            items: decode(MessageItem.self, column: 5, from: statement),
            timeline: decode(MessageItem.self, column: 6, from: statement),
            status: nullableText(statement, column: 7).flatMap(RunStatus.init(rawValue:)),
            error: nullableText(statement, column: 8),
            createdAt: text(statement, column: 9)
        )
    }

    private func decode<Value: Decodable>(
        _: Value.Type,
        column: Int32,
        from statement: OpaquePointer
    ) throws -> [Value]? {
        guard let value = nullableText(statement, column: column) else {
            return nil
        }
        guard let data = value.data(using: .utf8) else {
            throw SQLiteStoreError.invalidData("无法读取 JSON 数据")
        }
        do {
            return try jsonDecoder.decode([Value].self, from: data)
        } catch {
            throw SQLiteStoreError.invalidData("消息 JSON 数据损坏：\(error.localizedDescription)")
        }
    }

    private func encoded(_ value: (some Encodable)?) throws -> String? {
        guard let value else { return nil }
        let data = try jsonEncoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SQLiteStoreError.invalidData("无法编码 JSON 数据")
        }
        return string
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
