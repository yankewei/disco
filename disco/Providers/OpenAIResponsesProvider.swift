import Foundation

/// OpenAI Responses API Provider（计划 §10.2，ADR-004 的 URLSession 版）。
/// 只负责认证、请求构造、SSE 解析与错误转换；模型与推理配置来自 ModelRequest。
struct OpenAIResponsesProvider: ModelProvider {
    static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!
    static let defaultModel = "gpt-5.6"

    let descriptor = ProviderDescriptor(
        id: "openai-responses",
        displayName: "OpenAI Responses"
    )

    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    init(
        apiKey: String,
        baseURL: URL = OpenAIResponsesProvider.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    func models() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIProviderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw httpError(statusCode: httpResponse.statusCode, data: data)
        }

        let models = try JSONDecoder().decode(ModelListResponse.self, from: data).data
            .map(\.id)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !models.isEmpty else {
            throw OpenAIProviderError.noModels
        }
        return models
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: baseURL.appendingPathComponent("responses"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 90
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    let input = request.messages.map {
                        InputMessage(role: $0.role.rawValue, content: $0.text)
                    }
                    urlRequest.httpBody = try JSONEncoder().encode(
                        ResponsesRequestBody(
                            model: request.model,
                            input: input,
                            stream: true,
                            store: false,
                            reasoning: ReasoningConfig(
                                effort: request.reasoningEffort
                                    ?? (request.reasoningEnabled ? "high" : "none")
                            )
                        )
                    )

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw OpenAIProviderError.invalidResponse
                    }

                    guard (200..<300).contains(httpResponse.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            guard body.count < 1_048_576 else { break }
                            body.append(byte)
                        }

                        throw httpError(statusCode: httpResponse.statusCode, data: body)
                    }

                    if httpResponse.value(forHTTPHeaderField: "Content-Type")?
                        .localizedCaseInsensitiveContains("text/event-stream") != true {
                        var body = Data()
                        for try await byte in bytes {
                            guard body.count < 10_485_760 else {
                                throw OpenAIProviderError.invalidResponse
                            }
                            body.append(byte)
                        }

                        let text: String
                        let response = try JSONDecoder().decode(APIResponse.self, from: body)
                        if let message = response.error?.message, !message.isEmpty {
                            throw OpenAIProviderError.responseFailed(message)
                        }
                        text = response.outputText
                        guard !text.isEmpty else {
                            throw OpenAIProviderError.noTextOutput
                        }
                        continuation.yield(.textDelta(text))
                        continuation.finish()
                        return
                    }

                    var eventDecoder = ServerSentEventDecoder()
                    var parser = OpenAICompatibleStreamParser()

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let payload = eventDecoder.append(byte) else { continue }

                        switch try parser.parse(payload) {
                        case let .text(text):
                            continuation.yield(.textDelta(text))
                        case let .reasoning(text):
                            continuation.yield(.reasoningDelta(text))
                        case let .completed(text):
                            if let text {
                                continuation.yield(.textDelta(text))
                            }
                            guard parser.hasText else {
                                throw OpenAIProviderError.noTextOutput
                            }
                            continuation.finish()
                            return
                        case .ignored:
                            continue
                        }
                    }

                    if let payload = eventDecoder.finish() {
                        switch try parser.parse(payload) {
                        case let .text(text):
                            continuation.yield(.textDelta(text))
                        case let .reasoning(text):
                            continuation.yield(.reasoningDelta(text))
                        case let .completed(text):
                            if let text {
                                continuation.yield(.textDelta(text))
                            }
                        case .ignored:
                            break
                        }
                    }

                    guard parser.hasText else {
                        throw OpenAIProviderError.noTextOutput
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func httpError(statusCode: Int, data: Data) -> OpenAIProviderError {
        let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
        return .http(statusCode: statusCode, message: message)
    }
}

private struct ModelListResponse: Decodable {
    let data: [APIModel]
}

private struct APIModel: Decodable {
    let id: String
}

private struct ResponsesRequestBody: Encodable {
    let model: String
    let input: [InputMessage]
    let stream: Bool
    let store: Bool
    let reasoning: ReasoningConfig
}

