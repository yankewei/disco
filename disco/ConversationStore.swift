import Combine
import Foundation

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?

    private var provider: AIProvider?
    private var requestTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private let onMessagesChanged: ([ChatMessage]) -> Void

    init(
        messages: [ChatMessage] = [],
        onMessagesChanged: @escaping ([ChatMessage]) -> Void = { _ in }
    ) {
        self.messages = messages
        self.onMessagesChanged = onMessagesChanged
    }

    var canSend: Bool {
        provider != nil && !isStreaming && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRetry: Bool {
        !isStreaming && errorMessage != nil && messages.last?.role == .user
    }

    func configure(provider: AIProvider?) {
        self.provider = provider
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let provider, !text.isEmpty, !isStreaming else { return }

        draft = ""
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: text))

        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, text: ""))
        schedulePersistence()

        let requestMessages = Array(messages.dropLast())
        let requestID = UUID()
        activeRequestID = requestID
        isStreaming = true

        requestTask = Task { [weak self] in
            guard let self else { return }

            do {
                for try await event in provider.stream(messages: requestMessages) {
                    guard !Task.isCancelled, activeRequestID == requestID else { return }
                    if case let .textDelta(delta) = event,
                       let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[index].text += delta
                        schedulePersistence()
                    }
                }

                guard let index = messages.firstIndex(where: { $0.id == assistantID }),
                      !messages[index].text.isEmpty else {
                    throw OpenAIProviderError.noTextOutput
                }
            } catch {
                guard !Task.isCancelled, activeRequestID == requestID else { return }
                errorMessage = error.localizedDescription
                if let index = messages.firstIndex(where: { $0.id == assistantID }),
                   messages[index].text.isEmpty {
                    messages.remove(at: index)
                }
            }

            persistImmediately()

            if activeRequestID == requestID {
                activeRequestID = nil
                isStreaming = false
                requestTask = nil
            }
        }
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
        activeRequestID = nil
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
