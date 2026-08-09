import Foundation
import XCTest
@testable import disco

@MainActor
final class OpenAIChatCompletionsProviderTests: XCTestCase {
    func testKimiRequestUsesChatCompletionsThinkingAndPreservedReasoning() async throws {
        let provider = makeProvider(protocolClass: KimiChatStreamURLProtocol.self)
        let messages = [
            ChatMessage(role: .user, text: "你好"),
            ChatMessage(role: .assistant, text: "先前回答", reasoning: "先前思考"),
            ChatMessage(role: .user, text: "继续"),
        ]

        let events = try await collectEvents(provider, messages: messages)

        XCTAssertEqual(events, [
            .reasoningDelta("正在思考"),
            .textDelta("你好"),
            .usage(TokenUsageSnapshot(
                inputTokens: 10,
                outputTokens: 2,
                totalTokens: 12
            )),
            .textDelta("！"),
        ])
    }

    func testKimiThinkingCanBeDisabled() async throws {
        let provider = makeProvider(protocolClass: KimiThinkingDisabledURLProtocol.self)
        let messages = [
            ChatMessage(role: .assistant, text: "先前回答", reasoning: "不应回传"),
            ChatMessage(role: .user, text: "继续"),
        ]

        let events = try await collectEvents(
            provider,
            messages: messages,
            reasoningEnabled: false
        )

        XCTAssertEqual(events, [.textDelta("完成")])
    }

    func testModelsUsesParallelModelsEndpointAndSortsIDs() async throws {
        let provider = makeProvider(protocolClass: KimiModelsURLProtocol.self)

        let catalog = try await provider.modelCatalog()

        XCTAssertEqual(catalog, [
            ModelCatalogEntry(id: "k3", contextWindow: 1_048_576, supportsToolCalling: true),
            ModelCatalogEntry(id: "k3-256k", contextWindow: 262_144, supportsToolCalling: true),
            ModelCatalogEntry(id: "kimi-for-coding", supportsToolCalling: true),
        ])
        let models = try await provider.models()
        XCTAssertEqual(models, ["k3", "k3-256k", "kimi-for-coding"])
    }

    func testCompleteJSONResponseForwardsReasoningAndText() async throws {
        let provider = makeProvider(protocolClass: KimiJSONResponseURLProtocol.self)

        let events = try await collectEvents(provider)

        XCTAssertEqual(events, [
            .reasoningDelta("完整思考"),
            .textDelta("完整回答"),
        ])
    }

    func testHTTPErrorUsesServerMessage() async throws {
        let provider = makeProvider(protocolClass: KimiHTTPErrorURLProtocol.self)

        do {
            _ = try await collectEvents(provider)
            XCTFail("expected HTTP error")
        } catch let error as ChatCompletionsProviderError {
            guard case let .http(statusCode, message) = error else {
                return XCTFail("expected HTTP error, got \(error)")
            }
            XCTAssertEqual(statusCode, 401)
            XCTAssertEqual(message, "invalid api key")
        }
    }

    func testToolCallFailsExplicitlyUntilGenericToolLoopIsImplemented() async throws {
        let provider = makeProvider(protocolClass: KimiToolCallURLProtocol.self)

        do {
            _ = try await collectEvents(provider)
            XCTFail("expected unsupported tool call")
        } catch let error as ChatCompletionsProviderError {
            guard case .unsupportedToolCall = error else {
                return XCTFail("expected unsupportedToolCall, got \(error)")
            }
        }
    }

    private func makeProvider(
        protocolClass: URLProtocol.Type
    ) -> OpenAIChatCompletionsProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return OpenAIChatCompletionsProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.kimi.test/coding/v1")!,
            session: URLSession(configuration: configuration),
            dialect: .kimi
        )
    }

    private func collectEvents(
        _ provider: OpenAIChatCompletionsProvider,
        messages: [ChatMessage]? = nil,
        reasoningEnabled: Bool = true
    ) async throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        for try await event in provider.stream(request: ModelRequest(
            messages: messages ?? [ChatMessage(role: .user, text: "你好")],
            model: "kimi-for-coding",
            reasoningEnabled: reasoningEnabled
        )) {
            events.append(event)
        }
        return events
    }
}

