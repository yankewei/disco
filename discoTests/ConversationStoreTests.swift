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

    private func waitUntilStreamingFinishes(_ store: ConversationStore) async throws {
        for _ in 0..<100 where store.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isStreaming)
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

private actor StreamRecorder {
    private(set) var messages: [ChatMessage] = []

    func record(_ messages: [ChatMessage]) {
        self.messages = messages
    }
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
