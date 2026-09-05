@testable import Disco
import Foundation
import SQLite3
import XCTest

final class NativeCoreTests: XCTestCase {
    func testTimelineGroupsOnlyAdjacentToolsAndKeepsStableIdentity() {
        let first = MessageItem.toolCall(id: "read", name: "读取", input: nil, output: nil, error: nil, state: .completed)
        let second = MessageItem.webSearch(id: "search", query: "Swift", state: .started)
        let text = MessageItem.text(id: "text", text: "继续", state: .completed)
        let reasoning = MessageItem.reasoning(id: "reasoning", text: "分析", state: .completed)
        let groups = MessageTimelineGroup.group([first, second, text, first, reasoning, second])
        XCTAssertEqual(groups.map(\.id), ["read", "text", "read", "reasoning", "search"])
        XCTAssertEqual(groups.map { $0.activities.count }, [2, 0, 1, 1, 1])
        XCTAssertEqual(groups[0].activities.map(\.id), ["read", "search"])
        XCTAssertEqual(groups[0].id, MessageTimelineGroup.group([first])[0].id)
        XCTAssertTrue(groups[0].activities.contains { $0.isRunning })
    }

    func testGroupedToolDetailsPreserveFailureAndOutput() {
        let failed = MessageItem.toolCall(id: "failed", name: "读取", input: .string("file"), output: "partial", error: "文件不存在", state: .failed)
        let completed = MessageItem.webSearch(id: "done", query: "Swift", state: .completed)
        let groups = MessageTimelineGroup.group([failed, completed])
        XCTAssertEqual(groups.count, 1)
        XCTAssertFalse(groups[0].activities.contains { $0.isRunning })
        XCTAssertTrue(groups[0].activities[0].hasFailed)
        XCTAssertEqual(groups[0].activities[0].output, "partial")
        XCTAssertEqual(groups[0].activities[0].error, "文件不存在")
    }

    func testReasoningGroupsStaySeparateFromToolsAndTrackCompletion() {
        let first = MessageItem.reasoning(id: "thinking-1", text: "检查结构", state: .completed)
        let second = MessageItem.reasoning(id: "thinking-2", text: "分析实现", state: .updated)
        let tool = MessageItem.webSearch(id: "search", query: "Swift", state: .completed)
        let groups = MessageTimelineGroup.group([first, second, tool])
        XCTAssertEqual(groups.map { $0.activities.count }, [2, 1])
        XCTAssertEqual(groups[0].activities.map(\.kind), [.reasoning, .reasoning])
        XCTAssertEqual(groups[0].activities[1].output, "分析实现")
        XCTAssertTrue(groups[0].activities.contains { $0.isRunning })
        let completed = MessageItem.reasoning(id: "thinking-2", text: "分析实现", state: .completed)
        let finishedGroups = MessageTimelineGroup.group([first, completed, tool])
        XCTAssertEqual(groups[0].id, finishedGroups[0].id)
        XCTAssertFalse(finishedGroups[0].activities.contains { $0.isRunning })
    }

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

    func testProcessIdentityReportsNoStartTimeForMissingProcess() {
        XCTAssertNil(ProcessIdentity.startTime(of: Int32.max))
    }

