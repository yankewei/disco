import XCTest
@testable import disco

@MainActor
final class ProjectWorkspaceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("disco-project-tests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        suiteName = "ProjectWorkspaceTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testOpeningProjectPersistsProjectAndEmptyProjectConversation() throws {
        let workspace = try makeWorkspace(named: "Disco")
        let storeURL = temporaryDirectory.appendingPathComponent("store")
        let state = try makeState(storeURL: storeURL)

        _ = try state.openProject(at: workspace)

        let project = try XCTUnwrap(state.projects.first)
        let conversation = try XCTUnwrap(state.selectedConversation)
        XCTAssertEqual(project.workspaceRoot, workspace.resolvingSymlinksInPath())
        XCTAssertEqual(conversation.projectID, project.id)
        XCTAssertTrue(conversation.store.messages.isEmpty)

        let persistence = try ConversationPersistence(storeURL: storeURL)
        XCTAssertEqual(try persistence.loadProjects(), [project])
        let persistedConversation = try XCTUnwrap(try persistence.loadConversations().first)
        XCTAssertEqual(persistedConversation.projectID, project.id)
        XCTAssertTrue(persistedConversation.messages.isEmpty)
    }

    func testOpeningExistingProjectPreservesCurrentConversation() throws {
        let workspace = try makeWorkspace(named: "Disco")
        let state = try makeState(
            storeURL: temporaryDirectory.appendingPathComponent("store")
        )

        _ = try state.openProject(at: workspace)
        let firstConversationID = try XCTUnwrap(state.selectedConversation?.id)
        _ = try state.openProject(at: workspace)

        XCTAssertEqual(state.projects.count, 1)
        XCTAssertEqual(state.selectedConversation?.id, firstConversationID)
    }

    func testOpeningExistingProjectDoesNotSelectOrCreateConversation() throws {
        let workspace = try makeWorkspace(named: "Disco")
        let state = try makeState(
            storeURL: temporaryDirectory.appendingPathComponent("store")
        )

        let projectID = try state.openProject(at: workspace)
        let projectConversationID = try XCTUnwrap(state.selectedConversation?.id)
        let temporaryConversationID = state.createConversation(projectID: nil)
        let conversationCount = state.conversations.count

        XCTAssertNotEqual(temporaryConversationID, projectConversationID)
        XCTAssertEqual(try state.openProject(at: workspace), projectID)
        XCTAssertEqual(state.selectedConversation?.id, temporaryConversationID)
        XCTAssertEqual(state.conversations.count, conversationCount)
    }

    func testCreateConversationInCurrentContextFollowsSelectedProjectOrTemporaryMode() throws {
        let workspace = try makeWorkspace(named: "Disco")
        let state = try makeState(
            storeURL: temporaryDirectory.appendingPathComponent("store")
        )

        let projectID = try state.openProject(at: workspace)
        let projectConversationID = try XCTUnwrap(state.selectedConversation?.id)
        XCTAssertEqual(state.createConversationInCurrentContext(), projectConversationID)

        let temporaryConversationID = state.createConversation(projectID: nil)
        XCTAssertEqual(state.createConversationInCurrentContext(), temporaryConversationID)

        _ = state.createConversation(projectID: projectID)
        XCTAssertEqual(state.createConversationInCurrentContext(), projectConversationID)
    }

    func testSelectingProjectSelectsItsMostRecentConversation() throws {
        let workspace = try makeWorkspace(named: "Disco")
        let state = try makeState(
            storeURL: temporaryDirectory.appendingPathComponent("store")
        )

        let projectID = try state.openProject(at: workspace)
        let firstConversation = try XCTUnwrap(state.selectedConversation)
        firstConversation.store.restoreMessages([
            ChatMessage(role: .user, text: "旧项目会话")
        ])
        let recentConversationID = state.createConversation(projectID: projectID)
        _ = state.createConversation(projectID: nil)

        XCTAssertEqual(state.selectProject(id: projectID), recentConversationID)
        XCTAssertEqual(state.selectedConversationID, recentConversationID)
    }

    func testSelectingProjectCreatesConversationWhenItHasNone() throws {
        let workspace = try makeWorkspace(named: "Disco")
        let state = try makeState(
            storeURL: temporaryDirectory.appendingPathComponent("store")
        )

        let projectID = try state.openProject(at: workspace)
        let projectConversationID = try XCTUnwrap(state.selectedConversation?.id)
        state.deleteConversation(id: projectConversationID)

        let selectedID = try XCTUnwrap(state.selectProject(id: projectID))
        XCTAssertEqual(state.selectedConversationID, selectedID)
        XCTAssertEqual(state.selectedConversation?.projectID, projectID)
    }

    func testDeletingProjectRemovesItsConversationsButKeepsWorkspaceDirectory() throws {
        let workspace = try makeWorkspace(named: "Disco")
        let storeURL = temporaryDirectory.appendingPathComponent("store")
        let state = try makeState(storeURL: storeURL)

        let projectID = try state.openProject(at: workspace)
        let projectConversationID = try XCTUnwrap(state.selectedConversation?.id)
        state.deleteProject(id: projectID)

        XCTAssertTrue(state.projects.isEmpty)
        XCTAssertFalse(state.conversations.contains { $0.id == projectConversationID })
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertTrue(try ConversationPersistence(storeURL: storeURL).loadProjects().isEmpty)
        XCTAssertTrue(try ConversationPersistence(storeURL: storeURL).loadConversations().isEmpty)
    }

    func testNormalConversationDoesNotReuseProjectConversation() throws {
        let workspace = try makeWorkspace(named: "Disco")
        let state = try makeState(
            storeURL: temporaryDirectory.appendingPathComponent("store")
        )

        _ = try state.openProject(at: workspace)
        let projectConversationID = try XCTUnwrap(state.selectedConversation?.id)
        let normalConversationID = state.createConversation(projectID: nil)

        XCTAssertNotEqual(normalConversationID, projectConversationID)
        XCTAssertNil(state.selectedConversation?.projectID)
    }

    func testClearingProjectConversationKeepsEmptyConversationPersisted() throws {
        let workspace = try makeWorkspace(named: "Disco")
        let storeURL = temporaryDirectory.appendingPathComponent("store")
        let state = try makeState(storeURL: storeURL)
        _ = try state.openProject(at: workspace)
        let projectID = try XCTUnwrap(state.selectedConversation?.projectID)

        state.selectedConversation?.store.clear()

        let persistence = try ConversationPersistence(storeURL: storeURL)
        let conversation = try XCTUnwrap(try persistence.loadConversations().first)
        XCTAssertEqual(conversation.projectID, projectID)
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertEqual(try persistence.loadProjects().count, 1)
    }

    func testUnavailableProjectRetainsHistoryAndCanBeReconnected() throws {
        let workspace = try makeWorkspace(named: "Disco")
        let replacement = try makeWorkspace(named: "Replacement")
        let storeURL = temporaryDirectory.appendingPathComponent("store")
        let state = try makeState(storeURL: storeURL)
        _ = try state.openProject(at: workspace)
        let project = try XCTUnwrap(state.projects.first)
        let conversationID = try XCTUnwrap(state.selectedConversation?.id)
        try FileManager.default.removeItem(at: workspace)

        let restored = try makeState(storeURL: storeURL)
        XCTAssertEqual(restored.projects.count, 1)
        XCTAssertEqual(restored.selectedConversation?.id, conversationID)
        XCTAssertEqual(restored.selectedConversation?.projectID, project.id)
        XCTAssertEqual(
            restored.projectAvailability[project.id],
            .unavailable(.missing)
        )

        try restored.reconnectProject(id: project.id, to: replacement)

        XCTAssertEqual(restored.projects.first?.workspaceRoot, replacement.resolvingSymlinksInPath())
        XCTAssertEqual(
            restored.projectAvailability[project.id],
            .available(WorkspaceContext(
                rootURL: replacement.resolvingSymlinksInPath(),
                additionalReadableRoots: []
            ))
        )
    }

    func testReconnectingToAnotherProjectDirectoryDoesNotChangeState() throws {
        let first = try makeWorkspace(named: "First")
        let second = try makeWorkspace(named: "Second")
        let state = try makeState(
            storeURL: temporaryDirectory.appendingPathComponent("store")
        )
        _ = try state.openProject(at: first)
        _ = try state.openProject(at: second)
        let firstProject = try XCTUnwrap(state.projects.first { $0.name == "First" })
        let originalPath = firstProject.workspaceRoot

        XCTAssertThrowsError(try state.reconnectProject(id: firstProject.id, to: second))

        XCTAssertEqual(
            state.projects.first { $0.id == firstProject.id }?.workspaceRoot,
            originalPath
        )
        XCTAssertEqual(state.projects.count, 2)
    }

    private func makeWorkspace(named name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeState(storeURL: URL) throws -> AppState {
        AppState(
            keychain: InMemoryAuthStore(),
            defaults: defaults,
            persistence: try ConversationPersistence(storeURL: storeURL)
        )
    }
}
