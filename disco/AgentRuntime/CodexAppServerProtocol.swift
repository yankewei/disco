import Foundation

/// Codex app-server 的版本化 wire 契约。
///
/// 这些 DTO 对应本机 `codex-cli 0.147.0` 执行
/// `codex app-server generate-json-schema` 生成的 v2 核心 schema。
/// 这里只收敛当前产品需要的 thread/turn/text/tokenUsage/contextCompaction
/// 事件与 thread/compact/start；审批、工具调用等 server request 不在本契约
/// 范围内，由 transport 返回明确的“不支持”错误。
/// 旧版本 app-server 可能缺少 tokenUsage/contextCompaction 通知或
/// thread/compact/start 方法：相关 DTO 一律可选解码，缺失时静默降级。
enum CodexAppServerProtocol {
    static let cliVersion = "0.147.0"
    static let version = "v2"
}

/// 不依赖第三方库的 JSON 值。它只用于 JSON-RPC envelope 的动态部分，
/// 具体业务字段仍通过下面的 Codable DTO 解码。
enum CodexJSONValue: Codable, Equatable, Sendable {
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                self = .null
                return
            }
            if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
                return
            }
            if let value = try? container.decode(Double.self) {
                self = .number(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
        }

        if var container = try? decoder.unkeyedContainer() {
            var values: [CodexJSONValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(CodexJSONValue.self))
            }
            self = .array(values)
            return
        }

        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var values: [String: CodexJSONValue] = [:]
        for key in container.allKeys {
            values[key.stringValue] = try container.decode(CodexJSONValue.self, forKey: key)
        }
        self = .object(values)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .object(values):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: DynamicCodingKey(stringValue: key))
            }
        case let .array(values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .boolean(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    func decoded<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    var objectValue: [String: CodexJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

struct CodexRPCEnvelope: Decodable, Sendable {
    let id: Int?
    let method: String?
    let params: CodexJSONValue?
    let result: CodexJSONValue?
    let error: CodexRPCErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case id, method, params, result, error
    }
}

struct CodexRPCErrorPayload: Decodable, Sendable {
    let code: Int
    let message: String
}

struct CodexRPCRequest<Params: Encodable>: Encodable {
    let id: Int
    let method: String
    let params: Params
}

struct CodexRPCNotification<Params: Encodable>: Encodable {
    let method: String
    let params: Params
}

struct CodexRPCErrorResponse: Encodable {
    let id: Int
    let error: ErrorPayload

    struct ErrorPayload: Encodable {
        let code: Int
        let message: String
    }
}

struct CodexInitializeParams: Encodable {
    let clientInfo: CodexAppServerTransport.ClientInfo
}

struct CodexEmptyParams: Encodable {}

struct CodexThreadStartParams: Encodable {
    let model: String
    /// 线程的项目工作目录；nil 表示使用 app-server 默认目录（临时对话）。
    let cwd: String?
}

struct CodexThreadResumeParams: Encodable {
    let threadId: String
    let model: String?
    /// 续接时仍可携带工作目录；nil 表示沿用线程已有目录。
    let cwd: String?
}

struct CodexTurnInput: Encodable {
    let type: String
    let text: String
}

struct CodexTurnStartParams: Encodable {
    let threadId: String
    let input: [CodexTurnInput]
    let effort: String?
}

struct CodexTurnInterruptParams: Encodable {
    let threadId: String
    let turnId: String
}

struct CodexModelListParams: Encodable {
    let limit: Int
    let includeHidden: Bool
}

struct CodexInitializeResponse: Decodable, Sendable {
    let userAgent: String?
}

struct CodexThreadResponse: Decodable, Sendable {
    let thread: CodexThreadSummary
}

struct CodexThreadSummary: Decodable, Sendable {
    let id: String
}

struct CodexTurnResponse: Decodable, Sendable {
    let turn: CodexTurnSummary
}

struct CodexTurnSummary: Decodable, Sendable {
    let id: String
    let status: String?
    let error: CodexTurnError?
}

struct CodexTurnError: Decodable, Sendable {
    let message: String?
}

struct CodexModelListResponse: Decodable, Sendable {
    let data: [CodexModelEntry]
}

struct CodexModelEntry: Decodable, Sendable {
    let id: String
    let model: String
    let displayName: String
    let defaultReasoningEffort: String?
    let supportedReasoningEfforts: [CodexReasoningEffort]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        model = try container.decode(String.self, forKey: .model)
        displayName = try container.decode(String.self, forKey: .displayName)
        defaultReasoningEffort = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
        supportedReasoningEfforts = try container.decodeIfPresent(
            [CodexReasoningEffort].self,
            forKey: .supportedReasoningEfforts
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case displayName
        case defaultReasoningEffort
        case supportedReasoningEfforts
    }
}

/// `model/list` 在不同 app-server 版本中曾返回字符串或带描述的对象；
/// 两种形态都接受，具体描述暂不进入 UI。
struct CodexReasoningEffort: Decodable, Sendable, Equatable {
    let value: String

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let value = try? singleValue.decode(String.self) {
            self.value = value
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
            ?? container.decodeIfPresent(String.self, forKey: .effort)
            ?? container.decodeIfPresent(String.self, forKey: .value) {
            self.value = value
            return
        }

        throw DecodingError.valueNotFound(
            String.self,
            .init(codingPath: decoder.codingPath, debugDescription: "缺少 reasoning effort 名称。")
        )
    }

    private enum CodingKeys: String, CodingKey {
        case reasoningEffort
        case effort
        case value
    }
}

struct CodexAccountReadResponse: Decodable, Sendable {
    let requiresOpenaiAuth: Bool
    let account: CodexAccountEntry?
}

struct CodexAccountEntry: Decodable, Sendable {
    let type: String
    let email: String?
    let planType: String?
}

struct CodexTurnStartedNotification: Decodable, Sendable {
    let threadId: String
    let turn: CodexTurnSummary
}

struct CodexAgentMessageDeltaNotification: Decodable, Sendable {
    let delta: String
    let itemId: String
    let threadId: String
    let turnId: String
}

struct CodexReasoningSummaryTextDeltaNotification: Decodable, Sendable {
    let delta: String
    let itemId: String
    let summaryIndex: Int
    let threadId: String
    let turnId: String
}

struct CodexTurnCompletedNotification: Decodable, Sendable {
    let threadId: String
    let turn: CodexTurnSummary
}

/// item 生命周期的 envelope。ThreadItem 本身是一个大型版本化 union，
/// 当前不执行 item，因此只保留路由和展示所需的 id/type。
struct CodexItemLifecycleNotification: Decodable, Sendable {
    let threadId: String
    let turnId: String
    let item: CodexJSONValue

    var itemID: String? { item.objectValue?["id"]?.stringValue }
    var itemType: String? { item.objectValue?["type"]?.stringValue }
}

// MARK: - 上下文压缩 v1（计划《上下文压缩 v1》§4 Codex app-server）

/// `thread/tokenUsage/updated` 的用量明细（schema: TokenUsageBreakdown）。
/// 全部字段可选解码：旧版本缺字段时保持 nil，由 transport 决定取舍，不得伪造。
struct CodexTokenUsageBreakdown: Decodable, Sendable, Equatable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?
    let totalTokens: Int?
}

/// `thread/tokenUsage/updated` 的 tokenUsage 载荷（schema: ThreadTokenUsage）。
struct CodexThreadTokenUsage: Decodable, Sendable, Equatable {
    let last: CodexTokenUsageBreakdown?
    let total: CodexTokenUsageBreakdown?
    let modelContextWindow: Int?
}

/// `thread/tokenUsage/updated` 通知（schema: ThreadTokenUsageUpdatedNotification）。
struct CodexThreadTokenUsageUpdatedNotification: Decodable, Sendable {
    let threadId: String
    let turnId: String?
    let tokenUsage: CodexThreadTokenUsage?
}

/// `thread/compact/start` 请求参数（schema: ThreadCompactStartParams）。
struct CodexThreadCompactStartParams: Encodable {
    let threadId: String
}
