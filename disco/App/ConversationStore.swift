import Combine
import Foundation

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published private(set) var runState: AgentRunState = .idle
    @Published private(set) var errorMessage: String?
    /// 最近一次上下文占用快照（daemon 上报）。
    @Published private(set) var contextUsage: ContextUsageSnapshot?
    /// 最近一次成功的压缩记录（面板展示用）。
    @Published private(set) var lastSuccessfulCompaction: ContextCompactionSnapshot?
    /// 当前进行中的压缩记录；nil 表示没有压缩在跑。
    @Published private(set) var activeCompaction: ContextCompactionSnapshot?
    /// 当前待处理的守护进程审批请求；nil 表示无审批等待。
    @Published var pendingApproval: DaemonApprovalRequestedData?
    /// daemon 运行边界；所有会话都由 daemon 托管，注册 session 后启用。
    private var daemonClient: (any DiscoDaemonClient)?
    private var daemonSessionID: UUID?
    private var daemonRunsEnabled = false
    private var daemonRunID: UUID?
    private var daemonAssistantID: UUID?
    private var daemonCancellationRequested = false
    private var daemonCancelSent = false
    private var clearAfterDaemonRun = false
    private var isClearingDaemonSession = false

    private var requestTask: Task<Void, Never>?
    /// 发送前的同步占位标志：防止同一次视图更新内重复点击触发两次发送
    /// （状态突变已延迟到下一个 run loop，详见 send()）。
    private var isSendStarting = false
    private var compactionTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var activeRunID: RunID?
    private let onMessagesChanged: ([ChatMessage], String?, ConversationContextState) -> Void
    /// 历史兼容字段：旧版订阅服务商会话的线程 id；daemon 路径不再写入。
    private(set) var threadID: String?
    /// 压缩状态（最近一次成功压缩）；随每次持久化回调落盘。
    private(set) var contextState: ConversationContextState
    /// 原生 Agent 的上下文由其自身维护；只有 Rig 本地链路允许手动请求压缩。
    @Published private(set) var compactionMode = "local"

    var hasRuntime: Bool {
        daemonRunsEnabled && daemonClient != nil && daemonSessionID != nil
    }
    var hasDaemonSession: Bool { daemonSessionID != nil }
    var isStreaming: Bool { runState.isActive }

    var runStatusText: String? {
        switch runState {
        case .connecting: "正在连接"
        case .running: "回复生成中"
        case .waitingForTool: "正在等待工具"
        case .waitingForApproval: "等待你确认操作"
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
        guard !isStreaming, compactionTask == nil else { return false }
        return compactionMode == "local"
            && daemonSessionID != nil
            && daemonClient != nil
            && messages.count >= 2
    }

    var usesNativeCompaction: Bool { compactionMode == "native" }

    var canRetry: Bool {
        guard !isStreaming, errorMessage != nil, let last = messages.last else { return false }
        if last.role == .user { return true }
        return last.role == .assistant
            && messages.dropLast().last?.role == .user
    }

    /// 设置守护进程客户端引用；注册 session 后再单独启用 daemon 运行。
    func configure(daemonClient: (any DiscoDaemonClient)?) {
        self.daemonClient = daemonClient
    }

    func setCompactionMode(_ mode: String?) {
        compactionMode = mode ?? "local"
    }

    func enableDaemonRuns(sessionID: UUID) {
        daemonSessionID = sessionID
        daemonRunsEnabled = true
    }

    func disableDaemonRuns() {
        daemonRunsEnabled = false
    }

    /// 撤销 daemon 会话注册：会话暂时无法运行（等待重新注册）。
    func revertDaemonRegistration() {
        daemonSessionID = nil
        daemonRunsEnabled = false
        daemonRunID = nil
        daemonAssistantID = nil
        notifyMessagesChanged()
    }

    /// 从 daemon 恢复权威消息，同时更新本地 rich transcript 缓存。
    func restoreMessages(_ restored: [ChatMessage]) {
        messages = restored
        notifyMessagesChanged()
    }

    /// daemon 连接中断后结束当前远端运行；已注册会话等待重连，不切换运行来源。
    func handleDaemonDisconnection(_ message: String) {
        disableDaemonRuns()
        guard let assistantID = daemonAssistantID else { return }
        errorMessage = message
        runState = .failed
        pendingApproval = nil
        removeEmptyPlaceholder(assistantID)
        finishDaemonRun()
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
            guard !self.isStreaming,
                  let sessionID = self.daemonSessionID,
                  self.daemonRunsEnabled,
                  let client = self.daemonClient else { return }
            self.startDaemonRun(text: text, sessionID: sessionID, client: client)
        }
    }

    private func startDaemonRun(
        text: String,
        sessionID: UUID,
        client: any DiscoDaemonClient
    ) {
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

    // MARK: - 守护进程事件处理

    /// 处理守护进程推送的事件，映射为会话状态变更。
    func handleDaemonNotification(_ event: DaemonEvent) {
        // 压缩事件与具体 run 解耦:run 结束后仍能更新压缩状态。
        if event.eventName == "context.compaction" {
            handleDaemonCompactionEvent(event)
            return
        }
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
            break

        case "run.state":
            guard let data = try? event.decoded(as: DaemonRunStateData.self) else { return }
            switch data.state {
            case "connecting": runState = .connecting
            case "running": runState = .running
            case "waiting_for_tool": runState = .waitingForTool
            case "waiting_for_approval": runState = .waitingForApproval
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
            pendingApproval = nil
            removeEmptyPlaceholder(assistantID)
            finishDaemonRun()

        case "run.cancelled":
            runState = .cancelled
            pendingApproval = nil
            finishDaemonRun()

        // MARK: - 工具执行事件

        case "tool.started":
            guard let data = try? event.decoded(as: DaemonToolStartedData.self) else { return }
            guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
            messages[index].upsertToolCall(
                ChatMessage.ToolCallSnapshot(
                    id: data.toolCallId,
                    name: data.toolName,
                    arguments: data.arguments,
                    kind: data.kind
                )
            )
            schedulePersistence()

        case "tool.completed":
            guard let data = try? event.decoded(as: DaemonToolCompletedData.self) else { return }
            guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
            let completedCall = ChatMessage.ToolCallSnapshot(
                id: data.toolCallId,
                name: data.toolName,
                arguments: "",
                kind: data.kind,
                status: .completed,
                output: data.output
            )
            if let callIndex = messages[index].parts.firstIndex(where: { part in
                guard case let .toolCall(call) = part else { return false }
                return call.id == data.toolCallId
            }), case var .toolCall(updatedCall) = messages[index].parts[callIndex] {
                updatedCall.status = .completed
                updatedCall.output = data.output
                messages[index].parts[callIndex] = .toolCall(updatedCall)
            } else {
                // 可能错过了 started 事件，直接添加已完成调用，保证时间线仍然可见。
                messages[index].upsertToolCall(completedCall)
            }
            schedulePersistence()

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

    private func handleDaemonCompactionEvent(_ event: DaemonEvent) {
        guard let data = try? event.decoded(as: DaemonContextCompactionData.self) else { return }
        let runtimeKind: RuntimeKind = data.runtimeKind.contains("codex") ? .codex : .generic
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
            afterTokens: data.afterTokens,
            summary: data.summary,
            errorMessage: data.errorMessage
        )
        handleCompactionUpdate(ContextCompactionUpdate(snapshot: snapshot))
    }

    private func removeEmptyPlaceholder(_ assistantID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }),
              messages[index].isEmpty else { return }
        messages.remove(at: index)
    }

    /// 压缩状态更新：进行中覆盖 activeCompaction；成功时更新记录并立即落盘。
    /// 失败的压缩不覆盖上一个成功记录。
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
        threadID = nil
        errorMessage = nil
        contextState = ConversationContextState()
        contextUsage = nil
        lastSuccessfulCompaction = nil
        activeCompaction = nil
        pendingApproval = nil
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

    /// 响应审批请求。
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

    /// 手动压缩当前会话；不创建聊天占位消息。
    /// daemon 托管会话的压缩状态更新统一来自事件流。
    func compactContext() {
        guard canCompactContext,
              let client = daemonClient,
              let sessionID = daemonSessionID else { return }
        compactionTask?.cancel()
        let startedAt = Date.now
        activeCompaction = ContextCompactionSnapshot(
            id: UUID().uuidString,
            runtimeKind: .generic,
            trigger: .manual,
            status: .running,
            startedAt: startedAt
        )
        compactionTask = Task { [weak self] in
            guard let self else { return }
            defer { compactionTask = nil }
            do {
                try await client.compactContext(sessionID: sessionID)
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

    private func cancelCompaction() {
        compactionTask?.cancel()
        compactionTask = nil
        activeCompaction = nil
    }

    private func cancelRequest() {
        requestTask?.cancel()
        requestTask = nil
        guard daemonAssistantID != nil, isStreaming else { return }
        runState = .cancelling
        daemonCancellationRequested = true
        sendDaemonCancellationIfPossible()
        pendingApproval = nil
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

    private func schedulePersistence() {
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            persistenceTask = nil
            notifyMessagesChanged()
        }
    }

    private func persistImmediately() {
        persistenceTask?.cancel()
        persistenceTask = nil
        notifyMessagesChanged()
    }

    /// 持久化回调：daemon session 仍保留本地 rich transcript 作为离线缓存和恢复兜底。
    private func notifyMessagesChanged() {
        onMessagesChanged(
            messages,
            threadID,
            contextState
        )
    }
}
