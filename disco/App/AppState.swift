import AppKit
import Combine
import Foundation

enum AppStateProjectError: Error, LocalizedError {
    case directoryAlreadyUsed
    case projectNotFound

    var errorDescription: String? {
        switch self {
        case .directoryAlreadyUsed:
            return "该目录已经关联到另一个项目。"
        case .projectNotFound:
            return "找不到要操作的项目。"
        }
    }
}

/// 推送到 daemon 失败的 Provider 配置同步错误。
struct ProviderSyncError: Equatable {
    let vendor: ProviderVendor
    let message: String
}

extension Notification.Name {
    /// 菜单栏“对话 > 清空当前对话”发出的请求，由 ChatView 弹出确认
    static let discoRequestClearConversation = Notification.Name("discoRequestClearConversation")
    /// 菜单栏“对话 > 删除当前对话”发出的请求，由 ContentView 弹出确认
    static let discoRequestDeleteConversation = Notification.Name("discoRequestDeleteConversation")
    /// 菜单栏“添加项目”发出的请求，由 ContentView 展示目录选择器
    static let discoRequestOpenProject = Notification.Name("discoRequestOpenProject")
    /// 菜单栏“搜索对话”发出的请求，由 ConversationSidebar 聚焦搜索框
    static let discoFocusSidebarSearch = Notification.Name("discoFocusSidebarSearch")
    /// 用户消息“编辑后再次提问”发出的请求，由 ComposerView 聚焦输入框
    static let discoFocusComposer = Notification.Name("discoFocusComposer")
}

@MainActor
final class AppState: ObservableObject {
    private static let deletedRemoteSessionIDsKey = "deletedRemoteSessionIDs"

    @Published private(set) var activeVendor: ProviderVendor
    @Published private(set) var providerConfigs: [ProviderVendor: ProviderConfig]
    @Published private(set) var authError: String?
    /// 最近一次保存/同步到 daemon 失败的 Provider 配置错误；成功同步后清除。
    @Published private(set) var providerSyncError: ProviderSyncError?
    @Published private(set) var storageError: String?
    @Published private(set) var isRefreshingCodexModelCatalog = false
    @Published private(set) var codexModelCatalogError: String?
    @Published private(set) var projects: [ProjectSnapshot]
    @Published private(set) var projectAvailability: [UUID: ProjectAvailability]
    @Published private(set) var conversations: [ConversationSession]
    @Published var selectedConversationID: ConversationSession.ID? {
        didSet {
            if let selectedConversationID {
                defaults.set(selectedConversationID.uuidString, forKey: "selectedConversationID")
                conversations.first(where: { $0.id == selectedConversationID })?.store.markResultSeen()
            } else {
                defaults.removeObject(forKey: "selectedConversationID")
            }
        }
    }

    /// 当前使用（active）服务商的配置，供聊天界面读取
    var baseURL: String { providerConfigs[activeVendor]?.baseURL ?? "" }
    var model: String { providerConfigs[activeVendor]?.model ?? "" }
    var hasAPIKey: Bool { providerConfigs[activeVendor]?.hasAPIKey ?? false }
    var isActiveVendorConfigured: Bool { activeVendor.isConfigured(providerConfigs[activeVendor]) }

    /// 当前 daemon 运行边界（ACP adapter 建立后才非 nil）。
    private var activeDaemonClient: (any DiscoDaemonClient)? {
        acpDaemonAdapter
    }

    private var useDaemon: Bool {
        acpDaemonClient.state == .connected
            && acpDaemonAdapter != nil
            && isDaemonAvailable
    }

    private let keyStores: [ProviderVendor: APIKeyStoring]
    private let defaults: UserDefaults
    private let persistence: any ConversationPersisting
    private let projectPersistence: any ProjectPersisting
    private let workspaceResolver = WorkspaceResolver()
    /// 设置页验证前可能还没有 ProviderConfig，先暂存本次完整模型目录。
    private var discoveredModelCatalogs: [ProviderVendor: [ModelCatalogEntry]] = [:]
    /// 用户按模型填写的上下文窗口覆盖值，不随模型目录刷新删除。
    private var contextWindowOverrides: [ProviderVendor: [String: Int]] = [:]
    private var daemonEventTask: Task<Void, Never>?

