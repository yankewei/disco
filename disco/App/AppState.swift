import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var activeVendor: ProviderVendor
    @Published private(set) var providerConfigs: [ProviderVendor: ProviderConfig]
    @Published private(set) var authError: String?
    @Published private(set) var storageError: String?
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

    /// 当前使用（active）服务商的配置，供聊天界面读取
    var baseURL: String { providerConfigs[activeVendor]?.baseURL ?? "" }
    var model: String { providerConfigs[activeVendor]?.model ?? "" }
    var hasAPIKey: Bool { providerConfigs[activeVendor]?.hasAPIKey ?? false }

    private let keyStores: [ProviderVendor: APIKeyStoring]
    private let defaults: UserDefaults
    private let persistence: ConversationPersisting
    private var provider: ModelProvider?

    var selectedConversation: ConversationSession? {
        guard let selectedConversationID else { return conversations.first }
        return conversations.first { $0.id == selectedConversationID } ?? conversations.first
    }

    init(
        keychain: APIKeyStoring? = nil,
        defaults: UserDefaults? = nil,
        persistence: ConversationPersisting? = nil
    ) {
        let baseKeyStore = keychain ?? AuthFileStore()
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
        self.defaults = defaults
        self.persistence = resolvedPersistence
        self.keyStores = Dictionary(
            uniqueKeysWithValues: ProviderVendor.allCases.map {
                ($0, baseKeyStore.forAccount($0.keychainAccount))
            }
        )
        // 旧版全局思考模式开关：升级后迁移为各服务商的默认值，并移除旧键
        let legacyThinking = defaults.object(forKey: LegacyProviderKeys.thinkingEnabled) as? Bool
        storageError = startupStorageError
        conversations = []
        selectedConversationID = nil

        // 迁移旧版单服务商配置（apiBaseURL/apiModel + 旧 account）
        Self.migrateLegacyConfiguration(defaults: defaults, keyStores: self.keyStores)

        var loaded: [ProviderVendor: ProviderConfig] = [:]
        for vendor in ProviderVendor.allCases {
            guard let baseURL = defaults.string(forKey: vendor.baseURLDefaultsKey) else { continue }
            let storedKey = (try? self.keyStores[vendor]?.load()).flatMap { $0 }
            loaded[vendor] = ProviderConfig(
                baseURL: baseURL,
                model: defaults.string(forKey: vendor.modelDefaultsKey) ?? "",
                hasAPIKey: storedKey.map { !$0.isEmpty } ?? false,
                models: defaults.stringArray(forKey: vendor.modelsDefaultsKey) ?? [],
                thinkingEnabled: defaults.object(forKey: vendor.thinkingEnabledDefaultsKey) as? Bool ?? legacyThinking ?? true
            )
        }
        providerConfigs = loaded
        // 旧版全局开关迁移：写入已配置服务商的 per-vendor 键（不覆盖已存在的值），再移除旧键
        if let legacyThinking {
            for vendor in loaded.keys where defaults.object(forKey: vendor.thinkingEnabledDefaultsKey) == nil {
                defaults.set(legacyThinking, forKey: vendor.thinkingEnabledDefaultsKey)
            }
        }
        defaults.removeObject(forKey: LegacyProviderKeys.thinkingEnabled)

        let persistedActive = defaults.string(forKey: LegacyProviderKeys.activeVendor)
            .flatMap(ProviderVendor.init(rawValue:))
        let firstConfiguredVendor = ProviderVendor.allCases.first { loaded[$0] != nil }
        activeVendor = persistedActive ?? firstConfiguredVendor ?? .deepseek

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

        if providerConfigs[activeVendor]?.hasAPIKey == true,
           let provider = makeProvider(vendor: activeVendor) {
            installProvider(provider, stopActiveStreams: true)
        }
    }

    // MARK: - 多服务商配置

    func config(for vendor: ProviderVendor) -> ProviderConfig? {
        providerConfigs[vendor]
    }

    func setActiveVendor(_ vendor: ProviderVendor) {
        guard vendor.isAvailable, activeVendor != vendor else { return }
        activeVendor = vendor
        defaults.set(vendor.rawValue, forKey: LegacyProviderKeys.activeVendor)
        syncLegacyKeys()
        if let provider = makeProvider(vendor: vendor) {
            installProvider(provider, stopActiveStreams: true)
        } else {
            installProvider(nil, stopActiveStreams: true)
        }
    }

    func saveProviderConfig(
        vendor: ProviderVendor,
        baseURL: String,
        apiKey: String,
        model: String,
        models: [String] = []
    ) throws {
        let providerBaseURL = try Self.validatedBaseURL(baseURL)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw APIConfigurationError.missingModel
        }

        if trimmedKey.isEmpty {
            // 未填写新 Key：校验该服务商已保存的 Key 可用
            _ = try resolvedAPIKey(vendor: vendor, apiKey: apiKey)
        } else {
            try keyStores[vendor]?.save(trimmedKey)
        }

        var updated = providerConfigs
        let thinkingEnabled = providerConfigs[vendor]?.thinkingEnabled ?? true
        updated[vendor] = ProviderConfig(
            baseURL: providerBaseURL.absoluteString,
            model: trimmedModel,
            hasAPIKey: true,
            models: models,
            thinkingEnabled: thinkingEnabled
        )
        providerConfigs = updated
        defaults.set(providerBaseURL.absoluteString, forKey: vendor.baseURLDefaultsKey)
        defaults.set(trimmedModel, forKey: vendor.modelDefaultsKey)
        defaults.set(models, forKey: vendor.modelsDefaultsKey)
        defaults.set(thinkingEnabled, forKey: vendor.thinkingEnabledDefaultsKey)
        authError = nil

        if vendor == activeVendor {
            // 保存当前使用的服务商：同步 legacy 键并重建运行时
            syncLegacyKeys()
            if let provider = makeProvider(vendor: vendor) {
                installProvider(provider, stopActiveStreams: true)
            }
        } else if config(for: activeVendor)?.isConfigured != true {
            // 当前没有可用的服务商，保存后自动设为当前使用
            setActiveVendor(vendor)
        }
    }

    func deleteProviderAPIKey(vendor: ProviderVendor) throws {
        guard let keyStore = keyStores[vendor] else { return }
        try keyStore.delete()
        var updated = providerConfigs
        if var config = updated[vendor] {
            config.hasAPIKey = false
            updated[vendor] = config
        }
        providerConfigs = updated
        defaults.removeObject(forKey: vendor.baseURLDefaultsKey)
        defaults.removeObject(forKey: vendor.modelDefaultsKey)
        defaults.removeObject(forKey: vendor.modelsDefaultsKey)
        if vendor == activeVendor {
            installProvider(nil, stopActiveStreams: true)
            syncLegacyKeys()
        }
        authError = nil
    }

    func availableModels(vendor: ProviderVendor, baseURL: String, apiKey: String) async throws -> [String] {
        let providerBaseURL = try Self.validatedBaseURL(baseURL)
        let resolvedKey = try resolvedAPIKey(vendor: vendor, apiKey: apiKey)

        return try await OpenAIResponsesProvider(
            apiKey: resolvedKey,
            baseURL: providerBaseURL
        ).models()
    }

    /// 解析实际使用的 API Key：优先用输入值，否则读取该服务商已保存的 Key
    private func resolvedAPIKey(vendor: ProviderVendor, apiKey: String) throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            return trimmedKey
        }
        guard let storedKey = try keyStores[vendor]?.load(), !storedKey.isEmpty else {
            throw APIConfigurationError.missingAPIKey
        }
        return storedKey
    }

    // MARK: - 兼容旧接口（作用于当前使用的服务商）

    func saveConfiguration(baseURL: String, apiKey: String, model: String) throws {
        try saveProviderConfig(
            vendor: activeVendor,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model
        )
    }

    func deleteAPIKey() throws {
        try deleteProviderAPIKey(vendor: activeVendor)
    }

    func setActiveModel(_ model: String, for vendor: ProviderVendor) {
        guard vendor == activeVendor,
              var config = providerConfigs[vendor],
              config.model != model else { return }
        config.model = model
        providerConfigs[vendor] = config
        defaults.set(model, forKey: vendor.modelDefaultsKey)
        syncLegacyKeys()
        installProvider(makeProvider(vendor: vendor), stopActiveStreams: true)
    }

    func setThinkingEnabled(_ enabled: Bool, for vendor: ProviderVendor) {
        guard let config = providerConfigs[vendor],
              config.thinkingEnabled != enabled else { return }
        var updated = providerConfigs
        updated[vendor]?.thinkingEnabled = enabled
        providerConfigs = updated
        defaults.set(enabled, forKey: vendor.thinkingEnabledDefaultsKey)
        if vendor == activeVendor {
            refreshRuntimes(stopActiveStreams: false)
        }
    }

    // MARK: - 会话管理

    @discardableResult
    func createConversation() -> ConversationSession.ID {
        if let emptyConversation = conversations.first(where: { $0.store.messages.isEmpty }) {
            selectedConversationID = emptyConversation.id
            return emptyConversation.id
        }

        let conversation = makeConversation()
        conversation.store.configure(runtime: makeRuntime())
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
            conversation.store.configure(runtime: makeRuntime())
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

    // MARK: - Runtime

    private func installProvider(_ provider: ModelProvider?, stopActiveStreams: Bool) {
        self.provider = provider
        refreshRuntimes(stopActiveStreams: stopActiveStreams)
    }

    private func refreshRuntimes(stopActiveStreams: Bool) {
        for conversation in conversations {
            if stopActiveStreams {
                conversation.store.stop()
            }
            conversation.store.configure(runtime: makeRuntime())
        }
    }

    private func makeRuntime() -> AgentRuntime? {
        provider.map {
            GenericAgentRuntime(
                provider: $0,
                configuration: GenericAgentRuntime.Configuration(
                    model: model,
                    reasoningEnabled: providerConfigs[activeVendor]?.thinkingEnabled ?? true
                )
            )
        }
    }

    private func makeProvider(vendor: ProviderVendor? = nil) -> OpenAIResponsesProvider? {
        let vendor = vendor ?? activeVendor
        guard let config = providerConfigs[vendor],
              config.hasAPIKey,
              let providerBaseURL = try? Self.validatedBaseURL(config.baseURL),
              let storedKey = try? keyStores[vendor]?.load(),
              !storedKey.isEmpty else {
            return nil
        }
        return OpenAIResponsesProvider(
            apiKey: storedKey,
            baseURL: providerBaseURL
        )
    }

    /// 同步 legacy 单配置键（apiBaseURL/apiModel），保持与旧版本读取路径兼容
    private func syncLegacyKeys() {
        defaults.set(config(for: activeVendor)?.baseURL ?? "", forKey: LegacyProviderKeys.baseURL)
        defaults.set(config(for: activeVendor)?.model ?? "", forKey: LegacyProviderKeys.model)
    }

    private static func migrateLegacyConfiguration(
        defaults: UserDefaults,
        keyStores: [ProviderVendor: APIKeyStoring]
    ) {
        guard let legacyBase = defaults.string(forKey: LegacyProviderKeys.baseURL) else { return }
        let migratedVendor = ProviderVendor.allCases.first {
            $0.defaultBaseURL == legacyBase
        } ?? .openai

        if let legacyKey = try? keyStores[migratedVendor]?.forAccount(LegacyProviderKeys.keychainAccount).load(),
           !legacyKey.isEmpty {
            try? keyStores[migratedVendor]?.save(legacyKey)
            try? keyStores[migratedVendor]?.forAccount(LegacyProviderKeys.keychainAccount).delete()
        }

        defaults.set(legacyBase, forKey: migratedVendor.baseURLDefaultsKey)
        defaults.set(
            defaults.string(forKey: LegacyProviderKeys.model) ?? "",
            forKey: migratedVendor.modelDefaultsKey
        )
        defaults.removeObject(forKey: LegacyProviderKeys.baseURL)
        defaults.removeObject(forKey: LegacyProviderKeys.model)
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
