import XCTest
@testable import disco

final class ChatMessageTests: XCTestCase {
    func testConvenienceInitBuildsOrderedParts() {
        let message = ChatMessage(role: .assistant, text: "回答", reasoning: "思考")

        XCTAssertEqual(message.parts, [.reasoning("思考"), .text("回答")])
        XCTAssertEqual(message.text, "回答")
        XCTAssertEqual(message.reasoning, "思考")
    }

    func testTextOnlyInitProducesSingleTextPart() {
        let message = ChatMessage(role: .user, text: "你好")

        XCTAssertEqual(message.parts, [.text("你好")])
    }

    func testStreamingDeltasAppendToTrailingPartOfSameKind() {
        var message = ChatMessage(role: .assistant)

        message.appendReasoning("先分析")
        message.appendReasoning("再回答")
        message.appendText("最终回答")
        message.appendText("补充")

        XCTAssertEqual(message.parts, [.reasoning("先分析再回答"), .text("最终回答补充")])
    }

    func testDeltaAfterToolCallStartsANewPart() {
        var message = ChatMessage(role: .assistant, text: "开始")

        message.parts.append(.toolCall(.init(id: "1", name: "shell.execute", arguments: "{}")))
        message.appendText("继续")

        XCTAssertEqual(message.parts, [
            .text("开始"),
            .toolCall(.init(id: "1", name: "shell.execute", arguments: "{}")),
            .text("继续"),
        ])
    }

    func testEmptyPlaceholderHasNoParts() {
        let placeholder = ChatMessage(id: UUID(), role: .assistant)

        XCTAssertTrue(placeholder.parts.isEmpty)
        XCTAssertTrue(placeholder.text.isEmpty)
    }
}
