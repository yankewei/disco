import SwiftUI

/// 固定在输入框上方的审批卡片。
/// 当 Agent 需要执行敏感操作时展示影响范围并等待用户确认。
struct ApprovalPromptView: View {
    let approval: DaemonApprovalRequestedData
    let onApprove: () -> Void
    let onApproveForSession: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 28, height: 28)
                    .background(.orange.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("需要确认")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text(impactLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(approval.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                Text("等待你的决定")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)

                approvalActions
            }

            if let reason = approval.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            ScrollView(.vertical) {
                impactView
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 92)
            .scrollIndicators(.hidden)
            .background(DiscoScrollIndicatorHider())
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(
                cornerRadius: DiscoRadius.small,
                style: .continuous
            ))
            .clipShape(RoundedRectangle(cornerRadius: DiscoRadius.small, style: .continuous))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiscoTheme.elevatedSurface)
        .clipShape(RoundedRectangle(cornerRadius: DiscoRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DiscoRadius.medium, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(.orange)
                .frame(width: 3)
                .padding(.vertical, 8)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    private var approvalActions: some View {
        HStack(spacing: 6) {
            Button("拒绝", role: .destructive, action: onDecline)
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)

            if approval.allowsSessionApproval {
                Button("本次会话允许", action: onApproveForSession)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Button("允许一次", action: onApprove)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 根据影响类型展示不同的详情视图。
    @ViewBuilder
    private var impactView: some View {
        switch approval.impact.type {
        case "command":
            commandImpactView
        case "file_change":
            fileChangeImpactView
        case "network":
            networkImpactView
        case "permission":
            permissionImpactView
        default:
            if let description = approval.impact.description {
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// 命令执行的影响展示。
    private var commandImpactView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("将执行命令：")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            Text(commandText)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DiscoTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            if let cwd = approval.impact.cwd {
                Text("工作目录：\(cwd)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// 文件变更的影响展示。
    private var fileChangeImpactView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("将修改文件：")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            if let paths = approval.impact.paths {
                ForEach(paths, id: \.self) { path in
                    Label(path, systemImage: "doc")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let summary = approval.impact.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let diff = approval.impact.diff {
                ScrollView {
                    ApprovalDiffView(diff: diff)
                }
                .frame(maxHeight: 120)
                .scrollIndicators(.hidden)
                .background(DiscoScrollIndicatorHider())
                .background(DiscoTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }

    /// 网络请求的影响展示。
    private var networkImpactView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("将发起网络请求：")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            if let host = approval.impact.host {
                LabeledContent("目标", value: host)
                    .font(.caption)
            }
            if let scheme = approval.impact.scheme {
                LabeledContent("协议", value: scheme)
                    .font(.caption)
            }
            if let port = approval.impact.port {
                LabeledContent("端口", value: String(port))
                    .font(.caption)
            }
        }
    }

    /// 权限请求的影响展示。
    private var permissionImpactView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("需要权限：")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            if let scope = approval.impact.scope {
                LabeledContent("范围", value: scope)
                    .font(.caption)
            }
            if let description = approval.impact.description {
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 拼接命令文本。
    private var commandText: String {
        let executable = approval.impact.executable ?? ""
        let arguments = approval.impact.arguments?.joined(separator: " ") ?? ""
        return arguments.isEmpty ? executable : "\(executable) \(arguments)"
    }

    private var impactLabel: String {
        switch approval.kind {
        case "command": return "命令"
        case "file_change": return "文件变更"
        case "network": return "网络请求"
        default: return "权限请求"
        }
    }
}

#Preview("命令审批") {
    ApprovalPromptView(
        approval: DaemonApprovalRequestedData(
            runId: "run-1",
            sessionId: "session-1",
            approvalId: "approval-1",
            kind: "command",
            title: "执行 Shell 命令",
            reason: "需要列出项目目录中的文件",
            impact: DaemonApprovalImpact(
                type: "command",
                executable: "ls",
                arguments: ["-la", "/Users/test/project"],
                cwd: "/Users/test/project",
                paths: nil,
                summary: nil,
                diff: nil,
                host: nil,
                scheme: nil,
                port: nil,
                scope: nil,
                description: nil
            ),
            fingerprint: "abc123",
            allowsSessionApproval: true
        ),
        onApprove: {},
        onApproveForSession: {},
        onDecline: {}
    )
    .padding()
    .frame(width: 560)
}

#Preview("文件变更审批") {
    ApprovalPromptView(
        approval: DaemonApprovalRequestedData(
            runId: "run-1",
            sessionId: "session-1",
            approvalId: "approval-2",
            kind: "file_change",
            title: "修改文件",
            reason: "修复函数中的空指针问题",
            impact: DaemonApprovalImpact(
                type: "file_change",
                executable: nil,
                arguments: nil,
                cwd: nil,
                paths: ["/Users/test/project/main.swift"],
                summary: "修改 1 个文件，新增 3 行，删除 1 行",
                diff: "@@ -10,3 +10,5 @@\n func test() {\n-    print(\"old\")\n+    guard let value = optional else { return }\n+    print(value)\n+    print(\"new\")\n }",
                host: nil,
                scheme: nil,
                port: nil,
                scope: nil,
                description: nil
            ),
            fingerprint: "def456",
            allowsSessionApproval: false
        ),
        onApprove: {},
        onApproveForSession: {},
        onDecline: {}
    )
    .padding()
    .frame(width: 560)
}

/// diff 行级着色：新增行绿、删除行红、hunk 头弱化；保持等宽字体与可选中。
private struct ApprovalDiffView: View {
    let diff: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(
                Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                id: \.offset
            ) { _, line in
                Text(String(line))
                    .font(.caption.monospaced())
                    .foregroundStyle(color(for: line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.vertical, 6)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return .green
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return .red
        }
        if line.hasPrefix("@@") {
            return .secondary
        }
        return .primary
    }
}
