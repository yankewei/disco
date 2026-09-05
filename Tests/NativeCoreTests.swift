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
            createdAt: "2026-01-01T00:00:00Z",
            isPlan: false
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

        try store.updateSessionSettings(
            sessionID: session.id,
            reasoningEffort: .medium,
            sandboxMode: .readOnly
        )
        let updatedSession = try XCTUnwrap(store.session(id: session.id))
        XCTAssertEqual(updatedSession.modelID, session.modelID)
        XCTAssertEqual(updatedSession.agentThreadID, session.agentThreadID)
        XCTAssertEqual(updatedSession.reasoningEffort, .medium)
        XCTAssertEqual(updatedSession.sandboxMode, .readOnly)
        try store.updateSessionSettings(
            sessionID: session.id,
            reasoningEffort: nil,
            sandboxMode: .workspaceWrite
        )
        XCTAssertEqual(try store.session(id: session.id)?.modelID, session.modelID)
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

        store.close()

        let reopenedStore = try SQLiteStore(databaseURL: databaseURL)
        XCTAssertEqual(try reopenedStore.lastAgentSelection(), latestAgentSelection)
        let reopenedSession = try XCTUnwrap(reopenedStore.session(id: session.id))
        XCTAssertEqual(reopenedSession.modelID, session.modelID)
        XCTAssertEqual(reopenedSession.agentThreadID, session.agentThreadID)
        XCTAssertNil(reopenedSession.reasoningEffort)
        XCTAssertEqual(reopenedSession.sandboxMode, .workspaceWrite)
        reopenedStore.close()
    }

    func testSQLiteStoreUpdatesEmptySessionProviderAndModel() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = folder.appendingPathComponent("disco.sqlite")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try SQLiteStore(databaseURL: databaseURL)
        let project = ProjectInfo(
            projectID: "project-empty",
            name: "Disco",
            projectPath: "/tmp/disco",
            createdAt: "2026-01-01T00:00:00Z",
            activatedAt: nil
        )
        try store.createProject(project)
        let emptySession = SessionInfo(
            sessionID: "empty-session",
            projectID: project.id,
            agent: .codex,
            modelID: "o3",
            reasoningEffort: .high,
            sandboxMode: .workspaceWrite,
            agentThreadID: nil,
            title: "新对话",
            createdAt: "2026-01-01T00:00:00Z",
            activatedAt: nil
        )
        try store.createSession(emptySession)

        // 空会话可以切换 Provider，切换后原模型与推理深度应被清空。
        try store.updateSessionAgent(sessionID: emptySession.id, agent: .opencode)
        let switched = try XCTUnwrap(store.session(id: emptySession.id))
        XCTAssertEqual(switched.agent, .opencode)
        XCTAssertNil(switched.modelID)
        XCTAssertNil(switched.reasoningEffort)
        XCTAssertEqual(switched.agentThreadID, emptySession.agentThreadID)

        // 空会话也可以重新选择模型与推理深度。
        try store.updateSessionModel(
            sessionID: emptySession.id,
            modelID: "anthropic/claude",
            reasoningEffort: .medium
        )
        let modeled = try XCTUnwrap(store.session(id: emptySession.id))
        XCTAssertEqual(modeled.agent, .opencode)
        XCTAssertEqual(modeled.modelID, "anthropic/claude")
        XCTAssertEqual(modeled.reasoningEffort, .medium)

        // 重新打开后设置仍然保留。
        store.close()
        let reopenedStore = try SQLiteStore(databaseURL: databaseURL)
        let reopened = try XCTUnwrap(reopenedStore.session(id: emptySession.id))
        XCTAssertEqual(reopened.agent, .opencode)
        XCTAssertEqual(reopened.modelID, "anthropic/claude")
        XCTAssertEqual(reopened.reasoningEffort, .medium)
        reopenedStore.close()
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

        try store.deleteProject(projectID: project.id)

        XCTAssertNil(try store.project(id: project.id))
        XCTAssertTrue(try store.listSessions(projectID: project.id).isEmpty)
        XCTAssertNotNil(try store.project(id: remainingProject.id))
        XCTAssertEqual(try store.listSessions(projectID: remainingProject.id), [remainingSession])
        store.close()
    }

    func testSQLiteStoreRemovesConversationMessageCache() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = folder.appendingPathComponent("disco.sqlite")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(
            database,
            "CREATE TABLE conversation_messages (message_id TEXT PRIMARY KEY)",
            nil,
            nil,
            nil
        ), SQLITE_OK)

        let store = try SQLiteStore(databaseURL: databaseURL)
        store.close()

        let statement = try XCTUnwrap(try prepareStatement(
            database: database,
            sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'conversation_messages'"
        ))
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
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

final class PlanModeTests: XCTestCase {
    func testCodexPlanAndBuildUseNativeModesAndReplyToQuestions() async throws {
        try await verifyModeSwitch(backendKind: .codex)
    }

    func testOpenCodePlanAndBuildSelectAgentsAndReplyToQuestions() async throws {
        try await verifyModeSwitch(backendKind: .opencode)
    }

    func testCodexSkippedQuestionsReturnEmptyAnswers() async throws {
        try await verifyModeSwitch(backendKind: .codex, skipsQuestions: true)
    }

    func testOpenCodeSkippedQuestionsRejectRequest() async throws {
        try await verifyModeSwitch(backendKind: .opencode, skipsQuestions: true)
    }

