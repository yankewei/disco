import XCTest
@testable import disco

@MainActor
final class AppStateTests: XCTestCase {
    func testSaveConfigurationTrimsValuesPersistsThemAndUsesStoredKey() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainStore()
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
        let keychain = InMemoryKeychainStore()
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

        let keychain = InMemoryKeychainStore()
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
        let keychain = InMemoryKeychainStore()
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
        let keychain = InMemoryKeychainStore()
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

    func testThinkingEnabledDefaultsOnAndPersistsToggle() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = try makeAppState(defaults: defaults)

        XCTAssertTrue(appState.thinkingEnabled)

        appState.setThinkingEnabled(false)

        XCTAssertFalse(appState.thinkingEnabled)
        XCTAssertFalse(defaults.bool(forKey: "thinkingEnabled"))

        let restored = try makeAppState(defaults: defaults)
        XCTAssertFalse(restored.thinkingEnabled)
    }
}

@MainActor
private func makeAppState(
    keychain: APIKeyStoring = InMemoryKeychainStore(),
    defaults: UserDefaults
) throws -> AppState {
    AppState(
        keychain: keychain,
        defaults: defaults,
        persistence: try ConversationPersistence(isStoredInMemoryOnly: true)
    )
}
