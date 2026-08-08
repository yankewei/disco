import Combine
import Foundation

extension Notification.Name {
    /// 菜单栏“对话 > 清空当前对话”发出的请求，由 ChatView 弹出确认
    static let discoRequestClearConversation = Notification.Name("discoRequestClearConversation")
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var activeVendor: ProviderVendor
    @Published private(set) var providerConfigs: [ProviderVendor: ProviderConfig]
    @Published private(set) var authError: String?
    @Published private(set) var storageError: String?
    @Published private(set) var isRefreshingCodexModelCatalog = false
    @Published private(set) var codexModelCatalogError: String?
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

    /// 设置页中已添加但尚未完成配置的服务商（仅内存态，不持久化；保存配置后由设置页移出）
    @Published var pendingVendors: Set<ProviderVendor> = []

    /// 当前使用（active）服务商的配置，供聊天界面读取
    var baseURL: String { providerConfigs[activeVendor]?.baseURL ?? "" }
    var model: String { providerConfigs[activeVendor]?.model ?? "" }
    var hasAPIKey: Bool { providerConfigs[activeVendor]?.hasAPIKey ?? false }
    var isActiveVendorConfigured: Bool { activeVendor.isConfigured(providerConfigs[activeVendor]) }

    private let keyStores: [ProviderVendor: APIKeyStoring]
    private let defaults: UserDefaults
    private let persistence: ConversationPersisting
    private let codexTransportFactory: @MainActor () -> CodexAppServerTransport
    /// ChatGPT/Codex 使用一条应用级长连接；连接内按 threadId 隔离各会话。
    private var codexTransport: CodexAppServerTransport?
    /// 设置页验证前可能还没有 ProviderConfig，先暂存本次 model/list 的能力目录。
    private var discoveredModelReasoningCapabilities: [ProviderVendor: [String: ModelReasoningCapability]] = [:]

    var selectedConversation: ConversationSession? {
        guard let selectedConversationID else { return conversations.first }
        return conversations.first { $0.id == selectedConversationID } ?? conversations.first
    }

    init(
        keychain: APIKeyStoring? = nil,
        defaults: UserDefaults? = nil,
        persistence: ConversationPersisting? = nil,
        codexTransportFactory: @MainActor @escaping () -> CodexAppServerTransport = {
            CodexAppServerTransport()
        }
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
        self.codexTransportFactory = codexTransportFactory
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
            let capabilities = defaults.data(forKey: vendor.modelReasoningCapabilitiesDefaultsKey)
                .flatMap { try? JSONDecoder().decode([String: ModelReasoningCapability].self, from: $0) }
                ?? [:]
            loaded[vendor] = ProviderConfig(
                baseURL: baseURL,
                model: defaults.string(forKey: vendor.modelDefaultsKey) ?? "",
                hasAPIKey: vendor.requiresAPIKey && (storedKey.map { !$0.isEmpty } ?? false),
                models: defaults.stringArray(forKey: vendor.modelsDefaultsKey) ?? [],
                thinkingEnabled: defaults.object(forKey: vendor.thinkingEnabledDefaultsKey) as? Bool ?? legacyThinking ?? true,
                modelReasoningCapabilities: capabilities,
                reasoningEffort: defaults.string(forKey: vendor.reasoningEffortDefaultsKey),
                lastVerifiedAt: (defaults.object(forKey: vendor.verifiedAtDefaultsKey) as? TimeInterval)
                    .map(Date.init(timeIntervalSince1970:))
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
                    messages: $0.messages,
                    threadID: $0.threadID
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

        if activeVendor.isConfigured(providerConfigs[activeVendor]) {
            refreshRuntimes(stopActiveStreams: true)
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
        refreshRuntimes(stopActiveStreams: true)
    }

    func saveProviderConfig(
        vendor: ProviderVendor,
        baseURL: String,
        apiKey: String,
        model: String,
        models: [String] = []
    ) throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw APIConfigurationError.missingModel
        }

        var providerBaseURL = ""
        if vendor.requiresAPIKey {
            providerBaseURL = try Self.validatedBaseURL(baseURL).absoluteString
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedKey.isEmpty {
                // 未填写新 Key：校验该服务商已保存的 Key 可用
                _ = try resolvedAPIKey(vendor: vendor, apiKey: apiKey)
            } else {
                try keyStores[vendor]?.save(trimmedKey)
            }
        }

        var updated = providerConfigs
        let thinkingEnabled = providerConfigs[vendor]?.thinkingEnabled ?? true
        let capabilities = discoveredModelReasoningCapabilities[vendor]
            ?? providerConfigs[vendor]?.modelReasoningCapabilities
            ?? [:]
        let reasoningEffort = providerConfigs[vendor]?.reasoningEffort
        let verifiedAt = Date.now
        updated[vendor] = ProviderConfig(
            baseURL: providerBaseURL,
            model: trimmedModel,
            hasAPIKey: vendor.requiresAPIKey,
            models: models,
            thinkingEnabled: thinkingEnabled,
            modelReasoningCapabilities: capabilities,
            reasoningEffort: reasoningEffort,
            lastVerifiedAt: verifiedAt
        )
        providerConfigs = updated
        defaults.set(providerBaseURL, forKey: vendor.baseURLDefaultsKey)
        defaults.set(trimmedModel, forKey: vendor.modelDefaultsKey)
        defaults.set(models, forKey: vendor.modelsDefaultsKey)
        defaults.set(thinkingEnabled, forKey: vendor.thinkingEnabledDefaultsKey)
        persistModelReasoningCapabilities(capabilities, for: vendor)
        persistReasoningEffort(reasoningEffort, for: vendor)
        defaults.set(verifiedAt.timeIntervalSince1970, forKey: vendor.verifiedAtDefaultsKey)
        authError = nil

        if vendor == activeVendor {
            // 保存当前使用的服务商：同步 legacy 键并重建运行时
            syncLegacyKeys()
            refreshRuntimes(stopActiveStreams: true)
        } else if !activeVendor.isConfigured(config(for: activeVendor)) {
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
            config.model = ""
            config.models = []
            config.modelReasoningCapabilities = [:]
            config.reasoningEffort = nil
            config.lastVerifiedAt = nil
            updated[vendor] = config
        }
        providerConfigs = updated
        defaults.removeObject(forKey: vendor.baseURLDefaultsKey)
        defaults.removeObject(forKey: vendor.modelDefaultsKey)
        defaults.removeObject(forKey: vendor.modelsDefaultsKey)
        defaults.removeObject(forKey: vendor.modelReasoningCapabilitiesDefaultsKey)
        defaults.removeObject(forKey: vendor.reasoningEffortDefaultsKey)
        defaults.removeObject(forKey: vendor.verifiedAtDefaultsKey)
        if vendor == activeVendor {
            refreshRuntimes(stopActiveStreams: true)
            syncLegacyKeys()
        }
        authError = nil
    }

