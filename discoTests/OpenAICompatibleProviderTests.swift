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

private extension URLProtocol {
    func sendSSEStream(_ payload: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
private extension OpenAICompatibleProviderTests {
    func streamText(
        _ provider: OpenAIResponsesProvider,
        model: String,
        reasoningEnabled: Bool = true,
        reasoningEffort: String? = nil
    ) async throws -> String {
        var text = ""
        for try await event in provider.stream(request: ModelRequest(
            messages: [ChatMessage(role: .user, text: "Hi")],
            model: model,
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort
        )) {
            if case let .textDelta(delta) = event {
                text += delta
            }
        }
        return text
    }
}
