import Foundation

/// 会话标题推导：取首条用户消息的首行，否则「新对话」。
/// 聊天窗口标题、菜单栏快捷跳转等处共用，避免各处重复实现。
enum ConversationTitle {
    static func make(from messages: [ChatMessage]) -> String {
        guard let text = messages.first(where: { $0.role == .user })?.text else {
            return "新对话"
        }
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "新对话"
    }
}