    /// 用户已删除但远端 backend 暂不支持 session/delete 的会话。
    /// 这些 ID 不能再次被 session/list 导入，否则删除操作会在下次启动后失效。
    private var deletedRemoteSessionIDs: Set<UUID> {
        Set(
            (defaults.stringArray(forKey: Self.deletedRemoteSessionIDsKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        )
    }

    // MARK: - 守护进程（ACP stdio）

    /// ACP stdio client；App 以子进程方式启动 `disco-daemon --stdio`。
    let acpDaemonClient = ACPDaemonClient()
    private var acpDaemonAdapter: ACPDaemonClientAdapter?
    /// 守护进程进程管理器（查找 daemon 二进制、清理旧版 socket daemon）。
    let daemonProcessManager = DaemonProcessManager()
    /// App 退出时停止 daemon 的观察者，避免留下孤儿进程。
    private var daemonTerminationObserver: NSObjectProtocol?
    /// 守护进程连接状态（供 UI 观察）。
    @Published private(set) var daemonConnectionState: ACPDaemonClient.State = .disconnected
    /// 守护进程是否可用（已连接并完成初始化握手）。
    @Published private(set) var isDaemonAvailable = false
    /// daemon 权威状态快照的 revision；本地 SwiftData 仅作为该快照的投影缓存。
    @Published private(set) var daemonStateRevision: UInt64 = 0

    var selectedConversation: ConversationSession? {
        guard let selectedConversationID else { return conversations.first }
        return conversations.first { $0.id == selectedConversationID } ?? conversations.first
    }

    /// 设置页查询本地 Provider 模型时使用当前会话的项目工作区；临时会话回退到用户主目录。
    var modelDiscoveryWorkspacePath: String {
        if let projectID = selectedConversation?.projectID,
           case let .available(workspace) = projectAvailability[projectID] {
            return workspace.rootURL.path
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    init(
        keychain: APIKeyStoring? = nil,
        defaults: UserDefaults? = nil,
        persistence: (any ConversationPersisting & ProjectPersisting)? = nil
    ) {
        let baseKeyStore = keychain ?? AuthFileStore()
        let defaults = defaults ?? .standard
        let resolvedPersistence: any ConversationPersisting & ProjectPersisting
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
        self.projectPersistence = resolvedPersistence
        self.keyStores = Dictionary(
            uniqueKeysWithValues: ProviderVendor.allCases.map {
                ($0, baseKeyStore.forAccount($0.keychainAccount))
            }
        )
        for vendor in ProviderVendor.allCases {
            contextWindowOverrides[vendor] = defaults.data(
                forKey: vendor.contextWindowOverridesDefaultsKey
            ).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        }
        // 旧版全局思考模式开关：升级后迁移为各服务商的默认值，并移除旧键
        let legacyThinking = defaults.object(forKey: LegacyProviderKeys.thinkingEnabled) as? Bool
        storageError = startupStorageError
        projects = []
        projectAvailability = [:]
        conversations = []
        selectedConversationID = nil

        // 迁移旧版单服务商配置（apiBaseURL/apiModel + 旧 account）
        Self.migrateLegacyConfiguration(defaults: defaults, keyStores: self.keyStores)

        var loaded: [ProviderVendor: ProviderConfig] = [:]
        for vendor in ProviderVendor.allCases {
            guard let baseURL = defaults.string(forKey: vendor.baseURLDefaultsKey) else { continue }
            let storedKey = (try? self.keyStores[vendor]?.load()).flatMap { $0 }
            let modelCatalog: [ModelCatalogEntry]
            if let data = defaults.data(forKey: vendor.modelCatalogDefaultsKey),
               let decoded = try? JSONDecoder().decode([ModelCatalogEntry].self, from: data) {
                modelCatalog = decoded
                defaults.removeObject(forKey: vendor.modelsDefaultsKey)
                defaults.removeObject(forKey: vendor.modelContextWindowsDefaultsKey)
                defaults.removeObject(forKey: vendor.modelReasoningCapabilitiesDefaultsKey)
            } else {
                let contextWindows = defaults.data(forKey: vendor.modelContextWindowsDefaultsKey)
                    .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) }
                    ?? [:]
                let reasoningCapabilities = defaults.data(forKey: vendor.modelReasoningCapabilitiesDefaultsKey)
                    .flatMap {
                        try? JSONDecoder().decode(
                            [String: LegacyModelReasoningCapability].self,
                            from: $0
                        )
                    }
                    ?? [:]
                var modelIDs = defaults.stringArray(forKey: vendor.modelsDefaultsKey) ?? []
                let selectedModel = defaults.string(forKey: vendor.modelDefaultsKey) ?? ""
                let additionalIDs = contextWindows.keys.sorted()
                    + reasoningCapabilities.keys.sorted()
                    + (selectedModel.isEmpty ? [] : [selectedModel])
                for modelID in additionalIDs where !modelIDs.contains(modelID) {
                    modelIDs.append(modelID)
                }
                modelCatalog = modelIDs.map { modelID in
                    let reasoning = reasoningCapabilities[modelID]
                    return vendor.enrichingCatalogEntry(ModelCatalogEntry(
                        id: modelID,
                        contextWindow: contextWindows[modelID],
                        supportedReasoningEfforts: reasoning?.supportedEfforts,
                        defaultReasoningEffort: reasoning?.defaultEffort
                    ))
                }
                if !modelCatalog.isEmpty,
                   let data = try? JSONEncoder().encode(modelCatalog) {
                    defaults.set(data, forKey: vendor.modelCatalogDefaultsKey)
                    defaults.removeObject(forKey: vendor.modelsDefaultsKey)
                    defaults.removeObject(forKey: vendor.modelContextWindowsDefaultsKey)
                    defaults.removeObject(forKey: vendor.modelReasoningCapabilitiesDefaultsKey)
                }
            }
            loaded[vendor] = ProviderConfig(
                baseURL: baseURL,
                model: defaults.string(forKey: vendor.modelDefaultsKey) ?? "",
                hasAPIKey: vendor.requiresAPIKey && (storedKey.map { !$0.isEmpty } ?? false),
                modelCatalog: modelCatalog,
                thinkingEnabled: defaults.object(forKey: vendor.thinkingEnabledDefaultsKey) as? Bool ?? legacyThinking ?? true,
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
            projects = try resolvedPersistence.loadProjects()
            refreshProjectAvailability(persistChanges: true)
        } catch {
            storageError = "无法读取本地项目：\(error.localizedDescription)"
        }

        do {
            conversations = try resolvedPersistence.loadConversations().map {
                makeConversation(
                    id: $0.id,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    projectID: $0.projectID,
                    providerID: $0.providerID,
                    runtimeKind: $0.runtimeKind,
                    messages: $0.messages,
                    threadID: $0.threadID,
                    contextState: $0.contextState ?? ConversationContextState()
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

        // 测试环境不触碰真实 daemon：跳过启动与退出清理
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            // App 退出时停止 daemon，避免留下孤儿进程
            daemonTerminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stopDaemon()
                }
            }

            // Phase 1：启动守护进程连接（异步，不阻塞 UI）
            Task { await startDaemonIfNeeded() }
        }
    }

    deinit {
        if let daemonTerminationObserver {
            NotificationCenter.default.removeObserver(daemonTerminationObserver)
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

    /// 验证成功后记录验证时间（不改变已保存的模型/URL 等配置）。
    ///
    /// 设置页“验证并加载模型”成功时调用：旧版本保存的配置可能没有验证记录，
    /// 既然已成功从服务端拉到模型列表，即视为最近一次连接验证通过。
    func recordVerificationTime(for vendor: ProviderVendor) {
        guard var config = providerConfigs[vendor] else { return }
        let verifiedAt = Date.now
        config.lastVerifiedAt = verifiedAt
        providerConfigs[vendor] = config
        defaults.set(verifiedAt.timeIntervalSince1970, forKey: vendor.verifiedAtDefaultsKey)
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
        let discoveredByID = Dictionary(
            uniqueKeysWithValues: (discoveredModelCatalogs[vendor] ?? []).map { ($0.id, $0) }
        )
        let existingByID = Dictionary(
            uniqueKeysWithValues: (providerConfigs[vendor]?.modelCatalog ?? []).map { ($0.id, $0) }
        )
        let catalogIDs = models.isEmpty ? [trimmedModel] : models
        let modelCatalog = catalogIDs.map { modelID in
            discoveredByID[modelID]
                ?? existingByID[modelID]
                ?? vendor.enrichingCatalogEntry(ModelCatalogEntry(id: modelID))
        }
        let existingReasoningEffort = providerConfigs[vendor]?.reasoningEffort
        let selectedModelEntry = modelCatalog.first { $0.id == trimmedModel }
        let reasoningEffort: String?
        if let supported = selectedModelEntry?.supportedReasoningEfforts {
            reasoningEffort = existingReasoningEffort
                .flatMap { supported.contains($0) ? $0 : nil }
        } else {
            reasoningEffort = existingReasoningEffort
        }
        let verifiedAt = Date.now
        updated[vendor] = ProviderConfig(
            baseURL: providerBaseURL,
            model: trimmedModel,
            hasAPIKey: vendor.requiresAPIKey,
            modelCatalog: modelCatalog,
            thinkingEnabled: thinkingEnabled,
            reasoningEffort: reasoningEffort,
            lastVerifiedAt: verifiedAt
        )
        providerConfigs = updated
        defaults.set(providerBaseURL, forKey: vendor.baseURLDefaultsKey)
        defaults.set(trimmedModel, forKey: vendor.modelDefaultsKey)
        defaults.set(thinkingEnabled, forKey: vendor.thinkingEnabledDefaultsKey)
        persistModelCatalog(modelCatalog, for: vendor)
        persistReasoningEffort(reasoningEffort, for: vendor)
        defaults.set(verifiedAt.timeIntervalSince1970, forKey: vendor.verifiedAtDefaultsKey)
        authError = nil

        // 守护进程可用时，同步服务商配置到守护进程
        if useDaemon {
            let syncVendor = vendor
            Task { [weak self] in
                guard let self else { return }
                let resolvedKey = (try? self.resolvedAPIKey(vendor: syncVendor, apiKey: apiKey)) ?? ""
                do {
                    _ = try await self.acpDaemonClient.configureProvider(
                        providerID: syncVendor.daemonProviderID,
                        vendor: syncVendor.daemonVendor,
                        baseURL: providerBaseURL,
                        apiKey: resolvedKey,
                        model: trimmedModel,
                        thinkingEnabled: thinkingEnabled,
                        reasoningEffort: reasoningEffort
                    )
                    if self.providerSyncError?.vendor == syncVendor {
                        self.providerSyncError = nil
                    }
                    await self.refreshDaemonStateSnapshot()
                } catch {
                    self.providerSyncError = ProviderSyncError(
                        vendor: syncVendor,
                        message: "保存到后台失败：\(error.localizedDescription)"
                    )
                }
            }
        }

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
            config.modelCatalog = []
            config.reasoningEffort = nil
            config.lastVerifiedAt = nil
            updated[vendor] = config
        }
        providerConfigs = updated
        defaults.removeObject(forKey: vendor.baseURLDefaultsKey)
        defaults.removeObject(forKey: vendor.modelDefaultsKey)
        defaults.removeObject(forKey: vendor.modelCatalogDefaultsKey)
        defaults.removeObject(forKey: vendor.modelsDefaultsKey)
        defaults.removeObject(forKey: vendor.modelReasoningCapabilitiesDefaultsKey)
        defaults.removeObject(forKey: vendor.modelContextWindowsDefaultsKey)
        defaults.removeObject(forKey: vendor.contextWindowOverridesDefaultsKey)
        defaults.removeObject(forKey: vendor.reasoningEffortDefaultsKey)
        defaults.removeObject(forKey: vendor.verifiedAtDefaultsKey)
        if vendor == activeVendor {
            refreshRuntimes(stopActiveStreams: true)
            syncLegacyKeys()
        }
        if providerSyncError?.vendor == vendor {
            providerSyncError = nil
        }
        discoveredModelCatalogs[vendor] = nil
        contextWindowOverrides[vendor] = [:]
        authError = nil
    }

    /// 模型目录来自 daemon 的 `_disco/provider/models` 扩展。
    /// API Key 类服务商带凭据时由 daemon 实时查询，否则回退内置目录。
    func availableModels(
        vendor: ProviderVendor,
        baseURL: String? = nil,
        apiKey: String? = nil,
        workspacePath: String? = nil
    ) async throws -> [String] {
        guard useDaemon else {
            throw DaemonError.notConnected
        }
        let entries = try await acpDaemonClient.listProviderModels(
            providerID: vendor.daemonProviderID,
            vendor: vendor.daemonVendor,
            baseURL: baseURL,
            apiKey: apiKey,
            workspacePath: workspacePath
        )
        let modelCatalog = entries.map { entry in
            vendor.enrichingCatalogEntry(ModelCatalogEntry(
                id: entry.id,
                displayName: entry.displayName,
                contextWindow: entry.contextWindow.map { Int(clamping: $0) },
                supportedReasoningEfforts: entry.supportedReasoningEfforts,
                defaultReasoningEffort: entry.defaultReasoningEffort
            ))
        }
        discoveredModelCatalogs[vendor] = modelCatalog
        if var config = providerConfigs[vendor] {
            config.modelCatalog = modelCatalog
            providerConfigs[vendor] = config
            persistModelCatalog(modelCatalog, for: vendor)
        }
        if vendor == .chatgpt {
            codexModelCatalogError = nil
        }
        return modelCatalog.map(\.id)
    }

    /// 已保存的 Codex 配置可能来自旧版本；聊天页进入时按需补齐模型推理能力目录。
    func refreshCodexModelCatalogIfNeeded() async {
        guard activeVendor == .chatgpt,
              let config = providerConfigs[.chatgpt],
              ProviderVendor.chatgpt.isConfigured(config),
              config.catalogEntry(for: config.model)?.supportedReasoningEfforts == nil,
              !isRefreshingCodexModelCatalog else { return }

        isRefreshingCodexModelCatalog = true
        codexModelCatalogError = nil
        defer { isRefreshingCodexModelCatalog = false }

        do {
            let models = try await availableModels(vendor: .chatgpt)
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

    func startConversationWithModel(_ model: String, for vendor: ProviderVendor) {
        guard vendor.isAvailable,
              let configuration = providerConfigs[vendor] else { return }

        let previousConversation = selectedConversation
        let selectionChanged = vendor != activeVendor || configuration.model != model
        let sessionUsesSelectedProvider = previousConversation?.providerID
            .map { $0 == vendor.daemonProviderID } ?? true
        guard selectionChanged || !sessionUsesSelectedProvider else { return }

        let shouldStartFreshSession = previousConversation?.store.hasDaemonSession == true
            || previousConversation?.providerID != nil
            || previousConversation?.store.messages.isEmpty == false

        if vendor != activeVendor {
            setActiveVendor(vendor)
        }
        setActiveModel(model, for: vendor)
        guard shouldStartFreshSession else { return }

        _ = createConversation(projectID: previousConversation?.projectID, forceNew: true)
        if let previousConversation, previousConversation.store.messages.isEmpty {
            deleteConversation(id: previousConversation.id)
        }
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
        return config.catalogEntry(for: config.model)?.supportedReasoningEfforts
            ?? vendor.supportedReasoningEfforts
    }

    /// 当前推理档位；nil 表示 Codex 省略 effort，使用服务端默认值。
    func selectedReasoningEffort(for vendor: ProviderVendor) -> String? {
        guard let config = providerConfigs[vendor] else { return nil }
        let efforts = reasoningEfforts(for: vendor)
        if vendor == .chatgpt {
            guard let effort = config.reasoningEffort,
                  efforts.contains(effort) else { return nil }
            return effort
        }
        if let effort = config.reasoningEffort,
           efforts.contains(effort) {
            return effort
        }
        if config.thinkingEnabled, efforts.contains("high") {
            return "high"
        }
        if !config.thinkingEnabled, efforts.contains("none") {
            return "none"
        }
        return nil
    }

    func contextWindow(for vendor: ProviderVendor, model: String) -> Int? {
        contextWindowOverrides[vendor]?[model]
            ?? providerConfigs[vendor]?.catalogEntry(for: model)?.contextWindow
            ?? discoveredModelCatalogs[vendor]?.first { $0.id == model }?.contextWindow
            ?? vendor.contextWindow(for: model)
    }

    /// 设置或清除某个模型的上下文窗口覆盖值。合法范围为 4,096～16,777,216。
    func setContextWindowOverride(_ value: Int?, for model: String, vendor: ProviderVendor) {
        guard !model.isEmpty else { return }
        if let value, !(4_096...16_777_216).contains(value) {
            return
        }
        var overrides = contextWindowOverrides[vendor] ?? [:]
        if let value {
            overrides[model] = value
        } else {
            overrides.removeValue(forKey: model)
        }
        contextWindowOverrides[vendor] = overrides
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: vendor.contextWindowOverridesDefaultsKey)
        }
        if vendor == activeVendor {
            refreshRuntimes(stopActiveStreams: false)
        }
    }

    func contextWindowOverride(for vendor: ProviderVendor, model: String) -> Int? {
        contextWindowOverrides[vendor]?[model]
    }

    func defaultReasoningEffort(for vendor: ProviderVendor) -> String? {
        guard let config = providerConfigs[vendor] else { return nil }
        return config.catalogEntry(for: config.model)?.defaultReasoningEffort
    }

    func modelCatalogEntry(for vendor: ProviderVendor, model: String) -> ModelCatalogEntry? {
        providerConfigs[vendor]?.catalogEntry(for: model)
            ?? discoveredModelCatalogs[vendor]?.first { $0.id == model }
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
            if reasoningEfforts(for: vendor).count > 2 {
                setReasoningEffort("high", for: vendor)
            } else {
                setThinkingEnabled(true, for: vendor)
            }
        } else {
            setReasoningEffort(nil, for: vendor)
        }
    }

    // MARK: - Project / Workspace

    @discardableResult
    func openProject(at url: URL) throws -> ProjectSnapshot.ID {
        let resolved = try workspaceResolver.resolve(directory: url)
        if let existingIndex = projects.firstIndex(where: {
            $0.workspaceRoot.resolvingSymlinksInPath() == resolved.context.rootURL
        }) {
            var project = projects[existingIndex]
            project.workspaceRoot = resolved.context.rootURL
            project.bookmarkData = resolved.bookmarkData
            project.lastOpenedAt = .now
            try projectPersistence.saveProject(project)
            projects[existingIndex] = project
            projectAvailability[project.id] = .available(resolved.context)
            sortProjects()
            return project.id
        }

        let project = ProjectSnapshot(
            id: UUID(),
            name: resolved.projectName,
            workspaceRoot: resolved.context.rootURL,
            bookmarkData: resolved.bookmarkData,
            createdAt: .now,
            lastOpenedAt: .now
        )
        try projectPersistence.saveProject(project)
        projects.insert(project, at: 0)
        projectAvailability[project.id] = .available(resolved.context)
        _ = createConversation(projectID: project.id)
        return project.id
    }

    func reconnectProject(id: UUID, to url: URL) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw AppStateProjectError.projectNotFound
        }
        let resolved = try workspaceResolver.resolve(directory: url)
        if projects.contains(where: {
            $0.id != id && $0.workspaceRoot.resolvingSymlinksInPath() == resolved.context.rootURL
        }) {
            throw AppStateProjectError.directoryAlreadyUsed
        }

        var project = projects[index]
        project.workspaceRoot = resolved.context.rootURL
        project.name = resolved.projectName
        project.bookmarkData = resolved.bookmarkData
        project.lastOpenedAt = .now
        try projectPersistence.saveProject(project)
        projects[index] = project
        projectAvailability[id] = .available(resolved.context)
        sortProjects()
        refreshProjectRuntimes()
    }

    func deleteProject(id: ProjectSnapshot.ID) {
        guard projects.contains(where: { $0.id == id }) else { return }

        let projectConversations = conversations.filter { $0.projectID == id }
        let daemonConversations = projectConversations.filter(\.store.hasDaemonSession)
        guard daemonConversations.isEmpty else {
            guard useDaemon, let daemonClient = activeDaemonClient else {
                storageError = "daemon 当前不可用，无法删除项目会话；项目已保留。"
                return
            }

            Task { [weak self] in
                guard let self else { return }
                var deletedConversationIDs: [ConversationSession.ID] = []
                do {
                    for conversation in daemonConversations {
                        try await daemonClient.closeSession(sessionID: conversation.id)
                    }
                    for conversation in daemonConversations {
                        try await daemonClient.deleteSession(sessionID: conversation.id)
                        deletedConversationIDs.append(conversation.id)
                    }
                    removeProjectLocally(id: id)
                } catch let error as ACPDaemonError {
                    if isUnsupportedRemoteSessionDeletion(error) {
                        // 部分远端 backend 没有实现 session/delete；此时仍移除
                        // Disco 本地项目记录，避免项目永久无法删除。
                        for conversation in daemonConversations {
                            markRemoteSessionAsDeleted(conversation.id)
                        }
                        removeProjectLocally(id: id)
                        return
                    }
                    for conversationID in deletedConversationIDs {
                        removeConversationLocally(id: conversationID)
                    }
                    storageError = "无法完整删除项目会话，项目已保留：\(error.localizedDescription)"
                } catch {
                    for conversationID in deletedConversationIDs {
                        removeConversationLocally(id: conversationID)
                    }
                    storageError = "无法完整删除项目会话，项目已保留：\(error.localizedDescription)"
                }
            }
            return
        }

        removeProjectLocally(id: id)
    }

    private func removeProjectLocally(id: ProjectSnapshot.ID) {
        let removedConversationIDs = Set(
            conversations.filter { $0.projectID == id }.map(\.id)
        )
        do {
            try projectPersistence.deleteProject(id: id)
        } catch {
            storageError = "无法删除本地项目：\(error.localizedDescription)"
            return
        }

        for conversation in conversations where removedConversationIDs.contains(conversation.id) {
            conversation.store.stop()
        }
        conversations.removeAll { removedConversationIDs.contains($0.id) }
        projects.removeAll { $0.id == id }
        projectAvailability[id] = nil

        if let selectedConversationID,
           removedConversationIDs.contains(selectedConversationID) {
            self.selectedConversationID = conversations.first?.id
        }
        if conversations.isEmpty {
            conversations = [makeConversation()]
        }
        storageError = nil
    }

    func refreshProjectAvailability(persistChanges: Bool = true) {
        for index in projects.indices {
            let project = projects[index]
            let resolution = workspaceResolver.resolve(project: project)
            projectAvailability[project.id] = resolution.availability
            guard case .available = resolution.availability,
                  let canonicalURL = resolution.canonicalURL else { continue }

            var updatedProject = project
            updatedProject.workspaceRoot = canonicalURL
            if let bookmarkData = resolution.bookmarkData {
                updatedProject.bookmarkData = bookmarkData
            }
            guard updatedProject.workspaceRoot != project.workspaceRoot
                    || updatedProject.bookmarkData != project.bookmarkData else { continue }
            projects[index] = updatedProject
            if persistChanges {
                do {
                    try projectPersistence.saveProject(updatedProject)
                } catch {
                    storageError = "无法保存项目状态：\(error.localizedDescription)"
                }
            }
        }
        sortProjects()
        refreshProjectRuntimes()
    }

    private func refreshProjectRuntimes() {
        for conversation in conversations {
            guard let projectID = conversation.projectID else { continue }

            if !isProjectAvailable(projectID) {
                guard conversation.store.hasRuntime else { continue }
                conversation.store.stop()
                conversation.store.revertDaemonRegistration()
            } else if !conversation.store.hasRuntime {
                Task { [weak self] in
                    guard let self else { return }
                    await registerDaemonConversation(conversation)
                }
            }
        }
    }

    func projectAvailability(for projectID: UUID) -> ProjectAvailability? {
        projectAvailability[projectID]
    }

    private func isProjectAvailable(_ projectID: UUID) -> Bool {
        guard let availability = projectAvailability[projectID] else { return false }
        if case .available = availability { return true }
        return false
    }

    private func sortProjects() {
        projects.sort { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    /// 打开项目最近的会话；项目尚无会话时创建一段新的项目会话。
    @discardableResult
    func selectProject(id: ProjectSnapshot.ID) -> ConversationSession.ID? {
        guard projects.contains(where: { $0.id == id }) else { return nil }

        if let conversation = conversations.first(where: { $0.projectID == id }) {
            selectedConversationID = conversation.id
            return conversation.id
        }

        return createConversation(projectID: id)
    }

    // MARK: - 会话管理

    @discardableResult
    func createConversation(projectID: UUID? = nil, forceNew: Bool = false) -> ConversationSession.ID {
        if !forceNew,
           let emptyConversation = conversations.first(where: {
               $0.projectID == projectID && $0.store.messages.isEmpty
           }) {
            selectedConversationID = emptyConversation.id
            return emptyConversation.id
        }

        let conversation = makeConversation(projectID: projectID)
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        persistEmptyProjectConversation(conversation)

        if useDaemon {
            Task { [weak self] in
                guard let self else { return }
                await self.registerDaemonConversation(conversation)
            }
        }

        return conversation.id
    }

    @discardableResult
    func createConversationInCurrentContext() -> ConversationSession.ID {
        let projectID = selectedConversation?.projectID.flatMap { candidate in
            projects.contains(where: { $0.id == candidate }) ? candidate : nil
        }
        return createConversation(projectID: projectID)
    }

    func deleteConversation(id: ConversationSession.ID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        if conversation.store.hasDaemonSession {
            guard useDaemon, let daemonClient = activeDaemonClient else {
                storageError = "daemon 当前不可用，无法同时删除原始 Agent 会话；本地会话已保留。"
                return
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await daemonClient.closeSession(sessionID: id)
                    try await daemonClient.deleteSession(sessionID: id)
                    removeConversationLocally(id: id)
                } catch let error as ACPDaemonError {
                    if isUnsupportedRemoteSessionDeletion(error) {
                        // 后端不支持删除时，仍允许用户移除 Disco 本地会话记录。
                        markRemoteSessionAsDeleted(id)
                        removeConversationLocally(id: id)
                        return
                    }
                    storageError = "无法删除原始 Agent 会话，本地会话已保留：\(error.localizedDescription)"
                } catch {
                    storageError = "无法删除原始 Agent 会话，本地会话已保留：\(error.localizedDescription)"
                }
            }
            return
        }
        removeConversationLocally(id: id)
    }

    private func isUnsupportedRemoteSessionDeletion(_ error: ACPDaemonError) -> Bool {
        guard case let .rpcError(code, _, detail) = error else { return false }
        return code == -32602 && detail?.contains("不支持删除") == true
    }

    private func markRemoteSessionAsDeleted(_ id: UUID) {
        var deletedIDs = deletedRemoteSessionIDs
        deletedIDs.insert(id)
        defaults.set(deletedIDs.map(\.uuidString), forKey: Self.deletedRemoteSessionIDsKey)
    }

    /// 完成已确认不再有原始 Agent 状态的本地会话删除。
    private func removeConversationLocally(id: ConversationSession.ID) {
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
            conversations = [makeConversation()]
        }
        if selectedConversationID == id {
            selectedConversationID = conversations.first?.id
        }
    }

    private func makeConversation(
        id: UUID = UUID(),
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        projectID: UUID? = nil,
        providerID: String? = nil,
        runtimeKind: SessionRuntimeKind? = nil,
        messages: [ChatMessage] = [],
        threadID: String? = nil,
        contextState: ConversationContextState = ConversationContextState()
    ) -> ConversationSession {
        let session = ConversationSession(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            projectID: projectID,
            providerID: providerID,
            runtimeKind: runtimeKind,
            messages: messages,
            threadID: threadID,
            contextState: contextState
        ) { [weak self] messages, threadID, contextState in
            self?.persistConversation(
                id: id,
                createdAt: createdAt,
                projectID: projectID,
                messages: messages,
                threadID: threadID,
                contextState: contextState
            )
        }
        // 注入当前 transport 的公共 daemon client，用于运行和审批响应。
        session.store.configure(daemonClient: activeDaemonClient)
        return session
    }

    private func persistEmptyProjectConversation(_ conversation: ConversationSession) {
        guard conversation.projectID != nil else { return }
        persistConversation(
            id: conversation.id,
            createdAt: conversation.createdAt,
            projectID: conversation.projectID,
            messages: conversation.store.messages,
            threadID: conversation.store.threadID,
            contextState: conversation.store.contextState
        )
    }

    private func persistConversation(
        id: UUID,
        createdAt: Date,
        projectID: UUID?,
        messages: [ChatMessage],
        threadID: String?,
        contextState: ConversationContextState
    ) {
        let updatedAt = Date.now
        markConversationAsRecent(id: id, updatedAt: updatedAt)
        let metadata = conversations.first { $0.id == id }
        do {
            if messages.isEmpty, projectID == nil {
                try persistence.deleteConversation(id: id)
            } else {
                try persistence.saveConversation(
                    ConversationSnapshot(
                        id: id,
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        messages: messages,
                        threadID: threadID,
                        projectID: projectID,
                        providerID: metadata?.providerID,
                        runtimeKind: metadata?.runtimeKind,
                        contextState: contextState
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

    // MARK: - 运行时（daemon 托管）

    private func refreshRuntimes(stopActiveStreams: Bool) {
        if stopActiveStreams {
            for conversation in conversations {
                conversation.store.stop()
            }
        }
        syncActiveProviderToDaemon()
    }

    /// 把当前服务商配置推给 daemon，后续运行使用新配置。
    private func syncActiveProviderToDaemon() {
        guard useDaemon, let config = providerConfigs[activeVendor] else { return }
        let vendor = activeVendor
        let apiKey = vendor.requiresAPIKey
            ? ((try? keyStores[vendor]?.load()) ?? "")
            : ""
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.acpDaemonClient.configureProvider(
                    providerID: vendor.daemonProviderID,
                    vendor: vendor.daemonVendor,
                    baseURL: config.baseURL,
                    apiKey: apiKey,
                    model: config.model,
                    thinkingEnabled: config.thinkingEnabled,
                    reasoningEffort: config.reasoningEffort
                )
                if self.providerSyncError?.vendor == vendor {
                    self.providerSyncError = nil
                }
                await self.refreshDaemonStateSnapshot()
            } catch {
                self.providerSyncError = ProviderSyncError(
                    vendor: vendor,
                    message: "同步到后台失败：\(error.localizedDescription)"
                )
            }
        }
    }

    private func persistModelCatalog(
        _ catalog: [ModelCatalogEntry],
        for vendor: ProviderVendor
    ) {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        defaults.set(data, forKey: vendor.modelCatalogDefaultsKey)
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

    // MARK: - 守护进程管理

    /// 启动 `disco-daemon --stdio` 子进程并建立 ACP 连接。
    ///
    /// 启动前清理旧版 socket daemon（与当前 daemon 共享 SQLite 数据库，
    /// 避免两个 daemon 同时持有不同的 AppState）。
    private func startDaemonIfNeeded() async {
        daemonConnectionState = .connecting
        guard let binaryPath = daemonProcessManager.daemonBinaryPath() else {
            daemonConnectionState = .failed("守护进程未安装")
            return
        }

        daemonProcessManager.stopDaemon()

        do {
            try await acpDaemonClient.connect(binaryPath: binaryPath)
            _ = try await acpDaemonClient.initialize()
            acpDaemonAdapter = ACPDaemonClientAdapter(client: acpDaemonClient)
            reconfigureConversationDaemonClients()
            daemonConnectionState = .connected
            isDaemonAvailable = true
            startDaemonEventRouting()
            await synchronizeDaemonConversations()
        } catch {
            acpDaemonClient.disconnect()
            acpDaemonAdapter = nil
            daemonConnectionState = .failed(error.localizedDescription)
            isDaemonAvailable = false
        }
    }

    private func reconfigureConversationDaemonClients() {
        for conversation in conversations {
            conversation.store.configure(daemonClient: activeDaemonClient)
        }
    }

    /// 停止守护进程并断开连接。
    func stopDaemon() {
        daemonEventTask?.cancel()
        daemonEventTask = nil
        for conversation in conversations {
            conversation.store.handleDaemonDisconnection("daemon 已停止。")
        }
        acpDaemonClient.disconnect()
        acpDaemonAdapter = nil
        daemonConnectionState = .disconnected
        isDaemonAvailable = false
    }

    private func startDaemonEventRouting() {
        daemonEventTask?.cancel()
        guard let client = activeDaemonClient else { return }
        let events = client.events()
        daemonEventTask = Task { [weak self] in
            do {
                for try await event in events {
                    guard !Task.isCancelled, let self, let sessionID = event.sessionID else {
                        continue
                    }
                    guard let conversation = conversations.first(where: { $0.id == sessionID }) else {
                        continue
                    }
                    // 审批请求必须立即进入对应会话，否则用户停留在其他会话时，
                    // 审批弹窗虽已写入状态，却完全不可见。
                    if event.eventName == "approval.requested" {
                        selectedConversationID = conversation.id
                    }
                    conversation.store.handleDaemonNotification(event)
                    if event.eventName == "run.completed"
                        || event.eventName == "run.cancelled"
                        || event.eventName == "run.failed"
                    {
                        await refreshDaemonStateSnapshot(reloadSessionID: conversation.id)
                    }
                }
                guard !Task.isCancelled, let self else { return }
                daemonConnectionState = .disconnected
                isDaemonAvailable = false
                for conversation in conversations {
                    conversation.store.handleDaemonDisconnection("daemon 连接已中断。")
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                daemonConnectionState = .failed(error.localizedDescription)
                isDaemonAvailable = false
                for conversation in conversations {
                    conversation.store.handleDaemonDisconnection(
                        "daemon 连接已中断：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func synchronizeDaemonConversations() async {
        // 先从 daemon 获取一次带 revision 的权威快照，避免把多个 list 请求拼成不一致状态。
        if let snapshot = try? await acpDaemonClient.stateSnapshot() {
            daemonStateRevision = snapshot.revision
            importDaemonSessions(snapshot.sessions)
        } else if let serverSessions = try? await acpDaemonClient.listSessions().sessions {
            // 兼容旧 daemon；升级后的 daemon 会优先走 state/snapshot。
            importDaemonSessions(serverSessions)
        }

        // 所有本地会话都与 daemon 对齐：已有 daemon 会话恢复权威历史，没有的才新建。
        for conversation in conversations {
            await registerDaemonConversation(conversation)
        }
    }

    private func importDaemonSessions(_ serverSessions: [ACPSessionInfo]) {
        for serverSession in serverSessions {
            guard let sessionID = UUID(uuidString: serverSession.sessionId),
                  let projectID = serverSession.projectID,
                  projects.contains(where: { $0.id == projectID }),
                  !deletedRemoteSessionIDs.contains(sessionID),
                  !conversations.contains(where: { $0.id == sessionID }) else { continue }
            conversations.append(
                makeConversation(
                    id: sessionID,
                    projectID: projectID,
                    providerID: serverSession.providerID,
                    runtimeKind: serverSession.runtimeKind
                )
            )
        }
    }

    /// 运行结束后刷新 revision；同时从 daemon 恢复当前会话的完整消息，修复 replay 窗口
    /// 截断或连接抖动造成的 UI 增量缺失。
    private func refreshDaemonStateSnapshot(reloadSessionID: UUID? = nil) async {
        guard useDaemon else { return }
        guard let snapshot = try? await acpDaemonClient.stateSnapshot() else { return }
        if snapshot.revision != daemonStateRevision {
            daemonStateRevision = snapshot.revision
            importDaemonSessions(snapshot.sessions)
        }
        guard let reloadSessionID,
              let conversation = conversations.first(where: { $0.id == reloadSessionID }),
              let storedMessages = try? await acpDaemonClient.listMessages(
                  sessionID: reloadSessionID.uuidString
              ) else { return }
        conversation.store.restoreMessages(restoreDaemonMessages(storedMessages))
    }

    /// 对齐会话与 daemon：注册缺失的会话，并把 daemon 的权威历史恢复到本地。
    ///
    /// daemon 是消息的权威来源；本地 SwiftData 快照只作为离线回退缓存
    /// （注册成功后会以 daemon 恢复的内容为准刷新本地缓存）。
    /// 项目会话使用项目工作区；不挂在项目下的会话使用用户主目录作为工作区。
    private func registerDaemonConversation(_ conversation: ConversationSession) async {
        guard useDaemon else { return }

        let cwd: String
        if let projectID = conversation.projectID {
            guard case let .available(workspace) = projectAvailability[projectID] else { return }
            cwd = workspace.rootURL.path
        } else {
            cwd = FileManager.default.homeDirectoryForCurrentUser.path
        }

        do {
            let existingSessions = try await acpDaemonClient.listSessions(cwd: cwd).sessions
            let existingSession = existingSessions.first { info in
                UUID(uuidString: info.sessionId) == conversation.id
            }
            if let existingSession {
                let fallbackCompactionMode = switch existingSession.runtimeKind {
                case .acp, .codexAppServer: "native"
                default: "local"
                }
                conversation.store.setCompactionMode(
                    existingSession.compactionMode ?? fallbackCompactionMode
                )
                if let providerID = existingSession.providerID {
                    setSessionMetadata(
                        conversationID: conversation.id,
                        providerID: providerID,
                        runtimeKind: existingSession.runtimeKind
                    )
                }
                _ = try await acpDaemonClient.loadSession(
                    sessionID: conversation.id.uuidString,
                    cwd: cwd
                )
            } else {
                // 本地有历史但 daemon 没有同一个权威 session：不注册，避免丢上下文。
                guard conversation.store.messages.isEmpty else {
                    conversation.store.revertDaemonRegistration()
                    return
                }
                let vendor = activeVendor
                guard let config = providerConfigs[vendor] else { return }
                let apiKey = vendor.requiresAPIKey
                    ? ((try? keyStores[vendor]?.load()) ?? "")
                    : ""
                _ = try await acpDaemonClient.configureProvider(
                    providerID: vendor.daemonProviderID,
                    vendor: vendor.daemonVendor,
                    baseURL: config.baseURL,
                    apiKey: apiKey,
                    model: config.model,
                    thinkingEnabled: config.thinkingEnabled,
                    reasoningEffort: config.reasoningEffort
                )
                let created = try await acpDaemonClient.newSession(
                    cwd: cwd,
                    providerID: vendor.daemonProviderID,
                    sessionID: conversation.id.uuidString
                )
                guard UUID(uuidString: created.sessionId) == conversation.id else {
                    throw DaemonError.invalidResponse(
                        "ACP session/new 未返回请求的 ConversationSession ID。"
                    )
                }
                setSessionMetadata(
                    conversationID: conversation.id,
                    providerID: vendor.daemonProviderID,
                    runtimeKind: SessionRuntimeKind.from(providerID: vendor.daemonProviderID)
                )
                conversation.store.setCompactionMode(
                    vendor.daemonProviderID == "opencode_app_server"
                        || vendor.daemonProviderID == "codex_app_server"
                        ? "native"
                        : "local"
                )
            }

            let storedMessages = try await acpDaemonClient.listMessages(
                sessionID: conversation.id.uuidString
            )
            guard conversations.contains(where: { $0.id == conversation.id }) else {
                try? await acpDaemonClient.deleteSession(sessionID: conversation.id.uuidString)
                return
            }
            conversation.store.enableDaemonRuns(sessionID: conversation.id)
            if !storedMessages.isEmpty {
                conversation.store.restoreMessages(restoreDaemonMessages(storedMessages))
            } else if conversation.store.messages.isEmpty {
                // 让新建的空 session 也把 metadata 写入本地快照。
                persistEmptyProjectConversation(conversation)
            }
        } catch {
            conversation.store.disableDaemonRuns()
        }
    }

    private func setSessionMetadata(
        conversationID: UUID,
        providerID: String,
        runtimeKind: SessionRuntimeKind?
    ) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].providerID = providerID
        conversations[index].runtimeKind = runtimeKind ?? SessionRuntimeKind.from(providerID: providerID)
    }

    private func restoreDaemonMessages(_ storedMessages: [ACPSessionMessage]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for storedMessage in storedMessages {
            if let toolCallID = storedMessage.toolCallId,
               let assistantIndex = messages.lastIndex(where: { $0.role == .assistant }) {
                guard let callIndex = messages[assistantIndex].parts.firstIndex(where: { part in
                    guard case let .toolCall(call) = part else { return false }
                    return call.id == toolCallID
                }) else { continue }
                guard case let .toolCall(existingCall) = messages[assistantIndex].parts[callIndex] else {
                    continue
                }
                var updatedCall = existingCall
                updatedCall.status = .completed
                updatedCall.output = storedMessage.text
                messages[assistantIndex].parts[callIndex] = .toolCall(updatedCall)
                continue
            }

            guard let role = ChatMessage.Role(rawValue: storedMessage.role) else { continue }
            var parts: [ChatMessage.Part] = []
            if let reasoning = storedMessage.reasoning, !reasoning.isEmpty {
                parts.append(.reasoning(reasoning))
            }
            for toolCall in storedMessage.toolCalls ?? [] {
                parts.append(
                    .toolCall(
                        ChatMessage.ToolCallSnapshot(
                            id: toolCall.id,
                            name: toolCall.name,
                            arguments: toolCall.arguments,
                            status: toolCall.status == "running" ? .running : .completed,
                            output: toolCall.output
                        )
                    )
                )
            }
            if !storedMessage.text.isEmpty {
                parts.append(.text(TextContent(text: storedMessage.text)))
            }
            guard !parts.isEmpty else { continue }
            messages.append(
                ChatMessage(
                    id: UUID(uuidString: storedMessage.id) ?? UUID(),
                    role: role,
                    parts: parts
                )
            )
        }
        return messages
    }
}

/// 旧版按模型单独保存的推理能力，仅用于迁移到统一 ModelCatalogEntry。
private struct LegacyModelReasoningCapability: Codable {
    let supportedEfforts: [String]
    let defaultEffort: String?
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
