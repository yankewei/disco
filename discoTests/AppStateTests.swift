import XCTest
@testable import disco

@MainActor
final class AppStateTests: XCTestCase {
    func testProviderVendorsMapToDaemonProfiles() {
        XCTAssertEqual(ProviderVendor.openai.daemonProviderID, "codex_api")
        XCTAssertEqual(ProviderVendor.openai.daemonVendor, "openai")
        XCTAssertEqual(ProviderVendor.chatgpt.daemonProviderID, "codex_app_server")
        XCTAssertEqual(ProviderVendor.chatgpt.daemonVendor, "codex")
        XCTAssertEqual(ProviderVendor.moonshot.daemonVendor, "moonshot_kimi")
        XCTAssertEqual(ProviderVendor.zhipu.daemonVendor, "glm")
    }

    func testHostedWebSearchCapabilitiesAreVendorAndModelSpecific() {
        XCTAssertEqual(ProviderVendor.openai.hostedTools(for: "gpt-5.6"), [.webSearch])
        XCTAssertEqual(ProviderVendor.deepseek.hostedTools(for: "deepseek-v4-flash"), [.webSearch])
        XCTAssertTrue(ProviderVendor.deepseek.hostedTools(for: "deepseek-v4-pro").isEmpty)
        XCTAssertTrue(ProviderVendor.moonshot.hostedTools(for: "kimi-latest").isEmpty)
        XCTAssertTrue(ProviderVendor.kimiCode.hostedTools(for: "kimi-for-coding").isEmpty)
        XCTAssertTrue(ProviderVendor.zhipu.hostedTools(for: "glm-5").isEmpty)
        XCTAssertTrue(ProviderVendor.chatgpt.hostedTools(for: "gpt-5.6-codex").isEmpty)
    }

    func testKimiCodeUsesItsSubscriptionEndpointAndThinkingEfforts() {
        XCTAssertEqual(
            ProviderVendor.kimiCode.defaultBaseURL,
            "https://api.kimi.com/coding/v1"
        )
        XCTAssertEqual(
            ProviderVendor.kimiCode.supportedReasoningEfforts,
            ["none", "low", "high", "max"]
        )
        XCTAssertTrue(ProviderVendor.kimiCode.isAvailable)
        XCTAssertTrue(ProviderVendor.kimiCode.requiresAPIKey)
    }

