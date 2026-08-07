import XCTest
@testable import disco

@MainActor
final class AppStateTests: XCTestCase {
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
    keychain: APIKeyStoring = InMemoryAuthStore(),
    defaults: UserDefaults
) throws -> AppState {
    AppState(
        keychain: keychain,
        defaults: defaults,
        persistence: try ConversationPersistence(isStoredInMemoryOnly: true)
    )
}
