import XCTest
@testable import disco

@MainActor
final class ConversationStoreTests: XCTestCase {
    func testPlanModeIsOnlyAvailableWhenDaemonReportsIt() async throws {
        let sessionID = UUID()
        let client = RecordingDiscoDaemonClient(runID: UUID())
        client.availableCollaborationModes = [.default, .plan]
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)

        for _ in 0..<100 where !store.supportsPlanMode {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.supportsPlanMode)

        store.setCollaborationMode(.plan)
        for _ in 0..<100 where client.selectedCollaborationModes.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(client.selectedCollaborationModes, [.plan])
        XCTAssertEqual(store.collaborationMode, .plan)
    }

    func testDaemonRunStreamsIntoTheConversationAndCompletes() async throws {
        let sessionID = UUID()
        let runID = UUID()
        let client = RecordingDiscoDaemonClient(runID: runID)
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)
        store.draft = "  通过 daemon 运行  "

        store.send()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(client.startedRuns.first?.sessionID, sessionID)
        XCTAssertEqual(client.startedRuns.first?.text, "通过 daemon 运行")

        store.handleDaemonNotification(daemonEvent(
            "message.delta",
            runID: runID,
            sessionID: sessionID,
            fields: ["delta": .string("daemon 回答")]
        ))
        store.handleDaemonNotification(daemonEvent(
            "run.completed",
            runID: runID,
            sessionID: sessionID
        ))

        XCTAssertEqual(store.messages.map(\.text), ["通过 daemon 运行", "daemon 回答"])
        XCTAssertEqual(store.runState, .completed)
        XCTAssertFalse(store.isStreaming)
    }

    func testDaemonReasoningDeltasAppendToAssistantMessage() async throws {
        let sessionID = UUID()
        let runID = UUID()
        let client = RecordingDiscoDaemonClient(runID: runID)
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)
        store.draft = "一个问题"

        store.send()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.handleDaemonNotification(daemonEvent(
            "reasoning.delta",
            runID: runID,
            sessionID: sessionID,
            fields: ["delta": .string("先分析")]
        ))
        store.handleDaemonNotification(daemonEvent(
            "reasoning.delta",
            runID: runID,
            sessionID: sessionID,
            fields: ["delta": .string("再回答")]
        ))
        store.handleDaemonNotification(daemonEvent(
            "message.delta",
            runID: runID,
            sessionID: sessionID,
            fields: ["delta": .string("最终回答")]
        ))
        store.handleDaemonNotification(daemonEvent(
            "run.completed",
            runID: runID,
            sessionID: sessionID
        ))

        XCTAssertEqual(store.messages.last?.reasoning, "先分析再回答")
        XCTAssertEqual(store.messages.last?.text, "最终回答")
        XCTAssertNil(store.errorMessage)
    }

    func testContextUsageUsesTheLatestReportedWindow() async throws {
        let sessionID = UUID()
        let runID = UUID()
        let client = RecordingDiscoDaemonClient(runID: runID)
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)
        store.draft = "查看上下文"

        store.send()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        store.handleDaemonNotification(daemonEvent(
            "context.usage",
            runID: runID,
            sessionID: sessionID,
            fields: [
                "contextTokens": .number(150),
                "current": .object([
                    "input": .number(100),
                    "output": .number(50),
                    "total": .number(150),
                ]),
                "contextWindow": .number(200_000),
                "source": .string("codex"),
            ]
        ))
        XCTAssertEqual(store.contextUsage?.current.totalTokens, 150)
        XCTAssertEqual(store.contextUsage?.contextWindow, 200_000)
        XCTAssertEqual(store.contextUsage?.source, .codex)

        store.handleDaemonNotification(daemonEvent(
            "context.usage",
            runID: runID,
            sessionID: sessionID,
            fields: [
                "contextTokens": .number(200),
                "current": .object([
                    "input": .number(160),
                    "output": .number(40),
                    "total": .number(200),
                ]),
                "contextWindow": .null,
                "source": .string("codex"),
            ]
        ))
        XCTAssertEqual(store.contextUsage?.current.totalTokens, 200)
        XCTAssertNil(store.contextUsage?.contextWindow)
    }

    func testToolExecutionsRemainVisibleAfterDaemonRunCompletes() async throws {
        let sessionID = UUID()
        let runID = UUID()
        let client = RecordingDiscoDaemonClient(runID: runID)
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)
        store.draft = "执行工具"

        store.send()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        store.handleDaemonNotification(daemonEvent(
            "tool.started",
            runID: runID,
            sessionID: sessionID,
            fields: [
                "toolCallId": .string("tool-1"),
                "toolName": .string("shell"),
                "kind": .string("execute"),
                "arguments": .string(#"{"command":"pwd"}"#),
            ]
        ))
        store.handleDaemonNotification(daemonEvent(
            "tool.completed",
            runID: runID,
            sessionID: sessionID,
            fields: [
                "toolCallId": .string("tool-1"),
                "toolName": .string("shell"),
                "output": .string("/tmp/disco"),
            ]
        ))
        store.handleDaemonNotification(daemonEvent(
            "run.completed",
            runID: runID,
            sessionID: sessionID
        ))

        let toolCall = try XCTUnwrap(
            store.messages.last?.parts.compactMap { part -> ChatMessage.ToolCallSnapshot? in
                guard case let .toolCall(call) = part else { return nil }
                return call
            }.first
        )
        XCTAssertEqual(toolCall.name, "shell")
        XCTAssertEqual(toolCall.kind, "execute")
        XCTAssertEqual(toolCall.output, "/tmp/disco")
        XCTAssertTrue(toolCall.isCompleted)
    }

    func testFailedDaemonRunStartRemovesPlaceholderAndCanRetry() async throws {
        let sessionID = UUID()
        let client = RecordingDiscoDaemonClient(runID: UUID())
        client.startRunError = TestDaemonError.unavailable
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)
        store.draft = "请回答"

        store.send()
        for _ in 0..<100 where store.runState != .failed {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.messages.map(\.text), ["请回答"])
        XCTAssertEqual(store.messages.last?.role, .user)
        XCTAssertTrue(store.errorMessage?.contains("无法启动 daemon 运行") == true)
        XCTAssertTrue(store.canRetry)

        client.startRunError = nil
        store.regenerateLastResponse()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(client.startedRuns.first?.text, "请回答")
        XCTAssertEqual(store.draft, "")
        XCTAssertNil(store.errorMessage)
    }

    func testCancellingADaemonRunUsesTheDaemonRunID() async throws {
        let sessionID = UUID()
        let runID = UUID()
        let client = RecordingDiscoDaemonClient(runID: runID)
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)
        store.draft = "停止"

        store.send()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.stop()
        for _ in 0..<100 where client.cancelledRunIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(client.cancelledRunIDs, [runID])
        XCTAssertEqual(store.runState, .cancelling)
        store.handleDaemonNotification(daemonEvent(
            "run.cancelled",
            runID: runID,
            sessionID: sessionID
        ))
        XCTAssertEqual(store.runState, .cancelled)
        XCTAssertFalse(store.isStreaming)
    }

    func testDaemonApprovalIsDisplayedAndSubmitted() async throws {
        let sessionID = UUID()
        let runID = UUID()
        let approvalID = UUID()
        let client = RecordingDiscoDaemonClient(runID: runID)
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)
        store.draft = "执行需要审批的操作"

        store.send()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.handleDaemonNotification(daemonEvent(
            "approval.requested",
            runID: runID,
            sessionID: sessionID,
            fields: [
                "approvalId": .string(approvalID.uuidString),
                "kind": .string("command"),
                "title": .string("执行命令"),
                "reason": .string("需要修改工作区"),
                "impact": .object([
                    "type": .string("command"),
                    "executable": .string("git"),
                    "arguments": .array([.string("status")]),
                ]),
                "fingerprint": .string("command:git-status"),
                "allowsSessionApproval": .boolean(true),
            ]
        ))

        XCTAssertEqual(store.pendingApproval?.approvalId, approvalID.uuidString)
        XCTAssertEqual(store.runState, .waitingForApproval)

        store.respondToApproval(decision: "approve_once")
        for _ in 0..<100 where client.approvals.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(client.approvals.first?.0, approvalID)
        XCTAssertEqual(client.approvals.first?.1, "approve_once")
        XCTAssertNil(store.pendingApproval)

        store.handleDaemonNotification(daemonEvent(
            "run.completed",
            runID: runID,
            sessionID: sessionID
        ))
    }

    func testDaemonCompactionUsesDaemonClientAndCompletesViaEvent() async throws {
        let sessionID = UUID()
        let runID = UUID()
        let client = RecordingDiscoDaemonClient(runID: runID)
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)

        // 先启动一次 daemon run,让 handleDaemonNotification 具备 assistant 上下文。
        store.draft = "第一条"
        store.send()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.handleDaemonNotification(daemonEvent(
            "run.completed",
            runID: runID,
            sessionID: sessionID
        ))
        store.restoreMessages([
            ChatMessage(role: .user, text: "问题"),
            ChatMessage(role: .assistant, text: "回答"),
        ])

        XCTAssertTrue(store.canCompactContext)
        store.compactContext()
        for _ in 0..<100 where client.compactedSessionIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(client.compactedSessionIDs, [sessionID])
        XCTAssertNotNil(store.activeCompaction)

        store.handleDaemonNotification(daemonEvent(
            "context.compaction",
            runID: UUID(),
            sessionID: sessionID,
            fields: [
                "id": .string("compact-1"),
                "runtimeKind": .string("generic"),
                "trigger": .string("manual"),
                "status": .string("completed"),
                "startedAt": .string("1"),
                "completedAt": .string("2"),
                "beforeTokens": .number(100),
                "afterTokens": .number(50),
            ]
        ))

        XCTAssertEqual(store.lastSuccessfulCompaction?.id, "compact-1")
        XCTAssertEqual(store.lastSuccessfulCompaction?.status, .completed)
        XCTAssertNil(store.activeCompaction)
    }

    func testNativeAgentCompactionDisablesManualCompaction() {
        let sessionID = UUID()
        let client = RecordingDiscoDaemonClient(runID: UUID())
        let store = ConversationStore(messages: [
            ChatMessage(role: .user, text: "问题"),
            ChatMessage(role: .assistant, text: "回答"),
        ])
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)
        store.setCompactionMode("native")

        XCTAssertFalse(store.canCompactContext)
        XCTAssertTrue(store.usesNativeCompaction)
    }

    func testDaemonDisconnectionFailsTheActiveRun() async throws {
        let client = RecordingDiscoDaemonClient(runID: UUID())
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: UUID())
        store.draft = "等待 daemon"

        store.send()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.handleDaemonDisconnection("daemon 连接已中断。")

        XCTAssertEqual(store.runState, .failed)
        XCTAssertEqual(store.errorMessage, "daemon 连接已中断。")
        XCTAssertEqual(store.messages.map(\.text), ["等待 daemon"])
        XCTAssertFalse(store.isStreaming)
        XCTAssertFalse(store.hasRuntime)
    }

    func testClearingAnActiveDaemonConversationDeletesItAfterCancellation() async throws {
        let sessionID = UUID()
        let runID = UUID()
        let client = RecordingDiscoDaemonClient(runID: runID)
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)
        store.draft = "随后清空"

        store.send()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.clear()

        XCTAssertEqual(store.runState, .cancelling)
        XCTAssertEqual(store.messages.map(\.text), ["随后清空", ""])
        XCTAssertTrue(client.deletedSessionIDs.isEmpty)

        store.handleDaemonNotification(daemonEvent(
            "run.cancelled",
            runID: runID,
            sessionID: sessionID
        ))
        for _ in 0..<100 where client.deletedSessionIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(client.deletedSessionIDs, [sessionID])
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.runState, .idle)
    }

    func testClearResetsLocalHistory() {
        let store = ConversationStore(
            messages: [ChatMessage(role: .user, text: "旧消息")],
            threadID: "thr_old"
        )

        store.clear()

        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNil(store.threadID)
    }

    /// daemon 托管会话仍保留本地 rich transcript，作为离线缓存和恢复兜底。
    func testDaemonOwnedConversationRetainsLocalMessageCopies() {
        let probe = PersistenceProbe()
        let store = ConversationStore(
            messages: [ChatMessage(role: .user, text: "旧消息")],
            onMessagesChanged: { messages, _, _ in
                probe.messages = messages
            }
        )

        store.enableDaemonRuns(sessionID: UUID())
        store.restoreMessages([ChatMessage(role: .user, text: "daemon 历史")])

        XCTAssertEqual(store.messages.map(\.text), ["daemon 历史"])
        XCTAssertEqual(probe.messages.map(\.text), ["daemon 历史"])
    }

    /// 撤销 daemon 注册后，会话退回未托管状态并恢复本地落盘。
    func testRevertDaemonRegistrationRestoresLocalPersistence() {
        let probe = PersistenceProbe()
        let store = ConversationStore(
            messages: [],
            onMessagesChanged: { messages, _, _ in
                probe.messages = messages
            }
        )

        store.enableDaemonRuns(sessionID: UUID())
        store.restoreMessages([ChatMessage(role: .user, text: "daemon 历史")])
        XCTAssertEqual(probe.messages.map(\.text), ["daemon 历史"])

        store.revertDaemonRegistration()
        XCTAssertFalse(store.hasDaemonSession)
        XCTAssertEqual(probe.messages.map(\.text), ["daemon 历史"])
    }
}

