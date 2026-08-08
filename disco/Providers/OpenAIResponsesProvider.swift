import Foundation

/// OpenAI Responses API Provider（计划 §10.2，ADR-004 的 URLSession 版）。
/// 只负责认证、请求构造、SSE 解析与错误转换；模型、推理与托管工具来自 ModelRequest。
struct OpenAIResponsesProvider: ModelProvider {
    enum Dialect: Sendable {
        case openAI
        case deepSeek
        case compatible
    }

    static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!
    static let defaultModel = "gpt-5.6"

    let descriptor = ProviderDescriptor(
        id: "openai-responses",
        displayName: "OpenAI Responses"
    )

    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let dialect: Dialect

    init(
        apiKey: String,
        baseURL: URL = OpenAIResponsesProvider.defaultBaseURL,
        session: URLSession = .shared,
        dialect: Dialect = .openAI
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.dialect = dialect
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
                    var usesWebSearch = request.hostedTools.contains(.webSearch)
                    var didRetryWithoutWebSearch = false

                    while true {
                        let urlRequest = try makeURLRequest(
                            request: request,
                            usesWebSearch: usesWebSearch
                        )
                        let (bytes, response) = try await session.bytes(for: urlRequest)
                        guard let httpResponse = response as? HTTPURLResponse else {
                            throw OpenAIProviderError.invalidResponse
                        }

                        guard (200..<300).contains(httpResponse.statusCode) else {
                            let body = try await read(bytes: bytes, limit: 1_048_576)
                            if usesWebSearch,
                               !didRetryWithoutWebSearch,
                               shouldRetryWithoutWebSearch(
                                   statusCode: httpResponse.statusCode,
                                   data: body
                               ) {
                                usesWebSearch = false
                                didRetryWithoutWebSearch = true
                                continue
                            }
                            throw httpError(statusCode: httpResponse.statusCode, data: body)
                        }

                        if httpResponse.value(forHTTPHeaderField: "Content-Type")?
                            .localizedCaseInsensitiveContains("text/event-stream") != true {
                            let body = try await read(bytes: bytes, limit: 10_485_760)
                            let response = try JSONDecoder().decode(APIResponse.self, from: body)
                            if let message = response.error?.message, !message.isEmpty {
                                throw OpenAIProviderError.responseFailed(message)
                            }
                            var parser = OpenAICompatibleStreamParser()
                            let events = parser.parseCompleteResponse(response)
                            for event in events {
                                continuation.yield(event)
                            }
                            guard parser.hasText else {
                                throw OpenAIProviderError.noTextOutput
                            }
                            continuation.finish()
                            return
                        }

                        var eventDecoder = ServerSentEventDecoder()
                        var parser = OpenAICompatibleStreamParser()

                        for try await byte in bytes {
                            try Task.checkCancellation()
                            guard let payload = eventDecoder.append(byte) else { continue }
                            let batch = try parser.parse(payload)
                            for event in batch.events {
                                continuation.yield(event)
                            }
                            if batch.isCompleted {
                                guard parser.hasText else {
                                    throw OpenAIProviderError.noTextOutput
                                }
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

                        guard parser.hasText else {
                            throw OpenAIProviderError.noTextOutput
                        }
                        continuation.finish()
                        return
                    }
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

    private func makeURLRequest(
        request: ModelRequest,
        usesWebSearch: Bool
    ) throws -> URLRequest {
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
                ),
                tools: usesWebSearch ? [HostedToolRequest(type: "web_search")] : nil,
                toolChoice: usesWebSearch ? "auto" : nil,
                include: usesWebSearch && dialect == .openAI
                    ? ["web_search_call.action.sources"]
                    : nil
            )
        )
        return urlRequest
    }

