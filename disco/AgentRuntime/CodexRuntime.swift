import Foundation

/// Codex 运行时（计划 §6.2 Codex Runtime Adapter，ADR-003）。
///
/// 与 `GenericAgentRuntime` 正交：不实现 `ModelProvider`，而是通过
/// `CodexAppServerTransport` 把 ChatGPT/Codex 订阅的 turn 流映射为统一
/// `AgentEvent`。对话历史由服务端 thread 维护，客户端每次只发送新增的用户输入。
///
/// 不变量（与 GenericAgentRuntime 一致）：一次运行恰好发射一个终止事件
/// （runCompleted / runFailed / runCancelled），随后流结束。
///
/// 生命周期：传输层（握手 + thread/start 或 thread/resume）在首次运行时惰性建立；
/// `cancel(runID:)` 通过 `turn/interrupt` 中断服务端 turn。
@MainActor
final class CodexRuntime: AgentRuntime {
    struct Configuration: Sendable {
        let model: String
        /// nil 表示省略该字段，交由 app-server 使用模型默认档位。
        let reasoningEffort: String?
        /// 续接的 codex 会话线程 id（nil 表示新建线程）；来自会话持久化
        let resumeThreadID: String?
        /// 会话创建时锁定的项目工作目录；临时对话为 nil，线程以 app-server 默认目录运行。
        let cwd: String?

        init(
            model: String,
            reasoningEffort: String? = nil,
            resumeThreadID: String?,
            cwd: String? = nil
        ) {
            self.model = model
            self.reasoningEffort = reasoningEffort
            self.resumeThreadID = resumeThreadID
            self.cwd = cwd
        }
    }

    private let transport: CodexAppServerTransport
    private let configuration: Configuration
    /// 线程 id 就绪时回调（新建或续接），由上层写入会话并持久化
    private let onThreadReady: ((String) -> Void)?
    private var threadID: String?
    private var threadConnectionGeneration: UInt64?
    private var activeRunID: RunID?
    private var activeTask: Task<Void, Never>?

    private static let noTextFailure = AgentFailure(
        message: "助手没有返回文本内容。"
    )

    init(
        transport: CodexAppServerTransport,
        configuration: Configuration,
        onThreadReady: ((String) -> Void)? = nil
    ) {
        self.transport = transport
        self.configuration = configuration
        self.onThreadReady = onThreadReady
    }