private final class KimiChatStreamURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/coding/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("disco/") == true)
        let body = chatRequestJSON(request)
        XCTAssertEqual(body?["model"] as? String, "kimi-for-coding")
        XCTAssertEqual(body?["stream"] as? Bool, true)
        XCTAssertEqual(
            (body?["stream_options"] as? [String: Any])?["include_usage"] as? Bool,
            true
        )
        XCTAssertEqual(body?["thinking"] as? [String: String], [
            "type": "enabled",
            "effort": "high",
        ])
        XCTAssertNil(body?["reasoning_effort"])
        let messages = body?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 3)
        XCTAssertEqual(messages?[0]["role"] as? String, "user")
        XCTAssertNil(messages?[0]["reasoning_content"])
        XCTAssertEqual(messages?[1]["content"] as? String, "先前回答")
        XCTAssertEqual(messages?[1]["reasoning_content"] as? String, "先前思考")

        sendChatResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            body: """
            data: {"choices":[{"index":0,"delta":{"reasoning_content":"正在思考"},"finish_reason":null}]}

            data: {"choices":[{"index":0,"delta":{"content":"你好"},"finish_reason":null}]}

            data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}

            data: {"choices":[{"index":0,"delta":{"content":"！"},"finish_reason":"stop"}]}

            data: [DONE]

            """,
            chunkSize: 1
        )
    }

    override func stopLoading() {}
}

private final class KimiThinkingDisabledURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = chatRequestJSON(request)
        XCTAssertEqual(body?["thinking"] as? [String: String], ["type": "disabled"])
        XCTAssertNil(body?["reasoning_effort"])
        let messages = body?["messages"] as? [[String: Any]]
        XCTAssertNil(messages?.first?["reasoning_content"])
        sendChatResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            body: """
            data: {"choices":[{"index":0,"delta":{"content":"完成"},"finish_reason":"stop"}]}

            """
        )
    }

    override func stopLoading() {}
}

private final class KimiModelsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/coding/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("disco/") == true)
        sendChatResponse(
            statusCode: 200,
            contentType: "application/json",
            body: """
            {"data":[{"id":"kimi-for-coding"},{"id":"k3-256k","context_length":262144},{"id":"k3","context_length":1048576}]}
            """
        )
    }

    override func stopLoading() {}
}

private final class KimiJSONResponseURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        sendChatResponse(
            statusCode: 200,
            contentType: "application/json",
            body: """
            {
              "choices": [{
                "index": 0,
                "message": {
                  "role": "assistant",
                  "reasoning_content": "完整思考",
                  "content": "完整回答"
                },
                "finish_reason": "stop"
              }]
            }
            """
        )
    }

    override func stopLoading() {}
}

private final class KimiHTTPErrorURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        sendChatResponse(
            statusCode: 401,
            contentType: "application/json",
            body: "{\"error\":{\"message\":\"invalid api key\"}}"
        )
    }

    override func stopLoading() {}
}

private final class KimiToolCallURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        sendChatResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            body: """
            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

            """
        )
    }

    override func stopLoading() {}
}

private func chatRequestJSON(_ request: URLRequest) -> [String: Any]? {
    let data: Data?
    if let body = request.httpBody {
        data = body
    } else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        data = body
    } else {
        data = nil
    }
    return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

private extension URLProtocol {
    func sendChatResponse(
        statusCode: Int,
        contentType: String,
        body: String,
        chunkSize: Int? = nil
    ) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = Data(body.utf8)
        if let chunkSize {
            for start in stride(from: 0, to: data.count, by: chunkSize) {
                let end = min(start + chunkSize, data.count)
                client?.urlProtocol(self, didLoad: data.subdata(in: start..<end))
            }
        } else {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
