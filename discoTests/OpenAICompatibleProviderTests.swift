import Foundation
import XCTest
@testable import disco

@MainActor
final class OpenAICompatibleProviderTests: XCTestCase {
    func testDeepSeekUsesChatCompletionsAndDecodesItsStream() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepSeekURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.deepseek.com")!,
            model: "deepseek-v4-flash",
            session: URLSession(configuration: configuration)
        )

        var text = ""
        for try await event in provider.stream(
            messages: [ChatMessage(role: .user, text: "Hi")]
        ) {
            if case let .textDelta(delta) = event {
                text += delta
            }
        }

        XCTAssertEqual(text, "Hello!")
    }

    func testOpenAIKeepsUsingResponsesAndDecodesSeparateSSEFrames() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIURLProtocol.self]
        let provider = OpenAIResponsesProvider(
            apiKey: "test-key",
            baseURL: URL(string: "https://api.openai.test/v1")!,
            model: "test-model",
            session: URLSession(configuration: configuration)
        )

        var text = ""
        for try await event in provider.stream(
            messages: [ChatMessage(role: .user, text: "Hi")]
        ) {
            if case let .textDelta(delta) = event {
                text += delta
            }
        }

        XCTAssertEqual(text, "Hello!")
    }
}

private final class DeepSeekURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/chat/completions")

        let body = requestBodyData(request).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        XCTAssertNotNil(body?["messages"])
        XCTAssertNil(body?["input"])

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(
                """
                data: {"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}

                data: {"choices":[{"delta":{"content":"!"},"finish_reason":null}]}

                data: {"choices":[{"delta":{"content":""},"finish_reason":"stop"}]}

                data: [DONE]

                """.utf8
            )
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class OpenAIURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/v1/responses")

        let body = requestBodyData(request).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        XCTAssertNotNil(body?["input"])
        XCTAssertNil(body?["messages"])

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(
                """
                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":"Hello"}

                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":"!"}

                event: response.completed
                data: {"type":"response.completed","response":{"output":[]}}

                """.utf8
            )
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
