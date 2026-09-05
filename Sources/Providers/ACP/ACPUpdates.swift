import Foundation

struct ACPUpdateTranslator {
    private var tools: [String: [String: JSONValue]] = [:]
    private let planID = UUID().uuidString

    mutating func event(for update: [String: JSONValue]) -> BackendEvent? {
        guard let kind = update["sessionUpdate"]?.stringValue else { return nil }
        switch kind {
        case "agent_message_chunk", "agent_thought_chunk":
            guard let content = update["content"]?.objectValue else { return nil }
            let text: String
            switch content["type"]?.stringValue {
            case "text": text = content["text"]?.stringValue ?? ""
            case "resource_link": text = content["uri"]?.stringValue ?? ""
            case "resource":
                let resource = content["resource"]?.objectValue
                text = resource?["text"]?.stringValue ?? resource?["uri"]?.stringValue ?? "[资源]"
            case "image": text = "[Agent 返回了一张图片，当前暂不支持显示]"
            case "audio": text = "[Agent 返回了一段音频，当前暂不支持播放]"
            default: text = "[Agent 返回了暂不支持的内容]"
            }
            let itemID = update["messageId"]?.stringValue.map { kind + ":" + $0 }
            return kind == "agent_thought_chunk" ? .reasoning(text: text, itemID: itemID) : .text(text: text, itemID: itemID)
        case "tool_call", "tool_call_update":
            guard let id = update["toolCallId"]?.stringValue else { return nil }
            var tool = tools[id] ?? [:]
            tool.merge(update) { _, new in new }
            tools[id] = tool
            let state: ToolCallStatus = switch tool["status"]?.stringValue {
            case "completed": .completed
            case "failed": .failed
            default: .started
            }
            let output: String?
            if let contents = tool["content"]?.arrayValue {
                output = contents.compactMap { value -> String? in
                    guard let content = value.objectValue else { return nil }
                    switch content["type"]?.stringValue {
                    case "content":
                        let block = content["content"]?.objectValue
                        return block?["text"]?.stringValue ?? block?["uri"]?.stringValue ?? value.prettyPrinted()
                    case "diff":
                        let path = content["path"]?.stringValue ?? "文件"
                        let oldText = content["oldText"]?.stringValue ?? ""
                        let newText = content["newText"]?.stringValue ?? ""
                        return "\(path)\n--- 修改前\n\(oldText)\n+++ 修改后\n\(newText)"
                    default: return value.prettyPrinted()
                    }
                }.joined(separator: "\n")
            } else if let rawOutput = tool["rawOutput"] {
                output = rawOutput.stringValue ?? rawOutput.prettyPrinted()
            } else {
                output = nil
            }
            return .tool(
                id: "acp-tool:" + id,
                title: tool["title"]?.stringValue ?? "工具调用",
                state: state,
                input: tool["rawInput"],
                output: output,
                error: state == .failed ? (output ?? "工具执行失败") : nil
            )
        case "plan":
            guard let entries = update["entries"]?.arrayValue else { return nil }
            let todos = entries.compactMap { value -> TodoEntry? in
                guard let entry = value.objectValue, let text = entry["content"]?.stringValue else { return nil }
                return TodoEntry(text: text, completed: entry["status"]?.stringValue == "completed")
            }
            return .item(.todoList(id: planID, items: todos, state: .updated))
        default:
            return nil
        }
    }
}

struct ACPConversationHistory {
    private(set) var messages: [ConversationMessage] = []
    private var builder = TimelineBuilder()
    private var currentMessageID: String?

    mutating func beginTurn(prompt: String) {
        appendUser(prompt, messageID: UUID().uuidString)
    }

    mutating func appendUser(_ text: String, messageID: String?) {
        if messages.last?.role == .user, messageID == nil || currentMessageID == messageID {
            messages[messages.count - 1].text += text
            return
        }
        currentMessageID = messageID
        messages.append(ConversationMessage(
            id: messageID ?? UUID().uuidString, role: .user, text: text,
            reasoning: nil, toolCalls: nil, items: nil, timeline: nil,
            status: nil, error: nil, createdAt: .timestamp(), isPlan: false
        ))
        builder = TimelineBuilder()
    }

    mutating func append(_ event: BackendEvent, messageID: String?) {
        if messages.last?.role != .assistant || (messageID != nil && currentMessageID != nil && messageID != currentMessageID) {
            builder = TimelineBuilder()
            currentMessageID = messageID
            messages.append(ConversationMessage(
                id: messageID ?? UUID().uuidString, role: .assistant, text: "",
                reasoning: nil, toolCalls: nil, items: nil, timeline: nil,
                status: .completed, error: nil, createdAt: .timestamp(), isPlan: false
            ))
        } else if let messageID {
            currentMessageID = messageID
        }
        builder.apply(event)
        let index = messages.count - 1
        var message = messages[index]
        message.text = builder.assistantText
        message.reasoning = builder.reasoning
        message.toolCalls = builder.toolCalls
        message.items = builder.items
        message.timeline = builder.timeline
        messages[index] = message
    }

    mutating func finishTurn(status: RunStatus) {
        guard messages.last?.role == .assistant else { return }
        var message = messages[messages.count - 1]
        let finalized = builder.finalized(status: status)
        message.status = status
        message.toolCalls = finalized.toolCalls
        message.items = finalized.items
        message.timeline = finalized.timeline
        messages[messages.count - 1] = message
    }
}
