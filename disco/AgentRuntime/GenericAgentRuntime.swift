import Foundation

/// 通用运行时（计划 §6.1 Generic Agent Runtime）。
///
/// 当前 MVP 职责：
/// - 按会话配置（模型、推理开关）组装 `ModelRequest` 并交给 Provider；
/// - 消费 `ModelEvent`，转换为统一 `AgentEvent`（ADR-002）；
/// - 保证一次运行恰好一个终止事件（runCompleted / runFailed / runCancelled）；
/// - 通过 `cancel(runID:)` 提供带内取消（取消语义不依赖 UI 层 Task 状态）；
/// - 把 provider 错误翻译为 `AgentFailure`，UI 层不接触 provider 具体错误类型。
///
/// 会话配置在运行时创建时固定（计划 §6.3：会话创建后默认固定组合，
/// 切换配置需创建新的运行时）。
@MainActor
final class GenericAgentRuntime: AgentRuntime {
    struct Configuration: Sendable {
        let model: String
        let reasoningEnabled: Bool
        let reasoningEffort: String?
        let hostedTools: Set<HostedToolKind>

        init(
            model: String,
            reasoningEnabled: Bool,
            reasoningEffort: String? = nil,
            hostedTools: Set<HostedToolKind> = []
        ) {
            self.model = model
            self.reasoningEnabled = reasoningEnabled
            self.reasoningEffort = reasoningEffort
            self.hostedTools = hostedTools
        }
    }

    private let provider: any ModelProvider
    private let configuration: Configuration
    private var activeTask: Task<Void, Never>?

    init(provider: any ModelProvider, configuration: Configuration) {
        self.provider = provider
        self.configuration = configuration
    }

    func start(request: AgentRunRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            let provider = self.provider
            let configuration = self.configuration
            let task = Task {
                var didEmitTerminal = false

                func emitTerminal(_ event: AgentEvent) {
                    guard !didEmitTerminal else { return }
                    didEmitTerminal = true
                    continuation.yield(event)
                }

                do {
                    var hasText = false
                    for try await modelEvent in provider.stream(
                        request: ModelRequest(
                            messages: request.messages,
                            model: configuration.model,
                            reasoningEnabled: configuration.reasoningEnabled,
                            reasoningEffort: configuration.reasoningEffort,
                            hostedTools: configuration.hostedTools
                        )
                    ) {
                        try Task.checkCancellation()
                        switch modelEvent {
                        case let .textDelta(delta):
                            hasText = true
                            continuation.yield(.messageDelta(delta))
                        case let .reasoningDelta(delta):
                            continuation.yield(.reasoningDelta(delta))
                        case let .hostedToolUpdated(snapshot):
                            continuation.yield(.hostedToolUpdated(snapshot))
                        case let .citationAdded(citation):
                            continuation.yield(.citationAdded(citation))
                        }
                    }

                    if Task.isCancelled {
                        emitTerminal(.runCancelled(request.runID))
                    } else if hasText {
                        emitTerminal(.runCompleted(request.runID))
                    } else {
                        emitTerminal(.runFailed(request.runID, .noTextOutput))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    emitTerminal(.runCancelled(request.runID))
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    emitTerminal(.runCancelled(request.runID))
                    continuation.finish()
                } catch {
                    emitTerminal(.runFailed(request.runID, AgentFailure(message: error.localizedDescription)))
                    continuation.finish()
                }
            }

            activeTask = task

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func cancel(runID: RunID) async {
        activeTask?.cancel()
    }

    func shutdown() async {
        activeTask?.cancel()
    }
}