@MainActor
final class RecordingDiscoDaemonClient: DiscoDaemonClient {
    struct StartedRun: Equatable {
        let sessionID: UUID
        let text: String
    }

    let runID: UUID
    var startRunError: Error?
    private(set) var startedRuns: [StartedRun] = []
    private(set) var cancelledRunIDs: [UUID] = []
    private(set) var approvals: [(UUID, String)] = []
    private(set) var closedSessionIDs: [UUID] = []
    private(set) var deletedSessionIDs: [UUID] = []
    private(set) var compactedSessionIDs: [UUID] = []
    var availableCollaborationModes: [ConversationCollaborationMode] = [.default]
    private(set) var selectedCollaborationModes: [ConversationCollaborationMode] = []

    init(runID: UUID) {
        self.runID = runID
    }

    func events() -> AsyncThrowingStream<DaemonEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func startRun(sessionID: UUID, text: String) async throws -> UUID {
        if let startRunError { throw startRunError }
        startedRuns.append(StartedRun(sessionID: sessionID, text: text))
        return runID
    }

    func cancelRun(runID: UUID) async throws {
        cancelledRunIDs.append(runID)
    }

    func approve(approvalID: UUID, decision: String) async throws {
        approvals.append((approvalID, decision))
    }

    func closeSession(sessionID: UUID) async throws {
        closedSessionIDs.append(sessionID)
    }

