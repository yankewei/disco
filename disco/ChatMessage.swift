import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

enum AIEvent: Sendable {
    case textDelta(String)
}

protocol AIProvider {
    func stream(messages: [ChatMessage]) -> AsyncThrowingStream<AIEvent, Error>
}
