import Foundation

/// OpenAI Chat Completions 兼容 Provider（计划 §10.2，和 Responses Provider 并列）。
/// 当前 Kimi 方言使用其原生 `thinking` 参数，并保留 `reasoning_content` 消息历史。
struct OpenAIChatCompletionsProvider: ModelProvider {
    enum Dialect: Sendable, Equatable {
        case compatible
        case kimi
    }

    let descriptor = ProviderDescriptor(
        id: "openai-chat-completions",
        displayName: "OpenAI Chat Completions"
    )

    private static let userAgent: String = {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        return "disco/\(version)"
    }()

    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let dialect: Dialect

    init(
        apiKey: String,
        baseURL: URL,
        session: URLSession = .shared,
        dialect: Dialect = .compatible
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.dialect = dialect
    }

    func modelCatalog() async throws -> [ModelCatalogEntry] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatCompletionsProviderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw httpError(statusCode: httpResponse.statusCode, data: data)
        }

        let models = try JSONDecoder().decode(ChatModelListResponse.self, from: data).data
            .map {
                ModelCatalogEntry(
                    id: $0.id,
                    contextWindow: ($0.contextLength ?? 0) > 0 ? $0.contextLength : nil,
                    supportsToolCalling: dialect == .kimi ? true : nil
                )
            }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        guard !models.isEmpty else {
            throw ChatCompletionsProviderError.noModels
        }
        return models
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(request: request)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ChatCompletionsProviderError.invalidResponse
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        let body = try await read(bytes: bytes, limit: 1_048_576)
                        throw httpError(statusCode: httpResponse.statusCode, data: body)
                    }

                    var parser = ChatCompletionsStreamParser()
                    if httpResponse.value(forHTTPHeaderField: "Content-Type")?
                        .localizedCaseInsensitiveContains("text/event-stream") != true {
                        let body = try await read(bytes: bytes, limit: 10_485_760)
                        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: body)
                        for event in try parser.parseCompleteResponse(response) {
                            continuation.yield(event)
                        }
                        try parser.validateCompletion()
                        continuation.finish()
                        return
                    }

                    var eventDecoder = ServerSentEventDecoder()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let payload = eventDecoder.append(byte) else { continue }
                        let batch = try parser.parse(payload)
                        for event in batch.events {
                            continuation.yield(event)
                        }
                        if batch.isCompleted {
                            try parser.validateCompletion()
                            continuation.finish()
                            return
                        }
                    }

                    if let payload = eventDecoder.finish() {
                        let batch = try parser.parse(payload)
                        for event in batch.events {
                            continuation.yield(event)
                        }
                    }
                    try parser.validateCompletion()
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

    private func makeURLRequest(request: ModelRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 90
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        // instructions 映射规则固定（计划《上下文压缩 v1》§2）：
        // Chat Completions 在 messages 最前插入 system message；nil 时保持请求体不变。
        var messages = request.messages.map { message in
            ChatCompletionRequestMessage(
                role: message.role.rawValue,
                content: message.text,
                reasoningContent: request.reasoningEnabled
                    && message.role == .assistant
                    && !message.reasoning.isEmpty
                    ? message.reasoning
                    : nil
            )
        }
        if let instructions = request.instructions {
            messages.insert(
                ChatCompletionRequestMessage(
                    role: "system",
                    content: instructions,
                    reasoningContent: nil
                ),
                at: 0
            )
        }
        let selectedEffort = request.reasoningEffort
            ?? (request.reasoningEnabled ? "high" : "none")
        let thinking: ChatThinkingConfig?
        let reasoningEffort: String?
        switch dialect {
        case .kimi:
            thinking = selectedEffort == "none"
                ? ChatThinkingConfig(type: "disabled", effort: nil)
                : ChatThinkingConfig(type: "enabled", effort: selectedEffort)
            reasoningEffort = nil
        case .compatible:
            thinking = nil
            reasoningEffort = selectedEffort == "none" ? nil : selectedEffort
        }

        urlRequest.httpBody = try JSONEncoder().encode(ChatCompletionRequestBody(
            model: request.model,
            messages: messages,
            stream: true,
            streamOptions: ChatStreamOptions(includeUsage: true),
            thinking: thinking,
            reasoningEffort: reasoningEffort
        ))
        return urlRequest
    }

    private func read(bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            guard body.count < limit else {
                throw ChatCompletionsProviderError.invalidResponse
            }
            body.append(byte)
        }
        return body
    }

    private func httpError(statusCode: Int, data: Data) -> ChatCompletionsProviderError {
        let payload = try? JSONDecoder().decode(ChatErrorEnvelope.self, from: data).error
        if ContextOverflowMatcher.matches(
            code: payload?.code,
            type: payload?.type,
            message: payload?.message
        ) {
            return .contextOverflow(message: payload?.message ?? "请求超出模型上下文窗口。")
        }
        return .http(statusCode: statusCode, message: payload?.message)
    }
}

