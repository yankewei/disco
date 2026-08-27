import XCTest
@testable import disco

@MainActor
final class MessageRegenerationTests: XCTestCase {
    func testCanRegenerateAfterCompletedExchange() {
        let store = ConversationStore()
        store.configure(daemonClient: RecordingDiscoDaemonClient(runID: UUID()))
        store.enableDaemonRuns(sessionID: UUID())
        store.restoreMessages([
            ChatMessage(role: .user, text: "问题"),
            ChatMessage(role: .assistant, text: "回答"),
        ])

        // 正常完成后即可重新生成，不要求处于错误状态
        XCTAssertTrue(store.canRegenerate)
        XCTAssertFalse(store.canRetry)
    }

    func testCanRegenerateForUnansweredUserMessage() {
        let store = ConversationStore()
        store.configure(daemonClient: RecordingDiscoDaemonClient(runID: UUID()))
        store.enableDaemonRuns(sessionID: UUID())
        store.restoreMessages([ChatMessage(role: .user, text: "问题")])

        XCTAssertTrue(store.canRegenerate)
    }

    func testEditRemainsAvailableWithoutRuntimeButRegenerateDoesNot() {
        let store = ConversationStore()
        store.restoreMessages([
            ChatMessage(role: .user, text: "问题"),
            ChatMessage(role: .assistant, text: "回答"),
        ])

        XCTAssertTrue(store.canEditLastUserMessage)
        XCTAssertFalse(store.canRegenerate)
    }

    func testRegenerateWithoutRuntimeDoesNotDiscardHistory() {
        let store = ConversationStore()
        store.restoreMessages([
            ChatMessage(role: .user, text: "问题"),
            ChatMessage(role: .assistant, text: "回答"),
        ])

        store.regenerateLastResponse()

        XCTAssertEqual(store.messages.map(\.text), ["问题", "回答"])
        XCTAssertEqual(store.draft, "")
    }

    func testCannotRegenerateWhileStreaming() async throws {
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
        XCTAssertTrue(store.isStreaming)
        XCTAssertFalse(store.canRegenerate)

        // 结束运行后恢复可重新生成
        store.handleDaemonNotification(daemonEvent(
            "run.completed",
            runID: runID,
            sessionID: sessionID
        ))
        XCTAssertFalse(store.isStreaming)
        XCTAssertTrue(store.canRegenerate)
    }

    func testBeginEditLoadsLastUserMessageAndKeepsHistory() {
        let store = ConversationStore()
        store.restoreMessages([
            ChatMessage(role: .user, text: "第一轮"),
            ChatMessage(role: .assistant, text: "第一轮回答"),
            ChatMessage(role: .user, text: "第二轮问题"),
            ChatMessage(role: .assistant, text: "第二轮回答"),
        ])

        store.beginEditLastUserMessage()

        XCTAssertEqual(store.draft, "第二轮问题")
        XCTAssertEqual(
            store.messages.map(\.text),
            ["第一轮", "第一轮回答", "第二轮问题", "第二轮回答"]
        )
    }

    func testBeginEditOnUnansweredUserMessageKeepsDraftAndHistory() {
        let store = ConversationStore()
        store.restoreMessages([ChatMessage(role: .user, text: "只有一条")])

        store.beginEditLastUserMessage()

        XCTAssertEqual(store.draft, "只有一条")
        XCTAssertEqual(store.messages.map(\.text), ["只有一条"])
    }

    func testBeginEditOnEmptyConversationIsNoOp() {
        let store = ConversationStore()
        store.draft = "已有草稿"

        store.beginEditLastUserMessage()

        XCTAssertEqual(store.draft, "已有草稿")
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testRegenerateKeepsHistoryAndStartsAnotherRun() async throws {
        let client = RecordingDiscoDaemonClient(runID: UUID())
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: UUID())
        store.restoreMessages([
            ChatMessage(role: .user, text: "重试的问题"),
            ChatMessage(role: .assistant, text: "回答"),
        ])

        store.regenerateLastResponse()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.draft, "")
        XCTAssertEqual(client.startedRuns.count, 1)
        XCTAssertEqual(
            store.messages.map(\.text),
            ["重试的问题", "回答", "重试的问题", ""]
        )
    }
}
