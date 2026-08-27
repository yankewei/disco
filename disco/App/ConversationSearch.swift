import Foundation

/// 侧栏会话搜索匹配逻辑（纯值逻辑，便于单元测试）。
enum ConversationSearch {
    /// query 是否命中项目名或会话内任意一条消息文本；大小写不敏感。
    /// 命中项目名时视为该项目的所有会话匹配。
    /// query 为空白时视为未启用搜索，返回 true（不过滤）。
    static func matches(query: String, project: String?, messages: [ChatMessage]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if let project, project.localizedCaseInsensitiveContains(trimmed) {
            return true
        }
        return messages.contains { message in
            message.text.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
