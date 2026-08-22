import AppKit
import SwiftUI

/// 工具调用在 assistant 消息回合中的紧凑活动轨迹。
/// 参数与输出通过右侧 inspector 查看，避免把长内容塞进聊天时间线。
struct ToolExecutionView: View {
    let call: ChatMessage.ToolCallSnapshot
    let isSelected: Bool
    let onSelect: () -> Void

    private var presentation: ToolCallPresentation {
        ToolCallPresentation(call: call)
    }

    init(
        call: ChatMessage.ToolCallSnapshot,
        isSelected: Bool = false,
        onSelect: @escaping () -> Void = {}
    ) {
        self.call = call
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(presentation.toolTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)

                        if presentation.shouldShowToolIdentifier {
                            Text(presentation.toolIdentifier)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }

                        Text(call.isCompleted ? "已完成" : "执行中")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(call.isCompleted ? .green : .orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (call.isCompleted ? Color.green : Color.orange).opacity(0.10),
                                in: Capsule()
                            )
                    }

                    if let actionSummary = presentation.actionSummary {
                        Text(actionSummary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let outputPreview = presentation.outputPreview {
                        Text(outputPreview)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 12)

                if !call.isCompleted {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.orange)
                }

                if presentation.hasDetails {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 5)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(!presentation.hasDetails)
        .background(
            isSelected
                ? DiscoTheme.accent.opacity(0.10)
                : DiscoTheme.surface.opacity(0.56),
            in: RoundedRectangle(cornerRadius: DiscoRadius.small, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DiscoRadius.small, style: .continuous)
                .stroke(
                    isSelected ? DiscoTheme.accent.opacity(0.45) : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(presentation.hasDetails ? "打开工具详情" : "没有可查看的详情")
    }

    private var accessibilityLabel: String {
        var values = [presentation.toolTitle, call.isCompleted ? "已完成" : "执行中"]
        if presentation.shouldShowToolIdentifier {
            values.append("工具 \(presentation.toolIdentifier)")
        }
        if let actionSummary = presentation.actionSummary {
            values.append(actionSummary)
        }
        return values.joined(separator: "，")
    }
}

struct ToolCallInspector: View {
    let call: ChatMessage.ToolCallSnapshot
    let dismiss: () -> Void

    private var presentation: ToolCallPresentation {
        ToolCallPresentation(call: call)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.toolTitle)
                        .font(.headline)

                    HStack(spacing: 6) {
                        Text(call.isCompleted ? "已完成" : "执行中")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(call.isCompleted ? .green : .orange)

                        if presentation.shouldShowToolIdentifier {
                            Text(presentation.toolIdentifier)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 8)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("关闭工具详情")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if presentation.hasArguments {
                        ToolInspectorPayload(
                            title: "输入",
                            systemImage: "arrow.turn.down.right",
                            text: presentation.formatJSON(call.arguments)
                        )
                    }

                    if let outputPresentation = presentation.outputPresentation {
                        ToolInspectorPayload(
                            title: "输出",
                            systemImage: "arrow.turn.up.left",
                            text: outputPresentation.readableText,
                            rawText: outputPresentation.isWrapped ? call.output : nil
                        )
                    }

                    if !presentation.hasDetails {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "text.magnifyingglass")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                            Text("暂无可查看的输入或输出")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text("工具完成后，参数和结果会显示在这里。")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiscoTheme.surface)
    }
}

private struct ToolInspectorPayload: View {
    let title: String
    let systemImage: String
    let text: String
    let rawText: String?

    @State private var isShowingRawText = false

    init(
        title: String,
        systemImage: String,
        text: String,
        rawText: String? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.text = text
        self.rawText = rawText
    }

    private var displayedText: String {
        isShowingRawText ? (rawText ?? text) : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(displayedText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("复制\(title)")
            }

            Text(displayedText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: DiscoRadius.small, style: .continuous)
                )

