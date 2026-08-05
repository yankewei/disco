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
                ]
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
                ]
            )
        )

        let restored = try XCTUnwrap(persistence.loadConversations().first)
        XCTAssertEqual(restored.messages.count, 2)
        XCTAssertEqual(restored.messages.last?.id, assistantID)
        XCTAssertEqual(restored.messages.last?.text, "SwiftData 是本地持久化框架。")
    }
}