    private func read(
        bytes: URLSession.AsyncBytes,
        limit: Int
    ) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            guard body.count < limit else {
                throw OpenAIProviderError.invalidResponse
            }
            body.append(byte)
        }
        return body
    }

    private func shouldRetryWithoutWebSearch(statusCode: Int, data: Data) -> Bool {
        guard statusCode == 400,
              let payload = try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error else {
            return false
        }
        let toolParameters = ["tools", "tool_choice", "include"]
        if let param = payload.param?.lowercased(),
           toolParameters.contains(where: { param == $0 || param.hasPrefix("\($0).") }) {
            return true
        }

        let description = [payload.code, payload.type, payload.message]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let mentionsSearch = description.contains("web_search")
            || description.contains("web search")
        let isUnsupported = description.contains("unsupported")
            || description.contains("not supported")
            || description.contains("does not support")
        return mentionsSearch && isUnsupported
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
    let tools: [HostedToolRequest]?
    let toolChoice: String?
    let include: [String]?

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case stream
        case store
        case reasoning
        case tools
        case toolChoice = "tool_choice"
        case include
    }
}

private struct HostedToolRequest: Encodable {
    let type: String
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
    private var emittedCitations = Set<CitationKey>()
    private var tools: [String: HostedToolSnapshot] = [:]
    private var didReceiveTextDelta = false
    private var emittedTextItems = Set<String>()
    private var textBaseOffsets: [Int: Int] = [:]
    private var emittedTextUTF16Count = 0

    mutating func parse(_ payload: String) throws -> Batch {
        guard payload != "[DONE]" else { return .completed }
        guard let data = payload.data(using: .utf8) else {
            return .ignored
        }
        let event = try JSONDecoder().decode(StreamEvent.self, from: data)
        return try parse(event)
    }

    mutating func parseCompleteResponse(_ response: APIResponse) -> [ModelEvent] {
        events(from: response, includeText: true)
    }

