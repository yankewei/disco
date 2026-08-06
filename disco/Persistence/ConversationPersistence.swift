import Foundation
import SwiftData

struct ConversationSnapshot {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let messages: [ChatMessage]
}

@MainActor
protocol ConversationPersisting: AnyObject {
    func loadConversations() throws -> [ConversationSnapshot]
    func saveConversation(_ conversation: ConversationSnapshot) throws
    func deleteConversation(id: UUID) throws
}

@MainActor
final class ConversationPersistence: ConversationPersisting {
    private let container: ModelContainer
    private let context: ModelContext

    init(isStoredInMemoryOnly: Bool = false) throws {
        let configuration = ModelConfiguration(
            for: PersistedConversation.self,
            PersistedMessage.self,
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )
        container = try ModelContainer(
            for: PersistedConversation.self,
            PersistedMessage.self,
            configurations: configuration
        )
        context = container.mainContext
        context.autosaveEnabled = false
    }

    func loadConversations() throws -> [ConversationSnapshot] {
        let descriptor = FetchDescriptor<PersistedConversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map { conversation in
            var messages = conversation.messages
                .sorted { $0.position < $1.position }
                .compactMap { message -> ChatMessage? in
                    guard let role = ChatMessage.Role(rawValue: message.role) else { return nil }
                    return ChatMessage(
                        id: message.id,
                        role: role,
                        text: message.text,
                        reasoning: message.reasoning
                    )
                }
            if messages.last?.role == .assistant, messages.last?.text.isEmpty == true {
                messages.removeLast()
            }
            return ConversationSnapshot(
                id: conversation.id,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt,
                messages: messages
            )
        }
    }

    func saveConversation(_ conversation: ConversationSnapshot) throws {
        let conversationID = conversation.id
        let descriptor = FetchDescriptor<PersistedConversation>(
            predicate: #Predicate { $0.id == conversationID }
        )
        let persistedConversation: PersistedConversation
        if let existing = try context.fetch(descriptor).first {
            persistedConversation = existing
        } else {
            persistedConversation = PersistedConversation(
                id: conversation.id,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt
            )
            context.insert(persistedConversation)
        }

        persistedConversation.updatedAt = conversation.updatedAt

        let existingMessages = Dictionary(
            uniqueKeysWithValues: persistedConversation.messages.map { ($0.id, $0) }
        )
        let retainedIDs = Set(conversation.messages.map(\.id))
        for message in persistedConversation.messages where !retainedIDs.contains(message.id) {
            context.delete(message)
        }
        persistedConversation.messages.removeAll { !retainedIDs.contains($0.id) }

        for (position, message) in conversation.messages.enumerated() {
            if let persistedMessage = existingMessages[message.id] {
                persistedMessage.role = message.role.rawValue
                persistedMessage.text = message.text
                persistedMessage.reasoning = message.reasoning
                persistedMessage.position = position
            } else {
                let persistedMessage = PersistedMessage(
                    id: message.id,
                    role: message.role.rawValue,
                    text: message.text,
                    reasoning: message.reasoning,
                    position: position,
                    conversation: persistedConversation
                )
                context.insert(persistedMessage)
                persistedConversation.messages.append(persistedMessage)
            }
        }
        try context.save()
    }

    func deleteConversation(id: UUID) throws {
        let conversationID = id
        let descriptor = FetchDescriptor<PersistedConversation>(
            predicate: #Predicate { $0.id == conversationID }
        )
        if let conversation = try context.fetch(descriptor).first {
            context.delete(conversation)
            try context.save()
        }
    }
}

@MainActor
final class VolatileConversationPersistence: ConversationPersisting {
    private var conversations: [UUID: ConversationSnapshot] = [:]

    func loadConversations() -> [ConversationSnapshot] {
        conversations.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveConversation(_ conversation: ConversationSnapshot) {
        conversations[conversation.id] = conversation
    }

    func deleteConversation(id: UUID) {
        conversations[id] = nil
    }
}

@Model
private final class PersistedConversation {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \PersistedMessage.conversation)
    var messages: [PersistedMessage] = []

    init(id: UUID, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
private final class PersistedMessage {
    @Attribute(.unique) var id: UUID
    var role: String
    var text: String
    var reasoning: String = ""
    var position: Int
    var conversation: PersistedConversation?

    init(
        id: UUID,
        role: String,
        text: String,
        reasoning: String,
        position: Int,
        conversation: PersistedConversation
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.position = position
        self.conversation = conversation
    }
}
