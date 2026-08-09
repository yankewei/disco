import Foundation

/// 一次运行的唯一标识（计划 §8 `cancel(run_id: RunID)`）。
typealias RunID = UUID

/// 一次运行请求（计划 §8 AgentRunRequest）。
/// MVP 只携带消息；系统指令 / 项目上下文在后续迭代加入。
struct AgentRunRequest: Sendable {
    let runID: RunID
    let messages: [ChatMessage]
    /// 续接的 codex thread id（订阅服务商用；API Key 运行时忽略）。
    /// 有值时 thread/resume 而非新建线程，保证重启后上下文不丢失。
    var resumeThreadID: String? = nil
    /// Generic 运行时的有效上下文 checkpoint（计划《上下文压缩 v1》§2）。
    /// 由调用方按 providerID + model + promptVersion 校验后传入；
    /// 为 nil 时发送完整消息历史。
    var contextCheckpoint: ContextCheckpoint? = nil
}

/// 手动压缩请求（计划《上下文压缩 v1》§2 `compactContext(request:)` 的入参）。
struct ContextCompactionRequest: Sendable {
    /// 完整本地消息历史（Generic 用于选择压缩边界；Codex 忽略）。
    let messages: [ChatMessage]
    /// 续接的 codex thread id；为 nil 时 Codex 无法执行手动压缩。
    var resumeThreadID: String? = nil
    /// 当前持有的 checkpoint；有值时手动压缩把旧摘要与新增前缀一起折叠。
    var contextCheckpoint: ContextCheckpoint? = nil

    init(
        messages: [ChatMessage],
        resumeThreadID: String? = nil,
        contextCheckpoint: ContextCheckpoint? = nil
    ) {
        self.messages = messages
        self.resumeThreadID = resumeThreadID
        self.contextCheckpoint = contextCheckpoint
    }
}

/// 统一 Agent 事件（计划 §8 AgentEvent）。
/// Runtime 保证：一次运行恰好发射一个终止事件
/// （runCompleted / runFailed / runCancelled），随后流结束。
enum AgentEvent: Sendable, Equatable {
    case messageDelta(String)
    case reasoningDelta(String)
    case hostedToolUpdated(HostedToolSnapshot)
    case citationAdded(TextCitation)
    /// 上下文占用更新（真实 usage 或 checkpoint-aware 本地估算）。
    case contextUsageUpdated(ContextUsageSnapshot)
    /// 压缩状态更新（自动 / 手动 / 溢出恢复；running / completed / failed）。
    case contextCompactionUpdated(ContextCompactionUpdate)
    case runCompleted(RunID)
    case runFailed(RunID, AgentFailure)
    case runCancelled(RunID)
}

/// 失败信息：Runtime 在边界处把 provider 错误翻译成可展示的 AgentFailure
/// （计划 §8 AgentFailure），UI 层不接触 provider 具体错误类型。
struct AgentFailure: Error, Sendable, Equatable {
    /// 稳定错误码（计划《上下文压缩 v1》§2），供 UI 做差异化展示与恢复引导。
    enum Code: String, Codable, Sendable, Equatable {
        case generic
        case noTextOutput
        case contextOverflow
        case contextCompactionFailed
    }

    let code: Code
    let message: String
    /// 可选恢复建议（用户可读中文）。
    let recoverySuggestion: String?
    /// 是否可通过“重试”按钮直接恢复。
    let isRetryable: Bool

    init(
        code: Code = .generic,
        message: String,
        recoverySuggestion: String? = nil,
        isRetryable: Bool = false
    ) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.isRetryable = isRetryable
    }
}

extension AgentFailure {
    static let noTextOutput = AgentFailure(
        code: .noTextOutput,
        message: "模型没有返回文本内容。请确认所选模型支持 Responses API。"
    )

    /// 恢复重试后仍然上下文溢出（计划《上下文压缩 v1》§3：稳定失败）。
    static let contextOverflowUnrecoverable = AgentFailure(
        code: .contextOverflow,
        message: "会话超出模型上下文窗口，压缩后重试仍然失败。",
        recoverySuggestion: "请在设置中填写模型上下文窗口、手动压缩会话，或新建会话。",
        isRetryable: false
    )
}

/// 推理循环的所有者（ADR-001：Provider 与 Runtime 是两个正交维度）。
/// Runtime 负责：按会话配置组装 ModelRequest、消费 ModelEvent、
/// 控制取消、把 provider 错误翻译为 AgentFailure、发射统一 Agent 事件。
protocol AgentRuntime: Sendable {
    func start(request: AgentRunRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(runID: RunID) async

    /// 手动压缩上下文（计划《上下文压缩 v1》）。
    /// Generic 生成摘要 checkpoint；Codex 发送 thread/compact/start。
    func compactContext(request: ContextCompactionRequest) async throws -> ContextCompactionUpdate

    /// 释放运行时持有的资源（如 codex 子进程）。
    /// 会话删除或配置变更替换运行时前调用，避免遗留孤儿进程。
    func shutdown() async
}

/// 过渡默认实现：让各 Runtime 在接入压缩前保持可编译。
/// TODO(compaction)：Generic 与 Codex 都落地真实实现后移除该扩展。
extension AgentRuntime {
    func compactContext(request: ContextCompactionRequest) async throws -> ContextCompactionUpdate {
        throw AgentFailure(
            code: .contextCompactionFailed,
            message: "当前运行时暂不支持手动压缩。"
        )
    }
}

// MARK: - 上下文压缩契约（计划《上下文压缩 v1》§2）

/// 一次上下文占用快照。`source` 标记数据来源，UI 据此标注“服务商返回 / 本地估算”。
struct ContextUsageSnapshot: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable {
        case provider
        case codex
        case estimate
    }

    /// 当前占用（Codex：last；Generic：最近一次响应 usage 或 checkpoint-aware 估算）。
    let current: TokenUsageSnapshot
    /// 累计用量（Codex：total；Generic 无累计概念时为 nil）。
    let accumulated: TokenUsageSnapshot?
    /// 模型上下文窗口；未知为 nil（UI 无分母，不触发阈值压缩）。
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

/// Generic 压缩 checkpoint：一段已摘要历史的派生缓存（计划《上下文压缩 v1》§2）。
/// 原始消息始终是事实来源；checkpoint 校验失败即丢弃，不删除消息。
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

/// 一次压缩的状态快照（计划《上下文压缩 v1》§2）。
/// 缺失值保持 nil（如 Codex schema 没有 before/after），不得伪造。
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
        self.errorMessage = errorMessage
    }
}

/// 压缩状态更新载荷：快照 + 成功时的新 checkpoint（Codex 无 checkpoint，为 nil）。
struct ContextCompactionUpdate: Sendable, Equatable {
    let snapshot: ContextCompactionSnapshot
    let checkpoint: ContextCheckpoint?

    init(snapshot: ContextCompactionSnapshot, checkpoint: ContextCheckpoint? = nil) {
        self.snapshot = snapshot
        self.checkpoint = checkpoint
    }
}

/// 会话级上下文状态（计划《上下文压缩 v1》§2 持久化回调的载荷）。
/// checkpoint 只是派生缓存；原始消息始终是事实来源。
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