    func testKimiCodeContextWindowPrefersPersistedModelMetadata() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode([
                ModelCatalogEntry(id: "kimi-for-coding", contextWindow: 1_048_576),
            ]),
            forKey: ProviderVendor.kimiCode.modelCatalogDefaultsKey
        )
        defaults.set(
            ProviderVendor.kimiCode.defaultBaseURL,
            forKey: ProviderVendor.kimiCode.baseURLDefaultsKey
        )

        let appState = try makeAppState(defaults: defaults)

        XCTAssertEqual(
            appState.contextWindow(for: .kimiCode, model: "kimi-for-coding"),
            1_048_576
        )
        XCTAssertNil(appState.contextWindow(for: .kimiCode, model: "unknown-kimi-model"))
    }

    func testKnownContextWindowIsModelSpecific() {
        XCTAssertEqual(
            ProviderVendor.deepseek.contextWindow(for: "deepseek-v4-flash"),
            1_000_000
        )
        XCTAssertEqual(
            ProviderVendor.deepseek.contextWindow(for: "deepseek-v4-pro"),
            1_000_000
        )
        XCTAssertNil(ProviderVendor.deepseek.contextWindow(for: "deepseek-chat"))
        XCTAssertNil(ProviderVendor.openai.contextWindow(for: "gpt-5"))
        XCTAssertEqual(
            ProviderVendor.kimiCode.contextWindow(for: "kimi-for-coding"),
            262_144
        )
        XCTAssertNil(ProviderVendor.kimiCode.contextWindow(for: "unknown-kimi-model"))
    }

    func testLegacyModelMetadataMigratesIntoUnifiedCatalog() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vendor = ProviderVendor.kimiCode
        defaults.set(vendor.defaultBaseURL, forKey: vendor.baseURLDefaultsKey)
        defaults.set("kimi-for-coding", forKey: vendor.modelDefaultsKey)
        defaults.set(["kimi-for-coding"], forKey: vendor.modelsDefaultsKey)
        defaults.set(
            try JSONEncoder().encode(["kimi-for-coding": 1_048_576]),
            forKey: vendor.modelContextWindowsDefaultsKey
        )
        defaults.set(
            try JSONSerialization.data(withJSONObject: [
                "kimi-for-coding": [
                    "supportedEfforts": ["none", "low", "high", "max"],
                    "defaultEffort": "high",
                ],
            ]),
            forKey: vendor.modelReasoningCapabilitiesDefaultsKey
        )

        let appState = try makeAppState(defaults: defaults)
        let entry = try XCTUnwrap(
            appState.modelCatalogEntry(for: vendor, model: "kimi-for-coding")
        )

        XCTAssertEqual(entry.contextWindow, 1_048_576)
        XCTAssertEqual(entry.supportedReasoningEfforts, ["none", "low", "high", "max"])
        XCTAssertEqual(entry.defaultReasoningEffort, "high")
        XCTAssertEqual(entry.hostedTools, [])
        XCTAssertNotNil(defaults.data(forKey: vendor.modelCatalogDefaultsKey))
        XCTAssertNil(defaults.object(forKey: vendor.modelsDefaultsKey))
        XCTAssertNil(defaults.object(forKey: vendor.modelContextWindowsDefaultsKey))
        XCTAssertNil(defaults.object(forKey: vendor.modelReasoningCapabilitiesDefaultsKey))
    }

    func testSaveConfigurationTrimsValuesPersistsThemAndUsesStoredKey() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryAuthStore()
        let appState = try makeAppState(keychain: keychain, defaults: defaults)

        try appState.saveConfiguration(
            baseURL: "  https://example.com///  ",
            apiKey: "  test-key  ",
            model: "  test-model  "
        )

        XCTAssertEqual(appState.baseURL, "https://example.com")
        XCTAssertEqual(appState.model, "test-model")
        XCTAssertTrue(appState.hasAPIKey)
        XCTAssertEqual(try keychain.load(), "test-key")
        XCTAssertEqual(defaults.string(forKey: "apiBaseURL"), "https://example.com")
        XCTAssertEqual(defaults.string(forKey: "apiModel"), "test-model")

        try appState.saveConfiguration(
            baseURL: "https://example.org",
            apiKey: "",
            model: "next-model"
        )

        XCTAssertEqual(appState.baseURL, "https://example.org")
        XCTAssertEqual(appState.model, "next-model")
        XCTAssertEqual(try keychain.load(), "test-key")
    }

    func testSaveConfigurationRejectsInvalidBaseURLWithoutChangingState() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryAuthStore()
        let appState = try makeAppState(keychain: keychain, defaults: defaults)
        let originalBaseURL = appState.baseURL
        let originalModel = appState.model

        XCTAssertThrowsError(
            try appState.saveConfiguration(
                baseURL: "http://example.com?token=secret",
                apiKey: "new-key",
                model: "new-model"
            )
        ) { error in
            guard case .invalidBaseURL = error as? APIConfigurationError else {
                return XCTFail("expected invalidBaseURL, got \(error)")
            }
        }

        XCTAssertEqual(appState.baseURL, originalBaseURL)
        XCTAssertEqual(appState.model, originalModel)
        XCTAssertFalse(appState.hasAPIKey)
        XCTAssertNil(try keychain.load())
    }

    func testSaveConfigurationRequiresKeyAndModelWhenNoKeyIsStored() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = try makeAppState(defaults: defaults)

        XCTAssertThrowsError(
            try appState.saveConfiguration(
                baseURL: "https://example.com",
                apiKey: "",
                model: "test-model"
            )
        ) { error in
            guard case .missingAPIKey = error as? APIConfigurationError else {
                return XCTFail("expected missingAPIKey, got \(error)")
            }
        }

        let keychain = InMemoryAuthStore()
        let stateWithKey = try makeAppState(keychain: keychain, defaults: defaults)
        try keychain.save("stored-key")

        XCTAssertThrowsError(
            try stateWithKey.saveConfiguration(
                baseURL: "https://example.com",
                apiKey: "",
                model: "   "
            )
        ) { error in
            guard case .missingModel = error as? APIConfigurationError else {
                return XCTFail("expected missingModel, got \(error)")
            }
        }
    }

    func testDeletingAPIKeyDisablesConfiguredProvider() throws {
        let keychain = InMemoryAuthStore()
        let appState = try makeAppState(
            keychain: keychain,
            defaults: try XCTUnwrap(UserDefaults(suiteName: #function))
        )
        try appState.saveConfiguration(
            baseURL: "https://example.com",
            apiKey: "test-key",
            model: "test-model"
        )
        XCTAssertTrue(appState.selectedConversation?.store.canSend == false)

        try appState.deleteAPIKey()

        XCTAssertFalse(appState.hasAPIKey)
        XCTAssertNil(try keychain.load())
        XCTAssertTrue(appState.selectedConversation?.store.canSend == false)
    }

    func testFirstProviderSaveAutoActivatesAndConfigsStayIndependent() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryAuthStore()
        let appState = try makeAppState(keychain: keychain, defaults: defaults)

        // 首次配置某服务商（当前 active 未配置）→ 自动设为当前使用
        try appState.saveProviderConfig(
            vendor: .openai,
            baseURL: "https://api.openai.com/v1",
            apiKey: "openai-key",
            model: "gpt-5"
        )
        XCTAssertEqual(appState.activeVendor, .openai)
        XCTAssertEqual(appState.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(appState.model, "gpt-5")
        XCTAssertTrue(appState.hasAPIKey)

        // 再配置 DeepSeek，不改变当前使用
        try appState.saveProviderConfig(
            vendor: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "deepseek-key",
            model: "deepseek-chat"
        )
        XCTAssertEqual(appState.activeVendor, .openai)
        XCTAssertEqual(appState.baseURL, "https://api.openai.com/v1")

        // 手动切换当前使用 → 聊天侧读到新配置
        appState.setActiveVendor(.deepseek)
        XCTAssertEqual(appState.activeVendor, .deepseek)
        XCTAssertEqual(appState.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(appState.model, "deepseek-chat")

        // 两个服务商配置各自独立保留
        XCTAssertEqual(appState.config(for: .openai)?.model, "gpt-5")
        XCTAssertEqual(appState.config(for: .deepseek)?.model, "deepseek-chat")
        XCTAssertTrue(appState.hasAPIKey)
    }

    func testThinkingEnabledIsPerProviderAndPersistsToggle() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryAuthStore()
        let appState = try makeAppState(keychain: keychain, defaults: defaults)

        try appState.saveProviderConfig(
            vendor: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "deepseek-key",
            model: "deepseek-chat"
        )
        try appState.saveProviderConfig(
            vendor: .openai,
            baseURL: "https://api.openai.com/v1",
            apiKey: "openai-key",
            model: "gpt-5"
        )

        XCTAssertEqual(appState.config(for: .deepseek)?.thinkingEnabled, true)
        XCTAssertEqual(appState.config(for: .openai)?.thinkingEnabled, true)

        appState.setThinkingEnabled(false, for: .deepseek)

        XCTAssertEqual(appState.config(for: .deepseek)?.thinkingEnabled, false)
        XCTAssertEqual(appState.config(for: .openai)?.thinkingEnabled, true)
        XCTAssertFalse(defaults.bool(forKey: "provider.deepseek.thinkingEnabled"))

        // 重新创建 AppState：各服务商的开关独立恢复
        let restored = try makeAppState(keychain: InMemoryAuthStore(), defaults: defaults)
        XCTAssertEqual(restored.config(for: .deepseek)?.thinkingEnabled, false)
        XCTAssertEqual(restored.config(for: .openai)?.thinkingEnabled, true)
    }

    func testDeepSeekReasoningEffortSupportsLevelsAndPersistsSelection() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = try makeAppState(defaults: defaults)

        try appState.saveProviderConfig(
            vendor: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "deepseek-key",
            model: "deepseek-v4-flash"
        )

        XCTAssertEqual(appState.reasoningEfforts(for: .deepseek), ["none", "low", "high", "max"])

        appState.setReasoningEffort("max", for: .deepseek)
        XCTAssertEqual(appState.selectedReasoningEffort(for: .deepseek), "max")
        XCTAssertTrue(appState.config(for: .deepseek)?.thinkingEnabled == true)

        let restored = try makeAppState(defaults: defaults)
        XCTAssertEqual(restored.selectedReasoningEffort(for: .deepseek), "max")

        restored.resetReasoningSettings(for: .deepseek)
        XCTAssertEqual(restored.selectedReasoningEffort(for: .deepseek), "high")

        restored.setReasoningEffort("none", for: .deepseek)
        XCTAssertEqual(restored.selectedReasoningEffort(for: .deepseek), "none")
        XCTAssertFalse(restored.config(for: .deepseek)?.thinkingEnabled == true)
    }

    func testSaveProviderConfigPersistsModelListAndSwitchModel() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryAuthStore()
        let appState = try makeAppState(keychain: keychain, defaults: defaults)
        let models = ["deepseek-chat", "deepseek-reasoner"]

        try appState.saveProviderConfig(
            vendor: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "deepseek-key",
            model: "deepseek-chat",
            models: models
        )

        XCTAssertEqual(appState.config(for: .deepseek)?.models, models)

        // 聊天页切换模型：更新内存与 defaults，并同步 legacy 键
        appState.setActiveModel("deepseek-reasoner", for: .deepseek)
        XCTAssertEqual(appState.model, "deepseek-reasoner")
        XCTAssertEqual(defaults.string(forKey: "provider.deepseek.model"), "deepseek-reasoner")
        XCTAssertEqual(defaults.string(forKey: "apiModel"), "deepseek-reasoner")

        // 重启后模型与列表恢复
        let restored = try makeAppState(keychain: keychain, defaults: defaults)
        XCTAssertEqual(restored.model, "deepseek-reasoner")
        XCTAssertEqual(restored.config(for: .deepseek)?.models, models)
    }

    func testSwitchingToModelWithDifferentReasoningCapabilitiesClearsInvalidEffort() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = [
            ModelCatalogEntry(
                id: "deepseek-reasoner",
                supportedReasoningEfforts: ["none", "high"],
                defaultReasoningEffort: "high"
            ),
            ModelCatalogEntry(
                id: "deepseek-chat",
                supportedReasoningEfforts: ["none"],
                defaultReasoningEffort: "none"
            ),
        ]
        defaults.set(
            try JSONEncoder().encode(catalog),
            forKey: ProviderVendor.deepseek.modelCatalogDefaultsKey
        )
        defaults.set(
            ProviderVendor.deepseek.defaultBaseURL,
            forKey: ProviderVendor.deepseek.baseURLDefaultsKey
        )
        let appState = try makeAppState(defaults: defaults)

        try appState.saveProviderConfig(
            vendor: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "deepseek-key",
            model: "deepseek-reasoner",
            models: catalog.map(\.id)
        )
        appState.setReasoningEffort("high", for: .deepseek)

        try appState.saveProviderConfig(
            vendor: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "",
            model: "deepseek-chat",
            models: catalog.map(\.id)
        )

        XCTAssertNil(appState.config(for: .deepseek)?.reasoningEffort)
        XCTAssertNil(defaults.string(forKey: ProviderVendor.deepseek.reasoningEffortDefaultsKey))
    }

    func testLegacyGlobalThinkingEnabledMigratesToProviders() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryAuthStore()

        // 模拟旧版本：全局思考模式关闭，且已配置 DeepSeek
        defaults.set(false, forKey: "thinkingEnabled")
        defaults.set("https://api.deepseek.com/v1", forKey: "provider.deepseek.baseURL")
        defaults.set("deepseek-chat", forKey: "provider.deepseek.model")
        try keychain.save("deepseek-key")

        let appState = try makeAppState(keychain: keychain, defaults: defaults)

        // 旧全局键已移除，迁移值落到已配置服务商
        XCTAssertNil(defaults.object(forKey: "thinkingEnabled"))
        XCTAssertEqual(appState.config(for: .deepseek)?.thinkingEnabled, false)

        // 迁移值已持久化：重启后仍保留
        let restored = try makeAppState(keychain: keychain, defaults: defaults)
        XCTAssertEqual(restored.config(for: .deepseek)?.thinkingEnabled, false)
    }
    func testAuthFileStorePersistsKeysPerAccountAndRestrictsPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("auth.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let deepseekStore = AuthFileStore(account: "deepseek-api-key", fileURL: fileURL)
        XCTAssertNil(try deepseekStore.load())

        try deepseekStore.save("sk-deepseek")
        XCTAssertEqual(try deepseekStore.load(), "sk-deepseek")

        // 不同 account 相互隔离，且共用同一文件
        let openaiStore = deepseekStore.forAccount("openai-api-key")
        XCTAssertNil(try openaiStore.load())
        try openaiStore.save("sk-openai")
        XCTAssertEqual(try openaiStore.load(), "sk-openai")
        XCTAssertEqual(try deepseekStore.load(), "sk-deepseek")

        // 删除只影响自己的 account
        try deepseekStore.delete()
        XCTAssertNil(try deepseekStore.load())
        XCTAssertEqual(try openaiStore.load(), "sk-openai")

        // 文件权限 0600，且内容为可读 JSON
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: String]
        XCTAssertEqual(json?["openai-api-key"], "sk-openai")
    }

    func testSaveProviderConfigRecordsAndClearsVerificationTime() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryAuthStore()
        let appState = try makeAppState(keychain: keychain, defaults: defaults)

        XCTAssertNil(appState.config(for: .deepseek)?.lastVerifiedAt)

        // 保存配置即视为验证通过，记录时间
        try appState.saveProviderConfig(
            vendor: .deepseek,
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "deepseek-key",
            model: "deepseek-chat"
        )
        let verifiedAt = try XCTUnwrap(appState.config(for: .deepseek)?.lastVerifiedAt)
        XCTAssertEqual(verifiedAt.timeIntervalSinceNow, 0, accuracy: 5)
        XCTAssertNotNil(defaults.object(forKey: "provider.deepseek.verifiedAt"))

        // 重启后恢复；删除配置后清除
        let restored = try makeAppState(keychain: keychain, defaults: defaults)
        XCTAssertEqual(
            restored.config(for: .deepseek)?.lastVerifiedAt?.timeIntervalSince1970 ?? 0,
            verifiedAt.timeIntervalSince1970,
            accuracy: 1
        )
        try restored.deleteProviderAPIKey(vendor: .deepseek)
        XCTAssertNil(restored.config(for: .deepseek)?.lastVerifiedAt)
        XCTAssertNil(defaults.object(forKey: "provider.deepseek.verifiedAt"))
    }

    func testAuthFileStoreRecoversWhenFileMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("auth.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AuthFileStore(account: "deepseek-api-key", fileURL: fileURL)
        XCTAssertNil(try store.load())

        // 目录不存在时首次保存也能成功
        try store.save("sk-new")
        XCTAssertEqual(try store.load(), "sk-new")
    }
}

