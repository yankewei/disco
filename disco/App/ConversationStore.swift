import Combine
import Foundation

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?
    /// 最近一次上下文占用快照（服务商返回或本地估算）。
    @Published private(set) var contextUsage: ContextUsageSnapshot?
    /// 最近一次成功的压缩记录（面板展示用）。
    @Published private(set) var lastSuccessfulCompaction: ContextCompactionSnapshot?
    /// 当前进行中的压缩记录；nil 表示没有压缩在跑。
    @Published private(set) var activeCompaction: ContextCompactionSnapshot?

    private var runtime: (any AgentRuntime)?
    private var requestTask: Task<Void, Never>?
    private var compactionTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var activeRunID: RunID?
    private let onMessagesChanged: ([ChatMessage], String?, ConversationContextState) -> Void
    /// 订阅服务商（ChatGPT/Codex）的会话线程 id；其余服务商为 nil。
    /// 是持久化的单一来源：更新后立即通过 onMessagesChanged 落盘。
    private(set) var threadID: String?
    /// Generic 压缩 checkpoint 与最近一次成功压缩；随每次持久化回调落盘。
    private(set) var contextState: ConversationContextState

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
        runtime != nil
            && !isStreaming
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

    /// 更新订阅会话的线程 id（CodexRuntime 首次运行时回调）。
    /// 立即持久化，保证重启后能 thread/resume 续接上下文。
    func updateThreadID(_ id: String) {
        guard threadID != id else { return }
        threadID = id
        persistImmediately()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let runtime, !text.isEmpty, !isStreaming else { return }

        draft = ""
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: text))

        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant))
        schedulePersistence()

        let requestMessages = Array(messages.dropLast())
        let runID = RunID()
        activeRunID = runID
        isStreaming = true

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
                    handle(event, assistantID: assistantID)
                }
            } catch {
                guard !Task.isCancelled, activeRunID == runID else { return }
                errorMessage = "对话中断：\(error.localizedDescription)"
                removeEmptyPlaceholder(assistantID)
            }

            finishRun(runID)
        }
    }

    private func handle(_ event: AgentEvent, assistantID: UUID) {
        switch event {
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
        case let .runFailed(_, failure):
            errorMessage = failure.message
            removeEmptyPlaceholder(assistantID)
        case .runCompleted, .runCancelled:
            break
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
        isStreaming = false
        requestTask = nil
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
        persistImmediately()
    }

    func dismissError() {
        errorMessage = nil
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
        requestTask?.cancel()
        requestTask = nil
        if let runID = activeRunID {
            activeRunID = nil
            let runtime = runtime
            Task { await runtime?.cancel(runID: runID) }
        }
        isStreaming = false
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
