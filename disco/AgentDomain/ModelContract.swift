import Foundation

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

    init(
        instructions: String? = nil,
        messages: [ChatMessage],
        model: String,
        reasoningEnabled: Bool,
        reasoningEffort: String? = nil,
        hostedTools: Set<HostedToolKind> = []
    ) {
        self.instructions = instructions
        self.messages = messages
        self.model = model
        self.reasoningEnabled = reasoningEnabled
        self.reasoningEffort = reasoningEffort
        self.hostedTools = hostedTools
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
    /// 服务端返回的真实 token 用量（计划《上下文压缩 v1》§4）。
    /// 不计作文本输出，也不改变终止判断。
    case usage(TokenUsageSnapshot)
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
