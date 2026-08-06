import Foundation

/// 领域消息（计划 §13 Message：run 内有序内容片段）。
///
/// 内容以有序块（parts）组织，每类块在 UI 有独立图标与样式：
/// - `.text`      最终文本（正文）
/// - `.reasoning` 思考过程（`brain` 图标，可折叠）
/// - `.toolCall`  工具调用（`wrench` 图标；**解析与执行尚未接入**，仅预留架构）
///
/// 持久化层目前仍映射到 text/reasoning 两列；未来接入工具、
/// 附件、文件 diff 时再迁移为 parts 序列化。
struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    struct ToolCallSnapshot: Equatable, Sendable {
        let id: String
        let name: String
        let arguments: String
    }

    enum Part: Equatable, Sendable {
        case text(String)
        case reasoning(String)
        case toolCall(ToolCallSnapshot)
    }

    let id: UUID
    let role: Role
    var parts: [Part]

    init(id: UUID = UUID(), role: Role, parts: [Part] = []) {
        self.id = id
        self.role = role
        self.parts = parts
    }

    /// 便捷构造：纯文本消息（user 输入、旧调用点）。
    init(id: UUID = UUID(), role: Role, text: String) {
        self.init(id: id, role: role, parts: [.text(text)])
    }

    /// 便捷构造：思考 + 文本（持久化恢复路径）。
    init(id: UUID = UUID(), role: Role, text: String, reasoning: String) {
        var parts: [Part] = []
        if !reasoning.isEmpty {
            parts.append(.reasoning(reasoning))
        }
        parts.append(.text(text))
        self.init(id: id, role: role, parts: parts)
    }

    /// 全部文本块的拼接（UI 正文、测试断言、持久化映射共用）。
    var text: String {
        parts.compactMap { part -> String? in
            if case let .text(text) = part { return text }
            return nil
        }.joined()
    }

    /// 全部思考块的拼接。
    var reasoning: String {
        parts.compactMap { part -> String? in
            if case let .reasoning(reasoning) = part { return reasoning }
            return nil
        }.joined()
    }

    /// 流式追加：文本 delta 追加到末尾的文本块，否则新建一块。
    mutating func appendText(_ delta: String) {
        guard !parts.isEmpty else {
            parts.append(.text(delta))
            return
        }
        let lastIndex = parts.count - 1
        switch parts[lastIndex] {
        case var .text(text):
            text += delta
            parts[lastIndex] = .text(text)
        default:
            parts.append(.text(delta))
        }
    }

    /// 流式追加：思考 delta 追加到末尾的思考块，否则新建一块。
    mutating func appendReasoning(_ delta: String) {
        guard !parts.isEmpty else {
            parts.append(.reasoning(delta))
            return
        }
        let lastIndex = parts.count - 1
        switch parts[lastIndex] {
        case var .reasoning(reasoning):
            reasoning += delta
            parts[lastIndex] = .reasoning(reasoning)
        default:
            parts.append(.reasoning(delta))
        }
    }
}