    func availableModels(vendor: ProviderVendor, baseURL: String, apiKey: String) async throws -> [String] {
        if vendor == .chatgpt {
            // 订阅服务商：模型列表来自 codex app-server 的 model/list（按订阅计划过滤）
            let transport = codexTransportFactory()
            defer { transport.stop() }
            try await transport.start()
            let catalog = try await transport.listModels()
            let models = catalog.map(\.id)
            let capabilities = Dictionary(uniqueKeysWithValues: catalog.map {
                ($0.id, ModelReasoningCapability(
                    supportedEfforts: $0.supportedReasoningEfforts,
                    defaultEffort: $0.defaultReasoningEffort
                ))
            })
            discoveredModelReasoningCapabilities[vendor] = capabilities
            if var config = providerConfigs[vendor] {
                config.models = models
                config.modelReasoningCapabilities = capabilities
                providerConfigs[vendor] = config
                defaults.set(models, forKey: vendor.modelsDefaultsKey)
                persistModelReasoningCapabilities(capabilities, for: vendor)
            }
            codexModelCatalogError = nil
            return models
        }

        let providerBaseURL = try Self.validatedBaseURL(baseURL)
        let resolvedKey = try resolvedAPIKey(vendor: vendor, apiKey: apiKey)

        return try await OpenAIResponsesProvider(
            apiKey: resolvedKey,
            baseURL: providerBaseURL
        ).models()
    }

    /// 已保存的 Codex 配置可能来自旧版本；聊天页进入时按需补齐模型推理能力目录。
    func refreshCodexModelCatalogIfNeeded() async {
        guard activeVendor == .chatgpt,
              let config = providerConfigs[.chatgpt],
              ProviderVendor.chatgpt.isConfigured(config),
              config.modelReasoningCapabilities[config.model] == nil,
              !isRefreshingCodexModelCatalog else { return }

        isRefreshingCodexModelCatalog = true
        codexModelCatalogError = nil
        defer { isRefreshingCodexModelCatalog = false }

        do {
            let models = try await availableModels(vendor: .chatgpt, baseURL: "", apiKey: "")
            guard !Task.isCancelled,
                  activeVendor == .chatgpt,
                  providerConfigs[.chatgpt]?.model == config.model else { return }
            guard models.contains(config.model) else {
                codexModelCatalogError = "当前模型不在 Codex 可用目录中，请重新选择模型。"
                return
            }
        } catch is CancellationError {
            return
        } catch {
            codexModelCatalogError = "无法加载推理强度：\(error.localizedDescription)"
        }
    }

