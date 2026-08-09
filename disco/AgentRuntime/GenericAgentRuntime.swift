import Foundation

/// 通用运行时（计划 §6.1 Generic Agent Runtime）。
/// Runtime 负责上下文组装、自动压缩、溢出恢复和统一终止事件；Provider 只负责传输。
@MainActor
final class GenericAgentRuntime: AgentRuntime {
    struct Configuration: Sendable {
        let model: String
        let reasoningEnabled: Bool
        let reasoningEffort: String?
        let hostedTools: Set<HostedToolKind>
        /// nil 表示未知：不按本地阈值自动压缩，只在服务端明确溢出后恢复。
        let contextWindow: Int?

        init(
            model: String,
            reasoningEnabled: Bool,
            reasoningEffort: String? = nil,
            hostedTools: Set<HostedToolKind> = [],
            contextWindow: Int? = nil
        ) {
            self.model = model
            self.reasoningEnabled = reasoningEnabled
            self.reasoningEffort = reasoningEffort
            self.hostedTools = hostedTools
            self.contextWindow = contextWindow
        }
    }

    private let provider: any ModelProvider
    private let configuration: Configuration
    private var activeTask: Task<Void, Never>?

    init(provider: any ModelProvider, configuration: Configuration) {
        self.provider = provider
        self.configuration = configuration
    }

    private func makeCompactor() -> ContextCompactor {
        ContextCompactor(
            provider: provider,
            signature: .init(providerID: provider.descriptor.id, model: configuration.model),
            policy: .init(contextWindow: configuration.contextWindow)
        )
    }

    func start(request: AgentRunRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.execute(request: request, continuation: continuation)
            }
            activeTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func compactContext(request: ContextCompactionRequest) async throws -> ContextCompactionUpdate {
        guard activeTask == nil else {
            throw AgentFailure(
                code: .contextCompactionFailed,
                message: "回复生成中，暂时无法压缩上下文。"
            )
        }
        try Task.checkCancellation()
        return try await makeCompactor().compact(
            messages: request.messages,
            checkpoint: request.contextCheckpoint,
            trigger: .manual
        )
    }

    func cancel(runID: RunID) async {
        activeTask?.cancel()
    }

    func shutdown() async {
        activeTask?.cancel()
        activeTask = nil
    }

