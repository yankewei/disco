import Foundation

struct TimelineBuilder {
    private(set) var assistantText = ""
    private(set) var reasoning = ""
    private(set) var toolCalls: [ToolCall] = []
    private(set) var items: [MessageItem] = []
    private(set) var timeline: [MessageItem] = []

    mutating func apply(_ event: BackendEvent) {
        switch event {
        case let .text(text, itemID):
            assistantText += text
            appendText(type: .text, text: text, itemID: itemID)
        case let .reasoning(text, itemID):
            reasoning += text
            appendText(type: .reasoning, text: text, itemID: itemID)
        case let .item(item):
            upsertItem(item)
        case let .tool(id, title, state, input, output, error):
            upsertToolCall(
                id: id,
                title: title,
                state: state,
                input: input,
                output: output,
                error: error
            )
        }
    }

    mutating func finalized(status: RunStatus) -> TimelineBuilder {
        let finalState: MessageItemState = status == .completed ? .completed : .failed
        timeline = timeline.map { $0.withState(finalState) }
        items = items.map { $0.withState(finalState) }
        toolCalls = toolCalls.map { toolCall in
            var finalizedToolCall = toolCall
            if status == .completed || toolCall.status == .completed {
                finalizedToolCall.status = .completed
            } else {
                finalizedToolCall.status = .failed
            }
            return finalizedToolCall
        }
        return self
    }

    private mutating func appendText(
        type: TextItemKind,
        text: String,
        itemID: String?
    ) {
        guard !text.isEmpty else { return }
        if let itemID,
           let index = timeline.firstIndex(where: { $0.id == itemID && $0.textItemKind == type })
        {
            switch timeline[index] {
            case let .text(id, existingText, _) where type == .text:
                timeline[index] = .text(id: id, text: existingText + text, state: .updated)
            case let .reasoning(id, existingText, _) where type == .reasoning:
                timeline[index] = .reasoning(id: id, text: existingText + text, state: .updated)
            default:
                return
            }
            return
        }

        if itemID == nil, let last = timeline.last, last.textItemKind == type {
            switch last {
            case let .text(id, existingText, _):
                timeline[timeline.count - 1] = .text(id: id, text: existingText + text, state: .updated)
            case let .reasoning(id, existingText, _):
                timeline[timeline.count - 1] = .reasoning(id: id, text: existingText + text, state: .updated)
            default:
                break
            }
            return
        }

        let id = itemID ?? UUID().uuidString
        if type == .text {
            timeline.append(.text(id: id, text: text, state: .updated))
        } else {
            timeline.append(.reasoning(id: id, text: text, state: .updated))
        }
    }

    private mutating func upsertItem(_ item: MessageItem) {
        if case .codexEvent = item {
            return
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        if let index = timeline.firstIndex(where: { $0.id == item.id }) {
            timeline[index] = item
        } else {
            timeline.append(item)
        }
    }

    private mutating func upsertToolCall(
        id: String,
        title: String,
        state: ToolCallStatus,
        input: JSONValue?,
        output: String?,
        error: String?
    ) {
        if let index = toolCalls.firstIndex(where: { $0.id == id }) {
            if toolCalls[index].status == .started || state != .started {
                toolCalls[index].status = state
            }
            if let input {
                toolCalls[index].input = input
            }
            if let output {
                toolCalls[index].output = output
            }
            if let error {
                toolCalls[index].error = error
            }
        } else {
            toolCalls.append(
                ToolCall(
                    id: id,
                    name: title,
                    status: state,
                    input: input,
                    output: output,
                    error: error
                )
            )
        }

        guard let toolCall = toolCalls.first(where: { $0.id == id }) else { return }
        upsertItem(
            .toolCall(
                id: toolCall.id,
                name: toolCall.name,
                input: toolCall.input,
                output: toolCall.output,
                error: toolCall.error,
                state: toolCall.status
            )
        )
    }
}

enum TextItemKind: Equatable {
    case text
    case reasoning
}

private extension MessageItem {
    var textItemKind: TextItemKind? {
        switch self {
        case .text: .text
        case .reasoning: .reasoning
        default: nil
        }
    }

    func withState(_ state: MessageItemState) -> MessageItem {
        switch self {
        case let .text(id, text, itemState):
            return .text(id: id, text: text, state: finalState(itemState, fallback: state))
        case let .reasoning(id, text, itemState):
            return .reasoning(id: id, text: text, state: finalState(itemState, fallback: state))
        case let .toolCall(id, name, input, output, error, toolState):
            let nextToolState: ToolCallStatus = switch toolState {
            case .started:
                state == .completed ? .completed : .failed
            case .completed, .failed:
                toolState
            }
            return .toolCall(id: id, name: name, input: input, output: output, error: error, state: nextToolState)
        case let .commandExecution(id, command, output, processID, exitCode, durationMs, terminalInput, itemState):
            return .commandExecution(id: id, command: command, output: output, processID: processID, exitCode: exitCode, durationMs: durationMs, terminalInput: terminalInput, state: finalState(itemState, fallback: state))
        case let .fileChange(id, changes, patchOutput, itemState):
            return .fileChange(id: id, changes: changes, patchOutput: patchOutput, state: finalState(itemState, fallback: state))
        case let .mcpToolCall(id, server, tool, arguments, result, error, progress, itemState):
            return .mcpToolCall(id: id, server: server, tool: tool, arguments: arguments, result: result, error: error, progress: progress, state: finalState(itemState, fallback: state))
        case let .webSearch(id, query, itemState):
            return .webSearch(id: id, query: query, state: finalState(itemState, fallback: state))
        case let .todoList(id, items, itemState):
            return .todoList(id: id, items: items, state: finalState(itemState, fallback: state))
        case let .notice(id, message, itemState):
            return .notice(id: id, message: message, state: finalState(itemState, fallback: state))
        case let .error(id, message, itemState):
            return .error(id: id, message: message, state: finalState(itemState, fallback: state))
        case let .codexEvent(id, eventType, payload, itemState):
            return .codexEvent(id: id, eventType: eventType, payload: payload, state: finalState(itemState, fallback: state))
        }
    }

    private func finalState(_ currentState: MessageItemState, fallback: MessageItemState) -> MessageItemState {
        switch currentState {
        case .started, .updated:
            fallback
        case .completed:
            .completed
        case .failed:
            .failed
        }
    }
}