    /// 检测 codex 登录状态（订阅设置页展示；真实拉起 codex app-server，走 account/read）。
    /// 应用不读取 `~/.codex/auth.json`（ADR-003），登录判断统一走服务端接口。
    func codexAccountStatus() async throws -> CodexAccountStatus {
        let transport = codexTransportFactory()
        defer { transport.stop() }
        try await transport.start()
        return try await transport.accountStatus()
    }

    /// 读取已保存的 API Key 明文，仅供设置页用户主动点击"查看"时使用
    func revealAPIKey(for vendor: ProviderVendor) -> String? {
        guard let key = try? keyStores[vendor]?.load(), !key.isEmpty else { return nil }
        return key
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
        if vendor == .chatgpt {
            config.reasoningEffort = nil
            codexModelCatalogError = nil
        }
        providerConfigs[vendor] = config
        defaults.set(model, forKey: vendor.modelDefaultsKey)
        syncLegacyKeys()
        refreshRuntimes(stopActiveStreams: true)
    }

    func setThinkingEnabled(_ enabled: Bool, for vendor: ProviderVendor) {
        guard var config = providerConfigs[vendor] else { return }
        let syncedEffort: String?
        if !vendor.requiresAPIKey {
            syncedEffort = config.reasoningEffort
        } else if !enabled {
            syncedEffort = "none"
        } else if config.reasoningEffort == "none" {
            syncedEffort = "high"
        } else {
            syncedEffort = config.reasoningEffort ?? "high"
        }
        guard config.thinkingEnabled != enabled || config.reasoningEffort != syncedEffort else {
            return
        }
        config.thinkingEnabled = enabled
        config.reasoningEffort = syncedEffort
        var updated = providerConfigs
        updated[vendor] = config
        providerConfigs = updated
        defaults.set(enabled, forKey: vendor.thinkingEnabledDefaultsKey)
        persistReasoningEffort(syncedEffort, for: vendor)
        if vendor == activeVendor {
            refreshRuntimes(stopActiveStreams: false)
        }
    }

    /// 当前服务商可用的推理档位；DeepSeek 支持四档，其他 API Key 服务商保持二态语义。
    func reasoningEfforts(for vendor: ProviderVendor) -> [String] {
        guard let config = providerConfigs[vendor] else { return [] }
        if vendor == .chatgpt {
            return config.modelReasoningCapabilities[config.model]?.supportedEfforts ?? []
        }
        return vendor.supportedReasoningEfforts
    }

    /// 当前推理档位；nil 表示 Codex 省略 effort，使用服务端默认值。
    func selectedReasoningEffort(for vendor: ProviderVendor) -> String? {
        guard let config = providerConfigs[vendor] else { return nil }
        if vendor == .chatgpt {
            guard let effort = config.reasoningEffort,
                  reasoningEfforts(for: vendor).contains(effort) else { return nil }
            return effort
        }
        if let effort = config.reasoningEffort,
           reasoningEfforts(for: vendor).contains(effort) {
            return effort
        }
        return config.thinkingEnabled ? "high" : "none"
    }

    func defaultReasoningEffort(for vendor: ProviderVendor) -> String? {
        guard let config = providerConfigs[vendor], vendor == .chatgpt else { return nil }
        return config.modelReasoningCapabilities[config.model]?.defaultEffort
    }

    func setReasoningEffort(_ effort: String?, for vendor: ProviderVendor) {
        guard var config = providerConfigs[vendor] else { return }
        let supported = reasoningEfforts(for: vendor)
        if vendor.requiresAPIKey {
            guard let effort, supported.contains(effort) else { return }
            config.thinkingEnabled = effort != "none"
        } else if let effort {
            guard supported.contains(effort) else { return }
        }
        guard config.reasoningEffort != effort else { return }
        config.reasoningEffort = effort
        var updated = providerConfigs
        updated[vendor] = config
        providerConfigs = updated
        persistReasoningEffort(effort, for: vendor)
        if vendor == activeVendor {
            refreshRuntimes(stopActiveStreams: false)
        }
    }

