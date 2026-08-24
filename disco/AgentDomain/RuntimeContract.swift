import Foundation

/// 一次运行的唯一标识。
typealias RunID = UUID

/// Agent 运行状态。终止事件仍由 `runCompleted` / `runFailed` / `runCancelled`
/// 唯一承载；该状态用于让 Store/UI 准确表达运行正停在哪个阶段。
enum AgentRunState: Sendable, Equatable {
    case idle
    case connecting
    case running
    case waitingForTool
    case waitingForApproval
    case cancelling
    case completed
    case failed
    case cancelled

    var isActive: Bool {
        switch self {
        case .connecting, .running, .waitingForTool, .waitingForApproval, .cancelling:
            true
        case .idle, .completed, .failed, .cancelled:
            false
        }
    }
}

// MARK: - 上下文状态契约

/// 一次上下文占用快照。`source` 标记数据来源，UI 据此标注“服务商返回 / 本地估算”。
struct ContextUsageSnapshot: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable {
        case provider
        case codex
        case estimate
    }

    /// 当前占用（最近一次 daemon 上报的 usage）。
    let current: TokenUsageSnapshot
    /// 累计用量；无累计概念时为 nil。
    let accumulated: TokenUsageSnapshot?
    /// 模型上下文窗口；未知为 nil（UI 无分母）。
    let contextWindow: Int?
    let source: Source

    init(
        current: TokenUsageSnapshot,
        accumulated: TokenUsageSnapshot? = nil,
        contextWindow: Int? = nil,
        source: Source
    ) {
        self.current = current
        self.accumulated = accumulated
        self.contextWindow = contextWindow
        self.source = source
    }
}

/// 压缩 checkpoint：一段已摘要历史的派生缓存。
/// 原始消息始终是事实来源；checkpoint 校验失败即丢弃，不删除消息。
/// daemon 路径不再产生新 checkpoint；保留类型用于读取旧持久化数据。
struct ContextCheckpoint: Codable, Sendable, Equatable {
    let id: UUID
    let schemaVersion: Int
    /// 摘要 prompt 版本；prompt 变更后旧 checkpoint 不再使用。
    let promptVersion: Int
    let providerID: String
    let model: String
    /// 压缩边界：该消息（含）之前的历史已被 summary 覆盖。
    let boundaryMessageID: UUID
    /// 边界之前有序消息 `id + role + text + reasoning` 的 SHA-256 hex。
    let sourceDigest: String
    let summary: String
    let estimatedTokensBefore: Int
    let estimatedTokensAfter: Int
    let createdAt: Date
}

/// Runtime 类别（压缩记录的归属链路）。
enum RuntimeKind: String, Codable, Sendable {
    case generic
    case codex
}

/// 一次压缩的状态快照。缺失值保持 nil，不得伪造。
struct ContextCompactionSnapshot: Codable, Sendable, Equatable {
    enum Trigger: String, Codable, Sendable {
        case automatic
        case manual
        case overflowRecovery
    }

    enum Status: String, Codable, Sendable {
        case running
        case completed
        case failed
    }

    let id: String
    let runtimeKind: RuntimeKind
    let trigger: Trigger
    let status: Status
    let startedAt: Date
    let completedAt: Date?
    let beforeTokens: Int?
    let afterTokens: Int?
    let compactedMessageCount: Int?
    let summary: String?
    let errorMessage: String?

    init(
        id: String,
        runtimeKind: RuntimeKind,
        trigger: Trigger,
        status: Status,
        startedAt: Date,
        completedAt: Date? = nil,
        beforeTokens: Int? = nil,
        afterTokens: Int? = nil,
        compactedMessageCount: Int? = nil,
        summary: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.runtimeKind = runtimeKind
        self.trigger = trigger
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.beforeTokens = beforeTokens
        self.afterTokens = afterTokens
        self.compactedMessageCount = compactedMessageCount
        self.summary = summary
        self.errorMessage = errorMessage
    }
}

/// 压缩状态更新载荷：快照 + 成功时的新 checkpoint（daemon 路径为 nil）。
struct ContextCompactionUpdate: Sendable, Equatable {
    let snapshot: ContextCompactionSnapshot
    let checkpoint: ContextCheckpoint?

    init(snapshot: ContextCompactionSnapshot, checkpoint: ContextCheckpoint? = nil) {
        self.snapshot = snapshot
        self.checkpoint = checkpoint
    }
}

/// 会话级上下文状态（持久化回调的载荷）。
struct ConversationContextState: Sendable, Equatable {
    var checkpoint: ContextCheckpoint?
    var lastSuccessfulCompaction: ContextCompactionSnapshot?

    nonisolated init(
        checkpoint: ContextCheckpoint? = nil,
        lastSuccessfulCompaction: ContextCompactionSnapshot? = nil
    ) {
        self.checkpoint = checkpoint
        self.lastSuccessfulCompaction = lastSuccessfulCompaction
    }
}
