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
        firstConversation.store.configure(runtime: GenericAgentRuntime(
            provider: ImmediateProvider(text: "Hello"),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))
        firstConversation.store.draft = "Hi"
        firstConversation.store.send()

        for _ in 0..<100 where firstConversation.store.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }

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
        conversation.store.configure(runtime: GenericAgentRuntime(
            provider: ImmediateProvider(text: "持久化回复"),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))
        conversation.store.draft = "保存这段对话"
        conversation.store.send()

        for _ in 0..<100 where conversation.store.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }

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
        firstConversation.store.configure(runtime: GenericAgentRuntime(
            provider: ImmediateProvider(text: "第一条回复"),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))
        firstConversation.store.draft = "第一段对话"
        firstConversation.store.send()
        for _ in 0..<100 where firstConversation.store.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }

        let secondID = appState.createConversation()
        let secondConversation = try XCTUnwrap(appState.selectedConversation)
        secondConversation.store.configure(runtime: GenericAgentRuntime(
            provider: ImmediateProvider(text: "第二条回复"),
            configuration: .init(model: "test-model", reasoningEnabled: true)
        ))
        secondConversation.store.draft = "第二段对话"
        secondConversation.store.send()
        for _ in 0..<100 where secondConversation.store.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(appState.conversations.first?.id, secondID)

        firstConversation.store.draft = "继续第一段对话"
        firstConversation.store.send()
        for _ in 0..<100 where firstConversation.store.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(appState.conversations.first?.id, firstConversation.id)
    }
}

private struct ImmediateProvider: ModelProvider {
    let text: String

    let descriptor = ProviderDescriptor(id: "immediate", displayName: "Immediate")

    func models() async throws -> [String] { ["test-model"] }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(text))
            continuation.finish()
        }
    }
}
