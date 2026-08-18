import Foundation

/// 一次模型响应的 token 用量。可选字段为 `nil` 表示服务端未返回该明细，不得伪造。
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

/// 模型目录中的统一领域条目。可选能力为 `nil` 表示未声明，
/// 空集合表示明确声明不支持。
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
