import Foundation
import XCTest
@testable import disco

@MainActor
final class OpenAICompatibleProviderTests: XCTestCase {
    func testDeepSeekUsesResponsesAndDecodesItsStream() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepSeekURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.deepseek.com")!,
            session: URLSession(configuration: configuration)
        )

        let text = try await streamText(provider, model: "deepseek-v4-flash")
        XCTAssertEqual(text, "Hello!")
    }

    func testThinkingDisabledSendsReasoningEffortNone() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThinkingDisabledURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.deepseek.com")!,
            session: URLSession(configuration: configuration)
        )

        let text = try await streamText(
            provider,
            model: "deepseek-v4-flash",
            reasoningEnabled: false
        )
        XCTAssertEqual(text, "Hello!")
    }

    func testConfiguredReasoningEffortIsSentAsIs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MaxReasoningURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.deepseek.com")!,
            session: URLSession(configuration: configuration)
        )

        let text = try await streamText(
            provider,
            model: "deepseek-v4-flash",
            reasoningEnabled: true,
            reasoningEffort: "max"
        )
        XCTAssertEqual(text, "Hello!")
    }

    func testOpenAIKeepsUsingResponsesAndDecodesSeparateSSEFrames() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.openai.test/v1")!,
            session: URLSession(configuration: configuration)
        )

        let text = try await streamText(provider, model: "test-model")
        XCTAssertEqual(text, "Hello!")
    }

    func testReasoningDeltasAreForwarded() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.openai.test/v1")!,
            session: URLSession(configuration: configuration)
        )

        var reasoning = ""
        for try await event in provider.stream(request: ModelRequest(
            messages: [ChatMessage(role: .user, text: "Hi")],
            model: "test-model",
            reasoningEnabled: true
        )) {
            if case let .reasoningDelta(delta) = event {
                reasoning += delta
            }
        }
        XCTAssertEqual(reasoning, "The user greets me.")
    }

    func testAvailableModelsSortsModelIDs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelListURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.openai.test/v1")!,
            session: URLSession(configuration: configuration)
        )

        let models = try await provider.models()
        XCTAssertEqual(models, ["gpt-4", "gpt-5", "o1-mini"])
    }

    func testAvailableModelsRejectsAnEmptyModelList() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmptyModelListURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.openai.test/v1")!,
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await provider.models()
            XCTFail("expected noModels")
        } catch let error as OpenAIProviderError {
            guard case .noModels = error else {
                return XCTFail("expected noModels, got \(error)")
            }
        }
    }

    func testResponsesAcceptsACompleteJSONResponseWithoutSSE() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JSONResponseURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.openai.test/v1")!,
            session: URLSession(configuration: configuration)
        )

        let text = try await streamText(provider, model: "test-model")
        XCTAssertEqual(text, "Complete response")
    }

    func testStreamSurfacesHTTPErrorMessage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPErrorURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.openai.test/v1")!,
            session: URLSession(configuration: configuration)
        )

        do {
            for try await _ in provider.stream(request: ModelRequest(
                messages: [ChatMessage(role: .user, text: "Hi")],
                model: "test-model",
                reasoningEnabled: true
            )) {}
            XCTFail("expected HTTP error")
        } catch let error as OpenAIProviderError {
            guard case let .http(statusCode, message) = error else {
                return XCTFail("expected HTTP error, got \(error)")
            }
            XCTAssertEqual(statusCode, 401)
            XCTAssertEqual(message, "invalid api key")
        }
    }

    func testOpenAIWebSearchRequestAndStreamEventsAreNormalizedAndDeduplicated() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIWebSearchURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.openai.test/v1")!,
            session: URLSession(configuration: configuration),
            dialect: .openAI
        )

        let events = try await streamEvents(provider, hostedTools: [.webSearch])
        let citation = TextCitation(
            startIndex: 0,
            endIndex: 5,
            url: "https://swift.org/blog",
            title: "Swift Blog"
        )
        XCTAssertEqual(events, [
            .hostedToolUpdated(HostedToolSnapshot(
                id: "ws_1",
                kind: .webSearch,
                status: .inProgress,
                action: .search(queries: ["Swift news"]),
                sources: []
            )),
            .hostedToolUpdated(HostedToolSnapshot(
                id: "ws_1",
                kind: .webSearch,
                status: .searching,
                action: .search(queries: ["Swift news"]),
                sources: []
            )),
            .textDelta("Swift news"),
            .citationAdded(citation),
            .hostedToolUpdated(HostedToolSnapshot(
                id: "ws_1",
                kind: .webSearch,
                status: .completed,
                action: .search(queries: ["Swift news"]),
                sources: [
                    HostedToolSource(url: "https://swift.org/blog", title: "Swift Blog"),
                ]
            )),
        ])
    }

    func testDeepSeekWebSearchOmitsOpenAISourcesInclude() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepSeekWebSearchURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.deepseek.test/v1")!,
            session: URLSession(configuration: configuration),
            dialect: .deepSeek
        )

        let text = try await streamText(
            provider,
            model: "deepseek-v4-flash",
            hostedTools: [.webSearch]
        )
        XCTAssertEqual(text, "Hello!")
    }

    func testWebSearchUnsupportedErrorRetriesOnceWithoutTools() async throws {
        WebSearchFallbackURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebSearchFallbackURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.openai.test/v1")!,
            session: URLSession(configuration: configuration),
            dialect: .openAI
        )

        let text = try await streamText(
            provider,
            model: "unsupported-model",
            hostedTools: [.webSearch]
        )

        XCTAssertEqual(text, "Hello!")
        XCTAssertEqual(WebSearchFallbackURLProtocol.receivedRequestCount, 2)
    }

    func testUnrelatedBadRequestDoesNotRetryWithoutTools() async throws {
        UnrelatedBadRequestURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnrelatedBadRequestURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.openai.test/v1")!,
            session: URLSession(configuration: configuration),
            dialect: .openAI
        )

        do {
            _ = try await streamText(
                provider,
                model: "test-model",
                hostedTools: [.webSearch]
            )
            XCTFail("expected HTTP error")
        } catch let error as OpenAIProviderError {
            guard case let .http(statusCode, message) = error else {
                return XCTFail("expected HTTP error, got \(error)")
            }
            XCTAssertEqual(statusCode, 400)
            XCTAssertEqual(message, "input is invalid")
        }
        XCTAssertEqual(UnrelatedBadRequestURLProtocol.receivedRequestCount, 1)
    }

    func testCompleteJSONResponseIncludesHostedSearchAndCitationEvents() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JSONWebSearchURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.openai.test/v1")!,
            session: URLSession(configuration: configuration),
            dialect: .openAI
        )

        let events = try await streamEvents(provider, hostedTools: [.webSearch])

        XCTAssertEqual(events, [
            .hostedToolUpdated(HostedToolSnapshot(
                id: "ws_json",
                kind: .webSearch,
                status: .completed,
                action: .openPage(url: "https://example.com"),
                sources: [HostedToolSource(url: "https://example.com", title: "Example")]
            )),
            .textDelta("Example answer"),
            .citationAdded(TextCitation(
                startIndex: 0,
                endIndex: 7,
                url: "https://example.com",
                title: "Example"
            )),
            .textDelta(" More"),
            .citationAdded(TextCitation(
                startIndex: 15,
                endIndex: 19,
                url: "https://example.org",
                title: "More"
            )),
        ])
    }
}