    private mutating func parse(_ event: StreamEvent) throws -> Batch {
        switch event.type {
        case "response.reasoning_text.delta":
            guard let delta = event.delta, !delta.isEmpty else {
                return .ignored
            }
            return Batch(events: [.reasoningDelta(delta)])
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = event.delta, !delta.isEmpty else {
                return .ignored
            }
            didReceiveTextDelta = true
            if let outputIndex = event.outputIndex, textBaseOffsets[outputIndex] == nil {
                textBaseOffsets[outputIndex] = emittedTextUTF16Count
            }
            emittedTextUTF16Count += delta.utf16.count
            hasText = true
            return Batch(events: [.textDelta(delta)])
        case "response.output_text.done", "response.refusal.done":
            guard !didReceiveTextDelta,
                  let text = event.text ?? event.refusal,
                  !text.isEmpty else {
                return .ignored
            }
            let key = "output:\(event.outputIndex ?? 0):\(event.contentIndex ?? 0)"
            guard emittedTextItems.insert(key).inserted else {
                return .ignored
            }
            if let outputIndex = event.outputIndex, textBaseOffsets[outputIndex] == nil {
                textBaseOffsets[outputIndex] = emittedTextUTF16Count
            }
            emittedTextUTF16Count += text.utf16.count
            hasText = true
            return Batch(events: [.textDelta(text)])
        case "response.output_item.added", "response.output_item.done":
            guard let item = event.item else {
                return .ignored
            }
            return Batch(
                events: events(
                    from: item,
                    includeText: !didReceiveTextDelta,
                    citationOffset: textBaseOffsets[event.outputIndex ?? 0] ?? 0,
                    textItemKey: item.id ?? "output:\(event.outputIndex ?? 0)"
                )
            )
        case "response.web_search_call.in_progress",
             "response.web_search_call.searching",
             "response.web_search_call.completed":
            let status: HostedToolStatus
            switch event.type {
            case "response.web_search_call.searching":
                status = .searching
            case "response.web_search_call.completed":
                status = .completed
            default:
                status = .inProgress
            }
            return Batch(
                events: updateWebSearch(
                    id: event.itemID,
                    status: status,
                    action: event.action
                )
            )
        case "response.output_text.annotation.added":
            guard let annotation = event.annotation,
                  let citation = citation(
                    from: annotation,
                    offset: textBaseOffsets[event.outputIndex ?? 0] ?? 0
                  ) else {
                return .ignored
            }
            return Batch(events: emit(citation: citation))
        case "response.content_part.done":
            guard let part = event.part else {
                return .ignored
            }
            return Batch(
                events: events(
                    from: part,
                    includeText: !didReceiveTextDelta,
                    citationOffset: textBaseOffsets[event.outputIndex ?? 0] ?? 0,
                    textItemKey: event.itemID
                        ?? "output:\(event.outputIndex ?? 0):\(event.contentIndex ?? 0)"
                )
            )
        case "response.completed":
            let events = event.response.map {
                self.events(from: $0, includeText: !hasText)
            } ?? []
            return Batch(events: events, isCompleted: true)
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

    private mutating func events(
        from response: APIResponse,
        includeText: Bool
    ) -> [ModelEvent] {
        var events: [ModelEvent] = []
        var citationOffset = 0
        for (index, item) in (response.output ?? []).enumerated() {
            events.append(contentsOf: self.events(
                from: item,
                includeText: includeText,
                citationOffset: citationOffset,
                textItemKey: item.id ?? "response:\(index)"
            ))
            citationOffset += item.textUTF16Count
        }
        return events
    }

    private mutating func events(
        from item: ResponseOutputItem,
        includeText: Bool,
        citationOffset: Int,
        textItemKey: String
    ) -> [ModelEvent] {
        if item.type == "web_search_call" {
            return updateWebSearch(
                id: item.id,
                status: HostedToolStatus(apiStatus: item.status),
                action: item.action
            )
        }

        var events: [ModelEvent] = []
        var contentCitationOffset = citationOffset
        for (index, content) in (item.content ?? []).enumerated() {
            events.append(contentsOf: self.events(
                from: content,
                includeText: includeText,
                citationOffset: contentCitationOffset,
                textItemKey: "\(textItemKey):\(index)"
            ))
            contentCitationOffset += content.textUTF16Count
        }
        return events
    }

    private mutating func events(
        from content: ResponseContent,
        includeText: Bool,
        citationOffset: Int,
        textItemKey: String
    ) -> [ModelEvent] {
        var events: [ModelEvent] = []
        if includeText,
           let text = content.text ?? content.refusal,
           !text.isEmpty,
           emittedTextItems.insert(textItemKey).inserted {
            hasText = true
            emittedTextUTF16Count += text.utf16.count
            events.append(.textDelta(text))
        }
        for annotation in content.annotations ?? [] {
            guard let citation = citation(from: annotation, offset: citationOffset) else { continue }
            events.append(contentsOf: emit(citation: citation))
        }
        return events
    }

    private mutating func updateWebSearch(
        id: String?,
        status: HostedToolStatus,
        action: ResponseAction?
    ) -> [ModelEvent] {
        guard let id, !id.isEmpty else { return [] }
        let previous = tools[id]
        let convertedAction = action.flatMap(HostedToolAction.init(responseAction:))
        let sources = action?.sources?.compactMap { source -> HostedToolSource? in
            guard let url = source.url, !url.isEmpty else { return nil }
            return HostedToolSource(url: url, title: source.title)
        } ?? []
        let snapshot = HostedToolSnapshot(
            id: id,
            kind: .webSearch,
            status: status,
            action: convertedAction ?? previous?.action,
            sources: (previous?.sources ?? []).merging(sources)
        )
        guard snapshot != previous else { return [] }
        tools[id] = snapshot
        return [.hostedToolUpdated(snapshot)]
    }

    private func citation(from annotation: ResponseAnnotation, offset: Int) -> TextCitation? {
        guard annotation.type == "url_citation",
              let startIndex = annotation.startIndex,
              let endIndex = annotation.endIndex,
              let url = annotation.url,
              !url.isEmpty else {
            return nil
        }
        return TextCitation(
            startIndex: startIndex + offset,
            endIndex: endIndex + offset,
            url: url,
            title: annotation.title
        )
    }

    private mutating func emit(citation: TextCitation) -> [ModelEvent] {
        let key = CitationKey(citation)
        guard emittedCitations.insert(key).inserted else { return [] }
        return [.citationAdded(citation)]
    }
}

private struct CitationKey: Hashable {
    let startIndex: Int
    let endIndex: Int
    let url: String

    init(_ citation: TextCitation) {
        startIndex = citation.startIndex
        endIndex = citation.endIndex
        url = citation.url
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
    let item: ResponseOutputItem?
    let itemID: String?
    let outputIndex: Int?
    let contentIndex: Int?
    let annotation: ResponseAnnotation?
    let part: ResponseContent?
    let action: ResponseAction?

    private enum CodingKeys: String, CodingKey {
        case type
        case delta
        case text
        case refusal
        case message
        case error
        case response
        case item
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case annotation
        case part
        case action
    }
}

private struct APIResponse: Decodable {
    let error: APIErrorPayload?
    let output: [ResponseOutputItem]?
}

private struct ResponseOutputItem: Decodable {
    let id: String?
    let type: String?
    let status: String?
    let action: ResponseAction?
    let content: [ResponseContent]?

    var textUTF16Count: Int {
        content?.reduce(0) { result, content in
            result + content.textUTF16Count
        } ?? 0
    }
}

private struct ResponseContent: Decodable {
    let text: String?
    let refusal: String?
    let annotations: [ResponseAnnotation]?

    var textUTF16Count: Int {
        (text ?? refusal ?? "").utf16.count
    }
}

private struct ResponseAnnotation: Decodable {
    let type: String?
    let startIndex: Int?
    let endIndex: Int?
    let url: String?
    let title: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case startIndex = "start_index"
        case endIndex = "end_index"
        case url
        case title
    }
}

private struct ResponseAction: Decodable {
    let type: String?
    let query: String?
    let queries: [String]?
    let url: String?
    let pattern: String?
    let sources: [ResponseSource]?
}

private struct ResponseSource: Decodable {
    let url: String?
    let title: String?
}

private extension HostedToolStatus {
    init(apiStatus: String?) {
        switch apiStatus {
        case "completed": self = .completed
        case "searching": self = .searching
        default: self = .inProgress
        }
    }
}

private extension HostedToolAction {
    nonisolated init?(responseAction: ResponseAction) {
        switch responseAction.type {
        case "search":
            let queries = responseAction.queries
                ?? responseAction.query.map { [$0] }
                ?? []
            self = .search(queries: queries)
        case "open_page":
            guard let url = responseAction.url else { return nil }
            self = .openPage(url: url)
        case "find_in_page":
            guard let url = responseAction.url,
                  let pattern = responseAction.pattern else { return nil }
            self = .findInPage(url: url, pattern: pattern)
        default:
            return nil
        }
    }
}

private extension Array where Element == HostedToolSource {
    func merging(_ other: [HostedToolSource]) -> [HostedToolSource] {
        var urls = Set<String>()
        return (self + other).filter {
            urls.insert($0.normalizedURLKey).inserted
        }
    }
}

private struct ErrorEnvelope: Decodable {
    let error: APIErrorPayload
}

private struct APIErrorPayload: Decodable {
    let message: String?
    let type: String?
    let param: String?
    let code: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case type
        case param
        case code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        param = try container.decodeIfPresent(String.self, forKey: .param)
        if let stringCode = try? container.decode(String.self, forKey: .code) {
            code = stringCode
        } else if let integerCode = try? container.decode(Int.self, forKey: .code) {
            code = String(integerCode)
        } else {
            code = nil
        }
    }
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