@MainActor
private func makeAppState(
    keychain: APIKeyStoring? = nil,
    defaults: UserDefaults
) throws -> AppState {
    AppState(
        keychain: keychain ?? InMemoryAuthStore(),
        defaults: defaults,
        persistence: try ConversationPersistence(isStoredInMemoryOnly: true)
    )
}

// MARK: - ChatGPT 订阅（codex app-server）

extension AppStateTests {
    /// 订阅服务商保存配置：无需 Base URL / API Key，验证通过即视为已连接
    func testChatGPTSubscriptionSavesWithoutAPIKey() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryAuthStore()
        let appState = try makeAppState(keychain: keychain, defaults: defaults)

        try appState.saveProviderConfig(
            vendor: .chatgpt,
            baseURL: "",
            apiKey: "",
            model: "  gpt-5.6  ",
            models: ["gpt-5.6", "gpt-5.6-mini"]
        )

        let config = appState.config(for: .chatgpt)
        XCTAssertEqual(config?.baseURL, "")
        XCTAssertEqual(config?.model, "gpt-5.6")
        XCTAssertEqual(config?.models, ["gpt-5.6", "gpt-5.6-mini"])
        XCTAssertFalse(config?.hasAPIKey == true)
        XCTAssertTrue(ProviderVendor.chatgpt.isConfigured(config))
        XCTAssertTrue(appState.isActiveVendorConfigured)
        // 订阅服务商不写入任何 API Key
        XCTAssertNil(try keychain.load())
        // 当前没有其他已配置服务商，保存后自动设为当前使用
        XCTAssertEqual(appState.activeVendor, .chatgpt)
    }

    /// 重启后 ChatGPT 订阅仍应保持已配置；订阅服务商本来就没有 API Key。
    func testChatGPTSubscriptionRemainsConfiguredAfterReloadWithoutAPIKey() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = try makeAppState(keychain: InMemoryAuthStore(), defaults: defaults)
        try initial.saveProviderConfig(
            vendor: .chatgpt,
            baseURL: "",
            apiKey: "",
            model: "gpt-5.6",
            models: ["gpt-5.6"]
        )

        let restored = try makeAppState(keychain: InMemoryAuthStore(), defaults: defaults)

        XCTAssertFalse(restored.config(for: .chatgpt)?.hasAPIKey == true)
        XCTAssertTrue(ProviderVendor.chatgpt.isConfigured(restored.config(for: .chatgpt)))
        XCTAssertTrue(restored.isActiveVendorConfigured)
        XCTAssertEqual(restored.model, "gpt-5.6")
    }

    /// 订阅服务商切换模型（setActiveModel 路径）
    func testChatGPTSubscriptionSwitchModel() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = try makeAppState(defaults: defaults)

        try appState.saveProviderConfig(
            vendor: .chatgpt,
            baseURL: "",
            apiKey: "",
            model: "gpt-5.6",
            models: ["gpt-5.6", "gpt-5.6-mini"]
        )
        appState.setActiveModel("gpt-5.6-mini", for: .chatgpt)

        XCTAssertEqual(appState.config(for: .chatgpt)?.model, "gpt-5.6-mini")
        XCTAssertEqual(appState.model, "gpt-5.6-mini")
    }

    /// 移除订阅配置：清空配置且不再视为已连接
    func testChatGPTSubscriptionDeleteClearsConfiguration() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = try makeAppState(defaults: defaults)

        try appState.saveProviderConfig(
            vendor: .chatgpt,
            baseURL: "",
            apiKey: "",
            model: "gpt-5.6",
            models: ["gpt-5.6"]
        )
        try appState.deleteProviderAPIKey(vendor: .chatgpt)

        // 与 API Key 服务商一致的删除语义：配置保留但不再视为已连接
        XCTAssertEqual(appState.config(for: .chatgpt)?.hasAPIKey, false)
        XCTAssertEqual(appState.config(for: .chatgpt)?.model, "")
        XCTAssertFalse(appState.hasAPIKey)
        XCTAssertEqual(appState.model, "")
    }

    /// Codex 的模型能力与用户选择均应跨应用重启保留；未选择时仍使用服务端默认档位。
    func testCodexReasoningCapabilityAndSelectionPersist() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let catalog = [
            ModelCatalogEntry(
                id: "gpt-5.6",
                supportedReasoningEfforts: ["low", "medium", "high"],
                defaultReasoningEffort: "medium"
            ),
        ]
        defaults.set(
            try JSONEncoder().encode(catalog),
            forKey: ProviderVendor.chatgpt.modelCatalogDefaultsKey
        )
        defaults.set("", forKey: ProviderVendor.chatgpt.baseURLDefaultsKey)

        let appState = try makeAppState(defaults: defaults)
        try appState.saveProviderConfig(
            vendor: .chatgpt,
            baseURL: "",
            apiKey: "",
            model: "gpt-5.6",
            models: ["gpt-5.6"]
        )

        XCTAssertEqual(appState.reasoningEfforts(for: .chatgpt), ["low", "medium", "high"])
        XCTAssertNil(appState.selectedReasoningEffort(for: .chatgpt))
        XCTAssertEqual(appState.defaultReasoningEffort(for: .chatgpt), "medium")

        appState.setReasoningEffort("high", for: .chatgpt)
        let restored = try makeAppState(defaults: defaults)

        XCTAssertEqual(restored.selectedReasoningEffort(for: .chatgpt), "high")
        XCTAssertEqual(restored.defaultReasoningEffort(for: .chatgpt), "medium")

        restored.resetReasoningSettings(for: .chatgpt)
        XCTAssertNil(restored.selectedReasoningEffort(for: .chatgpt))
    }

    /// 目录缺失能力声明时会尝试经 daemon 加载；daemon 未连接时记录错误而不是崩溃。
    func testRefreshCodexModelCatalogReportsDaemonUnavailable() async throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appState = try makeAppState(defaults: defaults)
        try appState.saveProviderConfig(
            vendor: .chatgpt,
            baseURL: "",
            apiKey: "",
            model: "gpt-5.6",
            models: ["gpt-5.6"]
        )
        XCTAssertTrue(appState.reasoningEfforts(for: .chatgpt).isEmpty)

        await appState.refreshCodexModelCatalogIfNeeded()

        XCTAssertNotNil(appState.codexModelCatalogError)
        XCTAssertFalse(appState.isRefreshingCodexModelCatalog)
    }

    /// 能力目录已明确记录空档位时，表示模型不支持调整，不应再次请求加载目录。
    func testRefreshCodexModelCatalogDoesNotReloadKnownUnsupportedModel() async throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = [
            ModelCatalogEntry(id: "gpt-4o", supportedReasoningEfforts: []),
        ]
        defaults.set(
            try JSONEncoder().encode(catalog),
            forKey: ProviderVendor.chatgpt.modelCatalogDefaultsKey
        )
        defaults.set("", forKey: ProviderVendor.chatgpt.baseURLDefaultsKey)

        let appState = try makeAppState(defaults: defaults)
        try appState.saveProviderConfig(
            vendor: .chatgpt,
            baseURL: "",
            apiKey: "",
            model: "gpt-4o",
            models: ["gpt-4o"]
        )

        await appState.refreshCodexModelCatalogIfNeeded()

        XCTAssertTrue(appState.reasoningEfforts(for: .chatgpt).isEmpty)
        XCTAssertNil(appState.codexModelCatalogError)
    }

}
