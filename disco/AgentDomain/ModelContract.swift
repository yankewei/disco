import Foundation

/// 与具体 Provider 无关的 JSON 值，用于结构化工具 schema。
/// Provider 原始响应仍留在各自 Adapter 内，不通过该类型暴露给 UI。
enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .boolean(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

/// Runtime 向 Provider 广告的 client-owned function tool。
struct ModelToolDefinition: Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

/// 流式 arguments 增量；只在 Provider 已解析出稳定 call ID 与工具名后发射。
struct ModelToolCallDelta: Sendable, Equatable {
    let callID: String
    let name: String
    let argumentsDelta: String
}

/// Provider 完整收敛后的工具调用。
struct ModelToolCall: Sendable, Equatable {
    let callID: String
    let name: String
    let arguments: String
}

/// Runtime 执行工具后回传给模型的有限结果。
struct ModelToolResult: Sendable, Equatable {
    let callID: String
    let output: String
}

/// Provider 私有、仅在当前 run 内原样回放的 continuation。
/// payload 不进入 UI、日志或持久化。
struct ModelContinuation: Sendable, Equatable {
    let format: String
    let payload: Data
}

/// continuation 与对应工具结果不可拆分，避免构造“有结果但无上一轮”的请求。
struct ModelToolFollowUp: Sendable, Equatable {
    let continuation: ModelContinuation
    let results: [ModelToolResult]
}

/// Provider 成功完成一轮响应时发射的终止元数据。
struct ModelCompletion: Sendable, Equatable {
    let continuation: ModelContinuation?
}

/// 单个模型请求（计划 §8 `stream(request:)` 的入参）。
/// 模型与推理开关是**每请求参数**：Provider 是无状态传输（ADR-001），
/// 不持有会话配置；具体模型/是否推理由 Runtime 按会话配置填入。
struct ModelRequest: Sendable {
    /// 系统级指令（计划《上下文压缩 v1》§2）。
    /// 映射规则固定：Responses 原生方言用顶层 `instructions`；
    /// Responses 兼容方言在 `input` 最前插入 `system` message；
    /// Chat Completions 在 `messages` 最前插入 `system` message。
    /// `nil` 时保持现有请求体不变。
    let instructions: String?
    let messages: [ChatMessage]
    let model: String
    let reasoningEnabled: Bool
    let reasoningEffort: String?
    let hostedTools: Set<HostedToolKind>
    let functionTools: [ModelToolDefinition]
    let toolFollowUp: ModelToolFollowUp?

    init(
        instructions: String? = nil,
        messages: [ChatMessage],
        model: String,
        reasoningEnabled: Bool,
        reasoningEffort: String? = nil,
        hostedTools: Set<HostedToolKind> = [],
        functionTools: [ModelToolDefinition] = [],
        toolFollowUp: ModelToolFollowUp? = nil
    ) {
        self.instructions = instructions
        self.messages = messages
        self.model = model
        self.reasoningEnabled = reasoningEnabled
        self.reasoningEffort = reasoningEffort
        self.hostedTools = hostedTools
        self.functionTools = functionTools
        self.toolFollowUp = toolFollowUp
    }
}

/// 一次模型响应的 token 用量（计划《上下文压缩 v1》§2）。
/// 可选字段为 `nil` 表示服务端未返回该明细，不得伪造。
struct TokenUsageSnapshot: Codable, Sendable, Equatable {
    let inputTokens: Int
    let cachedInputTokens: Int?
    let outputTokens: Int
    let reasoningOutputTokens: Int?
    let totalTokens: Int

    init(
        inputTokens: Int,
        cachedInputTokens: Int? = nil,
        outputTokens: Int,
        reasoningOutputTokens: Int? = nil,
        totalTokens: Int
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }
}

/// 服务端模型目录中的统一领域条目。可选能力为 `nil` 表示服务端未声明，
/// 空集合表示服务端或当前 Adapter 明确声明不支持。
struct ModelCatalogEntry: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String?
    let contextWindow: Int?
    let supportedReasoningEfforts: [String]?
    let defaultReasoningEffort: String?
    let hostedTools: Set<HostedToolKind>?
    let supportsToolCalling: Bool?

    init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        supportedReasoningEfforts: [String]? = nil,
        defaultReasoningEffort: String? = nil,
        hostedTools: Set<HostedToolKind>? = nil,
        supportsToolCalling: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.hostedTools = hostedTools
        self.supportsToolCalling = supportsToolCalling
    }
}

/// Provider 输出的统一模型事件（ADR-002：统一事件，保留 provider 私有 DTO）。
enum ModelEvent: Sendable, Equatable {
    case textDelta(String)
    case reasoningDelta(String)
    case hostedToolUpdated(HostedToolSnapshot)
    case citationAdded(TextCitation)
    case toolCallDelta(ModelToolCallDelta)
    case toolCallCompleted(ModelToolCall)
    /// 服务端返回的真实 token 用量（计划《上下文压缩 v1》§4）。
    /// 不计作文本输出，也不改变终止判断。
    case usage(TokenUsageSnapshot)
    /// Provider 成功流恰好发射一次，随后流结束。
    case completed(ModelCompletion)
}

/// Provider 错误的统一分类（计划《上下文压缩 v1》§3）。
/// Runtime 只读取分类做恢复决策，不接触 provider 具体错误类型。
enum ModelFailureKind: Sendable, Equatable {
    /// 服务端明确判定输入超出上下文窗口。
    case contextOverflow
    case other
}

/// Provider 错误实现该协议以暴露稳定分类。
/// 分类规则（计划 §3）：优先服务端结构化 code/type；HTTP 400/413 单独不构成
/// context overflow；finish_reason == length 属于输出长度错误，不算溢出。
protocol ModelFailureClassifying: Error {
    var failureKind: ModelFailureKind { get }
}

/// 模型服务接入点（ADR-001）。
/// 实现只关心：认证、请求构造、流式协议解析与错误转换。
protocol ModelProvider: Sendable {
    /// 服务描述，用于展示与路由（计划 §8 ProviderDescriptor）。
    var descriptor: ProviderDescriptor { get }

    /// 服务端可用模型目录。协议未声明的能力保留为 `nil`，不在 Provider 内猜测。
    func modelCatalog() async throws -> [ModelCatalogEntry]

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
}

extension ModelProvider {
    /// 仅需要 ID 的调用方可使用该便利入口；目录解析仍只有一个真实 seam。
    func models() async throws -> [String] {
        try await modelCatalog().map(\.id)
    }
}

struct ProviderDescriptor: Sendable, Equatable {
    let id: String
    let displayName: String
}