    private func execute(
        request: AgentRunRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        var didEmitTerminal = false
        func emitTerminal(_ event: AgentEvent) {
            guard !didEmitTerminal else { return }
            didEmitTerminal = true
            continuation.yield(event)
        }

        defer {
            continuation.finish()
            activeTask = nil
        }

        do {
            let contextCompactor = makeCompactor()
            let inputBudget = ContextCompactor.Policy(
                contextWindow: configuration.contextWindow
            ).inputBudget
            var checkpoint = contextCompactor.validatedCheckpoint(
                request.contextCheckpoint,
                messages: request.messages
            )

            // 预防性自动压缩只在窗口已知且达到软阈值时执行。
            if contextCompactor.shouldCompact(messages: request.messages, checkpoint: checkpoint) {
                let startedAt = Date.now
                let compactionID = UUID().uuidString
                continuation.yield(.contextCompactionUpdated(ContextCompactionUpdate(
                    snapshot: ContextCompactionSnapshot(
                        id: compactionID,
                        runtimeKind: .generic,
                        trigger: .automatic,
                        status: .running,
                        startedAt: startedAt
                    )
                )))
                do {
                    let update = try await contextCompactor.compact(
                        messages: request.messages,
                        checkpoint: checkpoint,
                        trigger: .automatic
                    )
                    checkpoint = update.checkpoint
                    continuation.yield(.contextCompactionUpdated(update))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continuation.yield(.contextCompactionUpdated(ContextCompactionUpdate(
                        snapshot: ContextCompactionSnapshot(
                            id: compactionID,
                            runtimeKind: .generic,
                            trigger: .automatic,
                            status: .failed,
                            startedAt: startedAt,
                            completedAt: .now,
                            errorMessage: error.localizedDescription
                        )
                    )))
                    // 低于硬输入预算时，压缩失败不阻断原始请求；超预算则不能静默截断。
                    if let inputBudget,
                       contextCompactor.estimatedVisibleTokens(
                           messages: request.messages,
                           checkpoint: checkpoint
                       ) > inputBudget {
                        throw error
                    }
                }
            }

            var recoveryAttempted = false
            while true {
                try Task.checkCancellation()
                let input = contextCompactor.modelInput(
                    messages: request.messages,
                    checkpoint: checkpoint
                )
                let estimatedTokens = contextCompactor.estimatedVisibleTokens(
                    messages: request.messages,
                    checkpoint: checkpoint
                )
                continuation.yield(.contextUsageUpdated(ContextUsageSnapshot(
                    current: TokenUsageSnapshot(
                        inputTokens: estimatedTokens,
                        outputTokens: 0,
                        totalTokens: estimatedTokens
                    ),
                    contextWindow: configuration.contextWindow,
                    source: .estimate
                )))

                var hasText = false
                var emittedVisibleEvent = false
                do {
                    let stream = provider.stream(request: ModelRequest(
                        instructions: ContextCompactor.runtimeInstructions,
                        messages: input,
                        model: configuration.model,
                        reasoningEnabled: configuration.reasoningEnabled,
                        reasoningEffort: configuration.reasoningEffort,
                        hostedTools: configuration.hostedTools
                    ))
                    for try await modelEvent in stream {
                        try Task.checkCancellation()
                        switch modelEvent {
                        case let .textDelta(delta):
                            hasText = true
                            emittedVisibleEvent = true
                            continuation.yield(.messageDelta(delta))
                        case let .reasoningDelta(delta):
                            emittedVisibleEvent = true
                            continuation.yield(.reasoningDelta(delta))
                        case let .hostedToolUpdated(snapshot):
                            emittedVisibleEvent = true
                            continuation.yield(.hostedToolUpdated(snapshot))
                        case let .citationAdded(citation):
                            emittedVisibleEvent = true
                            continuation.yield(.citationAdded(citation))
                        case let .usage(snapshot):
                            continuation.yield(.contextUsageUpdated(ContextUsageSnapshot(
                                current: snapshot,
                                contextWindow: configuration.contextWindow,
                                source: .provider
                            )))
                        }
                    }
                    if hasText {
                        emitTerminal(.runCompleted(request.runID))
                    } else {
                        emitTerminal(.runFailed(request.runID, .noTextOutput))
                    }
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch let error as ModelFailureClassifying
                    where error.failureKind == .contextOverflow
                    && !recoveryAttempted
                    && !emittedVisibleEvent {
                    recoveryAttempted = true
                    let startedAt = Date.now
                    let compactionID = UUID().uuidString
                    continuation.yield(.contextCompactionUpdated(ContextCompactionUpdate(
                        snapshot: ContextCompactionSnapshot(
                            id: compactionID,
                            runtimeKind: .generic,
                            trigger: .overflowRecovery,
                            status: .running,
                            startedAt: startedAt
                        )
                    )))
                    do {
                        let update = try await contextCompactor.compactForOverflowRecovery(
                            messages: request.messages,
                            checkpoint: checkpoint
                        )
                        checkpoint = update.checkpoint
                        continuation.yield(.contextCompactionUpdated(update))
                        continue
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        continuation.yield(.contextCompactionUpdated(ContextCompactionUpdate(
                            snapshot: ContextCompactionSnapshot(
                                id: compactionID,
                                runtimeKind: .generic,
                                trigger: .overflowRecovery,
                                status: .failed,
                                startedAt: startedAt,
                                completedAt: .now,
                                errorMessage: error.localizedDescription
                            )
                        )))
                        throw AgentFailure.contextOverflowUnrecoverable
                    }
                } catch {
                    throw error
                }
            }
        } catch is CancellationError {
            emitTerminal(.runCancelled(request.runID))
        } catch let error as URLError where error.code == .cancelled {
            emitTerminal(.runCancelled(request.runID))
        } catch let error as AgentFailure {
            emitTerminal(.runFailed(request.runID, error))
        } catch {
            emitTerminal(.runFailed(
                request.runID,
                AgentFailure(message: error.localizedDescription)
            ))
        }
    }
}
