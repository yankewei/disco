@testable import Disco
import Foundation
import SQLite3
import XCTest

final class NativeCoreTests: XCTestCase {
    func testStoredMessageRoundTripKeepsTimeline() throws {
        let message = StoredMessage(
            id: "message-1",
            role: .assistant,
            text: "完成",
            reasoning: "分析",
            toolCalls: [
                ToolCall(
                    id: "tool-1",
                    name: "读取文件",
                    status: .completed,
                    input: .object(["path": .string("README.md")]),
                    output: "内容",
                    error: nil
                ),
            ],
            items: [
                .text(id: "text-1", text: "完成", state: .completed),
            ],
            timeline: [
                .toolCall(
                    id: "tool-1",
                    name: "读取文件",
                    input: nil,
                    output: "内容",
                    error: nil,
                    state: .completed
                ),
            ],
            status: nil,
            error: nil,
            createdAt: "2026-01-01T00:00:00Z"
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(StoredMessage.self, from: data)
        XCTAssertEqual(decoded, message)

        let commandJSON = #"{"type":"command_execution","id":"command-1","command":"pwd","output":"/tmp","processId":"42","state":"completed"}"#
        let command = try JSONDecoder().decode(MessageItem.self, from: Data(commandJSON.utf8))
        guard case let .commandExecution(_, _, _, processID, _, _, _, _) = command else {
            return XCTFail("命令消息项类型不正确")
        }
        XCTAssertEqual(processID, "42")
    }

    func testTimelineBuilderCombinesStreamedTextAndFinalizesState() {
        var builder = TimelineBuilder()
        builder.apply(.text(text: "先", itemID: "text-1"))
        builder.apply(.text(text: "后", itemID: "text-1"))
        builder.apply(.tool(
            id: "tool-1",
            title: "读取文件",
            state: .started,
            input: .object(["path": .string("README.md")]),
            output: nil,
            error: nil
        ))
        builder.apply(.tool(
            id: "tool-1",
            title: "读取文件",
            state: .completed,
            input: nil,
            output: "内容",
            error: nil
        ))
        let finalized = builder.finalized(status: .completed)

        XCTAssertEqual(finalized.assistantText, "先后")
        XCTAssertEqual(finalized.timeline.count, 2)
        XCTAssertEqual(finalized.timeline[0], .text(id: "text-1", text: "先后", state: .completed))
        XCTAssertEqual(finalized.timeline[1], .toolCall(
            id: "tool-1",
            name: "读取文件",
            input: .object(["path": .string("README.md")]),
            output: "内容",
            error: nil,
            state: .completed
        ))
    }

    func testJSONRPCConnectionRoundTrip() async throws {
        let script = #"while IFS= read -r line; do printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}'; done"#
        let process = ManagedProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            workingDirectory: nil
        )
        let connection = JSONRPCConnection(managedProcess: process)
        var didClose = false
        try connection.start(
            serverRequestHandler: { _ in .object([:]) },
            notificationHandler: { _, _ in },
            closeHandler: { didClose = true }
        )

        let response = try await connection.request(method: "ping")
        XCTAssertEqual(jsonObject(response)?["ok"], .boolean(true))
        connection.close()
        XCTAssertTrue(didClose)
    }

    func testCancellationTokenInvokesLatestHandlerWhenCancelled() {
        let token = CancellationToken()
        var invocationCount = 0
        token.onCancel = { invocationCount += 1 }

        token.cancel()
        token.cancel()

        XCTAssertEqual(invocationCount, 1)
        var invokedAfterCancellation = false
        token.onCancel = { invokedAfterCancellation = true }
        XCTAssertTrue(invokedAfterCancellation)
    }

    func testSQLiteStoreMigratesLegacySchema() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = folder.appendingPathComponent("legacy.sqlite")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var legacyDatabase: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &legacyDatabase) == SQLITE_OK else {
            XCTFail("无法创建旧数据库")
            return
        }
        defer { sqlite3_close(legacyDatabase) }
        let legacySchema = """
        CREATE TABLE projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            path TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL
        );
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            backend TEXT NOT NULL,
            backend_session_id TEXT,
            title TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            reasoning TEXT,
            tools_json TEXT,
            timeline_json TEXT,
            created_at TEXT NOT NULL
        );
        INSERT INTO projects VALUES ('project-1', 'Disco', '/tmp/disco', '2026-01-01T00:00:00Z');
        INSERT INTO sessions VALUES ('session-1', 'project-1', 'codex', 'thread-1', '旧会话', '2026-01-01T00:00:00Z');
        INSERT INTO messages VALUES ('message-1', 'session-1', 'assistant', '已迁移', NULL, NULL, NULL, '2026-01-01T00:00:01Z');
        """
        XCTAssertEqual(sqlite3_exec(legacyDatabase, legacySchema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(legacyDatabase)
        legacyDatabase = nil

        let store = try SQLiteStore(databaseURL: databaseURL)
        let session = try XCTUnwrap(store.session(id: "session-1"))
        XCTAssertEqual(session.backend, .codex)
        XCTAssertNil(session.modelID)
        let message = try XCTUnwrap(store.messages(sessionID: session.id).first)
        XCTAssertEqual(message.text, "已迁移")
        XCTAssertNil(message.items)
        XCTAssertNil(message.timeline)
        XCTAssertNil(message.status)
        XCTAssertNil(message.error)
        store.close()
    }

    func testSQLiteStoreRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = folder.appendingPathComponent("disco.sqlite")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try SQLiteStore(databaseURL: databaseURL)
        let project = ProjectInfo(
            id: "project-1",
            name: "Disco",
            path: "/tmp/disco",
            createdAt: "2026-01-01T00:00:00Z"
        )
        try store.createProject(project)
        let session = SessionInfo(
            sessionID: "session-1",
            projectID: project.id,
            backend: .codex,
            modelID: "o3",
            reasoningEffort: .high,
            sandboxMode: .workspaceWrite,
            backendSessionID: "thread-1",
            title: "新对话",
            updatedAt: "2026-01-01T00:00:00Z"
        )
        try store.createSession(session)
        try store.appendMessage(
            sessionID: session.id,
            message: StoredMessage(
                id: "message-1",
                role: .user,
                text: "执行任务",
                reasoning: nil,
                toolCalls: nil,
                items: nil,
                timeline: nil,
                status: nil,
                error: nil,
                createdAt: "2026-01-01T00:00:01Z"
            )
        )

        XCTAssertEqual(try store.listProjects(), [project])
        let storedSession = try XCTUnwrap(store.listSessions(projectID: project.id).first)
        XCTAssertEqual(storedSession.backend, session.backend)
        XCTAssertEqual(storedSession.backendSessionID, session.backendSessionID)
        XCTAssertEqual(storedSession.updatedAt, "2026-01-01T00:00:01Z")
        XCTAssertEqual(try store.messages(sessionID: session.id).count, 1)
        store.close()
    }
}
