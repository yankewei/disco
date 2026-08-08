import Foundation

/// 单个模型请求（计划 §8 `stream(request:)` 的入参）。
/// 模型与推理开关是**每请求参数**：Provider 是无状态传输（ADR-001），
/// 不持有会话配置；具体模型/是否推理由 Runtime 按会话配置填入。
struct ModelRequest: Sendable {
    let messages: [ChatMessage]
    let model: String
    let reasoningEnabled: Bool
    let reasoningEffort: String?
    let hostedTools: Set<HostedToolKind>

    init(
        messages: [ChatMessage],
        model: String,
        reasoningEnabled: Bool,
        reasoningEffort: String? = nil,
        hostedTools: Set<HostedToolKind> = []
    ) {
        self.messages = messages
        self.model = model
        self.reasoningEnabled = reasoningEnabled
        self.reasoningEffort = reasoningEffort
        self.hostedTools = hostedTools
    }
}

/// Provider 输出的统一模型事件（ADR-002：统一事件，保留 provider 私有 DTO）。
enum ModelEvent: Sendable, Equatable {
    case textDelta(String)
    case reasoningDelta(String)
    case hostedToolUpdated(HostedToolSnapshot)
    case citationAdded(TextCitation)
}

/// 模型服务接入点（ADR-001）。
/// 实现只关心：认证、请求构造、流式协议解析与错误转换。
protocol ModelProvider: Sendable {
    /// 服务描述，用于展示与路由（计划 §8 ProviderDescriptor）。
    var descriptor: ProviderDescriptor { get }

    /// 服务端可用模型列表。
    func models() async throws -> [String]

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
}

struct ProviderDescriptor: Sendable, Equatable {
    let id: String
    let displayName: String
}
