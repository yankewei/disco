import Combine
import Foundation

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?

    private var runtime: (any AgentRuntime)?
    private var requestTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var activeRunID: RunID?
    private let onMessagesChanged: ([ChatMessage], String?) -> Void
    /// 订阅服务商（ChatGPT/Codex）的会话线程 id；其余服务商为 nil。
    /// 是持久化的单一来源：更新后立即通过 onMessagesChanged 落盘。
    private(set) var threadID: String?

    init(
        messages: [ChatMessage] = [],
        threadID: String? = nil,
        onMessagesChanged: @escaping ([ChatMessage], String?) -> Void = { _, _ in }
    ) {
        self.messages = messages
        self.threadID = threadID
        self.onMessagesChanged = onMessagesChanged
    }

    var canSend: Bool {
        runtime != nil && !isStreaming && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                        resumeThreadID: self.threadID
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
        messages.removeAll()
        // 清空本地对话也意味着开始新的 Codex 上下文，不能让下一条消息
        // 继续复用旧的 app-server thread。
        threadID = nil
        errorMessage = nil
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
            onMessagesChanged(messages, threadID)
        }
    }

    private func persistImmediately() {
        persistenceTask?.cancel()
        persistenceTask = nil
        onMessagesChanged(messages, threadID)
    }
}