private struct ReasoningConfig: Encodable {
    let effort: String
}

private struct InputMessage: Encodable {
    let role: String
    let content: String
}

private struct ServerSentEventDecoder {
    private var lineBytes: [UInt8] = []
    private var dataLines: [String] = []

    mutating func append(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {
            lineBytes.append(byte)
            return nil
        }

        var line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        if line.last == "\r" {
            line.removeLast()
        }

        if line.isEmpty {
            return flushDataLines()
        }
        guard line.hasPrefix("data:") else { return nil }

        var value = String(line.dropFirst(5))
        if value.first == " " {
            value.removeFirst()
        }
        dataLines.append(value)
        return nil
    }

    mutating func finish() -> String? {
        if !lineBytes.isEmpty {
            _ = append(0x0A)
        }
        return flushDataLines()
    }

    private mutating func flushDataLines() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        return payload
    }
}

private struct OpenAICompatibleStreamParser {
    enum Result: Equatable {
        case text(String)
        case reasoning(String)
        case completed(String?)
        case ignored
    }

    private(set) var hasText = false

    mutating func parse(_ payload: String) throws -> Result {
        guard payload != "[DONE]" else { return .completed(nil) }
        guard let data = payload.data(using: .utf8) else { return .ignored }
        return try parseResponseEvent(data)
    }

    private mutating func parseResponseEvent(_ data: Data) throws -> Result {
        let event = try JSONDecoder().decode(StreamEvent.self, from: data)
        switch event.type {
        case "response.reasoning_text.delta":
            guard let delta = event.delta, !delta.isEmpty else { return .ignored }
            return .reasoning(delta)
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = event.delta, !delta.isEmpty else { return .ignored }
            hasText = true
            return .text(delta)
        case "response.output_text.done", "response.refusal.done":
            guard !hasText, let text = event.text ?? event.refusal, !text.isEmpty else {
                return .ignored
            }
            hasText = true
            return .text(text)
        case "response.completed":
            if !hasText, let text = event.response?.outputText, !text.isEmpty {
                hasText = true
                return .completed(text)
            }
            return .completed(nil)
        case "response.failed", "response.incomplete":
            throw OpenAIProviderError.responseFailed(
                event.response?.error?.message ?? "响应生成失败。"
            )
        case "error":
            throw OpenAIProviderError.responseFailed(
                event.message ?? event.error?.message ?? "服务返回了未知错误。"
            )
        default:
            return .ignored
        }
    }
}

private struct StreamEvent: Decodable {
    let type: String
    let delta: String?
    let text: String?
    let refusal: String?
    let message: String?
    let error: APIErrorPayload?
    let response: APIResponse?
}

private struct APIResponse: Decodable {
    let error: APIErrorPayload?
    let output: [ResponseOutputItem]?

    var outputText: String {
        output?
            .flatMap { $0.content ?? [] }
            .compactMap { $0.text ?? $0.refusal }
            .joined() ?? ""
    }
}

private struct ResponseOutputItem: Decodable {
    let content: [ResponseContent]?
}

private struct ResponseContent: Decodable {
    let text: String?
    let refusal: String?
}

private struct ErrorEnvelope: Decodable {
    let error: APIErrorPayload
}

private struct APIErrorPayload: Decodable {
    let message: String?
}

enum OpenAIProviderError: LocalizedError {
    case invalidResponse
    case noModels
    case noTextOutput
    case http(statusCode: Int, message: String?)
    case responseFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "服务器返回了无法识别的响应。"
        case .noModels:
            "服务器没有返回任何可用模型。"
        case .noTextOutput:
            "模型没有返回文本内容。请确认所选模型支持 Responses API。"
        case let .http(statusCode, message):
            if let message, !message.isEmpty {
                message
            } else {
                switch statusCode {
                case 401:
                    "API Key 无效，请在设置中重新配置。"
                case 429:
                    "请求过于频繁或额度不足，请稍后再试。"
                default:
                    "请求失败（HTTP \(statusCode)）。"
                }
            }
        case let .responseFailed(message):
            message
        }
    }
}
