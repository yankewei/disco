import XCTest
@testable import disco

@MainActor
final class ConversationPersistenceTests: XCTestCase {
    func testRepeatedStreamingSavesUpdateMessagesWithoutDuplicates() throws {
        let persistence = try ConversationPersistence(isStoredInMemoryOnly: true)
        let conversationID = UUID()
        let createdAt = Date.now
        let userMessage = ChatMessage(role: .user, text: "解释 SwiftData")
        let assistantID = UUID()

        try persistence.saveConversation(
            ConversationSnapshot(
                id: conversationID,
                createdAt: createdAt,
                updatedAt: createdAt,
                messages: [
                    userMessage,
                    ChatMessage(id: assistantID, role: .assistant, text: "SwiftData 是"),
                ],
                threadID: nil
            )
        )
        try persistence.saveConversation(
            ConversationSnapshot(
                id: conversationID,
                createdAt: createdAt,
                updatedAt: .now,
                messages: [
                    userMessage,
                    ChatMessage(id: assistantID, role: .assistant, text: "SwiftData 是本地持久化框架。"),
                ],
                threadID: nil
            )
        )

        let restored = try XCTUnwrap(persistence.loadConversations().first)
        XCTAssertEqual(restored.messages.count, 2)
        XCTAssertEqual(restored.messages.last?.id, assistantID)
        XCTAssertEqual(restored.messages.last?.text, "SwiftData 是本地持久化框架。")
    }

    func testReasoningPersistsAcrossSaveAndLoad() throws {
        let persistence = try ConversationPersistence(isStoredInMemoryOnly: true)
        let conversationID = UUID()
        let createdAt = Date.now
        let assistantMessage = ChatMessage(
            id: UUID(),
            role: .assistant,
            text: "回答",
            reasoning: "内部思考"
        )

        try persistence.saveConversation(
            ConversationSnapshot(
                id: conversationID,
                createdAt: createdAt,
                updatedAt: createdAt,
                messages: [
                    ChatMessage(role: .user, text: "问题"),
                    assistantMessage,
                ],
                threadID: nil
            )
        )

        let restored = try XCTUnwrap(persistence.loadConversations().first)
        let restoredAssistant = try XCTUnwrap(restored.messages.last)
        XCTAssertEqual(restoredAssistant.text, "回答")
        XCTAssertEqual(restoredAssistant.reasoning, "内部思考")
    }

    /// 订阅服务商：会话线程 id 持久化往返（重启后用于 thread/resume）
    func testThreadIDPersistsAcrossSaveAndLoad() throws {
        let persistence = try ConversationPersistence(isStoredInMemoryOnly: true)
        let conversationID = UUID()
        let createdAt = Date.now

        try persistence.saveConversation(
            ConversationSnapshot(
                id: conversationID,
                createdAt: createdAt,
                updatedAt: createdAt,
                messages: [
                    ChatMessage(role: .user, text: "你好"),
                    ChatMessage(role: .assistant, text: "你好！"),
                ],
                threadID: "thr_abc123"
            )
        )

        let restored = try XCTUnwrap(persistence.loadConversations().first)
        XCTAssertEqual(restored.threadID, "thr_abc123")

        // 覆盖保存时 threadID 跟随更新
        try persistence.saveConversation(
            ConversationSnapshot(
                id: conversationID,
                createdAt: createdAt,
                updatedAt: .now,
                messages: restored.messages,
                threadID: "thr_def456"
            )
        )
        let reloaded = try XCTUnwrap(persistence.loadConversations().first)
        XCTAssertEqual(reloaded.threadID, "thr_def456")
    }
}