            if rawText != nil {
                Button {
                    isShowingRawText.toggle()
                } label: {
                    Label(
                        isShowingRawText ? "显示可读内容" : "查看原始 JSON",
                        systemImage: isShowingRawText ? "chevron.down" : "chevron.right"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ToolCallPresentation {
    let call: ChatMessage.ToolCallSnapshot

    private var normalizedToolName: String {
        call.name.lowercased()
    }

    private var normalizedToolKind: String {
        call.kind?.lowercased() ?? ""
    }

    var toolIdentifier: String {
        let kind = call.kind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return kind.isEmpty ? call.name : kind
    }

    var shouldShowToolIdentifier: Bool {
        let kind = call.kind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !toolIdentifier.isEmpty
            && (!kind.isEmpty || toolIdentifier.caseInsensitiveCompare(toolTitle) != .orderedSame)
    }

    private var isCommandTool: Bool {
        [normalizedToolName, normalizedToolKind].contains {
            $0.contains("shell")
                || $0.contains("bash")
                || $0.contains("command")
                || $0.contains("exec")
                || $0.contains("execute")
                || $0.contains("执行命令")
        }
    }

    var toolTitle: String {
        if isCommandTool {
            return "执行命令"
        }

        switch normalizedToolKind {
        case "read": return "读取文件"
        case "edit", "delete", "move": return "修改文件"
        case "search": return "搜索代码"
        case "fetch": return "读取网页"
        default: break
        }

        switch normalizedToolName {
        case "read_file", "read": return "读取文件"
        case "write_file", "write": return "写入文件"
        case "edit_file", "edit", "apply_patch": return "修改文件"
        case "search", "grep": return "搜索代码"
        case "list_files", "glob": return "浏览文件"
        default: return call.name
        }
    }

    var actionSummary: String? {
        guard let arguments = argumentsObject else { return nil }
        if let command = stringValue(in: arguments, keys: ["command", "cmd", "script", "shellCommand"]) {
            return compact(command, limit: 140)
        }

        let value: String?
        if isCommandTool {
            value = nil
        } else if normalizedToolName.contains("search") || normalizedToolName.contains("grep") {
            value = stringValue(in: arguments, keys: ["query", "pattern", "path"])
        } else {
            value = stringValue(in: arguments, keys: ["path", "file", "filePath", "url"])
        }
        return value.map { compact($0, limit: 100) }
    }

    var hasDetails: Bool {
        hasArguments || outputPresentation != nil
    }

    var hasArguments: Bool {
        let trimmed = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let arguments = argumentsObject {
            return !arguments.isEmpty
        }
        return trimmed != "{}" && trimmed != "[]"
    }

    private var argumentsObject: [String: Any]? {
        guard let data = call.arguments.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    var outputPresentation: ToolOutputPresentation? {
        guard let output = call.output,
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ToolOutputPresentation(raw: output)
    }

    var outputPreview: String? {
        guard let readableText = outputPresentation?.readableText else { return nil }
        let firstLines = readableText
            .split(whereSeparator: { $0.isNewline })
            .prefix(2)
            .joined(separator: "  ")
        guard !firstLines.isEmpty else { return nil }
        return compact(String(firstLines), limit: 140)
    }

    func formatJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return json
        }
        return pretty
    }

    private func stringValue(in object: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { object[$0] as? String }.first
    }

    private func compact(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }
}

private struct ToolOutputPresentation {
    let readableText: String
    let isWrapped: Bool

    init(raw: String) {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            readableText = raw
            isWrapped = false
            return
        }

        if let object = value as? [String: Any],
           let readableValue = Self.firstTextValue(in: object) {
            readableText = readableValue
            isWrapped = true
            return
        }

        readableText = Self.prettyJSONString(value) ?? raw
        isWrapped = false
    }

    private static func firstTextValue(in object: [String: Any]) -> String? {
        for key in ["output", "content", "result", "text", "message"] {
            if let value = object[key] as? String {
                return value
            }
        }
        return nil
    }

    private static func prettyJSONString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

#Preview("工具执行中") {
    ToolExecutionView(
        call: ChatMessage.ToolCallSnapshot(
            id: "test-1",
            name: "shell",
            arguments: #"{"command":"git status --short"}"#
        )
    )
    .padding()
    .frame(width: 500)
}

#Preview("工具已完成") {
    ToolExecutionView(
        call: ChatMessage.ToolCallSnapshot(
            id: "test-2",
            name: "read_file",
            arguments: #"{"path":"/Users/test/main.swift"}"#,
            status: .completed,
            output: "import Foundation\n\nprint(\"Hello, World!\")"
        )
    )
    .padding()
    .frame(width: 500)
}
