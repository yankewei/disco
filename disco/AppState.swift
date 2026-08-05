import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var hasAPIKey = false
    @Published private(set) var keychainError: String?
    @Published private(set) var storageError: String?
    @Published private(set) var baseURL: String
    @Published private(set) var model: String
    @Published private(set) var conversations: [ConversationSession]
    @Published var selectedConversationID: ConversationSession.ID? {
        didSet {
            if let selectedConversationID {
                defaults.set(selectedConversationID.uuidString, forKey: "selectedConversationID")
            } else {
                defaults.removeObject(forKey: "selectedConversationID")
            }
        }
    }

    private let keychain: APIKeyStoring
    private let defaults: UserDefaults
    private let persistence: ConversationPersisting
    private var provider: AIProvider?

    var selectedConversation: ConversationSession? {
        guard let selectedConversationID else { return conversations.first }
        return conversations.first { $0.id == selectedConversationID } ?? conversations.first
    }

    init(
        keychain: APIKeyStoring? = nil,
        defaults: UserDefaults? = nil,
        persistence: ConversationPersisting? = nil
    ) {
        let keychain = keychain ?? KeychainStore()
        let defaults = defaults ?? .standard
        let resolvedPersistence: ConversationPersisting
        var startupStorageError: String?
        if let persistence {
            resolvedPersistence = persistence
        } else {
            do {
                resolvedPersistence = try ConversationPersistence()
            } catch {
                resolvedPersistence = VolatileConversationPersistence()
                startupStorageError = "无法打开本地会话数据库：\(error.localizedDescription)"
            }
        }
        self.keychain = keychain
        self.defaults = defaults
        self.persistence = resolvedPersistence
        conversations = []
        selectedConversationID = nil
        baseURL = defaults.string(forKey: "apiBaseURL")
            ?? OpenAIResponsesProvider.defaultBaseURL.absoluteString
        model = defaults.string(forKey: "apiModel")
            ?? OpenAIResponsesProvider.defaultModel
        storageError = startupStorageError

        do {
            conversations = try resolvedPersistence.loadConversations().map {
                makeConversation(
                    id: $0.id,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    messages: $0.messages
                )
            }
        } catch {
            storageError = "无法读取本地会话：\(error.localizedDescription)"
        }
        if conversations.isEmpty {
            conversations = [makeConversation()]
        }

        let restoredSelection = defaults.string(forKey: "selectedConversationID")
            .flatMap(UUID.init(uuidString:))
        selectedConversationID = conversations.contains(where: { $0.id == restoredSelection })
            ? restoredSelection
            : conversations.first?.id

        do {
            if let apiKey = try keychain.load(), !apiKey.isEmpty {
                let providerBaseURL: URL
                do {
                    providerBaseURL = try Self.validatedBaseURL(baseURL)
                } catch {
                    baseURL = OpenAIResponsesProvider.defaultBaseURL.absoluteString
                    providerBaseURL = OpenAIResponsesProvider.defaultBaseURL
                }
                hasAPIKey = true
                installProvider(OpenAIResponsesProvider(
                    apiKey: apiKey,
                    baseURL: providerBaseURL,
                    model: model
                ))
            }
        } catch {
            keychainError = error.localizedDescription
        }
    }

    func availableModels(baseURL: String, apiKey: String) async throws -> [String] {
        let providerBaseURL = try Self.validatedBaseURL(baseURL)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey: String
        if trimmedKey.isEmpty {
            guard let storedKey = try keychain.load(), !storedKey.isEmpty else {
                throw APIConfigurationError.missingAPIKey
            }
            resolvedKey = storedKey
        } else {
            resolvedKey = trimmedKey
        }

        return try await OpenAIResponsesProvider(
            apiKey: resolvedKey,
            baseURL: providerBaseURL,
            model: model
        ).availableModels()
    }

    func saveConfiguration(baseURL: String, apiKey: String, model: String) throws {
        let providerBaseURL = try Self.validatedBaseURL(baseURL)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw APIConfigurationError.missingModel
        }

        let resolvedKey: String
        if trimmedKey.isEmpty {
            guard let storedKey = try keychain.load(), !storedKey.isEmpty else {
                throw APIConfigurationError.missingAPIKey
            }
            resolvedKey = storedKey
        } else {
            try keychain.save(trimmedKey)
            resolvedKey = trimmedKey
        }

        let provider = OpenAIResponsesProvider(
            apiKey: resolvedKey,
            baseURL: providerBaseURL,
            model: trimmedModel
        )
        installProvider(provider)
        self.baseURL = providerBaseURL.absoluteString
        self.model = trimmedModel
        defaults.set(self.baseURL, forKey: "apiBaseURL")
        defaults.set(trimmedModel, forKey: "apiModel")
        hasAPIKey = true
        keychainError = nil
    }

    func deleteAPIKey() throws {
        try keychain.delete()
        installProvider(nil)
        hasAPIKey = false
        keychainError = nil
    }

    @discardableResult
    func createConversation() -> ConversationSession.ID {
        if let emptyConversation = conversations.first(where: { $0.store.messages.isEmpty }) {
            selectedConversationID = emptyConversation.id
            return emptyConversation.id
        }

        let conversation = makeConversation()
        conversation.store.configure(provider: provider)
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        return conversation.id
    }

    func deleteConversation(id: ConversationSession.ID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].store.stop()
        conversations.remove(at: index)
        do {
            try persistence.deleteConversation(id: id)
            storageError = nil
        } catch {
            storageError = "无法删除本地会话：\(error.localizedDescription)"
        }

        if conversations.isEmpty {
            let conversation = makeConversation()
            conversation.store.configure(provider: provider)
            conversations = [conversation]
        }
        if selectedConversationID == id {
            selectedConversationID = conversations.first?.id
        }
    }

    private func makeConversation(
        id: UUID = UUID(),
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        messages: [ChatMessage] = []
    ) -> ConversationSession {
        ConversationSession(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages
        ) { [weak self] messages in
            self?.persistConversation(
                id: id,
                createdAt: createdAt,
                messages: messages
            )
        }
    }

    private func persistConversation(
        id: UUID,
        createdAt: Date,
        messages: [ChatMessage]
    ) {
        let updatedAt = Date.now
        markConversationAsRecent(id: id, updatedAt: updatedAt)
        do {
            if messages.isEmpty {
                try persistence.deleteConversation(id: id)
            } else {
                try persistence.saveConversation(
                    ConversationSnapshot(
                        id: id,
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        messages: messages
                    )
                )
            }
            if storageError != nil {
                storageError = nil
            }
        } catch {
            storageError = "无法保存本地会话：\(error.localizedDescription)"
        }
    }

    private func markConversationAsRecent(id: UUID, updatedAt: Date) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].updatedAt = updatedAt
        guard index > 0 else { return }
        let conversation = conversations.remove(at: index)
        conversations.insert(conversation, at: 0)
    }

    private func installProvider(_ provider: AIProvider?) {
        self.provider = provider
        for conversation in conversations {
            conversation.store.stop()
            conversation.store.configure(provider: provider)
        }
    }

    private static func validatedBaseURL(_ value: String) throws -> URL {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        guard let url = URL(string: normalized),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw APIConfigurationError.invalidBaseURL
        }
        return url
    }
}

enum APIConfigurationError: LocalizedError {
    case invalidBaseURL
    case missingAPIKey
    case missingModel

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Base URL 必须是有效的 HTTPS 地址，且不能包含查询参数或片段。"
        case .missingAPIKey:
            "请填写 API Key。"
        case .missingModel:
            "请先获取并选择一个模型。"
        }
    }
}
