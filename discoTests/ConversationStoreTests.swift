import XCTest
@testable import disco

@MainActor
final class ConversationStoreTests: XCTestCase {
    func testEstimatedContextTokenCountIncludesHistoryAndDraft() {
        let store = ConversationStore(messages: [
            ChatMessage(role: .user, text: "你好"),
        ])
        store.draft = "hello"

        XCTAssertEqual(store.estimatedContextTokenCount, 4)
    }

    func testSendTrimsDraftPassesHistoryAndPersistsFinalMessages() async throws {
        let recorder = StreamRecorder()
        let persisted = StreamRecorder()
        let store = ConversationStore(
            messages: [ChatMessage(role: .user, text: "之前的问题")],
            onMessagesChanged: { messages, _ in
                Task { await persisted.record(messages) }
            }
        )
        store.configure(runtime: GenericAgentRuntime(
            provider: RecordingProvider(
                recorder: recorder,
                result: .success([.textDelta("回答")])
            ),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))
        store.draft = "  新的问题  "

        store.send()
        try await waitUntilStreamingFinishes(store)

        let receivedMessages = await recorder.messages
        XCTAssertEqual(
            receivedMessages.map(\.text),
            ["之前的问题", "新的问题"]
        )
        XCTAssertEqual(store.messages.map(\.role.rawValue), ["user", "user", "assistant"])
        XCTAssertEqual(store.messages.map(\.text), ["之前的问题", "新的问题", "回答"])
        for _ in 0..<100 {
            let savedMessages = await persisted.messages
            if savedMessages.last?.text == "回答" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let savedMessages = await persisted.messages
        XCTAssertEqual(savedMessages.map(\.role.rawValue), ["user", "user", "assistant"])
        XCTAssertEqual(savedMessages.map(\.text), ["之前的问题", "新的问题", "回答"])
        XCTAssertEqual(store.draft, "")
        XCTAssertFalse(store.isStreaming)
        XCTAssertNil(store.errorMessage)
    }

    func testFailedSendRemovesEmptyAssistantAndCanRetry() async throws {
        let store = ConversationStore()
        store.configure(runtime: GenericAgentRuntime(
            provider: RecordingProvider(
                recorder: StreamRecorder(),
                result: .failure(TestProviderError.failed)
            ),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))
        store.draft = "请回答"

        store.send()
        try await waitUntilStreamingFinishes(store)

        XCTAssertEqual(store.messages.map(\.text), ["请回答"])
        XCTAssertEqual(store.messages.last?.role, .user)
        XCTAssertEqual(store.errorMessage, "测试 provider 失败")
        XCTAssertTrue(store.canRetry)

        store.configure(runtime: GenericAgentRuntime(
            provider: RecordingProvider(
                recorder: StreamRecorder(),
                result: .success([.textDelta("重试成功")])
            ),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))
        store.retryLastMessage()
        try await waitUntilStreamingFinishes(store)

        XCTAssertEqual(store.messages.map(\.text), ["请回答", "重试成功"])
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.canRetry)
    }

    func testUnexpectedLocalToolCallFailsWithoutExecutingIt() async throws {
        let store = ConversationStore()
        store.configure(runtime: GenericAgentRuntime(
            provider: RecordingProvider(
                recorder: StreamRecorder(),
                result: .success([
                    .toolCallCompleted(ModelToolCall(
                        callID: "call_1",
                        name: "read_file",
                        arguments: "{}"
                    )),
                    .completed(ModelCompletion(continuation: nil)),
                ])
            ),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))
        store.draft = "读取文件"

        store.send()
        try await waitUntilStreamingFinishes(store)

        XCTAssertEqual(store.messages.map(\.text), ["读取文件"])
        XCTAssertEqual(store.errorMessage, "模型请求调用本地工具，但工具循环尚未启用。")
        XCTAssertTrue(store.canRetry)
    }