    func testManagedProcessTracksItsProcessInTheRegistry() throws {
        try withTemporaryRegistry { registry, registryPath in
            let process = ManagedProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                workingDirectory: nil,
                registry: registry
            )
            try process.launch()
            defer { process.forceTerminate() }
            XCTAssertTrue(recordedPIDs(in: registryPath).contains(process.process.processIdentifier))

            process.terminate()
            waitForExit([process.process])
            waitForRecordsToDisappear([process.process.processIdentifier], in: registryPath)
            XCTAssertTrue(recordedPIDs(in: registryPath).isEmpty)
        }
    }

    func testProviderProcessRegistryKeepsProcessesOwnedByALiveInstance() throws {
        try withTemporaryRegistry { registry, _ in
            let process = try launchedSleep()
            defer { if process.isRunning { process.terminate() } }
            registry.register(pid: process.processIdentifier, executablePath: "/bin/sleep")

            registry.reapOrphanedProcesses(executablePath: "/bin/echo")
            XCTAssertTrue(process.isRunning)

            // 属主（当前进程）仍然存活，不能当作上一轮的孤儿回收
            registry.reapOrphanedProcesses(executablePath: "/bin/sleep")
            XCTAssertTrue(process.isRunning)
        }
    }

    func testProviderProcessRegistryReapsEveryOrphanOfADeadOwner() throws {
        try withTemporaryRegistry { registry, registryPath in
            let deadOwner = try exitedProcessIdentity()
            let processes = [try launchedSleep(), try launchedSleep()]
            defer { processes.forEach { if $0.isRunning { $0.terminate() } } }
            let pids = processes.map(\.processIdentifier)
            for process in processes {
                registry.register(
                    pid: process.processIdentifier,
                    executablePath: "/bin/sleep",
                    ownerPID: deadOwner.pid,
                    ownerStartTime: deadOwner.startTime
                )
            }
            XCTAssertEqual(Set(recordedPIDs(in: registryPath)), Set(pids))

            registry.reapOrphanedProcesses(executablePath: "/bin/sleep")
            waitForExit(processes)
            XCTAssertTrue(processes.allSatisfy { !$0.isRunning })
            XCTAssertTrue(recordedPIDs(in: registryPath).isEmpty)
        }
    }

    func testProviderProcessRegistryReapsOrphanLaunchedThroughASymlink() throws {
        try withTemporaryRegistry { registry, registryPath in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let link = directory.appendingPathComponent("sleeper")
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: URL(fileURLWithPath: "/bin/sleep")
            )

            let deadOwner = try exitedProcessIdentity()
            let process = try launchedSleep(executableURL: link)
            defer { if process.isRunning { process.terminate() } }
            registry.register(
                pid: process.processIdentifier,
                executablePath: link.path,
                ownerPID: deadOwner.pid,
                ownerStartTime: deadOwner.startTime
            )

            registry.reapOrphanedProcesses(executablePath: link.path)
            waitForExit([process])
            XCTAssertFalse(process.isRunning)
            XCTAssertTrue(recordedPIDs(in: registryPath).isEmpty)
        }
    }

    func testProviderProcessRegistryPrunesRecordsOfExitedProcesses() throws {
        try withTemporaryRegistry { registry, registryPath in
            let process = try launchedSleep(arguments: ["0.2"])
            registry.register(pid: process.processIdentifier, executablePath: "/bin/sleep")
            XCTAssertEqual(recordedPIDs(in: registryPath), [process.processIdentifier])
            process.waitUntilExit()
            waitForPIDToDisappear(process.processIdentifier)

            registry.reapOrphanedProcesses(executablePath: "/bin/echo")
            XCTAssertTrue(recordedPIDs(in: registryPath).isEmpty)
        }
    }

    private func withTemporaryRegistry(
        _ body: (ProviderProcessRegistry, String) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let registryPath = directory.appendingPathComponent("provider-processes.json").path
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(
            ProviderProcessRegistry(storageURL: URL(fileURLWithPath: registryPath)),
            registryPath
        )
    }

    private func launchedSleep(
        executableURL: URL = URL(fileURLWithPath: "/bin/sleep"),
        arguments: [String] = ["60"]
    ) throws -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func exitedProcessIdentity() throws -> (pid: Int32, startTime: Double) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = []
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        let startTime = try XCTUnwrap(ProcessIdentity.startTime(of: pid))
        process.waitUntilExit()
        waitForPIDToDisappear(pid)
        return (pid, startTime)
    }

    private func waitForExit(_ processes: [Process]) {
        let deadline = Date().addingTimeInterval(5)
        while processes.contains(where: \.isRunning), Date() < deadline {
            usleep(100_000)
        }
    }

    // An exited process lingers in the process table as a zombie and keeps
    // reporting its original start time until it is reaped.
    private func waitForPIDToDisappear(_ pid: Int32) {
        let deadline = Date().addingTimeInterval(5)
        while ProcessIdentity.startTime(of: pid) != nil, Date() < deadline {
            usleep(20_000)
        }
    }

    private func waitForRecordsToDisappear(_ pids: [Int32], in registryPath: String) {
        let deadline = Date().addingTimeInterval(5)
        while recordedPIDs(in: registryPath).contains(where: pids.contains), Date() < deadline {
            usleep(20_000)
        }
    }

    private func recordedPIDs(in registryPath: String) -> [Int32] {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: registryPath)),
            let records = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return [] }
        return (records.arrayValue ?? []).compactMap { record in
            guard let pid = jsonNumber(jsonObject(record)?["pid"]) else { return nil }
            return Int32(pid)
        }
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
            // 两次 run 复用同一个常驻服务：模拟服务进程只被启动一次
            XCTAssertEqual(records.filter { jsonString($0["path"]) == "/global/health" }.count, 1)
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
        subscribers = []
        def publish(event):
            # 真实 opencode 的 /event 是广播语义：每个订阅者都收到全量事件
            for queue_ in list(subscribers):
                queue_.put(event)
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream" if urlparse(self.path).path == "/event" else "application/json")
                self.end_headers()
                if urlparse(self.path).path == "/global/health":
                    record({"path": "/global/health"})
                    self.wfile.write(b"{}")
                    return
                if urlparse(self.path).path != "/event":
                    self.wfile.write(b"{}")
                    return
                self.wfile.write(b'data: {"type":"server.connected","properties":{}}\n\n')
                self.wfile.flush()
                received = queue.Queue()
                subscribers.append(received)
                try:
                    while True:
                        self.wfile.write(("data: " + json.dumps(received.get()) + "\n\n").encode())
                        self.wfile.flush()
                finally:
                    subscribers.remove(received)
            def do_POST(self):
                path = urlparse(self.path).path
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"null")
                record({"path": path, "body": body})
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"id":"thread"}')
                if path.endswith("prompt_async"):
                    publish({"type": "question.asked" if body["agent"] == "plan" else "question.v2.asked", "properties": {"id": "question", "sessionID": "thread", "questions": [question]}})
                elif path.endswith(("reply", "reject")):
                    publish({"type": "session.idle", "properties": {"sessionID": "thread"}})
        ThreadingHTTPServer(("127.0.0.1", int(sys.argv[sys.argv.index("--port") + 1])), Handler).serve_forever()
    """#
}

final class OpenCodeStartupTests: XCTestCase {
    func testRunCancelledWhileServerStartsStopsWaiting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("provider")
        try Self.neverReadyScript.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let backend = OpenCodeBackend(executableURL: executable)
        defer { backend.shutdown() }
        let cancellation = CancellationToken()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            cancellation.cancel()
        }

        // 服务一直不就绪时，取消必须立刻生效，而不是等满 30 秒启动超时
        let startedAt = Date()
        do {
            _ = try await backend.run(context: BackendRunContext(
                agentThreadID: nil,
                modelID: nil,
                reasoningEffort: nil,
                sandboxMode: nil,
                workingDirectory: directory.path,
                prompt: "开始",
                mode: .agent,
                emit: { _ in },
                cancellation: cancellation,
                reportAgentThreadID: { _ in },
                requestUserInput: { _ in nil },
                requestApproval: { _, _, _ in .denied }
            ))
            XCTFail("取消之后不应该正常结束")
        } catch OpenCodeBackendError.cancelled {
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
        }
    }

    private static let neverReadyScript = #"""
    #!/usr/bin/python3
    import sys, time
    from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            time.sleep(30)
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[sys.argv.index("--port") + 1])), Handler).serve_forever()
    """#
}

final class OpenCodeSharedServerTests: XCTestCase {
    func testConcurrentRunsShareOneServerWithoutMixingEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("provider")
        try Self.sharedServerScript.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let backend = OpenCodeBackend(executableURL: executable)
        defer { backend.shutdown() }

        let first = Task { try await self.runPrompt(backend: backend, directory: directory) }
        let second = Task { try await self.runPrompt(backend: backend, directory: directory) }
        let (firstRun, secondRun) = try await (first.value, second.value)

        // 同一目录下的两个会话共用一个常驻服务和一条事件流，回答不能互相串台
        XCTAssertNotEqual(firstRun.threadID, secondRun.threadID)
        XCTAssertEqual(firstRun.texts, ["回答 \(firstRun.threadID)"])
        XCTAssertEqual(secondRun.texts, ["回答 \(secondRun.threadID)"])

        let log = try String(
            contentsOf: directory.appendingPathComponent("requests.jsonl"),
            encoding: .utf8
        )
        let paths = try log.split(separator: "\n").map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }.compactMap { jsonString($0.objectValue?["path"]) }
        XCTAssertEqual(paths.filter { $0 == "/global/health" }.count, 1)
        let streams = paths.filter { $0.hasPrefix("/event?directory=") }
        XCTAssertEqual(streams.count, 2)
        for stream in streams {
            XCTAssertEqual(
                String(stream.dropFirst("/event?directory=".count)).removingPercentEncoding,
                directory.path
            )
        }
        // 两次 prompt 都在两条事件流建立之后才提交，所以每个 run 都确实收到了
        // 另一个会话和陌生会话的 part 事件；上面的精确断言才有意义
        XCTAssertEqual(paths.filter { $0.contains("prompt_async") }.count, 2)
        let lastStream = paths.lastIndex { $0.hasPrefix("/event") } ?? -1
        let firstPrompt = paths.firstIndex { $0.contains("prompt_async") } ?? .max
        XCTAssertLessThan(lastStream, firstPrompt)
    }

    private func runPrompt(
        backend: OpenCodeBackend,
        directory: URL
    ) async throws -> (threadID: String, texts: [String]) {
        let collector = EmittedTexts()
        let cancellation = CancellationToken()
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            cancellation.cancel()
        }
        defer { timeout.cancel() }
        let threadID = try await backend.run(context: BackendRunContext(
            agentThreadID: nil,
            modelID: nil,
            reasoningEffort: nil,
            sandboxMode: nil,
            workingDirectory: directory.path,
            prompt: "开始",
            mode: .agent,
            emit: collector.record,
            cancellation: cancellation,
            reportAgentThreadID: { _ in },
            requestUserInput: { _ in nil },
            requestApproval: { _, _, _ in .denied }
        ))
        return (threadID, collector.texts)
    }

    private final class EmittedTexts {
        private let lock = NSLock()
        private var values: [String] = []

        func record(_ event: BackendEvent) {
            guard case let .item(.text(_, text, _)) = event else { return }
            lock.withLock { values.append(text) }
        }

        var texts: [String] {
            lock.withLock { values }
        }
    }

    private static let sharedServerScript = #"""
    #!/usr/bin/python3
    import itertools, json, os, queue, sys, time
    from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
    from urllib.parse import urlparse
    log = os.path.join(os.path.dirname(__file__), "requests.jsonl")
    def record(value):
        with open(log, "a") as file:
            file.write(json.dumps(value) + "\n")
    sessions = itertools.count(1)
    subscribers = []
    def publish(event):
        # 真实 /event 按目录广播：同目录的每个订阅者都会收到全部会话的事件
        for received in list(subscribers):
            received.put(event)
    def part(session_id, text):
        return {"type": "message.part.updated", "properties": {
            "sessionID": session_id,
            "time": 1,
            "part": {
                "id": "prt_" + session_id,
                "sessionID": session_id,
                "messageID": "msg_" + session_id,
                "type": "text",
                "text": text,
                "time": {"start": 1, "end": 2},
            },
        }}
    def wait_for_both_subscribers():
        deadline = time.time() + 5
        while len(subscribers) < 2 and time.time() < deadline:
            time.sleep(0.02)
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            parsed = urlparse(self.path)
            record({"path": self.path})
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream" if parsed.path == "/event" else "application/json")
            self.end_headers()
            if parsed.path != "/event":
                self.wfile.write(b"{}")
                return
            self.wfile.write(b'data: {"type":"server.connected","properties":{}}\n\n')
            self.wfile.flush()
            received = queue.Queue()
            subscribers.append(received)
            try:
                while True:
                    self.wfile.write(("data: " + json.dumps(received.get()) + "\n\n").encode())
                    self.wfile.flush()
            finally:
                subscribers.remove(received)
        def do_POST(self):
            parsed = urlparse(self.path)
            record({"path": self.path})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            if parsed.path == "/session":
                self.wfile.write(json.dumps({"id": "ses_%d" % next(sessions)}).encode())
                return
            self.wfile.write(b"{}")
            if not parsed.path.endswith("prompt_async"):
                return
            session_id = parsed.path.split("/")[2]
            wait_for_both_subscribers()
            publish(part(session_id, "回答 " + session_id))
            publish(part("ses_intruder", "别的会话的回答"))
            publish({"type": "session.status", "properties": {"sessionID": session_id, "status": {"type": "idle"}}})
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[sys.argv.index("--port") + 1])), Handler).serve_forever()
    """#
}

