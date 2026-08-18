import XCTest
@testable import disco

@MainActor
final class ConversationManagementTests: XCTestCase {
    func testCreatingAndDeletingConversationsKeepsAValidSelection() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            keychain: InMemoryAuthStore(),
            defaults: defaults,
            persistence: try ConversationPersistence(isStoredInMemoryOnly: true)
        )

        let firstConversation = try XCTUnwrap(appState.selectedConversation)
        firstConversation.store.restoreMessages([
            ChatMessage(role: .user, text: "Hi"),
            ChatMessage(role: .assistant, text: "Hello"),
        ])

        let secondID = appState.createConversation()
        XCTAssertEqual(appState.conversations.count, 2)
        XCTAssertEqual(appState.selectedConversationID, secondID)
        XCTAssertTrue(appState.selectedConversation?.store.messages.isEmpty == true)

        appState.deleteConversation(id: secondID)
        XCTAssertEqual(appState.conversations.count, 1)
        XCTAssertEqual(appState.selectedConversationID, firstConversation.id)
    }

    func testMessagesRestoreAfterRelaunchAndClearDeletesThem() async throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = try ConversationPersistence(isStoredInMemoryOnly: true)

        let firstAppState = AppState(
            keychain: InMemoryAuthStore(),
            defaults: defaults,
            persistence: persistence
        )
        let conversation = try XCTUnwrap(firstAppState.selectedConversation)
        conversation.store.restoreMessages([
            ChatMessage(role: .user, text: "保存这段对话"),
            ChatMessage(role: .assistant, text: "持久化回复"),
        ])

        let restoredAppState = AppState(
            keychain: InMemoryAuthStore(),
            defaults: defaults,
            persistence: persistence
        )
        let restoredConversation = try XCTUnwrap(restoredAppState.selectedConversation)
        XCTAssertEqual(
            restoredConversation.store.messages.map(\.text),
            ["保存这段对话", "持久化回复"]
        )

        restoredConversation.store.clear()
        let appStateAfterClear = AppState(
            keychain: InMemoryAuthStore(),
            defaults: defaults,
            persistence: persistence
        )
        XCTAssertEqual(appStateAfterClear.conversations.count, 1)
        XCTAssertTrue(appStateAfterClear.selectedConversation?.store.messages.isEmpty == true)
    }

    func testActiveConversationMovesToTopOfRecentList() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            keychain: InMemoryAuthStore(),
            defaults: defaults,
            persistence: try ConversationPersistence(isStoredInMemoryOnly: true)
        )

        let firstConversation = try XCTUnwrap(appState.selectedConversation)
        firstConversation.store.restoreMessages([
            ChatMessage(role: .user, text: "第一段对话"),
            ChatMessage(role: .assistant, text: "第一条回复"),
        ])

        let secondID = appState.createConversation()
        let secondConversation = try XCTUnwrap(appState.selectedConversation)
        secondConversation.store.restoreMessages([
            ChatMessage(role: .user, text: "第二段对话"),
            ChatMessage(role: .assistant, text: "第二条回复"),
        ])
        XCTAssertEqual(appState.conversations.first?.id, secondID)

        firstConversation.store.restoreMessages(firstConversation.store.messages + [
            ChatMessage(role: .user, text: "继续第一段对话"),
        ])
        XCTAssertEqual(appState.conversations.first?.id, firstConversation.id)
    }
}