    func testRequestUserInputPausesRunAndResumesWithValidatedAnswer() async throws {
        let script = UserInputToolScript()
        let store = ConversationStore()
        store.configure(runtime: GenericAgentRuntime(
            provider: UserInputToolProvider(script: script),
            configuration: .init(
                model: "test-model",
                reasoningEnabled: true,
                userInputEnabled: true
            )
        ))
        store.draft = "帮我选择"

        store.send()
        try await waitUntil(store) { $0.runState == .waitingForUserInput }

        guard case let .userInput(request)? = store.firstPendingInteraction else {
            return XCTFail("应该收到用户问答请求")
        }
        XCTAssertTrue(store.isStreaming)
        XCTAssertEqual(request.questions.map(\.id), ["target"])
        XCTAssertEqual(request.questions[0].options.map(\.label), ["A", "B"])
        XCTAssertFalse(store.canSubmitUserInput(request))

        store.updateUserInput(
            requestID: request.id,
            questionID: "target",
            value: "B",
            isCustom: false
        )
        XCTAssertTrue(store.canSubmitUserInput(request))
        store.submitUserInput(request)
        try await waitUntilStreamingFinishes(store)

        XCTAssertEqual(store.messages.last?.text, "你选择了 B")
        XCTAssertNil(store.userInputDrafts[request.id])
        XCTAssertEqual(
            store.interactionRecords.first(where: { $0.id == .userInput(request.id) })?.status,
            .resolved("已回答")
        )

        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].functionTools.map(\.name), ["request_user_input"])
        XCTAssertNil(requests[0].toolFollowUp)
        XCTAssertEqual(requests[1].toolFollowUp?.results.first?.callID, "call_input")
        XCTAssertEqual(
            requests[1].toolFollowUp?.results.first?.output,
            #"{"answers":[{"answers":["B"],"question_id":"target"}]}"#
        )
    }

    func testStoppingWhileWaitingForUserInputCancelsInteractionAndRun() async throws {
        let script = UserInputToolScript()
        let store = ConversationStore()
        store.configure(runtime: GenericAgentRuntime(
            provider: UserInputToolProvider(script: script),
            configuration: .init(
                model: "test-model",
                reasoningEnabled: true,
                userInputEnabled: true
            )
        ))
        store.draft = "先问我"

        store.send()
        try await waitUntil(store) { $0.runState == .waitingForUserInput }
        store.stop()

        XCTAssertEqual(store.runState, .cancelled)
        XCTAssertFalse(store.isStreaming)
        XCTAssertTrue(store.userInputDrafts.isEmpty)
        XCTAssertEqual(store.interactionRecords.last?.status, .cancelled)
    }

    func testStopRemovesOnlyTheEmptyAssistantPlaceholder() async throws {
        let store = ConversationStore()
        store.configure(runtime: GenericAgentRuntime(
            provider: NeverEndingProvider(),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))
        store.draft = "暂不等待"

        store.send()
        for _ in 0..<100 where !store.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.isStreaming)
        XCTAssertEqual(store.messages.last?.role, .assistant)

        store.stop()

        XCTAssertFalse(store.isStreaming)
        XCTAssertEqual(store.messages.map(\.text), ["暂不等待"])
        XCTAssertNil(store.errorMessage)
    }

    func testEmptyStreamShowsNoTextOutputErrorAndRemovesPlaceholder() async throws {
        let store = ConversationStore()
        store.configure(runtime: GenericAgentRuntime(
            provider: RecordingProvider(
                recorder: StreamRecorder(),
                result: .success([])
            ),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))
        store.draft = "空响应"

        store.send()
        try await waitUntilStreamingFinishes(store)

        XCTAssertEqual(store.messages.map(\.text), ["空响应"])
        XCTAssertEqual(
            store.errorMessage,
            "模型没有返回文本内容。请确认所选模型支持 Responses API。"
        )
        XCTAssertTrue(store.canRetry)
    }

    func testReasoningDeltasAppendToAssistantMessage() async throws {
        let store = ConversationStore()
        store.configure(runtime: GenericAgentRuntime(
            provider: RecordingProvider(
                recorder: StreamRecorder(),
                result: .success([
                    .reasoningDelta("先分析"),
                    .reasoningDelta("再回答"),
                    .textDelta("最终回答"),
                ])
            ),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))
        store.draft = "一个问题"

        store.send()
        try await waitUntilStreamingFinishes(store)

        XCTAssertEqual(store.messages.last?.reasoning, "先分析再回答")
        XCTAssertEqual(store.messages.last?.text, "最终回答")
        XCTAssertNil(store.errorMessage)
    }

    func testHostedSearchUpdatesInPlaceAndKeepsCitation() async throws {
        let store = ConversationStore()
        let searching = HostedToolSnapshot(
            id: "ws_1",
            kind: .webSearch,
            status: .searching,
            action: .search(queries: ["Swift 最新版本"]),
            sources: []
        )
        let completed = HostedToolSnapshot(
            id: "ws_1",
            kind: .webSearch,
            status: .completed,
            action: searching.action,
            sources: [HostedToolSource(url: "https://swift.org", title: "Swift")]
        )
        let citation = TextCitation(
            startIndex: 0,
            endIndex: 5,
            url: "https://swift.org",
            title: "Swift"
        )
        store.configure(runtime: GenericAgentRuntime(
            provider: RecordingProvider(
                recorder: StreamRecorder(),
                result: .success([
                    .hostedToolUpdated(searching),
                    .textDelta("Swift 最新版本"),
                    .citationAdded(citation),
                    .hostedToolUpdated(completed),
                ])
            ),
            configuration: .init(
                model: "test-model",
                reasoningEnabled: true,
                hostedTools: [.webSearch]
            )
        ))
        store.draft = "查一下 Swift"

        store.send()
        try await waitUntilStreamingFinishes(store)

        XCTAssertEqual(store.messages.last?.parts, [
            .hostedTool(completed),
            .text(TextContent(text: "Swift 最新版本", citations: [citation])),
        ])
        XCTAssertNil(store.errorMessage)
    }

    func testToolOnlyFailureKeepsSearchActivity() async throws {
        let store = ConversationStore()
        let search = HostedToolSnapshot(
            id: "ws_1",
            kind: .webSearch,
            status: .searching,
            action: .search(queries: ["无法完成的搜索"]),
            sources: []
        )
        store.configure(runtime: GenericAgentRuntime(
            provider: RecordingProvider(
                recorder: StreamRecorder(),
                result: .success([.hostedToolUpdated(search)])
            ),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))
        store.draft = "搜索"

        store.send()
        try await waitUntilStreamingFinishes(store)

        XCTAssertEqual(store.messages.last?.parts, [.hostedTool(search)])
        XCTAssertEqual(store.errorMessage, AgentFailure.noTextOutput.message)
        XCTAssertTrue(store.canRetry)
    }

    func testRegenerateLastResponseReusesLastUserMessageAndReplacesAnswer() async throws {
        let recorder = StreamRecorder()
        let store = ConversationStore(messages: [
            ChatMessage(role: .user, text: "保留的上下文"),
            ChatMessage(role: .assistant, text: "之前的回答"),
            ChatMessage(role: .user, text: "重新回答这个问题"),
            ChatMessage(role: .assistant, text: "需要替换的回答"),
        ])
        store.configure(runtime: GenericAgentRuntime(
            provider: RecordingProvider(
                recorder: recorder,
                result: .success([.textDelta("新的回答")])
            ),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))

        XCTAssertTrue(store.canRegenerateLastResponse)
        store.regenerateLastResponse()
        try await waitUntilStreamingFinishes(store)

        let receivedMessages = await recorder.messages
        XCTAssertEqual(
            receivedMessages.map(\.text),
            ["保留的上下文", "之前的回答", "重新回答这个问题"]
        )
        XCTAssertEqual(
            store.messages.map(\.text),
            ["保留的上下文", "之前的回答", "重新回答这个问题", "新的回答"]
        )
        XCTAssertTrue(store.canRegenerateLastResponse)
    }

    func testClearStartsANewCodexThread() {
        let store = ConversationStore(
            messages: [ChatMessage(role: .user, text: "旧消息")],
            threadID: "thr_old"
        )

        store.clear()

        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNil(store.threadID)
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

    func testDaemonDisconnectionFailsTheActiveRun() async throws {
        let client = RecordingDiscoDaemonClient(runID: UUID())
        let store = ConversationStore()
        store.configure(runtime: GenericAgentRuntime(
            provider: NeverEndingProvider(),
            configuration: .init(model: "fallback-model", reasoningEnabled: false)
        ))
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

    /// daemon 托管会话：消息由 daemon 保存，本地持久化回调不再收到消息副本。
    func testDaemonOwnedConversationSkipsLocalMessageCopies() {
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
        XCTAssertTrue(probe.messages.isEmpty, "daemon 托管会话不应落盘消息副本")
    }

    /// 撤销 daemon 注册后，会话退回直连路径并恢复本地落盘。
    func testRevertDaemonRegistrationRestoresLocalPersistence() {
        let probe = PersistenceProbe()
        let store = ConversationStore(
            messages: [],
            onMessagesChanged: { messages, threadID, _ in
                probe.messages = messages
                probe.threadID = threadID
            }
        )

        store.enableDaemonRuns(sessionID: UUID())
        store.restoreMessages([ChatMessage(role: .user, text: "daemon 历史")])
        XCTAssertTrue(probe.messages.isEmpty)

        store.revertDaemonRegistration()
        XCTAssertFalse(store.hasDaemonSession)
        XCTAssertEqual(probe.messages.map(\.text), ["daemon 历史"])

        store.updateThreadID("thr_1")
        XCTAssertEqual(probe.messages.map(\.text), ["daemon 历史"])
        XCTAssertEqual(probe.threadID, "thr_1")
    }

    private func waitUntil(
        _ store: ConversationStore,
        condition: (ConversationStore) -> Bool
    ) async throws {
        for _ in 0..<100 where !condition(store) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(store))
    }
}