    private func verifyModeSwitch(backendKind: BackendKind, skipsQuestions: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("provider")
        try Self.providerScript.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let backend: AgentBackend = backendKind == .codex
            ? CodexBackend(executableURL: executable)
            : OpenCodeBackend(executableURL: executable)
        defer { backend.shutdown() }
        XCTAssertTrue(backend.supportsPlan)
        for mode in [RunMode.plan, .agent] {
            let cancellation = CancellationToken()
            let timeout = Task {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                cancellation.cancel()
            }
            defer { timeout.cancel() }
            var questionCount = 0
            let threadID = try await backend.run(context: BackendRunContext(
                agentThreadID: mode == .plan ? nil : "thread",
                modelID: nil,
                reasoningEffort: .medium,
                sandboxMode: nil,
                workingDirectory: directory.path,
                prompt: "制定计划",
                mode: mode,
                emit: { _ in },
                cancellation: cancellation,
                reportAgentThreadID: { XCTAssertEqual($0, "thread") },
                requestUserInput: { questions in
                    questionCount += 1
                    XCTAssertEqual(questions.count, 1)
                    XCTAssertEqual(questions.first?.title, "选择方案")
                    XCTAssertEqual(questions.first?.options.first?.label, "方案 A")
                    return skipsQuestions ? nil : [["方案 A"]]
                },
                requestApproval: { _, _, _ in .denied }
            ))
            XCTAssertEqual(threadID, "thread")
            XCTAssertEqual(questionCount, 1)
        }
        let log = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        let records = try log.split(separator: "\n").map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }.compactMap(\.objectValue)
        if backendKind == .codex {
            let initialization = try XCTUnwrap(records.first { jsonString($0["method"]) == "initialize" })
            XCTAssertEqual(jsonObject(jsonObject(initialization["params"])?["capabilities"])?["experimentalApi"], .boolean(true))
            let turns = records.filter { jsonString($0["method"]) == "turn/start" }
            XCTAssertEqual(turns.count, 2)
            for (index, turn) in turns.enumerated() {
                let mode = try XCTUnwrap(jsonObject(jsonObject(turn["params"])?["collaborationMode"]))
                XCTAssertEqual(mode["mode"], .string(index == 0 ? "plan" : "default"))
                let settings = try XCTUnwrap(jsonObject(mode["settings"]))
                XCTAssertEqual(settings["model"], .string("resolved-model"))
                XCTAssertEqual(settings["reasoning_effort"], .string("medium"))
                XCTAssertEqual(settings["developer_instructions"], .null)
            }
            let replies = records.filter { $0["id"] == .string("question") }
            XCTAssertEqual(replies.count, 2)
            XCTAssertEqual(jsonObject(jsonObject(jsonObject(replies.first?["result"])?["answers"])?["choice"])?["answers"], .array(skipsQuestions ? [] : [.string("方案 A")]))
        } else {
            let prompts = records.filter { jsonString($0["path"])?.contains("prompt_async") == true }
            XCTAssertEqual(prompts.count, 2)
            XCTAssertEqual(jsonObject(prompts.first?["body"])?["agent"], .string("plan"))
            XCTAssertEqual(jsonObject(prompts.last?["body"])?["agent"], .string("build"))
            let action = skipsQuestions ? "reject" : "reply"
            let replies = records.filter { jsonString($0["path"])?.contains("question/question/\(action)") == true }
            XCTAssertEqual(replies.count, 2)
            if skipsQuestions {
                XCTAssertEqual(replies.first?["body"], .null)
            } else {
                XCTAssertEqual(jsonObject(replies.first?["body"])?["answers"], .array([.array([.string("方案 A")])]))
            }
            XCTAssertEqual(jsonString(replies.last?["path"]), "/api/session/thread/question/question/\(action)")
        }
    }

    private static let providerScript = #"""
    #!/usr/bin/python3
    import json, sys, os, queue
    from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
    from urllib.parse import urlparse
    log = os.path.join(os.path.dirname(__file__), "requests.jsonl")
    def record(value):
        with open(log, "a") as file:
            file.write(json.dumps(value) + "\n")
    question = {"id": "choice", "header": "方案", "question": "选择方案", "options": [{"label": "方案 A", "description": "简洁实现"}]}
    if "serve" not in sys.argv:
        def send(value):
            print(json.dumps(value), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            record(request)
            method = request.get("method")
            if method == "initialized":
                continue
            if method == "turn/start":
                send({"id": request["id"], "result": {"turn": {"id": "turn"}}})
                send({"id": "question", "method": "item/tool/requestUserInput", "params": {"threadId": "thread", "questions": [question]}})
            elif method is None:
                send({"method": "turn/completed", "params": {"threadId": "thread", "turn": {"id": "turn", "status": "completed"}}})
            else:
                send({"id": request["id"], "result": {"thread": {"id": "thread"}, "model": "resolved-model"}})
    else:
        events = queue.Queue()
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream" if urlparse(self.path).path == "/event" else "application/json")
                self.end_headers()
                if urlparse(self.path).path != "/event":
                    self.wfile.write(b"{}")
                    return
                self.wfile.write(b'data: {"type":"server.connected","properties":{}}\n\n')
                self.wfile.flush()
                while True:
                    self.wfile.write(("data: " + json.dumps(events.get()) + "\n\n").encode())
                    self.wfile.flush()
            def do_POST(self):
                path = urlparse(self.path).path
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"null")
                record({"path": path, "body": body})
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"id":"thread"}')
                if path.endswith("prompt_async"):
                    events.put({"type": "question.asked" if body["agent"] == "plan" else "question.v2.asked", "properties": {"id": "question", "sessionID": "thread", "questions": [question]}})
                elif path.endswith(("reply", "reject")):
                    events.put({"type": "session.idle", "properties": {"sessionID": "thread"}})
        ThreadingHTTPServer(("127.0.0.1", int(sys.argv[sys.argv.index("--port") + 1])), Handler).serve_forever()
    """#
}

