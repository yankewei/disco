import Foundation

struct OpenAIResponsesProvider: AIProvider {
    static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!
    static let defaultModel = "gpt-5.6"

    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let session: URLSession

    private var apiStyle: CompatibleAPIStyle {
        let host = baseURL.host?.lowercased()
        return host == "api.deepseek.com" || host?.hasSuffix(".deepseek.com") == true
            ? .chatCompletions
            : .responses
    }

    init(
        apiKey: String,
        baseURL: URL = OpenAIResponsesProvider.defaultBaseURL,
        model: String = OpenAIResponsesProvider.defaultModel,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    func availableModels() async throws -> [String] {
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

    func stream(messages: [ChatMessage]) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = apiStyle == .chatCompletions ? "chat/completions" : "responses"
                    var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 90
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    let input = messages.map {
                        InputMessage(role: $0.role.rawValue, content: $0.text)
                    }
                    switch apiStyle {
                    case .responses:
                        request.httpBody = try JSONEncoder().encode(
                            ResponsesRequestBody(model: model, input: input, stream: true, store: false)
                        )
                    case .chatCompletions:
                        request.httpBody = try JSONEncoder().encode(
                            ChatCompletionsRequestBody(model: model, messages: input, stream: true)
                        )
                    }

                    let (bytes, response) = try await session.bytes(for: request)
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
                        switch apiStyle {
                        case .responses:
                            let response = try JSONDecoder().decode(APIResponse.self, from: body)
                            if let message = response.error?.message, !message.isEmpty {
                                throw OpenAIProviderError.responseFailed(message)
                            }
                            text = response.outputText
                        case .chatCompletions:
                            text = try JSONDecoder().decode(ChatCompletionResponse.self, from: body).text
                        }
                        guard !text.isEmpty else {
                            throw OpenAIProviderError.noTextOutput
                        }
                        continuation.yield(.textDelta(text))
                        continuation.finish()
                        return
                    }

                    var eventDecoder = ServerSentEventDecoder()
                    var parser = OpenAICompatibleStreamParser(style: apiStyle)

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let payload = eventDecoder.append(byte) else { continue }

                        switch try parser.parse(payload) {
                        case let .text(text):
                            continuation.yield(.textDelta(text))
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
}

private struct ChatCompletionsRequestBody: Encodable {
    let model: String
    let messages: [InputMessage]
    let stream: Bool
}

private struct InputMessage: Encodable {
    let role: String
    let content: String
}

private enum CompatibleAPIStyle {
    case responses
    case chatCompletions
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
        case completed(String?)
        case ignored
    }

    let style: CompatibleAPIStyle
    private(set) var hasText = false

    mutating func parse(_ payload: String) throws -> Result {
        guard payload != "[DONE]" else { return .completed(nil) }
        guard let data = payload.data(using: .utf8) else { return .ignored }

        switch style {
        case .responses:
            return try parseResponseEvent(data)
        case .chatCompletions:
            return try parseChatCompletionChunk(data)
        }
    }

    private mutating func parseResponseEvent(_ data: Data) throws -> Result {
        let event = try JSONDecoder().decode(StreamEvent.self, from: data)
        switch event.type {
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

    private mutating func parseChatCompletionChunk(_ data: Data) throws -> Result {
        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
        guard let choice = chunk.choices.first else { return .ignored }

        let text = choice.delta.content ?? choice.delta.refusal
        if let text, !text.isEmpty {
            hasText = true
            return choice.finishReason == nil ? .text(text) : .completed(text)
        }
        return choice.finishReason == nil ? .ignored : .completed(nil)
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

private struct ChatCompletionChunk: Decodable {
    let choices: [ChatCompletionChoice]
}

private struct ChatCompletionChoice: Decodable {
    let delta: ChatCompletionDelta
    let finishReason: String?

    private enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

private struct ChatCompletionDelta: Decodable {
    let content: String?
    let refusal: String?
}

private struct ChatCompletionResponse: Decodable {
    let choices: [ChatCompletionResponseChoice]

    var text: String {
        choices.compactMap(\.message.content).joined()
    }
}

private struct ChatCompletionResponseChoice: Decodable {
    let message: ChatCompletionMessage
}

private struct ChatCompletionMessage: Decodable {
    let content: String?
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
