import SwiftUI

/// 工具执行状态在聊天时间线中的展示视图（Phase 3）。
struct ToolExecutionView: View {
    let execution: ToolExecutionDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 工具名称与状态图标
            HStack(spacing: 6) {
                Image(systemName: execution.isCompleted ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(execution.isCompleted ? .green : .orange)

                Text(toolDisplayName(execution.toolName))
                    .font(.caption.weight(.semibold))

                if !execution.isCompleted {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 8)

                if execution.isCompleted {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            // 参数（过长时截断）
            if !execution.arguments.isEmpty {
                Text(formatArguments(execution.arguments))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }

            // 输出（仅完成后显示）
            if let output = execution.output, !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .background(DiscoTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: DiscoRadius.small, style: .continuous))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiscoTheme.elevatedSurface)
        .clipShape(RoundedRectangle(cornerRadius: DiscoRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DiscoRadius.medium, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    /// 工具名称的本地化展示。
    private func toolDisplayName(_ name: String) -> String {
        switch name {
        case "shell": return "Shell 命令"
        case "read_file": return "读取文件"
        case "write_file": return "写入文件"
        case "edit_file": return "编辑文件"
        case "search": return "代码搜索"
        case "list_files": return "列出文件"
        default: return name
        }
    }

    /// 格式化参数 JSON 为紧凑展示文本。
    private func formatArguments(_ json: String) -> String {
        // 尝试解析为 JSON 并格式化；失败时直接展示原始字符串
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return json
        }
        let parts = obj.map { key, value in
            "\(key): \(value)"
        }
        return parts.joined(separator: ", ")
    }
}

#Preview("工具执行中") {
    ToolExecutionView(
        execution: ToolExecutionDisplay(
            id: "test-1",
            toolName: "shell",
            arguments: #"{"command": "ls -la /tmp"}"#
        )
    )
    .padding()
    .frame(width: 400)
}

#Preview("工具已完成") {
    ToolExecutionView(
        execution: ToolExecutionDisplay(
            id: "test-2",
            toolName: "read_file",
            arguments: #"{"path": "/Users/test/main.swift"}"#,
            output: "import Foundation\n\nprint(\"Hello, World!\")",
            isCompleted: true
        )
    )
    .padding()
    .frame(width: 400)
}