    func deleteSession(sessionID: UUID) async throws {
        deletedSessionIDs.append(sessionID)
    }

    func compactContext(sessionID: UUID) async throws {
        compactedSessionIDs.append(sessionID)
    }

    func collaborationModes(sessionID: UUID) async throws -> [ConversationCollaborationMode] {
        availableCollaborationModes
    }

    func setCollaborationMode(
        _ mode: ConversationCollaborationMode,
        sessionID: UUID
    ) async throws {
        selectedCollaborationModes.append(mode)
    }
}

enum TestDaemonError: LocalizedError {
    case unavailable

    var errorDescription: String? { "daemon 不可用" }
}

func daemonEvent(
    _ name: String,
    runID: UUID,
    sessionID: UUID,
    fields: [String: DaemonJSONValue] = [:]
) -> DaemonEvent {
    DaemonEvent(
        eventName: name,
        data: .object(fields.merging([
            "runId": .string(runID.uuidString),
            "sessionId": .string(sessionID.uuidString),
        ]) { current, _ in current })
    )
}

/// 等待一次运行结束。
///
/// send() 的状态突变延迟到下一个 run loop 执行，因此先等待运行启动
/// （或已经结束），再等待流式结束。
@MainActor
func waitUntilStreamingFinishes(_ store: ConversationStore) async throws {
    for _ in 0..<100 where !store.isStreaming {
        try await Task.sleep(for: .milliseconds(10))
    }
    for _ in 0..<100 where store.isStreaming {
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(store.isStreaming)
}

/// 捕获持久化回调的轻量探针（@MainActor 测试内同步使用）。
final class PersistenceProbe {
    var messages: [ChatMessage] = []
    var threadID: String?
}
