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
        let store = ConversationStore()
        store.configure(provider: ChunkedMarkdownProvider(chunks: [
            "# 标题", "\n\n", "- 第一项", "\n", "- 第二项", "\n\n",
            "```swift\n", "let value = 1\n", "```",
        ]))
        store.draft = "请使用 Markdown 回复"
        store.send()

        for _ in 0..<100 where store.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.messages.last?.text, expected)
    }
}

private struct ChunkedMarkdownProvider: AIProvider {
    let chunks: [String]

    func stream(messages: [ChatMessage]) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(.textDelta(chunk))
            }
            continuation.finish()
        }
    }
}