private final class DeepSeekURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        assertResponsesRequest(request, expectedEffort: "high")
        sendSSEStream(helloStreamSSE(includesReasoning: true))
    }

    override func stopLoading() {}
}

private final class ThinkingDisabledURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        assertResponsesRequest(request, expectedEffort: "none")
        sendSSEStream(helloStreamSSE())
    }

    override func stopLoading() {}
}

private final class MaxReasoningURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        assertResponsesRequest(request, expectedEffort: "max")
        sendSSEStream(helloStreamSSE())
    }

    override func stopLoading() {}
}

private final class OpenAIURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        assertResponsesRequest(request, expectedEffort: "high")
        sendSSEStream(helloStreamSSE(includesReasoning: true))
    }

    override func stopLoading() {}
}

private final class ModelListURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        sendJSON("""
        {"data":[{"id":"gpt-5"},{"id":"o1-mini"},{"id":"gpt-4"}]}
        """)
    }

    override func stopLoading() {}

    private func sendJSON(_ body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class EmptyModelListURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"data\":[]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class JSONResponseURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/v1/responses")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(
                """
                {"output":[{"content":[{"text":"Complete response"}]}]}
                """.utf8
            )
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class HTTPErrorURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 401,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data("{\"error\":{\"message\":\"invalid api key\"}}".utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class OpenAIWebSearchURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = requestJSON(request)
        XCTAssertEqual((body?["tools"] as? [[String: String]])?.first?["type"], "web_search")
        XCTAssertEqual(body?["tool_choice"] as? String, "auto")
        XCTAssertEqual(
            body?["include"] as? [String],
            ["web_search_call.action.sources"]
        )
        sendSSEStream(webSearchStreamSSE(), chunkSize: 1)
    }

    override func stopLoading() {}
}

