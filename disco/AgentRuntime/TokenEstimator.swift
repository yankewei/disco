import Foundation

/// 可复用的 token 粗略估算（计划《上下文压缩 v1》§3）。
/// 仅用于本地阈值决策与 UI 展示，不代表服务商最终 usage。
/// 规则：ASCII 约 4 字符 1 token；非 ASCII 每字符 1 token。
enum TokenEstimator {
    static func estimatedTokenCount(for text: String) -> Int {
        var tokens = 0
        var asciiRunLength = 0

        func flushASCII() {
            guard asciiRunLength > 0 else { return }
            tokens += Int(ceil(Double(asciiRunLength) / 4))
            asciiRunLength = 0
        }

        for scalar in text.unicodeScalars {
            if scalar.value < 128 {
                asciiRunLength += 1
            } else {
                flushASCII()
                tokens += 1
            }
        }
        flushASCII()
        return tokens
    }

    /// 只估算用户/助手可见文本；reasoning 不回传给模型，不占下一轮上下文。
    static func estimatedTokenCount(for message: ChatMessage) -> Int {
        estimatedTokenCount(for: message.text)
    }

    static func estimatedTokenCount(forMessages messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimatedTokenCount(for: $1) }
    }
}