@MainActor
private final class RecordingDiscoDaemonClient: DiscoDaemonClient {
    struct StartedRun: Equatable {
        let sessionID: UUID
        let text: String
    }

    let runID: UUID
    private(set) var startedRuns: [StartedRun] = []
    private(set) var cancelledRunIDs: [UUID] = []
    private(set) var approvals: [(UUID, String)] = []
    private(set) var deletedSessionIDs: [UUID] = []

    init(runID: UUID) {
        self.runID = runID
    }

    func events() -> AsyncThrowingStream<DaemonEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func startRun(sessionID: UUID, text: String) async throws -> UUID {
        startedRuns.append(StartedRun(sessionID: sessionID, text: text))
        return runID
    }

    func cancelRun(runID: UUID) async throws {
        cancelledRunIDs.append(runID)
    }

    func approve(approvalID: UUID, decision: String) async throws {
        approvals.append((approvalID, decision))
    }

    func deleteSession(sessionID: UUID) async throws {
        deletedSessionIDs.append(sessionID)
    }
}

private func daemonEvent(
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

private actor StreamRecorder {
    private(set) var messages: [ChatMessage] = []

    func record(_ messages: [ChatMessage]) {
        self.messages = messages
    }
}

/// 捕获持久化回调的轻量探针（@MainActor 测试内同步使用）。
private final class PersistenceProbe {
    var messages: [ChatMessage] = []
    var threadID: String?
}

private struct RecordingProvider: ModelProvider {
    let recorder: StreamRecorder
    let result: Result<[ModelEvent], Error>

    let descriptor = ProviderDescriptor(id: "recording", displayName: "Recording")

    func modelCatalog() async throws -> [ModelCatalogEntry] {
        [ModelCatalogEntry(id: "test-model")]
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(request.messages)
                switch result {
                case let .success(events):
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                case let .failure(error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

private struct NeverEndingProvider: ModelProvider {
    let descriptor = ProviderDescriptor(id: "never-ending", displayName: "NeverEnding")

    func modelCatalog() async throws -> [ModelCatalogEntry] {
        [ModelCatalogEntry(id: "test-model")]
    }
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { _ in }
    }
}

private actor UserInputToolScript {
    private(set) var requests: [ModelRequest] = []

    func events(for request: ModelRequest) -> [ModelEvent] {
        requests.append(request)
        if request.toolFollowUp == nil {
            return [
                .toolCallCompleted(ModelToolCall(
                    callID: "call_input",
                    name: "request_user_input",
                    arguments: #"{"questions":[{"id":"target","header":"目标","question":"请选择一个目标","options":[{"label":"A","description":"第一个选项"},{"label":"B","description":"第二个选项"}],"allows_other":false}]}"#
                )),
                .completed(ModelCompletion(continuation: ModelContinuation(
                    format: "test",
                    payload: Data("{}".utf8)
                ))),
            ]
        }
        return [
            .textDelta("你选择了 B"),
            .completed(ModelCompletion(continuation: nil)),
        ]
    }
}

private struct UserInputToolProvider: ModelProvider {
    let script: UserInputToolScript
    let descriptor = ProviderDescriptor(id: "user-input", displayName: "User Input")

    func modelCatalog() async throws -> [ModelCatalogEntry] {
        [ModelCatalogEntry(id: "test-model")]
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await script.events(for: request) {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

private enum TestProviderError: LocalizedError {
    case failed

    var errorDescription: String? { "测试 provider 失败" }
}
