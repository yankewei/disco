import Combine
import Foundation

enum UserInteractionStatus: Equatable {
    case pending
    case submitting
    case resolved(String)
    case failed(String)
    case cancelled
}

struct UserInteractionRecord: Identifiable, Equatable {
    let interaction: PendingUserInteraction
    var status: UserInteractionStatus

    var id: PendingUserInteraction.ID { interaction.id }
}

struct UserInputDraft: Equatable {
    var values: [String: String] = [:]
    var customQuestionIDs: Set<String> = []
}

/// 工具执行在 UI 时间线中的展示模型。
struct ToolExecutionDisplay: Identifiable, Equatable {
    let id: String  // toolCallId
    let toolName: String
    let arguments: String
    var output: String?
    var isCompleted: Bool = false
}

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published private(set) var runState: AgentRunState = .idle
    @Published private(set) var errorMessage: String?
    /// 仅驻留内存的交互记录；不进入 ChatMessage 或持久化回调。
    @Published private(set) var interactionRecords: [UserInteractionRecord] = []
    /// 表单草稿按 request ID 保存，切换会话不会丢失；运行终止时清空。
    @Published private(set) var userInputDrafts: [UserInputRequestID: UserInputDraft] = [:]
    /// 最近一次上下文占用快照（服务商返回或本地估算）。
    @Published private(set) var contextUsage: ContextUsageSnapshot?
    /// 最近一次成功的压缩记录（面板展示用）。
    @Published private(set) var lastSuccessfulCompaction: ContextCompactionSnapshot?
    /// 当前进行中的压缩记录；nil 表示没有压缩在跑。
    @Published private(set) var activeCompaction: ContextCompactionSnapshot?
    /// 当前待处理的守护进程审批请求；nil 表示无审批等待。
    @Published var pendingApproval: DaemonApprovalRequestedData?
    /// 当前运行中活跃/已完成的工具执行记录（守护进程路径）。
    @Published private(set) var toolExecutions: [ToolExecutionDisplay] = []

    /// daemon 运行边界；只有成功注册了 daemon session 的会话才启用。
    private var daemonClient: (any DiscoDaemonClient)?
    private var daemonSessionID: UUID?
    private var daemonRunsEnabled = false
    private var daemonRunID: UUID?
    private var daemonAssistantID: UUID?
    private var daemonCancellationRequested = false
    private var daemonCancelSent = false
    private var clearAfterDaemonRun = false
    private var isClearingDaemonSession = false

    private var runtime: (any AgentRuntime)?
    private var requestTask: Task<Void, Never>?
    /// 发送前的同步占位标志：防止同一次视图更新内重复点击触发两次发送
    /// （状态突变已延迟到下一个 run loop，详见 send()）。
    private var isSendStarting = false
    private var compactionTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var activeRunID: RunID?
    private let onMessagesChanged: ([ChatMessage], String?, ConversationContextState) -> Void
    /// 订阅服务商（ChatGPT/Codex）的会话线程 id；其余服务商为 nil。
    /// 是持久化的单一来源：更新后立即通过 onMessagesChanged 落盘。
    private(set) var threadID: String?
    /// Generic 压缩 checkpoint 与最近一次成功压缩；随每次持久化回调落盘。
    private(set) var contextState: ConversationContextState

    var hasRuntime: Bool {
        if daemonSessionID != nil {
            return daemonRunsEnabled && daemonClient != nil
        }
        return runtime != nil
    }
    var hasDaemonSession: Bool { daemonSessionID != nil }
    var isStreaming: Bool { runState.isActive }

    var firstPendingInteraction: PendingUserInteraction? {
        interactionRecords.first { record in
            switch record.status {
            case .pending, .failed: true
            case .submitting, .resolved, .cancelled: false
            }
        }?.interaction
    }

    var runStatusText: String? {
        switch runState {
        case .connecting: "正在连接"
        case .running: "回复生成中"
        case .waitingForTool: "正在等待工具"
        case .waitingForApproval: "等待你确认操作"
        case .waitingForUserInput: "等待你的回答"
        case .cancelling: "正在停止"
        case .idle, .completed, .failed, .cancelled: nil
        }
    }

    init(
        messages: [ChatMessage] = [],
        threadID: String? = nil,
        contextState: ConversationContextState = ConversationContextState(),
        onMessagesChanged: @escaping ([ChatMessage], String?, ConversationContextState) -> Void = { _, _, _ in }
    ) {
        self.messages = messages
        self.threadID = threadID
        self.contextState = contextState
        self.lastSuccessfulCompaction = contextState.lastSuccessfulCompaction
        self.onMessagesChanged = onMessagesChanged
    }

    /// 兼容上下文压缩前的测试/调用方回调签名。
    convenience init(
        messages: [ChatMessage] = [],
        threadID: String? = nil,
        onMessagesChanged: @escaping ([ChatMessage], String?) -> Void
    ) {
        self.init(
            messages: messages,
            threadID: threadID,
            onMessagesChanged: { messages, threadID, _ in
                onMessagesChanged(messages, threadID)
            }
        )
    }

    var canSend: Bool {
        hasRuntime
            && !isStreaming
            && !isClearingDaemonSession
            && compactionTask == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canCompactContext: Bool {
        guard let runtime, !isStreaming, compactionTask == nil else { return false }
        if runtime is CodexRuntime {
            return threadID != nil
        }
        let userCount = messages.lazy.filter { $0.role == .user }.count
        return userCount >= ContextCompactor.minimumUserTurnsForManualCompaction
            && ContextCompactor.compressiblePrefix(
                messages: messages,
                afterBoundary: contextState.checkpoint,
                preservedUserTurns: ContextCompactor.preservedUserTurns
            ) != nil
    }

    /// 仅用于发送前 UI 提示的 checkpoint-aware 本地 token 粗略估算。
    var estimatedContextTokenCount: Int {
        let visibleMessages: [ChatMessage]
        if let checkpoint = contextState.checkpoint,
           let boundary = messages.firstIndex(where: { $0.id == checkpoint.boundaryMessageID }),
           ContextCompactor.sourceDigest(forMessagesPrefix: Array(messages[...boundary]))
                == checkpoint.sourceDigest {
            visibleMessages = [
                ChatMessage(role: .user, text: ContextCompactor.summaryMarkerText),
                ChatMessage(role: .assistant, text: checkpoint.summary),
            ] + Array(messages.dropFirst(boundary + 1))
        } else {
            visibleMessages = messages
        }
        return TokenEstimator.estimatedTokenCount(forMessages: visibleMessages)
            + TokenEstimator.estimatedTokenCount(
                for: draft.trimmingCharacters(in: .whitespacesAndNewlines)
            )
    }

    var canRetry: Bool {
        guard !isStreaming, errorMessage != nil, let last = messages.last else { return false }
        if last.role == .user { return true }
        return last.role == .assistant
            && messages.dropLast().last?.role == .user
    }

    var canRegenerateLastResponse: Bool {
        guard runtime != nil, !isStreaming, messages.count >= 2 else { return false }
        return messages[messages.count - 1].role == .assistant
            && messages[messages.count - 2].role == .user
    }

    /// 替换运行时，返回旧的运行时（供调用方释放资源，如终止 codex 子进程）。
    @discardableResult
    func configure(runtime: (any AgentRuntime)?) -> (any AgentRuntime)? {
        let oldRuntime = self.runtime
        self.runtime = runtime
        return oldRuntime
    }

    /// 设置守护进程客户端引用；注册 session 后再单独启用 daemon 运行。
    func configure(daemonClient: (any DiscoDaemonClient)?) {
        self.daemonClient = daemonClient
    }

    func enableDaemonRuns(sessionID: UUID) {
        daemonSessionID = sessionID
        daemonRunsEnabled = true
    }

    func disableDaemonRuns() {
        daemonRunsEnabled = false
    }

    /// daemon 连接中断后结束当前远端运行；已注册会话等待重连，不切换运行来源。
    func handleDaemonDisconnection(_ message: String) {
        disableDaemonRuns()
        guard let assistantID = daemonAssistantID else { return }
        errorMessage = message
        runState = .failed
        cancelPendingInteractions()
        removeEmptyPlaceholder(assistantID)
        finishDaemonRun()
    }

    /// 更新订阅会话的线程 id（CodexRuntime 首次运行时回调）。
    /// 立即持久化，保证重启后能 thread/resume 续接上下文。
    func updateThreadID(_ id: String) {
        guard threadID != id else { return }
        threadID = id
        persistImmediately()
    }

    /// 发送消息。
    ///
    /// 状态突变延迟到下一个 MainActor run loop 执行，避免在输入框/按钮事件
    /// 触发的视图更新事务内同步发布（SwiftUI 运行时警告
    /// "Publishing changes from within view updates"）。
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend, !isSendStarting else { return }
        isSendStarting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSendStarting = false }
            guard !self.isStreaming else { return }
            if let sessionID = self.daemonSessionID {
                guard self.daemonRunsEnabled, let client = self.daemonClient else { return }
                self.startDaemonRun(text: text, sessionID: sessionID, client: client)
            } else if let runtime = self.runtime {
                self.startRun(text: text, runtime: runtime)
            }
        }
    }

    private func startDaemonRun(
        text: String,
        sessionID: UUID,
        client: any DiscoDaemonClient
    ) {
        interactionRecords.removeAll { record in
            switch record.status {
            case .resolved, .cancelled: true
            case .pending, .submitting, .failed: false
            }
        }
        draft = ""
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: text))

        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant))
        schedulePersistence()

        activeRunID = UUID()
        daemonRunID = nil
        daemonAssistantID = assistantID
        daemonCancellationRequested = false
        daemonCancelSent = false
        runState = .connecting

        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let runID = try await client.startRun(sessionID: sessionID, text: text)
                guard daemonAssistantID == assistantID else {
                    try? await client.cancelRun(runID: runID)
                    return
                }
                daemonRunID = runID
                activeRunID = runID
                sendDaemonCancellationIfPossible()
            } catch {
                guard daemonAssistantID == assistantID else { return }
                errorMessage = "无法启动 daemon 运行：\(error.localizedDescription)"
                runState = .failed
                removeEmptyPlaceholder(assistantID)
                finishDaemonRun()
            }
        }
    }

    private func startRun(text: String, runtime: any AgentRuntime) {
        interactionRecords.removeAll { record in
            switch record.status {
            case .resolved, .cancelled: true
            case .pending, .submitting, .failed: false
            }
        }
        draft = ""
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: text))

        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant))
        schedulePersistence()

        let requestMessages = Array(messages.dropLast())
        let runID = RunID()
        activeRunID = runID
        runState = .connecting

        requestTask = Task { [weak self] in
            guard let self else { return }

            do {
                for try await event in runtime.start(
                    request: AgentRunRequest(
                        runID: runID,
                        messages: requestMessages,
                        resumeThreadID: self.threadID,
                        contextCheckpoint: self.contextState.checkpoint
                    )
                ) {
                    guard !Task.isCancelled, activeRunID == runID else { return }
                    // 让状态发布发生在全新的 MainActor job 中，避免在
                    // 视图更新事务内同步修改被观察状态。
                    await Task.yield()
                    handle(event, assistantID: assistantID)
                }
            } catch {
                guard !Task.isCancelled, activeRunID == runID else { return }
                errorMessage = "对话中断：\(error.localizedDescription)"
                runState = .failed
                removeEmptyPlaceholder(assistantID)
            }

            finishRun(runID)
        }
    }

    private func handle(_ event: AgentEvent, assistantID: UUID) {
        switch event {
        case let .runStateChanged(_, state):
            runState = state
        case let .messageDelta(delta):
            guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
            messages[index].appendText(delta)
            schedulePersistence()
        case let .reasoningDelta(delta):
            guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
            messages[index].appendReasoning(delta)
            schedulePersistence()
        case let .hostedToolUpdated(snapshot):
            guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
            messages[index].upsertHostedTool(snapshot)
            schedulePersistence()
        case let .citationAdded(citation):
            guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
            messages[index].appendCitation(citation)
            schedulePersistence()
        case let .contextUsageUpdated(snapshot):
            contextUsage = snapshot
        case let .contextCompactionUpdated(update):
            handleCompactionUpdate(update)
        case let .approvalRequested(request):
            appendInteraction(.approval(request))
        case let .approvalResolved(id, decision):
            resolveInteraction(.approval(id), summary: Self.approvalSummary(decision))
        case let .userInputRequested(request):
            appendInteraction(.userInput(request))
            if userInputDrafts[request.id] == nil {
                userInputDrafts[request.id] = UserInputDraft()
            }
        case let .userInputResolved(id):
            resolveInteraction(.userInput(id), summary: "已回答")
            userInputDrafts[id] = nil
        case let .runFailed(_, failure):
            errorMessage = failure.message
            runState = .failed
            cancelPendingInteractions()
            removeEmptyPlaceholder(assistantID)
        case .runCompleted:
            runState = .completed
        case .runCancelled:
            runState = .cancelled
            cancelPendingInteractions()
        }
    }

    // MARK: - 守护进程事件处理

    /// 处理守护进程推送的事件，映射到与 AgentEvent 相同的内部状态变更。
    ///
    /// 当运行通过守护进程路由时（`useDaemon == true`），事件流来自守护进程通知
    /// 而非本地 AgentRuntime。此方法将守护进程事件翻译为与 `handle(_:assistantID:)`
    /// 等价的状态更新，确保 UI 层无需区分数据来源。
    func handleDaemonNotification(_ event: DaemonEvent) {
        guard let assistantID = daemonAssistantID else { return }
        if let runID = event.runID {
            daemonRunID = runID
            activeRunID = runID
            sendDaemonCancellationIfPossible()
        }
        switch event.eventName {
        case "message.delta":
            guard let data = try? event.decoded(as: DaemonMessageDeltaData.self) else { return }
            guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
            messages[index].appendText(data.delta)
            schedulePersistence()

        case "reasoning.delta":
            guard let data = try? event.decoded(as: DaemonReasoningDeltaData.self) else { return }
            guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
            messages[index].appendReasoning(data.delta)
            schedulePersistence()

        case "context.usage":
            guard let data = try? event.decoded(as: DaemonContextUsageData.self) else { return }
            let currentUsage = TokenUsageSnapshot(
                inputTokens: data.current.input,
                cachedInputTokens: data.current.cachedInput,
                outputTokens: data.current.output,
                reasoningOutputTokens: data.current.reasoningOutput,
                totalTokens: data.current.total
            )
            let accumulatedUsage: TokenUsageSnapshot?
            if let accumulated = data.accumulated {
                accumulatedUsage = TokenUsageSnapshot(
                    inputTokens: accumulated.input,
                    cachedInputTokens: accumulated.cachedInput,
                    outputTokens: accumulated.output,
                    reasoningOutputTokens: accumulated.reasoningOutput,
                    totalTokens: accumulated.total
                )
            } else {
                accumulatedUsage = nil
            }
            let source: ContextUsageSnapshot.Source
            switch data.source {
            case "codex": source = .codex
            case "estimate": source = .estimate
            default: source = .provider
            }
            contextUsage = ContextUsageSnapshot(
                current: currentUsage,
                accumulated: accumulatedUsage,
                contextWindow: data.contextWindow,
                source: source
            )

        case "context.compaction":
            guard let data = try? event.decoded(as: DaemonContextCompactionData.self) else { return }
            let runtimeKind: RuntimeKind = data.runtimeKind == "codex" ? .codex : .generic
            let trigger: ContextCompactionSnapshot.Trigger
            switch data.trigger {
            case "automatic": trigger = .automatic
            case "overflow_recovery": trigger = .overflowRecovery
            default: trigger = .manual
            }
            let status: ContextCompactionSnapshot.Status
            switch data.status {
            case "running": status = .running
            case "completed": status = .completed
            default: status = .failed
            }
            let snapshot = ContextCompactionSnapshot(
                id: data.id,
                runtimeKind: runtimeKind,
                trigger: trigger,
                status: status,
                startedAt: Date.now,
                completedAt: status != .running ? Date.now : nil,
                beforeTokens: data.beforeTokens,
                afterTokens: data.afterTokens
            )
            let update = ContextCompactionUpdate(snapshot: snapshot)
            handleCompactionUpdate(update)

        case "run.state":
            guard let data = try? event.decoded(as: DaemonRunStateData.self) else { return }
            switch data.state {
            case "connecting": runState = .connecting
            case "running": runState = .running
            case "waiting_for_tool": runState = .waitingForTool
            case "waiting_for_approval": runState = .waitingForApproval
            case "waiting_for_user_input": runState = .waitingForUserInput
            case "cancelling": runState = .cancelling
            default: break
            }

        case "run.completed":
            runState = .completed
            finishDaemonRun()

        case "run.failed":
            if let data = try? event.decoded(as: DaemonRunFailedData.self) {
                errorMessage = data.error.message
            } else {
                errorMessage = "运行失败。"
            }
            runState = .failed
            cancelPendingInteractions()
            removeEmptyPlaceholder(assistantID)
            finishDaemonRun()

        case "run.cancelled":
            runState = .cancelled
            cancelPendingInteractions()
            finishDaemonRun()

        // MARK: - 工具执行事件

        case "tool.started":
            guard let data = try? event.decoded(as: DaemonToolStartedData.self) else { return }
            let execution = ToolExecutionDisplay(
                id: data.toolCallId,
                toolName: data.toolName,
                arguments: data.arguments
            )
            toolExecutions.append(execution)

        case "tool.completed":
            guard let data = try? event.decoded(as: DaemonToolCompletedData.self) else { return }
            if let index = toolExecutions.firstIndex(where: { $0.id == data.toolCallId }) {
                toolExecutions[index].output = data.output
                toolExecutions[index].isCompleted = true
            } else {
                // 可能错过了 started 事件，直接添加已完成记录
                let execution = ToolExecutionDisplay(
                    id: data.toolCallId,
                    toolName: data.toolName,
                    arguments: "",
                    output: data.output,
                    isCompleted: true
                )
                toolExecutions.append(execution)
            }

        // MARK: - 审批事件

        case "approval.requested":
            guard let data = try? event.decoded(as: DaemonApprovalRequestedData.self) else { return }
            pendingApproval = data
            runState = .waitingForApproval

        case "approval.resolved":
            guard let data = try? event.decoded(as: DaemonApprovalResolvedData.self) else { return }
            if pendingApproval?.approvalId == data.approvalId {
                pendingApproval = nil
            }

        default:
            break
        }
    }

    private func appendInteraction(_ interaction: PendingUserInteraction) {
        guard !interactionRecords.contains(where: { $0.id == interaction.id }) else { return }
        interactionRecords.append(UserInteractionRecord(
            interaction: interaction,
            status: .pending
        ))
    }

    private func resolveInteraction(
        _ id: PendingUserInteraction.ID,
        summary: String
    ) {
        guard let index = interactionRecords.firstIndex(where: { $0.id == id }) else { return }
        interactionRecords[index].status = .resolved(summary)
    }

    private static func approvalSummary(_ decision: ApprovalDecision) -> String {
        switch decision {
        case .approveOnce: "已允许一次"
        case .approveForSession: "已在本次会话允许"
        case .decline: "已拒绝"
        }
    }

    private func removeEmptyPlaceholder(_ assistantID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }),
              messages[index].isEmpty else { return }
        messages.remove(at: index)
    }

    /// 压缩状态更新：进行中覆盖 activeCompaction；成功时更新 checkpoint 并立即落盘。
    /// 失败的压缩不覆盖上一个有效 checkpoint / 成功记录（计划 §2）。
    private func handleCompactionUpdate(_ update: ContextCompactionUpdate) {
        switch update.snapshot.status {
        case .running:
            activeCompaction = update.snapshot
        case .completed:
            activeCompaction = nil
            lastSuccessfulCompaction = update.snapshot
            contextState.lastSuccessfulCompaction = update.snapshot
            if let checkpoint = update.checkpoint {
                contextState.checkpoint = checkpoint
            }
            persistImmediately()
        case .failed:
            activeCompaction = nil
        }
    }

    private func finishRun(_ runID: RunID) {
        guard activeRunID == runID else { return }
        persistImmediately()
        activeRunID = nil
        requestTask = nil
        toolExecutions.removeAll()
    }

    private func finishDaemonRun() {
        let shouldClear = clearAfterDaemonRun
        let sessionIDToClear = daemonSessionID
        persistImmediately()
        activeRunID = nil
        daemonRunID = nil
        daemonAssistantID = nil
        daemonCancellationRequested = false
        daemonCancelSent = false
        clearAfterDaemonRun = false
        requestTask = nil
        toolExecutions.removeAll()
        if shouldClear, let sessionIDToClear {
            clearDaemonSessionAndLocalHistory(sessionIDToClear)
        }
    }

    func stop() {
        let hadActiveRequest = requestTask != nil || isStreaming
        cancelRequest()
        cancelCompaction()

        var removedPlaceholder = false
        if let last = messages.last, last.role == .assistant, last.isEmpty {
            messages.removeLast()
            removedPlaceholder = true
        }
        if hadActiveRequest || removedPlaceholder {
            persistImmediately()
        }
    }

    func clear() {
        if let daemonSessionID {
            if daemonAssistantID != nil {
                clearAfterDaemonRun = true
                cancelRequest()
            } else {
                clearDaemonSessionAndLocalHistory(daemonSessionID)
            }
            return
        }
        clearLocalHistory()
    }

    private func clearLocalHistory() {
        cancelRequest()
        cancelCompaction()
        messages.removeAll()
        // 清空本地对话也意味着开始新的 Codex 上下文，不能让下一条消息
        // 继续复用旧的 app-server thread。
        threadID = nil
        errorMessage = nil
        // 清空会话同时清空 checkpoint、最近压缩记录和 usage（计划 §2）
        contextState = ConversationContextState()
        contextUsage = nil
        lastSuccessfulCompaction = nil
        activeCompaction = nil
        interactionRecords.removeAll()
        userInputDrafts.removeAll()
        pendingApproval = nil
        toolExecutions.removeAll()
        runState = .idle
        persistImmediately()
    }

    private func clearDaemonSessionAndLocalHistory(_ sessionID: UUID) {
        guard !isClearingDaemonSession, let daemonClient else { return }
        isClearingDaemonSession = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await daemonClient.deleteSession(sessionID: sessionID)
                isClearingDaemonSession = false
                guard daemonSessionID == sessionID else { return }
                daemonRunsEnabled = false
                daemonSessionID = nil
                clearLocalHistory()
            } catch {
                isClearingDaemonSession = false
                errorMessage = "无法清理 daemon 会话，本地历史已保留：\(error.localizedDescription)"
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func updateUserInput(
        requestID: UserInputRequestID,
        questionID: String,
        value: String,
        isCustom: Bool
    ) {
        guard case let .userInput(request)? = interactionRecords.first(
            where: { $0.id == .userInput(requestID) }
        )?.interaction,
              request.questions.contains(where: { $0.id == questionID }) else { return }
        var draft = userInputDrafts[requestID] ?? UserInputDraft()
        draft.values[questionID] = value
        if isCustom {
            draft.customQuestionIDs.insert(questionID)
        } else {
            draft.customQuestionIDs.remove(questionID)
        }
        userInputDrafts[requestID] = draft
    }

    func canSubmitUserInput(_ request: UserInputRequest) -> Bool {
        guard let draft = userInputDrafts[request.id] else { return false }
        return request.questions.allSatisfy { question in
            guard let value = draft.values[question.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return false }
            if question.options.isEmpty || draft.customQuestionIDs.contains(question.id) {
                return true
            }
            return question.options.contains(where: { $0.label == value })
        }
    }

    func submitUserInput(_ request: UserInputRequest) {
        guard let runtime,
              canSubmitUserInput(request),
              let index = interactionRecords.firstIndex(where: {
                  $0.id == .userInput(request.id)
              }),
              interactionRecords[index].status != .submitting,
              let draft = userInputDrafts[request.id] else { return }

        let answers = request.questions.map {
            UserInputAnswer(
                questionID: $0.id,
                answers: [draft.values[$0.id]?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""]
            )
        }
        interactionRecords[index].status = .submitting
        errorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.submitUserInput(requestID: request.id, answers: answers)
            } catch {
                guard let index = interactionRecords.firstIndex(where: {
                    $0.id == .userInput(request.id)
                }) else { return }
                interactionRecords[index].status = .failed(error.localizedDescription)
            }
        }
    }

    func decideApproval(_ request: ApprovalRequest, decision: ApprovalDecision) {
        guard let runtime,
              let index = interactionRecords.firstIndex(where: {
                  $0.id == .approval(request.id)
              }),
              interactionRecords[index].status != .submitting else { return }
        interactionRecords[index].status = .submitting
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.respond(to: request.id, decision: decision)
            } catch {
                guard let index = interactionRecords.firstIndex(where: {
                    $0.id == .approval(request.id)
                }) else { return }
                interactionRecords[index].status = .failed(error.localizedDescription)
            }
        }
    }

    /// 响应守护进程路径的审批请求。
    ///
    func respondToApproval(decision: String) {
        guard let approval = pendingApproval else { return }
        pendingApproval = nil
        guard let client = daemonClient,
              let approvalUUID = UUID(uuidString: approval.approvalId) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.approve(approvalID: approvalUUID, decision: decision)
            } catch {
                guard daemonAssistantID != nil else { return }
                pendingApproval = approval
                runState = .waitingForApproval
                errorMessage = "无法提交审批结果：\(error.localizedDescription)"
            }
        }
    }

    func retryLastMessage() {
        guard canRetry, let lastMessage = messages.last else { return }
        if lastMessage.role == .assistant {
            messages.removeLast()
            guard let userMessage = messages.popLast(), userMessage.role == .user else { return }
            draft = userMessage.text
        } else {
            messages.removeLast()
            draft = lastMessage.text
        }
        send()
    }

    /// 丢弃最后一轮回答，使用同一条用户消息重新运行。
    func regenerateLastResponse() {
        guard canRegenerateLastResponse else { return }
        messages.removeLast()
        let userMessage = messages.removeLast()
        draft = userMessage.text
        send()
    }

    /// 手动压缩当前会话；不创建聊天占位消息。
    func compactContext() {
        guard canCompactContext, let runtime else { return }
        compactionTask?.cancel()
        let startedAt = Date.now
        let running = ContextCompactionSnapshot(
            id: UUID().uuidString,
            runtimeKind: appRuntimeKind,
            trigger: .manual,
            status: .running,
            startedAt: startedAt
        )
        activeCompaction = running
        let request = ContextCompactionRequest(
            messages: messages,
            resumeThreadID: threadID,
            contextCheckpoint: contextState.checkpoint
        )
        compactionTask = Task { [weak self] in
            guard let self else { return }
            defer { compactionTask = nil }

            do {
                let update = try await runtime.compactContext(request: request)
                guard !Task.isCancelled else { return }
                handleCompactionUpdate(update)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                activeCompaction = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private var appRuntimeKind: RuntimeKind {
        runtime is CodexRuntime ? .codex : .generic
    }

    private func cancelCompaction() {
        compactionTask?.cancel()
        compactionTask = nil
        activeCompaction = nil
    }

    private func cancelRequest() {
        if daemonAssistantID != nil {
            guard isStreaming else { return }
            runState = .cancelling
            daemonCancellationRequested = true
            sendDaemonCancellationIfPossible()
            cancelPendingInteractions()
            return
        }
        if isStreaming {
            runState = .cancelling
        }
        requestTask?.cancel()
        requestTask = nil
        if let runID = activeRunID {
            activeRunID = nil
            let runtime = runtime
            Task { await runtime?.cancel(runID: runID) }
        }
        cancelPendingInteractions()
        runState = .cancelled
    }

    private func sendDaemonCancellationIfPossible() {
        guard daemonCancellationRequested,
              !daemonCancelSent,
              let client = daemonClient,
              let runID = daemonRunID else { return }
        daemonCancelSent = true
        Task {
            try? await client.cancelRun(runID: runID)
        }
    }

    private func cancelPendingInteractions() {
        for index in interactionRecords.indices {
            switch interactionRecords[index].status {
            case .pending, .submitting, .failed:
                interactionRecords[index].status = .cancelled
            case .resolved, .cancelled:
                break
            }
        }
        userInputDrafts.removeAll()
        pendingApproval = nil
    }

    private func schedulePersistence() {
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            persistenceTask = nil
            onMessagesChanged(messages, threadID, contextState)
        }
    }

    private func persistImmediately() {
        persistenceTask?.cancel()
        persistenceTask = nil
        onMessagesChanged(messages, threadID, contextState)
    }
}
