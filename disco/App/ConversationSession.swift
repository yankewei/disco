import Foundation

@MainActor
struct ConversationSession: Identifiable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let store: ConversationStore

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        messages: [ChatMessage] = [],
        threadID: String? = nil,
        contextState: ConversationContextState = ConversationContextState(),
        onMessagesChanged: @escaping ([ChatMessage], String?, ConversationContextState) -> Void = { _, _, _ in }
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        store = ConversationStore(
            messages: messages,
            threadID: threadID,
            contextState: contextState,
            onMessagesChanged: onMessagesChanged
        )
    }
}