private struct ChatModelListResponse: Decodable {
    let data: [ChatAPIModel]
}

private struct ChatAPIModel: Decodable {
    let id: String
    let contextLength: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case contextLength = "context_length"
    }
}

private struct ChatCompletionRequestBody: Encodable {
    let model: String
    let messages: [ChatCompletionRequestMessage]
    let stream: Bool
    let streamOptions: ChatStreamOptions
    let thinking: ChatThinkingConfig?
    let reasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case streamOptions = "stream_options"
        case thinking
        case reasoningEffort = "reasoning_effort"
    }
}

private struct ChatCompletionRequestMessage: Encodable {
    let role: String
    let content: String
    let reasoningContent: String?

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
    }
}

private struct ChatStreamOptions: Encodable {
    let includeUsage: Bool

    private enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

private struct ChatThinkingConfig: Encodable {
    let type: String
    let effort: String?
}

private struct ChatCompletionsStreamParser {
    struct Batch {
        static let ignored = Batch(events: [])
        static let completed = Batch(events: [], isCompleted: true)

        let events: [ModelEvent]
        let isCompleted: Bool

        init(events: [ModelEvent], isCompleted: Bool = false) {
            self.events = events
            self.isCompleted = isCompleted
        }
    }

    private(set) var hasText = false
    private var requestedToolCall = false

    mutating func parse(_ payload: String) throws -> Batch {
        guard payload != "[DONE]" else { return .completed }
        guard let data = payload.data(using: .utf8) else { return .ignored }
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        return try parse(response, usesDelta: true)
    }

    mutating func parseCompleteResponse(_ response: ChatCompletionResponse) throws -> [ModelEvent] {
        try parse(response, usesDelta: false).events
    }

    mutating func validateCompletion() throws {
        if requestedToolCall {
            throw ChatCompletionsProviderError.unsupportedToolCall
        }
        if !hasText {
            throw ChatCompletionsProviderError.noTextOutput
        }
    }

