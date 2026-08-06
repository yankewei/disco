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
    private let onMessagesChanged: ([ChatMessage]) -> Void

    init(
        messages: [ChatMessage] = [],
        onMessagesChanged: @escaping ([ChatMessage]) -> Void = { _ in }
    ) {
        self.messages = messages
        self.onMessagesChanged = onMessagesChanged
    }

    var canSend: Bool {
        runtime != nil && !isStreaming && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRetry: Bool {
        !isStreaming && errorMessage != nil && messages.last?.role == .user
    }

    func configure(runtime: (any AgentRuntime)?) {
        self.runtime = runtime
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
                    request: AgentRunRequest(runID: runID, messages: requestMessages)
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
        case let .runFailed(_, failure):
            errorMessage = failure.message
            removeEmptyPlaceholder(assistantID)
        case .reasoningDelta, .runCompleted, .runCancelled:
            break
        }
    }

    private func removeEmptyPlaceholder(_ assistantID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }),
              messages[index].text.isEmpty else { return }
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
        if let last = messages.last, last.role == .assistant, last.text.isEmpty {
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
        errorMessage = nil
        persistImmediately()
    }

    func dismissError() {
        errorMessage = nil
    }

    func retryLastMessage() {
        guard canRetry, let lastMessage = messages.last else { return }
        messages.removeLast()
        draft = lastMessage.text
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
            onMessagesChanged(messages)
        }
    }

    private func persistImmediately() {
        persistenceTask?.cancel()
        persistenceTask = nil
        onMessagesChanged(messages)
    }
}