private final class DeepSeekWebSearchURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = requestJSON(request)
        XCTAssertEqual((body?["tools"] as? [[String: String]])?.first?["type"], "web_search")
        XCTAssertEqual(body?["tool_choice"] as? String, "auto")
        XCTAssertNil(body?["include"])
        sendSSEStream(helloStreamSSE())
    }

    override func stopLoading() {}
}

private final class WebSearchFallbackURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestCount = 0

    static var receivedRequestCount: Int {
        lock.withLock { requestCount }
    }

    static func reset() {
        lock.withLock { requestCount = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let count = Self.lock.withLock {
            Self.requestCount += 1
            return Self.requestCount
        }
        let body = requestJSON(request)
        if count == 1 {
            XCTAssertNotNil(body?["tools"])
            sendResponse(
                statusCode: 400,
                contentType: "application/json",
                body: """
                {"error":{"message":"web_search is not supported by this model","type":"invalid_request_error","param":"tools","code":"unsupported_value"}}
                """
            )
        } else {
            XCTAssertNil(body?["tools"])
            XCTAssertNil(body?["tool_choice"])
            XCTAssertNil(body?["include"])
            sendSSEStream(helloStreamSSE())
        }
    }

    override func stopLoading() {}
}

private final class UnrelatedBadRequestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestCount = 0

    static var receivedRequestCount: Int {
        lock.withLock { requestCount }
    }

    static func reset() {
        lock.withLock { requestCount = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requestCount += 1 }
        sendResponse(
            statusCode: 400,
            contentType: "application/json",
            body: """
            {"error":{"message":"input is invalid","type":"invalid_request_error","param":"input","code":400}}
            """
        )
    }

    override func stopLoading() {}
}

private final class JSONWebSearchURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        sendResponse(
            statusCode: 200,
            contentType: "application/json",
            body: """
            {
              "output": [
                {
                  "id": "ws_json",
                  "type": "web_search_call",
                  "status": "completed",
                  "action": {
                    "type": "open_page",
                    "url": "https://example.com",
                    "sources": [{"url":"https://example.com","title":"Example"}]
                  }
                },
                {
                  "id": "msg_json",
                  "type": "message",
                  "content": [{
                    "type": "output_text",
                    "text": "Example answer",
                    "annotations": [{
                      "type": "url_citation",
                      "start_index": 0,
                      "end_index": 7,
                      "url": "https://example.com",
                      "title": "Example"
                    }]
                  }]
                },
                {
                  "id": "msg_more",
                  "type": "message",
                  "content": [{
                    "type": "output_text",
                    "text": " More",
                    "annotations": [{
                      "type": "url_citation",
                      "start_index": 1,
                      "end_index": 5,
                      "url": "https://example.org",
                      "title": "More"
                    }]
                  }]
                }
              ]
            }
            """
        )
    }

    override func stopLoading() {}
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data
}