    private mutating func parse(
        _ response: ChatCompletionResponse,
        usesDelta: Bool
    ) throws -> Batch {
        if let error = response.error, let message = error.message, !message.isEmpty {
            if ContextOverflowMatcher.matches(
                code: error.code,
                type: error.type,
                message: error.message
            ) {
                throw ChatCompletionsProviderError.contextOverflow(message: message)
            }
            throw ChatCompletionsProviderError.responseFailed(message)
        }

        var events: [ModelEvent] = []
        if let usage = response.usage?.snapshot {
            events.append(.usage(usage))
        }
        guard let choice = response.choices?.first(where: { $0.index == 0 })
            ?? response.choices?.first else {
            // include_usage 的尾部 chunk 合法地没有 choices；usage 仍需透传。
            return Batch(events: events)
        }

        let message = usesDelta ? choice.delta : choice.message
        if let reasoning = message?.reasoningContent ?? message?.reasoning,
           !reasoning.isEmpty {
            events.append(.reasoningDelta(reasoning))
        }
        if let text = message?.content, !text.isEmpty {
            hasText = true
            events.append(.textDelta(text))
        }
        if message?.toolCalls?.isEmpty == false {
            requestedToolCall = true
        }

        switch choice.finishReason {
        case nil:
            return Batch(events: events)
        case "stop":
            return Batch(events: events, isCompleted: true)
        case "tool_calls", "function_call":
            requestedToolCall = true
            return Batch(events: events, isCompleted: true)
        case "length":
            throw ChatCompletionsProviderError.responseFailed("模型输出达到长度上限。")
        case "content_filter":
            throw ChatCompletionsProviderError.responseFailed("模型输出被内容安全策略过滤。")
        case let reason?:
            throw ChatCompletionsProviderError.responseFailed("模型以未知原因结束：\(reason)")
        }
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [ChatCompletionChoice]?
    let error: ChatAPIErrorPayload?
    let usage: ChatCompletionUsage?
}

private struct ChatCompletionChoice: Decodable {
    let index: Int
    let delta: ChatCompletionMessage?
    let message: ChatCompletionMessage?
    let finishReason: String?

    private enum CodingKeys: String, CodingKey {
        case index
        case delta
        case message
        case finishReason = "finish_reason"
    }
}

private struct ChatCompletionUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let promptTokensDetails: PromptTokensDetails?
    let completionTokensDetails: CompletionTokensDetails?
    let cachedTokens: Int?
    let reasoningTokens: Int?

    struct PromptTokensDetails: Decodable {
        let cachedTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    struct CompletionTokensDetails: Decodable {
        let reasoningTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
        case cachedTokens = "cached_tokens"
        case reasoningTokens = "reasoning_tokens"
    }

    var snapshot: TokenUsageSnapshot? {
        guard let promptTokens, let completionTokens else { return nil }
        return TokenUsageSnapshot(
            inputTokens: promptTokens,
            cachedInputTokens: promptTokensDetails?.cachedTokens ?? cachedTokens,
            outputTokens: completionTokens,
            reasoningOutputTokens: completionTokensDetails?.reasoningTokens ?? reasoningTokens,
            totalTokens: totalTokens ?? promptTokens + completionTokens
        )
    }
}

private struct ChatCompletionMessage: Decodable {
    let content: String?
    let reasoningContent: String?
    let reasoning: String?
    let toolCalls: [ChatCompletionToolCall]?

    private enum CodingKeys: String, CodingKey {
        case content
        case reasoningContent = "reasoning_content"
        case reasoning
        case toolCalls = "tool_calls"
    }
}

private struct ChatCompletionToolCall: Decodable {
    let index: Int?
    let id: String?
}

private struct ChatErrorEnvelope: Decodable {
    let error: ChatAPIErrorPayload
}

private struct ChatAPIErrorPayload: Decodable {
    let message: String?
    let type: String?
    let code: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case type
        case code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        if let string = try? container.decode(String.self, forKey: .code) {
            code = string
        } else if let number = try? container.decode(Int.self, forKey: .code) {
            code = String(number)
        } else {
            code = nil
        }
    }
}

enum ChatCompletionsProviderError: LocalizedError {
    case invalidResponse
    case noModels
    case noTextOutput
    case unsupportedToolCall
    case http(statusCode: Int, message: String?)
    case responseFailed(String)
    case contextOverflow(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "服务器返回了无法识别的响应。"
        case .noModels:
            "服务器没有返回任何可用模型。"
        case .noTextOutput:
            "模型没有返回文本内容。请确认所选模型支持 Chat Completions API。"
        case .unsupportedToolCall:
            "模型请求调用工具，但当前 Chat Completions Runtime 尚未接入本地工具循环。"
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
        case let .contextOverflow(message):
            message
        }
    }
}

extension ChatCompletionsProviderError: ModelFailureClassifying {
    var failureKind: ModelFailureKind {
        if case .contextOverflow = self { return .contextOverflow }
        return .other
    }
}
