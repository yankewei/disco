import XCTest
@testable import disco

@MainActor
final class ConversationPersistenceTests: XCTestCase {
    func testRepeatedStreamingSavesUpdateMessagesWithoutDuplicates() throws {
        let persistence = try ConversationPersistence(isStoredInMemoryOnly: true)
        let conversationID = UUID()
        let createdAt = Date.now
        let userMessage = ChatMessage(role: .user, text: "解释 SwiftData")
        let assistantID = UUID()

        try persistence.saveConversation(
            ConversationSnapshot(
                id: conversationID,
                createdAt: createdAt,
                updatedAt: createdAt,
                messages: [
                    userMessage,
                    ChatMessage(id: assistantID, role: .assistant, text: "SwiftData 是"),
                ],
                threadID: nil
            )
        )
        try persistence.saveConversation(
            ConversationSnapshot(
                id: conversationID,
                createdAt: createdAt,
                updatedAt: .now,
                messages: [
                    userMessage,
                    ChatMessage(id: assistantID, role: .assistant, text: "SwiftData 是本地持久化框架。"),
                ],
                threadID: nil
            )
        )

        let restored = try XCTUnwrap(persistence.loadConversations().first)
        XCTAssertEqual(restored.messages.count, 2)
        XCTAssertEqual(restored.messages.last?.id, assistantID)
        XCTAssertEqual(restored.messages.last?.text, "SwiftData 是本地持久化框架。")
    }

    func testReasoningPersistsAcrossSaveAndLoad() throws {
        let persistence = try ConversationPersistence(isStoredInMemoryOnly: true)
        let conversationID = UUID()
        let createdAt = Date.now
        let assistantMessage = ChatMessage(
            id: UUID(),
            role: .assistant,
            text: "回答",
            reasoning: "内部思考"
        )

        try persistence.saveConversation(
            ConversationSnapshot(
                id: conversationID,
                createdAt: createdAt,
                updatedAt: createdAt,
                messages: [
                    ChatMessage(role: .user, text: "问题"),
                    assistantMessage,
                ],
                threadID: nil
            )
        )

        let restored = try XCTUnwrap(persistence.loadConversations().first)
        let restoredAssistant = try XCTUnwrap(restored.messages.last)
        XCTAssertEqual(restoredAssistant.text, "回答")
        XCTAssertEqual(restoredAssistant.reasoning, "内部思考")
    }

    func testHostedSearchAndCitationsPersistInPartOrder() throws {
        let persistence = try ConversationPersistence(isStoredInMemoryOnly: true)
        let citation = TextCitation(
            startIndex: 0,
            endIndex: 4,
            url: "https://example.com/source",
            title: "示例来源"
        )
        let search = HostedToolSnapshot(
            id: "ws_1",
            kind: .webSearch,
            status: .completed,
            action: .search(queries: ["今日新闻"]),
            sources: [
                HostedToolSource(url: "https://example.com/source", title: "示例来源"),
            ]
        )
        let assistant = ChatMessage(
            role: .assistant,
            parts: [
                .reasoning("需要查找最新信息"),
                .hostedTool(search),
                .text(TextContent(text: "今日新闻摘要", citations: [citation])),
            ]
        )

        try persistence.saveConversation(
            ConversationSnapshot(
                id: UUID(),
                createdAt: .now,
                updatedAt: .now,
                messages: [
                    ChatMessage(role: .user, text: "今天有什么新闻？"),
                    assistant,
                ],
                threadID: nil
            )
        )

        let restored = try XCTUnwrap(persistence.loadConversations().first?.messages.last)
        XCTAssertEqual(restored.parts, assistant.parts)
        XCTAssertEqual(restored.sources, search.sources)
    }

    func testCorruptPartsDataFallsBackToLegacyTextAndReasoning() {
        let id = UUID()

        let restored = ConversationPersistence.restoreMessage(
            id: id,
            role: .assistant,
            text: "旧正文",
            reasoning: "旧思考",
            partsData: Data("not-json".utf8)
        )

        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.parts, [
            .reasoning("旧思考"),
            .text(TextContent(text: "旧正文")),
        ])
    }

    func testProjectAndConversationProjectIDPersistAcrossSaveAndLoad() throws {
        let persistence = try ConversationPersistence(isStoredInMemoryOnly: true)
        let project = ProjectSnapshot(
            id: UUID(),
            name: "Disco",
            workspaceRoot: URL(fileURLWithPath: "/tmp/disco"),
            bookmarkData: Data("bookmark".utf8),
            createdAt: .now,
            lastOpenedAt: .now
        )
        let conversationID = UUID()

        try persistence.saveProject(project)
        try persistence.saveConversation(
            ConversationSnapshot(
                id: conversationID,
                createdAt: .now,
                updatedAt: .now,
                messages: [],
                threadID: nil,
                projectID: project.id
            )
        )

        let restoredProject = try XCTUnwrap(persistence.loadProjects().first)
        let restoredConversation = try XCTUnwrap(persistence.loadConversations().first)
        XCTAssertEqual(restoredProject, project)
        XCTAssertEqual(restoredConversation.projectID, project.id)
        XCTAssertTrue(restoredConversation.messages.isEmpty)
    }

    /// 订阅服务商：会话线程 id 持久化往返（重启后用于 thread/resume）
    func testThreadIDPersistsAcrossSaveAndLoad() throws {
        let persistence = try ConversationPersistence(isStoredInMemoryOnly: true)
        let conversationID = UUID()
        let createdAt = Date.now

        try persistence.saveConversation(
            ConversationSnapshot(
                id: conversationID,
                createdAt: createdAt,
                updatedAt: createdAt,
                messages: [
                    ChatMessage(role: .user, text: "你好"),
                    ChatMessage(role: .assistant, text: "你好！"),
                ],
                threadID: "thr_abc123"
            )
        )

        let restored = try XCTUnwrap(persistence.loadConversations().first)
        XCTAssertEqual(restored.threadID, "thr_abc123")

        // 覆盖保存时 threadID 跟随更新
        try persistence.saveConversation(
            ConversationSnapshot(
                id: conversationID,
                createdAt: createdAt,
                updatedAt: .now,
                messages: restored.messages,
                threadID: "thr_def456"
            )
        )
        let reloaded = try XCTUnwrap(persistence.loadConversations().first)
        XCTAssertEqual(reloaded.threadID, "thr_def456")
    }

    func testSessionRuntimeMetadataPersistsAcrossSaveAndLoad() throws {
        let persistence = try ConversationPersistence(isStoredInMemoryOnly: true)
        let conversationID = UUID()

        try persistence.saveConversation(
            ConversationSnapshot(
                id: conversationID,
                createdAt: .now,
                updatedAt: .now,
                messages: [ChatMessage(role: .user, text: "保留来源")],
                threadID: nil,
                projectID: UUID(),
                providerID: "opencode_app_server",
                runtimeKind: .acp
            )
        )

        let restored = try XCTUnwrap(persistence.loadConversations().first)
        XCTAssertEqual(restored.providerID, "opencode_app_server")
        XCTAssertEqual(restored.runtimeKind, .acp)
    }
}
