import XCTest
@testable import disco

@MainActor
final class StreamingMarkdownTests: XCTestCase {
    func testStreamingKeepsMarkdownStructureAcrossDeltas() async throws {
        let expected = """
        # 标题

        - 第一项
        - 第二项

        ```swift
        let value = 1
        ```
        """
        let chunks = [
            "# 标题", "\n\n", "- 第一项", "\n", "- 第二项", "\n\n",
            "```swift\n", "let value = 1\n", "```",
        ]
        let sessionID = UUID()
        let runID = UUID()
        let client = RecordingDiscoDaemonClient(runID: runID)
        let store = ConversationStore()
        store.configure(daemonClient: client)
        store.enableDaemonRuns(sessionID: sessionID)
        store.draft = "请使用 Markdown 回复"

        store.send()
        for _ in 0..<100 where client.startedRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        for chunk in chunks {
            store.handleDaemonNotification(daemonEvent(
                "message.delta",
                runID: runID,
                sessionID: sessionID,
                fields: ["delta": .string(chunk)]
            ))
        }
        store.handleDaemonNotification(daemonEvent(
            "run.completed",
            runID: runID,
            sessionID: sessionID
        ))

        XCTAssertEqual(store.messages.last?.text, expected)
        XCTAssertFalse(store.isStreaming)
    }
}
