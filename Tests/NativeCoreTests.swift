@testable import Disco
import Foundation
import SQLite3
import XCTest

final class NativeCoreTests: XCTestCase {
    func testConversationMessageRoundTripKeepsTimeline() throws {
        let message = ConversationMessage(
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
        let decoded = try JSONDecoder().decode(ConversationMessage.self, from: data)
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

    func testTimelineBuilderReplacesSnapshotsAndIgnoresEmptyTextItems() {
        var builder = TimelineBuilder()
        builder.apply(.item(.reasoning(id: "reasoning-1", text: "", state: .updated)))
        XCTAssertTrue(builder.timeline.isEmpty)

        builder.apply(.item(.reasoning(id: "reasoning-1", text: "初始分析", state: .updated)))
        builder.apply(.item(.reasoning(id: "reasoning-1", text: "完整分析", state: .completed)))
        builder.apply(.item(.text(id: "text-1", text: "最终答案", state: .completed)))

        XCTAssertEqual(builder.reasoning, "完整分析")
        XCTAssertEqual(builder.assistantText, "最终答案")
        XCTAssertEqual(builder.timeline, [
            .reasoning(id: "reasoning-1", text: "完整分析", state: .completed),
            .text(id: "text-1", text: "最终答案", state: .completed),
        ])
    }

    func testOpenCodeMessageParsingReplacesDuplicatePartIDs() throws {
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        [{
          "info": {"id": "message-1", "role": "assistant"},
          "parts": [
            {"id": "prt-1", "type": "text", "text": "旧内容"},
            {"id": "prt-1", "type": "text", "text": "新内容"}
          ]
        }]
        """#.utf8))

        let messages = parseOpenCodeMessages(response)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "新内容")
        XCTAssertEqual(messages[0].timeline, [
            .text(id: "prt-1", text: "新内容", state: .started),
        ])
    }

    func testOpenCodeStreamStateUsesPartKindAndOneAuthoritativeSource() {
        let state = OpenCodeEventStreamState()
        state.registerPartKind(.reasoning, partID: "reasoning-1")

        XCTAssertEqual(state.partKind(for: "reasoning-1"), .reasoning)
        XCTAssertTrue(state.acceptsStreamDelta(
            messageID: "message-1",
            partID: "reasoning-1",
            kind: .reasoning,
            source: .messagePartDelta
        ))
        XCTAssertFalse(state.acceptsPartSnapshot(
            partID: "reasoning-1",
            kind: .reasoning,
            hasContent: true
        ))
        XCTAssertFalse(state.acceptsStreamDelta(
            messageID: "message-1",
            partID: "reasoning-1",
            kind: .reasoning,
            source: .sessionNextDelta
        ))
    }

    func testOpenCodeStreamStateAllowsReplacingSnapshotsButBlocksLaterDeltas() {
        let state = OpenCodeEventStreamState()
        state.registerPartKind(.text, partID: "text-1")

        XCTAssertFalse(state.acceptsPartSnapshot(
            partID: "text-1",
            kind: .text,
            hasContent: false
        ))
        XCTAssertTrue(state.acceptsPartSnapshot(
            partID: "text-1",
            kind: .text,
            hasContent: true
        ))
        XCTAssertTrue(state.acceptsPartSnapshot(
            partID: "text-1",
            kind: .text,
            hasContent: true
        ))
        XCTAssertFalse(state.acceptsStreamDelta(
            messageID: "message-1",
            partID: "text-1",
            kind: .text,
            source: .messagePartDelta
        ))
    }

    func testTimelineBuilderIgnoresProtocolEvents() {
        var builder = TimelineBuilder()
        builder.apply(.item(
            .codexEvent(
                id: "event-1",
                eventType: "hook/started",
                payload: [String: JSONValue](),
                state: .updated
            )
        ))

        XCTAssertTrue(builder.timeline.isEmpty)
        XCTAssertTrue(builder.items.isEmpty)
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
        XCTAssertEqual(session.agent, .codex)
        XCTAssertEqual(session.agentThreadID, "thread-1")
        XCTAssertNil(session.modelID)
        XCTAssertNil(try store.lastAgentSelection())
        store.close()

        var migratedDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &migratedDatabase, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(migratedDatabase) }
        let messagesTableStatement = try XCTUnwrap(try prepareStatement(
            database: migratedDatabase,
            sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'messages'"
        ))
        defer { sqlite3_finalize(messagesTableStatement) }
        XCTAssertEqual(sqlite3_step(messagesTableStatement), SQLITE_DONE)
    }

    func testSQLiteStoreRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = folder.appendingPathComponent("disco.sqlite")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try SQLiteStore(databaseURL: databaseURL)
        let project = ProjectInfo(
            projectID: "project-1",
            name: "Disco",
            projectPath: "/tmp/disco",
            createdAt: "2026-01-01T00:00:00Z",
            activatedAt: "2026-01-01T00:00:01Z"
        )
        try store.createProject(project)
        let session = SessionInfo(
            sessionID: "session-1",
            projectID: project.id,
            agent: .codex,
            modelID: "o3",
            reasoningEffort: .high,
            sandboxMode: .workspaceWrite,
            agentThreadID: "thread-1",
            title: "新对话",
            createdAt: "2026-01-01T00:00:00Z",
            activatedAt: "2026-01-01T00:00:01Z"
        )
        try store.createSession(session)

        XCTAssertEqual(try store.listProjects(), [project])
        let storedSession = try XCTUnwrap(store.listSessions(projectID: project.id).first)
        XCTAssertEqual(storedSession.agent, session.agent)
        XCTAssertEqual(storedSession.agentThreadID, session.agentThreadID)
        XCTAssertEqual(storedSession.activatedAt, "2026-01-01T00:00:01Z")

        try store.updateSessionModel(
            sessionID: session.id,
            modelID: "gpt-5",
            reasoningEffort: .medium
        )
        XCTAssertEqual(try store.session(id: session.id)?.modelID, "gpt-5")
        XCTAssertEqual(try store.session(id: session.id)?.reasoningEffort, .medium)
        try store.updateSessionModel(
            sessionID: session.id,
            modelID: nil,
            reasoningEffort: nil
        )
        XCTAssertNil(try store.session(id: session.id)?.modelID)
        XCTAssertNil(try store.session(id: session.id)?.reasoningEffort)

        let firstAgentSelection = LastAgentSelection(
            agent: .codex,
            modelID: "o3",
            reasoningEffort: .high
        )
        try store.saveLastAgentSelection(firstAgentSelection)
        XCTAssertEqual(try store.lastAgentSelection(), firstAgentSelection)

        let latestAgentSelection = LastAgentSelection(
            agent: .opencode,
            modelID: "anthropic/claude",
            reasoningEffort: nil
        )
        try store.saveLastAgentSelection(latestAgentSelection)
        XCTAssertEqual(try store.lastAgentSelection(), latestAgentSelection)

        let emptySession = SessionInfo(
            sessionID: "empty-session-1",
            projectID: project.id,
            agent: .codex,
            modelID: "o3",
            reasoningEffort: .high,
            sandboxMode: .workspaceWrite,
            agentThreadID: nil,
            title: "新对话",
            createdAt: "2026-01-01T00:00:02Z",
            activatedAt: nil
        )
        try store.createSession(emptySession)
        try store.updateSessionAgent(sessionID: emptySession.id, agent: .opencode)
        let updatedSession = try XCTUnwrap(store.session(id: emptySession.id))
        XCTAssertEqual(updatedSession.agent, .opencode)
        XCTAssertNil(updatedSession.modelID)
        XCTAssertNil(updatedSession.reasoningEffort)

        store.close()

        let reopenedStore = try SQLiteStore(databaseURL: databaseURL)
        XCTAssertEqual(try reopenedStore.lastAgentSelection(), latestAgentSelection)
        reopenedStore.close()
    }

    func testSQLiteStorePersistsConversationTimeline() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = folder.appendingPathComponent("disco.sqlite")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try SQLiteStore(databaseURL: databaseURL)
        let project = ProjectInfo(
            projectID: "project-1",
            name: "Disco",
            projectPath: "/tmp/disco",
            createdAt: "2026-01-01T00:00:00Z",
            activatedAt: nil
        )
        try store.createProject(project)
        let session = SessionInfo(
            sessionID: "session-1",
            projectID: project.id,
            agent: .codex,
            modelID: nil,
            reasoningEffort: nil,
            sandboxMode: nil,
            agentThreadID: nil,
            title: "测试会话",
            createdAt: "2026-01-01T00:00:00Z",
            activatedAt: nil
        )
        try store.createSession(session)

        let messages = [
            ConversationMessage(
                id: "user-1",
                role: .user,
                text: "读取 README",
                reasoning: nil,
                toolCalls: nil,
                items: nil,
                timeline: nil,
                status: nil,
                error: nil,
                createdAt: "2026-01-01T00:00:00Z"
            ),
            ConversationMessage(
                id: "assistant-1",
                role: .assistant,
                text: "README 内容如下",
                reasoning: "先读取文件",
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
                    .reasoning(id: "reasoning-1", text: "先读取文件", state: .completed),
                    .toolCall(
                        id: "tool-1",
                        name: "读取文件",
                        input: .object(["path": .string("README.md")]),
                        output: "内容",
                        error: nil,
                        state: .completed
                    ),
                ],
                timeline: [
                    .reasoning(id: "reasoning-1", text: "先读取文件", state: .completed),
                    .toolCall(
                        id: "tool-1",
                        name: "读取文件",
                        input: .object(["path": .string("README.md")]),
                        output: "内容",
                        error: nil,
                        state: .completed
                    ),
                    .text(id: "text-1", text: "README 内容如下", state: .completed),
                ],
                status: .completed,
                error: nil,
                createdAt: "2026-01-01T00:00:01Z"
            ),
        ]

        try store.replaceMessages(messages, sessionID: session.id)
        XCTAssertEqual(try store.loadMessages(sessionID: session.id), messages)
        store.close()

        let reopenedStore = try SQLiteStore(databaseURL: databaseURL)
        defer { reopenedStore.close() }
        XCTAssertEqual(try reopenedStore.loadMessages(sessionID: session.id), messages)
    }

    func testSQLiteStoreDeletesSession() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = folder.appendingPathComponent("disco.sqlite")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try SQLiteStore(databaseURL: databaseURL)
        let project = ProjectInfo(
            projectID: "project-1",
            name: "Disco",
            projectPath: "/tmp/disco",
            createdAt: "2026-01-01T00:00:00Z",
            activatedAt: nil
        )
        try store.createProject(project)
        try store.createSession(
            SessionInfo(
                sessionID: "session-1",
                projectID: project.id,
                agent: .codex,
                modelID: nil,
                reasoningEffort: nil,
                sandboxMode: nil,
                agentThreadID: "thread-1",
                title: "已删除会话",
                createdAt: "2026-01-01T00:00:00Z",
                activatedAt: nil
            )
        )

        try store.deleteSession(sessionID: "session-1")
        XCTAssertNil(try store.session(id: "session-1"))
        XCTAssertTrue(try store.listSessions(projectID: project.id).isEmpty)
        store.close()

        let reopenedStore = try SQLiteStore(databaseURL: databaseURL)
        defer { reopenedStore.close() }
        XCTAssertTrue(try reopenedStore.listSessions(projectID: project.id).isEmpty)
    }

    func testSQLiteStoreDeletesProjectAndCascadesLocalData() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = folder.appendingPathComponent("disco.sqlite")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try SQLiteStore(databaseURL: databaseURL)
        let project = ProjectInfo(
            projectID: "project-1",
            name: "Disco",
            projectPath: "/tmp/disco",
            createdAt: "2026-01-01T00:00:00Z",
            activatedAt: nil
        )
        let remainingProject = ProjectInfo(
            projectID: "project-2",
            name: "Other",
            projectPath: "/tmp/other",
            createdAt: "2026-01-01T00:00:00Z",
            activatedAt: nil
        )
        try store.createProject(project)
        try store.createProject(remainingProject)

        let deletedSession = SessionInfo(
            sessionID: "session-1",
            projectID: project.id,
            agent: .codex,
            modelID: nil,
            reasoningEffort: nil,
            sandboxMode: nil,
            agentThreadID: "agent-thread-1",
            title: "待删除会话",
            createdAt: "2026-01-01T00:00:00Z",
            activatedAt: nil
        )
        let remainingSession = SessionInfo(
            sessionID: "session-2",
            projectID: remainingProject.id,
            agent: .opencode,
            modelID: nil,
            reasoningEffort: nil,
            sandboxMode: nil,
            agentThreadID: "agent-thread-2",
            title: "保留会话",
            createdAt: "2026-01-01T00:00:00Z",
            activatedAt: nil
        )
        try store.createSession(deletedSession)
        try store.createSession(remainingSession)
        try store.replaceMessages([
            ConversationMessage(
                id: "message-1",
                role: .user,
                text: "本地消息",
                reasoning: nil,
                toolCalls: nil,
                items: nil,
                timeline: nil,
                status: nil,
                error: nil,
                createdAt: "2026-01-01T00:00:00Z"
            ),
        ], sessionID: deletedSession.id)

        try store.deleteProject(projectID: project.id)

        XCTAssertNil(try store.project(id: project.id))
        XCTAssertTrue(try store.listSessions(projectID: project.id).isEmpty)
        XCTAssertTrue(try store.loadMessages(sessionID: deletedSession.id).isEmpty)
        XCTAssertNotNil(try store.project(id: remainingProject.id))
        XCTAssertEqual(try store.listSessions(projectID: remainingProject.id), [remainingSession])
        store.close()
    }

    private func prepareStatement(
        database: OpaquePointer?,
        sql: String
    ) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "NativeCoreTests", code: 1)
        }
        return statement
    }
}
