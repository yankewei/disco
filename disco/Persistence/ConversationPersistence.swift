import Foundation
import SwiftData

struct ConversationSnapshot {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let messages: [ChatMessage]
    /// 订阅服务商（ChatGPT/Codex）的会话线程 id；重启后用于 thread/resume。
    /// API Key 服务商不使用，始终为 nil。
    let threadID: String?
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
        let configuration: ModelConfiguration
        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                for: PersistedConversation.self,
                PersistedMessage.self,
                isStoredInMemoryOnly: true
            )
        } else {
            // 显式指定存储位置：~/Library/Application Support/disco/conversations.store
            // （本应用曾启用 App Sandbox，数据在容器内；关闭沙盒后迁移旧存储，见 migrateFromContainer）
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support")
            let storeURL = directory
                .appendingPathComponent("disco", isDirectory: true)
                .appendingPathComponent("conversations.store")
            try Self.migrateContainerStoreIfNeeded(to: storeURL)
            configuration = ModelConfiguration(
                "disco",
                url: storeURL
            )
        }
        container = try ModelContainer(
            for: PersistedConversation.self,
            PersistedMessage.self,
            configurations: configuration
        )
        context = container.mainContext
        context.autosaveEnabled = false
    }

    /// 沙盒容器内的旧 SwiftData 存储迁移到新位置（关闭 App Sandbox 后）。
    /// 新位置已存在时不迁移；迁移失败不阻塞启动（空会话可接受）。
    private static func migrateContainerStoreIfNeeded(to storeURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.yankewei.disco"
        let containerStore = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")
            .appendingPathComponent(bundleID)
            .appendingPathComponent("Data/Library/Application Support/default.store")
        guard FileManager.default.fileExists(atPath: containerStore.path) else { return }

        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // SwiftData 采用 WAL：连带 -wal / -shm 一起迁移
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: containerStore.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.moveItem(
                at: source,
                to: URL(fileURLWithPath: storeURL.path + suffix)
            )
        }
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
                messages: messages,
                threadID: conversation.threadID
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
        persistedConversation.threadID = conversation.threadID

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
    /// 订阅服务商的会话线程 id（其余服务商为 nil）
    var threadID: String?
    @Relationship(deleteRule: .cascade, inverse: \PersistedMessage.conversation)
    var messages: [PersistedMessage] = []

    init(id: UUID, createdAt: Date, updatedAt: Date, threadID: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.threadID = threadID
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
