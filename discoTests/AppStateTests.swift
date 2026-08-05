import XCTest
@testable import disco

@MainActor
final class AppStateTests: XCTestCase {
    func testSaveConfigurationTrimsValuesPersistsThemAndUsesStoredKey() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainStore()
        let appState = AppState(
            keychain: keychain,
            defaults: defaults,
            persistence: try ConversationPersistence(isStoredInMemoryOnly: true)
        )

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
        let appState = AppState(
            keychain: keychain,
            defaults: defaults,
            persistence: try ConversationPersistence(isStoredInMemoryOnly: true)
        )
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
        let appState = AppState(
            keychain: InMemoryKeychainStore(),
            defaults: defaults,
            persistence: try ConversationPersistence(isStoredInMemoryOnly: true)
        )

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
        let stateWithKey = AppState(
            keychain: keychain,
            defaults: defaults,
            persistence: try ConversationPersistence(isStoredInMemoryOnly: true)
        )
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
        let appState = AppState(
            keychain: keychain,
            defaults: UserDefaults(suiteName: #function)!,
            persistence: try ConversationPersistence(isStoredInMemoryOnly: true)
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
}