private func requestJSON(_ request: URLRequest) -> [String: Any]? {
    requestBodyData(request).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
}

private func assertResponsesRequest(_ request: URLRequest, expectedEffort: String) {
    XCTAssertEqual(request.url?.lastPathComponent, "responses")

    let body = requestBodyData(request).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    XCTAssertNotNil(body?["input"])
    XCTAssertNil(body?["messages"])
    let reasoning = body?["reasoning"] as? [String: Any]
    XCTAssertEqual(reasoning?["effort"] as? String, expectedEffort)
}

private func helloStreamSSE(includesReasoning: Bool = false) -> Data {
    let reasoningFrame = includesReasoning
        ? "event: response.reasoning_text.delta\ndata: {\"type\":\"response.reasoning_text.delta\",\"delta\":\"The user greets me.\"}\n\n"
        : ""
    return Data(
        """
        \(reasoningFrame)event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hello"}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"!"}

        event: response.completed
        data: {"type":"response.completed","response":{"output":[]}}

        """.utf8
    )
}

private func webSearchStreamSSE() -> Data {
    Data(
        """
        data: {"type":"response.output_item.added","item":{"id":"ws_1","type":"web_search_call","status":"in_progress","action":{"type":"search","query":"Swift news"}}}

        data: {"type":"response.web_search_call.searching","item_id":"ws_1","action":{"type":"search","queries":["Swift news"]}}

        data: {"type":"response.output_text.delta","delta":"Swift news"}

        data: {"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","start_index":0,"end_index":5,"url":"https://swift.org/blog","title":"Swift Blog"}}

        data: {"type":"response.output_item.done","item":{"id":"ws_1","type":"web_search_call","status":"completed","action":{"type":"search","query":"Swift news","sources":[{"url":"https://swift.org/blog","title":"Swift Blog"}]}}}

        data: {"type":"response.completed","response":{"output":[{"id":"ws_1","type":"web_search_call","status":"completed","action":{"type":"search","query":"Swift news","sources":[{"url":"https://swift.org/blog","title":"Swift Blog"}]}},{"id":"msg_1","type":"message","content":[{"type":"output_text","text":"Swift news","annotations":[{"type":"url_citation","start_index":0,"end_index":5,"url":"https://swift.org/blog","title":"Swift Blog"}]}]}]}}

        """.utf8
    )
}

private extension URLProtocol {
    func sendSSEStream(_ payload: Data, chunkSize: Int? = nil) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let chunkSize {
            for start in stride(from: 0, to: payload.count, by: chunkSize) {
                let end = min(start + chunkSize, payload.count)
                client?.urlProtocol(self, didLoad: payload.subdata(in: start..<end))
            }
        } else {
            client?.urlProtocol(self, didLoad: payload)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    func sendResponse(statusCode: Int, contentType: String, body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
private extension OpenAICompatibleProviderTests {
    func streamText(
        _ provider: OpenAIResponsesProvider,
        model: String,
        reasoningEnabled: Bool = true,
        reasoningEffort: String? = nil,
        hostedTools: Set<HostedToolKind> = []
    ) async throws -> String {
        var text = ""
        for try await event in provider.stream(request: ModelRequest(
            messages: [ChatMessage(role: .user, text: "Hi")],
            model: model,
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort,
            hostedTools: hostedTools
        )) {
            if case let .textDelta(delta) = event {
                text += delta
            }
        }
        return text
    }

    func streamEvents(
        _ provider: OpenAIResponsesProvider,
        hostedTools: Set<HostedToolKind>
    ) async throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        for try await event in provider.stream(request: ModelRequest(
            messages: [ChatMessage(role: .user, text: "Hi")],
            model: "test-model",
            reasoningEnabled: true,
            hostedTools: hostedTools
        )) {
            events.append(event)
        }
        return events
    }
}
