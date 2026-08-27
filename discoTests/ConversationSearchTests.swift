import XCTest
@testable import disco

final class ConversationSearchTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(ConversationSearch.matches(query: "", project: nil, messages: []))
        XCTAssertTrue(ConversationSearch.matches(query: "   ", project: nil, messages: []))
    }

    func testMatchesMessageTextCaseInsensitively() {
        let messages = [
            ChatMessage(role: .user, text: "解释一下 BubbleSort 的复杂度"),
            ChatMessage(role: .assistant, text: "最坏时间复杂度是 O(n²)。"),
        ]

        XCTAssertTrue(ConversationSearch.matches(query: "bubblesort", project: nil, messages: messages))
        XCTAssertTrue(ConversationSearch.matches(query: "复杂度", project: nil, messages: messages))
        XCTAssertFalse(ConversationSearch.matches(query: "快速排序", project: nil, messages: messages))
    }

    func testMatchesProjectName() {
        XCTAssertTrue(ConversationSearch.matches(query: "disco", project: "Disco", messages: []))
        XCTAssertFalse(ConversationSearch.matches(query: "不匹配", project: "Disco", messages: []))
    }

    func testTrimsWhitespaceInQuery() {
        let messages = [ChatMessage(role: .user, text: "持久化回复")]
        XCTAssertTrue(ConversationSearch.matches(query: "  持久化  ", project: nil, messages: messages))
    }
}