    func resetReasoningSettings(for vendor: ProviderVendor) {
        if vendor.requiresAPIKey {
            if vendor.supportedReasoningEfforts.count > 2 {
                setReasoningEffort("high", for: vendor)
            } else {
                setThinkingEnabled(true, for: vendor)
            }
        } else {
            setReasoningEffort(nil, for: vendor)
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
        conversation.store.configure(runtime: makeRuntime(for: conversation))
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        return conversation.id
    }

    func deleteConversation(id: ConversationSession.ID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].store.stop()
        let oldRuntime = conversations[index].store.configure(runtime: nil)
        conversations.remove(at: index)
        if let oldRuntime {
            Task { await oldRuntime.shutdown() }
        }
        do {
            try persistence.deleteConversation(id: id)
            storageError = nil
        } catch {
            storageError = "无法删除本地会话：\(error.localizedDescription)"
        }

        if conversations.isEmpty {
            let conversation = makeConversation()
            conversation.store.configure(runtime: makeRuntime(for: conversation))
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
        messages: [ChatMessage] = [],
        threadID: String? = nil
    ) -> ConversationSession {
        ConversationSession(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages,
            threadID: threadID
        ) { [weak self] messages, threadID in
            self?.persistConversation(
                id: id,
                createdAt: createdAt,
                messages: messages,
                threadID: threadID
            )
        }
    }

    private func persistConversation(
        id: UUID,
        createdAt: Date,
        messages: [ChatMessage],
        threadID: String?
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
                        messages: messages,
                        threadID: threadID
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

    private func refreshRuntimes(stopActiveStreams: Bool) {
        // 配置或 active vendor 变化后，旧连接上的 thread 不再属于当前运行时。
        // CodexRuntime.shutdown() 不会关闭共享连接，因此由拥有者统一处理。
        codexTransport?.stop()
        codexTransport = nil
        for conversation in conversations {
            if stopActiveStreams {
                conversation.store.stop()
            }
            let oldRuntime = conversation.store.configure(runtime: makeRuntime(for: conversation))
            if let oldRuntime {
                // 释放旧运行时（如终止 codex 子进程），避免切换配置后遗留孤儿进程
                Task { await oldRuntime.shutdown() }
            }
        }
    }

    /// 按当前服务商装配运行时（运行时按会话独立，Codex transport 共享）：
    /// - 订阅类（ChatGPT/Codex）：`CodexRuntime`（ADR-003，经 codex app-server）；
    ///   一条应用级长连接承载多个线程，续接已持久化的 thread id；
    /// - API Key 类：`GenericAgentRuntime` + `OpenAIResponsesProvider`。
    /// 会话配置在运行时创建时固定（计划 §6.3）。
    private func makeRuntime(for conversation: ConversationSession) -> AgentRuntime? {
        let vendor = activeVendor
        guard let config = providerConfigs[vendor], vendor.isConfigured(config) else {
            return nil
        }
        if vendor == .chatgpt {
            let store = conversation.store
            return CodexRuntime(
                transport: codexTransportForRuntime(),
                configuration: CodexRuntime.Configuration(
                    model: config.model,
                    reasoningEffort: selectedReasoningEffort(for: vendor),
                    resumeThreadID: store.threadID
                ),
                onThreadReady: { threadID in
                    // 线程就绪（新建或续接）：写回会话并触发持久化
                    store.updateThreadID(threadID)
                }
            )
        }
        guard let provider = makeProvider(vendor: vendor) else { return nil }
        return GenericAgentRuntime(
            provider: provider,
            configuration: GenericAgentRuntime.Configuration(
                model: config.model,
                reasoningEnabled: config.thinkingEnabled,
                reasoningEffort: selectedReasoningEffort(for: vendor),
                hostedTools: vendor.hostedTools(for: config.model)
            )
        )
    }

    private func codexTransportForRuntime() -> CodexAppServerTransport {
        if let codexTransport { return codexTransport }
        let transport = codexTransportFactory()
        codexTransport = transport
        return transport
    }

    private func makeProvider(vendor: ProviderVendor) -> OpenAIResponsesProvider? {
        guard let config = providerConfigs[vendor],
              config.hasAPIKey,
              let providerBaseURL = try? Self.validatedBaseURL(config.baseURL),
              let storedKey = try? keyStores[vendor]?.load(),
              !storedKey.isEmpty else {
            return nil
        }
        let dialect: OpenAIResponsesProvider.Dialect
        switch vendor {
        case .openai:
            dialect = .openAI
        case .deepseek:
            dialect = .deepSeek
        default:
            dialect = .compatible
        }
        return OpenAIResponsesProvider(
            apiKey: storedKey,
            baseURL: providerBaseURL,
            dialect: dialect
        )
    }

    private func persistModelReasoningCapabilities(
        _ capabilities: [String: ModelReasoningCapability],
        for vendor: ProviderVendor
    ) {
        guard let data = try? JSONEncoder().encode(capabilities) else { return }
        defaults.set(data, forKey: vendor.modelReasoningCapabilitiesDefaultsKey)
    }

    private func persistReasoningEffort(_ effort: String?, for vendor: ProviderVendor) {
        if let effort {
            defaults.set(effort, forKey: vendor.reasoningEffortDefaultsKey)
        } else {
            defaults.removeObject(forKey: vendor.reasoningEffortDefaultsKey)
        }
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
