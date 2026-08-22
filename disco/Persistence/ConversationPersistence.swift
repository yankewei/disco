import Foundation
import SwiftData

enum SessionRuntimeKind: String, Codable, Sendable {
    case acp
    case codexAppServer = "codex_app_server"
    case rig
    case unknown

    static func from(providerID: String?) -> Self? {
        switch providerID {
        case "opencode_app_server": .acp
        case "codex_app_server": .codexAppServer
        case nil: nil
        default: .rig
        }
    }
}

struct ConversationSnapshot {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let messages: [ChatMessage]
    /// 订阅服务商（ChatGPT/Codex）的会话线程 id；重启后用于 thread/resume。
    /// API Key 服务商不使用，始终为 nil。
    let threadID: String?
    /// Project UUID；nil 表示普通对话。
    let projectID: UUID?
    /// 创建该会话时绑定的 daemon Provider profile。
    let providerID: String?
    /// 该会话实际使用的 backend runtime；不跟随当前 active provider 改变。
    let runtimeKind: SessionRuntimeKind?
    /// Generic 压缩 checkpoint 与最近压缩记录（派生缓存，消息才是事实来源）。
    var contextState: ConversationContextState? = nil

    init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        messages: [ChatMessage],
        threadID: String?,
        projectID: UUID? = nil,
        providerID: String? = nil,
        runtimeKind: SessionRuntimeKind? = nil,
        contextState: ConversationContextState? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.threadID = threadID
        self.projectID = projectID
        self.providerID = providerID
        self.runtimeKind = runtimeKind
        self.contextState = contextState
    }
}

@MainActor
protocol ConversationPersisting: AnyObject {
    func loadConversations() throws -> [ConversationSnapshot]
    func saveConversation(_ conversation: ConversationSnapshot) throws
    func deleteConversation(id: UUID) throws
}

@MainActor
protocol ProjectPersisting: AnyObject {
    func loadProjects() throws -> [ProjectSnapshot]
    func saveProject(_ project: ProjectSnapshot) throws
    func deleteProject(id: UUID) throws
}

@MainActor
final class ConversationPersistence: ConversationPersisting, ProjectPersisting {
    private let container: ModelContainer
    private let context: ModelContext

