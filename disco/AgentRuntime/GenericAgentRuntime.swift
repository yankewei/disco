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
        /// 是否向模型广告客户端托管的 `request_user_input`。
        /// 首批只为 OpenAI 原生 Responses 方言开启。
        let userInputEnabled: Bool
        /// 会话创建时锁定的 Workspace；临时对话为 nil，不能由工具参数覆盖。
        let workspace: WorkspaceContext?
        /// 单次运行允许发起的最大模型请求数，防止异常响应形成无限续传。
        let maximumModelRounds: Int
        /// 单次运行允许处理的最大客户端工具调用数。
        let maximumToolCalls: Int
        /// nil 表示未知：不按本地阈值自动压缩，只在服务端明确溢出后恢复。
        let contextWindow: Int?

        init(
            model: String,
            reasoningEnabled: Bool,
            reasoningEffort: String? = nil,
            hostedTools: Set<HostedToolKind> = [],
            userInputEnabled: Bool = false,
            workspace: WorkspaceContext? = nil,
            maximumModelRounds: Int = 8,
            maximumToolCalls: Int = 16,
            contextWindow: Int? = nil
        ) {
            self.model = model
            self.reasoningEnabled = reasoningEnabled
            self.reasoningEffort = reasoningEffort
            self.hostedTools = hostedTools
            self.userInputEnabled = userInputEnabled
            self.workspace = workspace
            self.maximumModelRounds = maximumModelRounds
            self.maximumToolCalls = maximumToolCalls
            self.contextWindow = contextWindow
        }
    }

    private let provider: any ModelProvider
    private let configuration: Configuration
    private let toolExecutor: (any ToolExecutor)?
    private var activeRunID: RunID?
    private var activeTask: Task<Void, Never>?
    private var pendingUserInput: PendingUserInput?

    private struct PendingUserInput {
        let request: UserInputRequest
        let continuation: CheckedContinuation<[UserInputAnswer], Error>
    }

    private struct UserInputArguments: Decodable {
        struct Question: Decodable {
            struct Option: Decodable {
                let label: String
                let description: String
            }

            let id: String
            let header: String
            let question: String
            let options: [Option]
            let allowsOther: Bool
        }

        let questions: [Question]
    }

    private struct UserInputResult: Encodable {
        struct Answer: Encodable {
            let questionID: String
            let answers: [String]
        }

        let answers: [Answer]
    }

    private static let maximumUserInputRounds = 4

    private static let userInputTool = ModelToolDefinition(
        name: "request_user_input",
        description: "Ask the user one to three short questions only when their answer is required to continue. Do not request passwords, API keys, authentication codes, or other secrets.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "questions": .object([
                    "type": .string("array"),
                    "minItems": .number(1),
                    "maxItems": .number(3),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "id": .object(["type": .string("string")]),
                            "header": .object(["type": .string("string")]),
                            "question": .object(["type": .string("string")]),
                            "options": .object([
                                "type": .string("array"),
                                "maxItems": .number(3),
                                "items": .object([
                                    "type": .string("object"),
                                    "properties": .object([
                                        "label": .object(["type": .string("string")]),
                                        "description": .object(["type": .string("string")]),
                                    ]),
                                    "required": .array([.string("label"), .string("description")]),
                                    "additionalProperties": .boolean(false),
                                ]),
                            ]),
                            "allows_other": .object(["type": .string("boolean")]),
                        ]),
                        "required": .array([
                            .string("id"),
                            .string("header"),
                            .string("question"),
                            .string("options"),
                            .string("allows_other"),
                        ]),
                        "additionalProperties": .boolean(false),
                    ]),
                ]),
            ]),
            "required": .array([.string("questions")]),
            "additionalProperties": .boolean(false),
        ])
    )

    init(
        provider: any ModelProvider,
        configuration: Configuration,
        toolExecutor: (any ToolExecutor)? = nil
    ) {
        self.provider = provider
        self.configuration = configuration
        self.toolExecutor = toolExecutor
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
            activeRunID = request.runID
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
        guard activeRunID == runID else { return }
        activeTask?.cancel()
        cancelPendingUserInput()
        await toolExecutor?.cancel(runID: runID)
    }

    func submitUserInput(
        requestID: UserInputRequestID,
        answers: [UserInputAnswer]
    ) async throws {
        guard let pendingUserInput,
              pendingUserInput.request.id == requestID,
              pendingUserInput.request.runID == activeRunID else {
            throw AgentFailure(message: "这组问题已经失效或不属于当前运行。")
        }
        try Self.validate(answers: answers, for: pendingUserInput.request)
        self.pendingUserInput = nil
        pendingUserInput.continuation.resume(returning: answers)
    }

    func shutdown() async {
        let runID = activeRunID
        activeTask?.cancel()
        cancelPendingUserInput()
        if let runID {
            await toolExecutor?.cancel(runID: runID)
        }
        activeRunID = nil
        activeTask = nil
    }

    private func cancelPendingUserInput() {
        guard let pendingUserInput else { return }
        self.pendingUserInput = nil
        pendingUserInput.continuation.resume(throwing: CancellationError())
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
            activeRunID = nil
            activeTask = nil
        }

        do {
            continuation.yield(.runStateChanged(request.runID, .running))
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
            var toolFollowUp: ModelToolFollowUp?
            var userInputRoundCount = 0
            var modelRoundCount = 0
            var toolCallCount = 0
            var committedToolCallIDs = Set<String>()
            var hasAnyText = false
            while true {
                try Task.checkCancellation()
                guard modelRoundCount < configuration.maximumModelRounds else {
                    throw AgentFailure(
                        message: "模型工具循环超过最大模型轮次（\(configuration.maximumModelRounds)），运行已停止。"
                    )
                }
                modelRoundCount += 1
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

                var emittedVisibleEvent = false
                var toolCalls: [ModelToolCall] = []
                var modelCompletion: ModelCompletion?
                do {
                    let stream = provider.stream(request: ModelRequest(
                        instructions: ContextCompactor.runtimeInstructions,
                        messages: input,
                        model: configuration.model,
                        reasoningEnabled: configuration.reasoningEnabled,
                        reasoningEffort: configuration.reasoningEffort,
                        hostedTools: configuration.hostedTools,
                        functionTools: (configuration.userInputEnabled ? [Self.userInputTool] : [])
                            + (toolExecutor?.toolDefinitions ?? []),
                        toolFollowUp: toolFollowUp
                    ))
                    for try await modelEvent in stream {
                        try Task.checkCancellation()
                        switch modelEvent {
                        case let .textDelta(delta):
                            hasAnyText = true
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
                        case .toolCallDelta:
                            break
                        case let .toolCallCompleted(call):
                            if !toolCalls.contains(where: { $0.callID == call.callID }) {
                                toolCalls.append(call)
                            }
                        case let .usage(snapshot):
                            continuation.yield(.contextUsageUpdated(ContextUsageSnapshot(
                                current: snapshot,
                                contextWindow: configuration.contextWindow,
                                source: .provider
                            )))
                        case let .completed(completion):
                            modelCompletion = completion
                        }
                    }

                    if !toolCalls.isEmpty {
                        guard toolCalls.count == 1, let call = toolCalls.first else {
                            throw AgentFailure(
                                message: "当前工具循环一次只支持一个客户端工具调用。"
                            )
                        }
                        let isUserInputCall = configuration.userInputEnabled
                            && call.name == Self.userInputTool.name
                        if !isUserInputCall, toolExecutor == nil {
                            throw AgentFailure(
                                message: "模型请求调用本地工具，但工具循环尚未启用。"
                            )
                        }
                        guard let modelContinuation = modelCompletion?.continuation else {
                            throw AgentFailure(message: "模型没有返回可续接的完整工具调用。")
                        }
                        guard committedToolCallIDs.insert(call.callID).inserted else {
                            throw AgentFailure(
                                message: "模型重复提交了已经处理的工具调用：\(call.callID)"
                            )
                        }
                        guard toolCallCount < configuration.maximumToolCalls else {
                            throw AgentFailure(
                                message: "模型工具循环超过最大工具调用次数（\(configuration.maximumToolCalls)），运行已停止。"
                            )
                        }
                        toolCallCount += 1

                        let output: String
                        if isUserInputCall {
                            guard userInputRoundCount < Self.maximumUserInputRounds else {
                                throw AgentFailure(message: "模型连续请求用户输入的次数过多，运行已停止。")
                            }
                            let userInputRequest = try Self.decodeUserInputRequest(
                                call.arguments,
                                runID: request.runID
                            )
                            userInputRoundCount += 1
                            continuation.yield(.userInputRequested(userInputRequest))
                            continuation.yield(.runStateChanged(request.runID, .waitingForUserInput))
                            let answers = try await waitForUserInput(userInputRequest)
                            continuation.yield(.userInputResolved(userInputRequest.id))
                            continuation.yield(.runStateChanged(request.runID, .running))
                            output = try Self.encodeUserInputResult(answers)
                        } else {
                            guard let toolExecutor else {
                                assertionFailure("本地工具能力检查与执行分支不一致。")
                                throw AgentFailure(message: "本地工具执行器不可用。")
                            }
                            guard toolExecutor.toolDefinitions.contains(where: {
                                $0.name == call.name
                            }) else {
                                throw AgentFailure(message: "模型调用了未广告的本地工具：\(call.name)")
                            }
                            guard let arguments = call.arguments.data(using: .utf8),
                                  let object = try? JSONSerialization.jsonObject(with: arguments),
                                  object is [String: Any] else {
                                throw AgentFailure(message: "模型返回的工具参数不是有效的 JSON object。")
                            }
                            continuation.yield(.runStateChanged(request.runID, .waitingForTool))
                            let result: ToolExecutionResult
                            do {
                                result = try await toolExecutor.execute(ToolExecutionRequest(
                                    call: call,
                                    context: ToolExecutionContext(
                                        runID: request.runID,
                                        workspace: configuration.workspace
                                    )
                                ))
                            } catch is CancellationError where !Task.isCancelled {
                                throw AgentFailure(
                                    message: "工具执行被意外取消，运行已停止。"
                                )
                            } catch let error as URLError
                                where error.code == .cancelled && !Task.isCancelled {
                                throw AgentFailure(
                                    message: "工具执行被意外取消，运行已停止。"
                                )
                            } catch where Task.isCancelled {
                                throw CancellationError()
                            }
                            try Task.checkCancellation()
                            continuation.yield(.runStateChanged(request.runID, .running))
                            output = try Self.encodeToolExecutionResult(result)
                        }

                        toolFollowUp = ModelToolFollowUp(
                            continuation: modelContinuation,
                            results: [ModelToolResult(callID: call.callID, output: output)]
                        )
                        continue
                    }

                    if hasAnyText {
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
                    && toolFollowUp != nil {
                    throw AgentFailure.contextOverflowAfterToolExecution
                } catch let error as ModelFailureClassifying
                    where error.failureKind == .contextOverflow
                    && !recoveryAttempted
                    && toolFollowUp == nil
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

    private func waitForUserInput(_ request: UserInputRequest) async throws -> [UserInputAnswer] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingUserInput = PendingUserInput(
                    request: request,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingUserInput()
            }
        }
    }

    private static func decodeUserInputRequest(
        _ arguments: String,
        runID: RunID
    ) throws -> UserInputRequest {
        guard let data = arguments.data(using: .utf8) else {
            throw AgentFailure(message: "模型返回了无法解析的用户问题。")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded: UserInputArguments
        do {
            decoded = try decoder.decode(UserInputArguments.self, from: data)
        } catch {
            throw AgentFailure(message: "模型返回的用户问题格式无效。")
        }
        guard (1...3).contains(decoded.questions.count) else {
            throw AgentFailure(message: "模型一次只能询问 1 到 3 个问题。")
        }

        var questionIDs = Set<String>()
        let questions = try decoded.questions.map { question -> UserInputQuestion in
            let id = question.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let header = question.header.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = question.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= 64, questionIDs.insert(id).inserted else {
                throw AgentFailure(message: "模型返回了空白或重复的问题标识。")
            }
            guard !header.isEmpty, header.count <= 24,
                  !prompt.isEmpty, prompt.count <= 1_000 else {
                throw AgentFailure(message: "模型返回的问题标题或内容无效。")
            }
            guard question.options.isEmpty || (2...3).contains(question.options.count) else {
                throw AgentFailure(message: "每个选择题必须提供 2 到 3 个选项。")
            }

            var optionLabels = Set<String>()
            let options = try question.options.enumerated().map { index, option -> UserInputOption in
                let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let description = option.description.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, label.count <= 80,
                      description.count <= 240,
                      optionLabels.insert(label).inserted else {
                    throw AgentFailure(message: "模型返回了空白、重复或过长的选项。")
                }
                return UserInputOption(
                    id: "\(id)-\(index)",
                    label: label,
                    description: description.isEmpty ? nil : description
                )
            }
            return UserInputQuestion(
                id: id,
                header: header,
                question: prompt,
                options: options,
                allowsOther: question.allowsOther,
                isSensitive: false
            )
        }
        return UserInputRequest(
            id: UserInputRequestID(rawValue: UUID().uuidString),
            runID: runID,
            questions: questions
        )
    }

    private static func validate(
        answers: [UserInputAnswer],
        for request: UserInputRequest
    ) throws {
        let questionIDs = Set(request.questions.map(\.id))
        guard answers.count == request.questions.count,
              Set(answers.map(\.questionID)) == questionIDs,
              Set(answers.map(\.questionID)).count == answers.count else {
            throw AgentFailure(message: "请完整回答当前请求中的所有问题。")
        }

        for answer in answers {
            guard answer.answers.count == 1,
                  let value = answer.answers.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  value.count <= 2_000,
                  let question = request.questions.first(where: { $0.id == answer.questionID }) else {
                throw AgentFailure(message: "每个问题都需要一个有效答案。")
            }
            if !question.options.isEmpty,
               !question.options.contains(where: { $0.label == value }),
               !question.allowsOther {
                throw AgentFailure(message: "答案不在当前问题允许的选项中。")
            }
        }
    }

    private static func encodeUserInputResult(_ answers: [UserInputAnswer]) throws -> String {
        let payload = UserInputResult(answers: answers.map {
            UserInputResult.Answer(questionID: $0.questionID, answers: $0.answers)
        })
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard let value = String(data: data, encoding: .utf8) else {
            throw AgentFailure(message: "无法编码用户答案。")
        }
        return value
    }

    private static func encodeToolExecutionResult(_ result: ToolExecutionResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        guard let value = String(data: data, encoding: .utf8) else {
            throw AgentFailure(message: "无法编码工具执行结果。")
        }
        return value
    }
}
