import XCTest
@testable import disco

final class ChatMessageTests: XCTestCase {
    func testConvenienceInitBuildsOrderedParts() {
        let message = ChatMessage(role: .assistant, text: "回答", reasoning: "思考")

        XCTAssertEqual(message.parts, [
            .reasoning("思考"),
            .text(TextContent(text: "回答")),
        ])
        XCTAssertEqual(message.text, "回答")
        XCTAssertEqual(message.reasoning, "思考")
    }

    func testTextOnlyInitProducesSingleTextPart() {
        let message = ChatMessage(role: .user, text: "你好")

        XCTAssertEqual(message.parts, [.text(TextContent(text: "你好"))])
    }

    func testStreamingDeltasAppendToTrailingPartOfSameKind() {
        var message = ChatMessage(role: .assistant)

        message.appendReasoning("先分析")
        message.appendReasoning("再回答")
        message.appendText("最终回答")
        message.appendText("补充")

        XCTAssertEqual(message.parts, [
            .reasoning("先分析再回答"),
            .text(TextContent(text: "最终回答补充")),
        ])
    }

    func testDeltaAfterToolCallStartsANewPart() {
        var message = ChatMessage(role: .assistant, text: "开始")

        message.parts.append(.toolCall(.init(id: "1", name: "shell.execute", arguments: "{}")))
        message.appendText("继续")

        XCTAssertEqual(message.parts, [
            .text(TextContent(text: "开始")),
            .toolCall(.init(id: "1", name: "shell.execute", arguments: "{}")),
            .text(TextContent(text: "继续")),
        ])
    }

    func testToolCallLifecycleUpdatesInPlaceAndKeepsOrder() {
        var message = ChatMessage(role: .assistant)
        message.appendReasoning("先分析")
        message.upsertToolCall(
            .init(id: "1", name: "shell", arguments: #"{"command":"pwd"}"#)
        )
        XCTAssertTrue(message.hasRunningToolCall)
        message.appendReasoning("再整理")
        message.upsertToolCall(
            .init(
                id: "1",
                name: "shell",
                arguments: #"{"command":"pwd"}"#,
                status: .completed,
                output: "/tmp/disco"
            )
        )
        XCTAssertFalse(message.hasRunningToolCall)
        message.appendText("完成")

        XCTAssertEqual(message.parts.map { part in
            switch part {
            case .reasoning: return "reasoning"
            case .toolCall: return "toolCall"
            case .text: return "text"
            case .hostedTool: return "hostedTool"
            }
        }, ["reasoning", "toolCall", "reasoning", "text"])
        XCTAssertEqual(
            message.parts.compactMap { part -> ChatMessage.ToolCallSnapshot? in
                guard case let .toolCall(call) = part else { return nil }
                return call
            }.first?.output,
            "/tmp/disco"
        )
    }

    func testEmptyPlaceholderHasNoParts() {
        let placeholder = ChatMessage(id: UUID(), role: .assistant)

        XCTAssertTrue(placeholder.parts.isEmpty)
        XCTAssertTrue(placeholder.text.isEmpty)
    }

    func testHostedToolUpdatesInPlaceAndCitationDeduplicates() {
        var message = ChatMessage(role: .assistant)
        let searching = HostedToolSnapshot(
            id: "ws_1",
            kind: .webSearch,
            status: .searching,
            action: .search(queries: ["Swift 6"]),
            sources: []
        )
        var completed = searching
        completed.status = .completed

        message.upsertHostedTool(searching)
        message.upsertHostedTool(completed)
        message.appendText("Swift 6")
        let citation = TextCitation(
            startIndex: 0,
            endIndex: 7,
            url: "https://swift.org",
            title: "Swift"
        )
        message.appendCitation(citation)
        message.appendCitation(citation)

        XCTAssertEqual(message.parts, [
            .hostedTool(completed),
            .text(TextContent(text: "Swift 6", citations: [citation])),
        ])
        XCTAssertEqual(message.sources, [
            HostedToolSource(url: "https://swift.org", title: "Swift"),
        ])
    }

    func testCitationMarkdownUsesUTF16OffsetsForEmojiAndChinese() {
        let content = TextContent(
            text: "😀中文来源",
            citations: [
                TextCitation(
                    startIndex: 2,
                    endIndex: 6,
                    url: "https://example.com/path_(one)",
                    title: "来源"
                ),
            ]
        )

        XCTAssertEqual(
            content.citationMarkdown,
            "😀[中文来源](<https://example.com/path_(one)>)"
        )
    }

    func testInvalidAndOverlappingCitationsFallBackWithoutChangingText() {
        let content = TextContent(
            text: "abcdef",
            citations: [
                TextCitation(startIndex: 0, endIndex: 4, url: "https://a.test", title: nil),
                TextCitation(startIndex: 2, endIndex: 6, url: "https://b.test", title: nil),
                TextCitation(startIndex: 20, endIndex: 21, url: "https://c.test", title: nil),
            ]
        )

        XCTAssertEqual(
            content.citationMarkdown,
            "[abcd](<https://a.test>)ef [2](<https://b.test>) [3](<https://c.test>)"
        )
    }

    func testCitationMarkdownRejectsNonWebSchemes() {
        let content = TextContent(
            text: "不要执行",
            citations: [
                TextCitation(
                    startIndex: 0,
                    endIndex: 4,
                    url: "javascript:alert(1)",
                    title: nil
                ),
            ]
        )

        XCTAssertEqual(content.citationMarkdown, "不要执行")
    }
}