    init(storeURL: URL? = nil, isStoredInMemoryOnly: Bool = false) throws {
        let configuration: ModelConfiguration
        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                for: PersistedConversation.self,
                PersistedMessage.self,
                PersistedProject.self,
                isStoredInMemoryOnly: true
            )
        } else {
            // 显式指定存储位置：~/Library/Application Support/disco/conversations.store。
            // Project/Workspace 开发基线已明确放弃旧会话，因此这里不再迁移旧 store。
            let resolvedStoreURL = storeURL ?? Self.defaultStoreURL
            try FileManager.default.createDirectory(
                at: resolvedStoreURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(
                "disco",
                url: resolvedStoreURL
            )
        }
        container = try ModelContainer(
            for: PersistedConversation.self,
            PersistedMessage.self,
            PersistedProject.self,
            configurations: configuration
        )
        context = container.mainContext
        context.autosaveEnabled = false
    }

    private static var defaultStoreURL: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return directory
            .appendingPathComponent("disco", isDirectory: true)
            .appendingPathComponent("conversations.store")
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
                    return Self.restoreMessage(
                        id: message.id,
                        role: role,
                        text: message.text,
                        reasoning: message.reasoning,
                        partsData: message.partsData
                    )
                }
            if messages.last?.role == .assistant, messages.last?.isEmpty == true {
                messages.removeLast()
            }
            return ConversationSnapshot(
                id: conversation.id,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt,
                messages: messages,
                threadID: conversation.threadID,
                projectID: conversation.projectID,
                providerID: conversation.providerID,
                runtimeKind: conversation.runtimeKind.flatMap(SessionRuntimeKind.init(rawValue:)),
                // 解码/版本/校验失败时丢弃 checkpoint，不删除消息（计划 §2）
                contextState: PersistedConversationContextState.decode(conversation.contextStateData)
            )
        }
    }

    func loadProjects() throws -> [ProjectSnapshot] {
        let descriptor = FetchDescriptor<PersistedProject>(
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map {
            ProjectSnapshot(
                id: $0.id,
                name: $0.name,
                workspaceRoot: URL(fileURLWithPath: $0.workspacePath),
                bookmarkData: $0.bookmarkData,
                createdAt: $0.createdAt,
                lastOpenedAt: $0.lastOpenedAt
            )
        }
    }

    func saveProject(_ project: ProjectSnapshot) throws {
        let projectID = project.id
        let descriptor = FetchDescriptor<PersistedProject>(
            predicate: #Predicate { $0.id == projectID }
        )
        let persistedProject: PersistedProject
        if let existing = try context.fetch(descriptor).first {
            persistedProject = existing
        } else {
            persistedProject = PersistedProject(
                id: project.id,
                name: project.name,
                workspacePath: project.workspaceRoot.path,
                bookmarkData: project.bookmarkData,
                createdAt: project.createdAt,
                lastOpenedAt: project.lastOpenedAt
            )
            context.insert(persistedProject)
        }
        persistedProject.name = project.name
        persistedProject.workspacePath = project.workspaceRoot.path
        persistedProject.bookmarkData = project.bookmarkData
        persistedProject.lastOpenedAt = project.lastOpenedAt
        try context.save()
    }

    func deleteProject(id: UUID) throws {
        let projectID = id
        let projectDescriptor = FetchDescriptor<PersistedProject>(
            predicate: #Predicate { $0.id == projectID }
        )
        if let project = try context.fetch(projectDescriptor).first {
            context.delete(project)
        }

        let conversationDescriptor = FetchDescriptor<PersistedConversation>(
            predicate: #Predicate { $0.projectID == projectID }
        )
        for conversation in try context.fetch(conversationDescriptor) {
            context.delete(conversation)
        }
        try context.save()
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
        persistedConversation.projectID = conversation.projectID
        persistedConversation.providerID = conversation.providerID
        persistedConversation.runtimeKind = conversation.runtimeKind?.rawValue
        persistedConversation.contextStateData = try PersistedConversationContextState
            .encode(conversation.contextState)

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
                persistedMessage.partsData = try PersistedPartsEnvelope.encode(message.parts)
                persistedMessage.position = position
            } else {
                let persistedMessage = PersistedMessage(
                    id: message.id,
                    role: message.role.rawValue,
                    text: message.text,
                    reasoning: message.reasoning,
                    partsData: try PersistedPartsEnvelope.encode(message.parts),
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

    /// 新 parts 格式优先；损坏、未知版本或旧记录统一回退到 legacy 列。
    static func restoreMessage(
        id: UUID,
        role: ChatMessage.Role,
        text: String,
        reasoning: String,
        partsData: Data?
    ) -> ChatMessage {
        if let partsData, let parts = try? PersistedPartsEnvelope.decode(partsData) {
            return ChatMessage(id: id, role: role, parts: parts)
        }
        return ChatMessage(id: id, role: role, text: text, reasoning: reasoning)
    }
}

@MainActor
final class VolatileConversationPersistence: ConversationPersisting, ProjectPersisting {
    private var conversations: [UUID: ConversationSnapshot] = [:]
    private var projects: [UUID: ProjectSnapshot] = [:]

    func loadConversations() -> [ConversationSnapshot] {
        conversations.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveConversation(_ conversation: ConversationSnapshot) {
        conversations[conversation.id] = conversation
    }

    func deleteConversation(id: UUID) {
        conversations[id] = nil
    }

    func loadProjects() -> [ProjectSnapshot] {
        projects.values.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    func saveProject(_ project: ProjectSnapshot) {
        projects[project.id] = project
    }

    func deleteProject(id: UUID) {
        projects[id] = nil
        conversations = conversations.filter { $0.value.projectID != id }
    }
}

@Model
private final class PersistedConversation {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    /// 订阅服务商的会话线程 id（其余服务商为 nil）
    var threadID: String?
    /// Project UUID；nil 表示普通对话。
    var projectID: UUID?
    /// daemon Provider profile；旧记录可能为空。
    var providerID: String?
    /// SessionRuntimeKind.rawValue；旧记录可能为空。
    var runtimeKind: String?
    /// 版本化 JSON（PersistedConversationContextState）；旧库记录为 nil。
    var contextStateData: Data? = nil
    @Relationship(deleteRule: .cascade, inverse: \PersistedMessage.conversation)
    var messages: [PersistedMessage] = []

    init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        threadID: String? = nil,
        projectID: UUID? = nil,
        providerID: String? = nil,
        runtimeKind: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.threadID = threadID
        self.projectID = projectID
        self.providerID = providerID
        self.runtimeKind = runtimeKind
    }
}

@Model
private final class PersistedProject {
    @Attribute(.unique) var id: UUID
    var name: String
    var workspacePath: String
    var bookmarkData: Data?
    var createdAt: Date
    var lastOpenedAt: Date

    init(
        id: UUID,
        name: String,
        workspacePath: String,
        bookmarkData: Data?,
        createdAt: Date,
        lastOpenedAt: Date
    ) {
        self.id = id
        self.name = name
        self.workspacePath = workspacePath
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}

/// 会话上下文状态的持久化线格式（计划《上下文压缩 v1》§2）。
/// 显式 version 避免依赖合成编码格式；解码失败统一返回 nil（丢弃 checkpoint，不动消息）。
struct PersistedConversationContextState: Codable {
    static let currentVersion = 1

    let version: Int
    let checkpoint: ContextCheckpoint?
    let lastSuccessfulCompaction: ContextCompactionSnapshot?

    static func encode(_ state: ConversationContextState?) throws -> Data? {
        guard let state, state.checkpoint != nil || state.lastSuccessfulCompaction != nil else {
            return nil
        }
        return try JSONEncoder().encode(
            PersistedConversationContextState(
                version: currentVersion,
                checkpoint: state.checkpoint,
                lastSuccessfulCompaction: state.lastSuccessfulCompaction
            )
        )
    }

    static func decode(_ data: Data?) -> ConversationContextState? {
        guard let data,
              let decoded = try? JSONDecoder().decode(PersistedConversationContextState.self, from: data),
              decoded.version == currentVersion else {
            return nil
        }
        return ConversationContextState(
            checkpoint: decoded.checkpoint,
            lastSuccessfulCompaction: decoded.lastSuccessfulCompaction
        )
    }
}

@Model
private final class PersistedMessage {
    @Attribute(.unique) var id: UUID
    var role: String
    var text: String
    var reasoning: String = ""
    var partsData: Data? = nil
    var position: Int
    var conversation: PersistedConversation?

    init(
        id: UUID,
        role: String,
        text: String,
        reasoning: String,
        partsData: Data? = nil,
        position: Int,
        conversation: PersistedConversation
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.partsData = partsData
        self.position = position
        self.conversation = conversation
    }
}

/// parts 的稳定持久化线格式。显式 version/type 避免依赖 Swift enum 的合成编码格式。
private struct PersistedPartsEnvelope: Codable {
    private static let currentVersion = 1

    let version: Int
    let parts: [PersistedPart]

    static func encode(_ parts: [ChatMessage.Part]) throws -> Data {
        try JSONEncoder().encode(
            PersistedPartsEnvelope(version: currentVersion, parts: parts.map(PersistedPart.init))
        )
    }

    static func decode(_ data: Data) throws -> [ChatMessage.Part] {
        let envelope = try JSONDecoder().decode(PersistedPartsEnvelope.self, from: data)
        guard envelope.version == currentVersion else {
            throw PartsCodingError.unsupportedVersion
        }
        return try envelope.parts.map { try $0.part }
    }
}

private struct PersistedPart: Codable {
    enum Kind: String, Codable {
        case text
        case reasoning
        case hostedTool
        case toolCall
    }

    let type: Kind
    let text: TextContent?
    let reasoning: String?
    let hostedTool: HostedToolSnapshot?
    let toolCall: ChatMessage.ToolCallSnapshot?

    nonisolated init(_ part: ChatMessage.Part) {
        switch part {
        case let .text(content):
            type = .text
            text = content
            reasoning = nil
            hostedTool = nil
            toolCall = nil
        case let .reasoning(value):
            type = .reasoning
            text = nil
            reasoning = value
            hostedTool = nil
            toolCall = nil
        case let .hostedTool(snapshot):
            type = .hostedTool
            text = nil
            reasoning = nil
            hostedTool = snapshot
            toolCall = nil
        case let .toolCall(snapshot):
            type = .toolCall
            text = nil
            reasoning = nil
            hostedTool = nil
            toolCall = snapshot
        }
    }

    var part: ChatMessage.Part {
        get throws {
            switch type {
            case .text:
                guard let text else { throw PartsCodingError.missingPayload }
                return .text(text)
            case .reasoning:
                guard let reasoning else { throw PartsCodingError.missingPayload }
                return .reasoning(reasoning)
            case .hostedTool:
                guard let hostedTool else { throw PartsCodingError.missingPayload }
                return .hostedTool(hostedTool)
            case .toolCall:
                guard let toolCall else { throw PartsCodingError.missingPayload }
                return .toolCall(toolCall)
            }
        }
    }
}

private enum PartsCodingError: Error {
    case unsupportedVersion
    case missingPayload
}
