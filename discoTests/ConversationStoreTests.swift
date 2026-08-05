import XCTest
@testable import disco

@MainActor
final class ConversationStoreTests: XCTestCase {
    func testSendTrimsDraftPassesHistoryAndPersistsFinalMessages() async throws {
        let recorder = StreamRecorder()
        let persisted = StreamRecorder()
        let store = ConversationStore(
            messages: [ChatMessage(role: .user, text: "之前的问题")],
            onMessagesChanged: { messages in
                Task { await persisted.record(messages) }
            }
        )
        store.configure(provider: RecordingProvider(
            recorder: recorder,
            result: .success([.textDelta("回答")])
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
        store.configure(provider: RecordingProvider(
            recorder: StreamRecorder(),
            result: .failure(TestProviderError.failed)
        ))
        store.draft = "请回答"

        store.send()
        try await waitUntilStreamingFinishes(store)

        XCTAssertEqual(store.messages.map(\.text), ["请回答"])
        XCTAssertEqual(store.messages.last?.role, .user)
        XCTAssertEqual(store.errorMessage, "测试 provider 失败")
        XCTAssertTrue(store.canRetry)

        store.configure(provider: RecordingProvider(
            recorder: StreamRecorder(),
            result: .success([.textDelta("重试成功")])
        ))
        store.retryLastMessage()
        try await waitUntilStreamingFinishes(store)

        XCTAssertEqual(store.messages.map(\.text), ["请回答", "重试成功"])
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.canRetry)
    }

    func testStopRemovesOnlyTheEmptyAssistantPlaceholder() async throws {
        let store = ConversationStore()
        store.configure(provider: NeverEndingProvider())
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

    private func waitUntilStreamingFinishes(_ store: ConversationStore) async throws {
        for _ in 0..<100 where store.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isStreaming)
    }
}

private actor StreamRecorder {
    private(set) var messages: [ChatMessage] = []

    func record(_ messages: [ChatMessage]) {
        self.messages = messages
    }
}

private struct RecordingProvider: AIProvider {
    let recorder: StreamRecorder
    let result: Result<[AIEvent], Error>

    func stream(messages: [ChatMessage]) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(messages)
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

private struct NeverEndingProvider: AIProvider {
    func stream(messages: [ChatMessage]) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { _ in }
    }
}

private enum TestProviderError: LocalizedError {
    case failed

    var errorDescription: String? { "测试 provider 失败" }
}