    func start(request: AgentRunRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor [weak self] in
                self?.run(request: request, continuation: continuation)
            }
        }
    }

    func compactContext(request: ContextCompactionRequest) async throws -> ContextCompactionUpdate {
        guard activeRunID == nil else {
            throw AgentFailure(
                code: .contextCompactionFailed,
                message: "回复生成中，暂时无法压缩上下文。"
            )
        }
        guard let requestedThreadID = threadID ?? request.resumeThreadID else {
            throw CodexAppServerError.noActiveThread
        }
        try await ensureReady()
        guard let threadID, threadID == requestedThreadID else {
            throw CodexAppServerError.noActiveThread
        }
        let startedAt = Date.now
        let itemID = try await transport.compactThread(threadID: threadID)
        return ContextCompactionUpdate(
            snapshot: ContextCompactionSnapshot(
                id: itemID,
                runtimeKind: .codex,
                trigger: .manual,
                status: .completed,
                startedAt: startedAt,
                completedAt: .now
            )
        )
    }

    func cancel(runID: RunID) async {
        guard activeRunID == runID else { return }
        activeTask?.cancel()
        do {
            if let threadID {
                try await transport.interruptTurn(threadID: threadID)
            }
        } catch {
            // 中断失败（如 turn 已结束）：服务端最终会以 completed/interrupted
            // 结束并清理 activeTurn；运行流侧已通过任务取消兜底。
        }
    }

    func shutdown() async {
        activeTask?.cancel()
        // transport 由 AppState 按连接生命周期持有；关闭一个会话不能
        // 杀掉同一连接上的其他 conversation。
    }

    // MARK: - 内部实现

    private func run(
        request: AgentRunRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) {
        let runID = request.runID
        activeRunID = runID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(runID: runID, request: request, continuation: continuation)
            self.activeRunID = nil
        }
        activeTask = task
        continuation.onTermination = { _ in
            task.cancel()
        }
    }

    private func execute(
        runID: RunID,
        request: AgentRunRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        defer { continuation.finish() }

        var didEmitTerminal = false
        func emitTerminal(_ event: AgentEvent) {
            guard !didEmitTerminal else { return }
            didEmitTerminal = true
            continuation.yield(event)
        }

        do {
            try await ensureReady()
            guard !Task.isCancelled else {
                emitTerminal(.runCancelled(runID))
                return
            }

            let input = request.messages.last(where: { $0.role == .user })?.text ?? ""
            guard let threadID else {
                emitTerminal(.runFailed(runID, AgentFailure(message: "Codex 会话线程尚未就绪。")))
                return
            }
            continuation.yield(.runStateChanged(runID, .running))
            var hasText = false
            for try await turnEvent in transport.startTurn(
                threadID: threadID,
                input: input,
                effort: configuration.reasoningEffort
            ) {
                try Task.checkCancellation()
                switch turnEvent {
                case .started, .itemStarted, .itemCompleted:
                    break
                case let .contextUsageUpdated(usage):
                    continuation.yield(.contextUsageUpdated(ContextUsageSnapshot(
                        current: TokenUsageSnapshot(
                            inputTokens: usage.last.inputTokens,
                            cachedInputTokens: usage.last.cachedInputTokens,
                            outputTokens: usage.last.outputTokens,
                            reasoningOutputTokens: usage.last.reasoningOutputTokens,
                            totalTokens: usage.last.totalTokens
                        ),
                        accumulated: TokenUsageSnapshot(
                            inputTokens: usage.total.inputTokens,
                            cachedInputTokens: usage.total.cachedInputTokens,
                            outputTokens: usage.total.outputTokens,
                            reasoningOutputTokens: usage.total.reasoningOutputTokens,
                            totalTokens: usage.total.totalTokens
                        ),
                        contextWindow: usage.modelContextWindow,
                        source: .codex
                    )))
                case let .contextCompactionStarted(itemID):
                    continuation.yield(.contextCompactionUpdated(ContextCompactionUpdate(
                        snapshot: ContextCompactionSnapshot(
                            id: itemID,
                            runtimeKind: .codex,
                            trigger: .automatic,
                            status: .running,
                            startedAt: .now
                        )
                    )))
                case let .contextCompactionCompleted(itemID):
                    continuation.yield(.contextCompactionUpdated(ContextCompactionUpdate(
                        snapshot: ContextCompactionSnapshot(
                            id: itemID,
                            runtimeKind: .codex,
                            trigger: .automatic,
                            status: .completed,
                            startedAt: .now,
                            completedAt: .now
                        )
                    )))
                case let .agentMessageDelta(delta):
                    hasText = true
                    continuation.yield(.messageDelta(delta))
                case let .reasoningSummaryDelta(delta):
                    continuation.yield(.reasoningDelta(delta))
                case let .completed(status):
                    switch status {
                    case .completed:
                        emitTerminal(hasText
                            ? .runCompleted(runID)
                            : .runFailed(runID, Self.noTextFailure))
                    case .interrupted:
                        emitTerminal(.runCancelled(runID))
                    case let .failed(message):
                        emitTerminal(.runFailed(runID, AgentFailure(message: message)))
                    }
                    return
                }
            }

            // 传输层流结束但未收到 turn/completed（契约外情况）：兜底为失败
            if Task.isCancelled {
                emitTerminal(.runCancelled(runID))
            } else {
                emitTerminal(.runFailed(runID, AgentFailure(message: "turn 未正常结束。")))
            }
        } catch is CancellationError {
            emitTerminal(.runCancelled(runID))
        } catch let error as URLError where error.code == .cancelled {
            emitTerminal(.runCancelled(runID))
        } catch {
            emitTerminal(.runFailed(runID, AgentFailure(message: error.localizedDescription)))
        }
    }

    /// 惰性建立传输层，并在连接重建后重新 resume 本运行时的 thread。
    private func ensureReady() async throws {
        if !transport.isReady {
            try await transport.start()
        }
        if threadConnectionGeneration != transport.connectionGeneration {
            let resolved = try await transport.startThread(
                model: configuration.model,
                resumeThreadID: threadID ?? configuration.resumeThreadID,
                cwd: configuration.cwd
            )
            threadID = resolved
            threadConnectionGeneration = transport.connectionGeneration
            onThreadReady?(resolved)
        }
    }
}
