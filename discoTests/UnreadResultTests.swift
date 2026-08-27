import XCTest
@testable import disco

@MainActor
final class UnreadResultTests: XCTestCase {
    func testRunCompletionMarksUnreadAndMarkSeenClears() async throws {
        let sessionID = UUID()
        let runID = UUID()
        let client = RecordingDiscoDaemonClient(runID: runID)
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)
        store.draft = "一个问题"

        store.send()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.hasUnreadResult)

        store.handleDaemonNotification(daemonEvent(
            "run.completed",
            runID: runID,
            sessionID: sessionID
        ))
        XCTAssertTrue(store.hasUnreadResult)

        store.markResultSeen()
        XCTAssertFalse(store.hasUnreadResult)
    }

    func testRunFailureMarksUnread() async throws {
        let sessionID = UUID()
        let runID = UUID()
        let client = RecordingDiscoDaemonClient(runID: runID)
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)
        store.draft = "一个问题"

        store.send()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        store.handleDaemonNotification(daemonEvent(
            "run.failed",
            runID: runID,
            sessionID: sessionID,
            fields: ["error": .object(["message": .string("出错了")])]
        ))
        XCTAssertTrue(store.hasUnreadResult)
    }

    func testClearHistoryResetsUnread() {
        let store = ConversationStore()
        store.restoreMessages([ChatMessage(role: .user, text: "历史")])

        store.clear()

        XCTAssertFalse(store.hasUnreadResult)
    }
}
