import AppKit
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedProjectIDs: Set<String> = []

    var body: some View {
        NavigationSplitView {
            SidebarView(expandedProjectIDs: $expandedProjectIDs)
                .navigationSplitViewColumnWidth(228)
        } detail: {
            ConversationView()
        }
        .background(.regularMaterial)
        .alert(
            "Disco",
            isPresented: Binding(
                get: { model.workspaceError != nil },
                set: { isPresented in
                    if !isPresented {
                        model.workspaceError = nil
                    }
                }
            )
        ) {
            Button("好") { model.workspaceError = nil }
        } message: {
            Text(model.workspaceError ?? "")
        }
        .task {
            await model.refresh()
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var expandedProjectIDs: Set<String>
    @State private var sessionToDelete: SessionInfo?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("项目")
                    .font(.headline)
                Spacer()
                Button {
                    model.chooseDirectory()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("添加项目")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            List {
                ForEach(model.projects) { project in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedProjectIDs.contains(project.id) },
                            set: { isExpanded in
                                if isExpanded {
                                    expandedProjectIDs.insert(project.id)
                                } else {
                                    expandedProjectIDs.remove(project.id)
                                }
                            }
                        )
                    ) {
                        ForEach(model.sessionsByProject[project.id] ?? []) { session in
                            SessionRow(session: session, sessionToDelete: $sessionToDelete)
                        }
                    } label: {
                        Button {
                            model.selectProject(project)
                        } label: {
                            Label(project.name, systemImage: "folder")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                guard let session = model.selectedSession else { return }
                sessionToDelete = session
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                SettingsLink {
                    Image(systemName: "gearshape")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("设置")
                .accessibilityLabel("设置")

                Spacer()
            }
            .padding(12)
        }
        .alert(
            "删除会话？",
            isPresented: Binding(
                get: { sessionToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        sessionToDelete = nil
                    }
                }
            )
        ) {
            Button("取消", role: .cancel) {
                sessionToDelete = nil
            }
            Button("删除", role: .destructive) {
                guard let session = sessionToDelete else { return }
                sessionToDelete = nil
                model.deleteSession(session)
            }
        } message: {
            Text("将从 Disco 中移除“\(sessionToDelete?.title ?? "新对话")”；Provider 中的历史不会被删除。")
        }
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo
    @Binding var sessionToDelete: SessionInfo?

    var body: some View {
        Button {
            model.selectSession(session)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: session.agent.systemImage)
                    .foregroundStyle(.secondary)
                Text(session.title)
                    .lineLimit(1)
                Spacer()
                if model.runningSessionIDs.contains(session.id) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .listRowBackground(
            model.selectedSessionID == session.id
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
        .contextMenu {
            Button("删除会话", role: .destructive) {
                sessionToDelete = session
            }
        }
    }
}

private struct ConversationView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            conversationHeader
            Divider()
            if model.selectedSession != nil {
                messageList
                Divider()
                ApprovalList()
                ComposerView()
            } else {
                WelcomeView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var conversationHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedSession?.title ?? model.selectedProject?.name ?? "Disco")
                    .font(.headline)
                if let project = model.selectedProject {
                        Text(project.projectPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if model.selectedProject != nil {
                Button {
                    model.startNewSession()
                } label: {
                    Image(systemName: "plus.message")
                }
                .buttonStyle(.borderless)
                .help("新建会话")
            }
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var messageList: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.messages) { message in
                        MessageView(message: message)
                            .id(message.id)
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.messages.count) {
                if let lastMessage = model.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollProxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let hasSelectedProject = model.selectedProject != nil
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(hasSelectedProject ? "开始新的会话" : "开始使用 Disco")
                .font(.title2.weight(.semibold))
            Text(hasSelectedProject
                ? "选择 Provider 后开始与项目协作。"
                : "添加一个项目，然后开始与 Codex 或 OpenCode 协作。")
                .foregroundStyle(.secondary)
            Button(hasSelectedProject ? "新建会话" : "添加项目") {
                if hasSelectedProject {
                    model.createSession()
                } else {
                    model.chooseDirectory()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MessageView: View {
    let message: ConversationMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 0)
                Text(message.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: 620, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text("Disco")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let status = message.status {
                        Text(statusLabel(status))
                            .font(.caption)
                            .foregroundStyle(status == .failed ? .red : .secondary)
                    }
                }
                if let timeline = message.timeline, !timeline.isEmpty {
                    ForEach(timeline) { item in
                        MessageItemView(item: item)
                    }
                } else {
                    MarkdownText(text: message.text)
                }
                if let error = message.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusLabel(_ status: RunStatus) -> String {
        switch status {
        case .completed: "完成"
        case .cancelled: "已取消"
        case .failed: "失败"
        }
    }
}

private struct MessageItemView: View {
    let item: MessageItem

    var body: some View {
        switch item {
        case let .text(_, text, _):
            MarkdownText(text: text)
        case let .reasoning(_, text, state):
            DisclosureGroup("分析过程 · \(stateLabel(state))") {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
        case let .toolCall(_, name, input, output, error, state):
            ToolCard(
                title: name,
                state: toolStateLabel(state),
                input: input?.prettyPrinted(),
                output: output,
                error: error
            )
        case let .commandExecution(_, command, output, _, exitCode, _, terminalInput, state):
            ToolCard(
                title: command.isEmpty ? "命令执行" : command,
                state: stateLabel(state),
                input: terminalInput,
                output: output,
                error: exitCode.map { $0 == 0 ? nil : "退出码：\($0)" } ?? nil
            )
        case let .fileChange(_, changes, patchOutput, state):
            ToolCard(
                title: "文件变更（\(changes.count)）",
                state: stateLabel(state),
                input: changes.map(\.path).joined(separator: "\n"),
                output: patchOutput,
                error: nil
            )
        case let .mcpToolCall(_, server, tool, arguments, result, error, progress, state):
            ToolCard(
                title: "MCP · \(server) / \(tool)",
                state: stateLabel(state),
                input: arguments.prettyPrinted(),
                output: [progress ?? [], result.map { [$0.prettyPrinted()] } ?? []].flatMap { $0 }.joined(separator: "\n"),
                error: error
            )
        case let .webSearch(_, query, state):
            ToolCard(title: "网页搜索", state: stateLabel(state), input: query, output: nil, error: nil)
        case let .todoList(_, items, state):
            VStack(alignment: .leading, spacing: 6) {
                Label("计划 · \(stateLabel(state))", systemImage: "checklist")
                    .font(.subheadline.weight(.medium))
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label(item.text, systemImage: item.completed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.completed ? .secondary : .primary)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        case let .error(_, message, state):
            ToolCard(title: "错误", state: stateLabel(state), input: nil, output: nil, error: message)
        case let .codexEvent(_, eventType, payload, state):
            ToolCard(title: eventType, state: stateLabel(state), input: JSONValue.object(payload).prettyPrinted(), output: nil, error: nil)
        }
    }

    private func stateLabel(_ state: MessageItemState) -> String {
        switch state {
        case .started: "运行中"
        case .updated: "更新中"
        case .completed: "完成"
        case .failed: "失败"
        }
    }

    private func toolStateLabel(_ state: ToolCallStatus) -> String {
        switch state {
        case .started: "运行中"
        case .completed: "完成"
        case .failed: "失败"
        }
    }
}

private struct ToolCard: View {
    let title: String
    let state: String
    let input: String?
    let output: String?
    let error: String?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let input, !input.isEmpty {
                    Text(input)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let output, !output.isEmpty {
                    Divider()
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Image(systemName: "terminal")
                Text(title)
                    .lineLimit(1)
                Spacer()
                Text(state)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MarkdownText: View {
    let text: String

    var body: some View {
        if let attributedText = try? AttributedString(markdown: text) {
            Text(attributedText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ApprovalList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let sessionID = model.selectedSessionID {
            ForEach(model.approvalRequests.filter { $0.sessionID == sessionID }) { request in
                ApprovalCard(request: request)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
        }
    }
}

private struct ApprovalCard: View {
    @EnvironmentObject private var model: AppModel
    let request: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title ?? request.toolName, systemImage: "hand.raised")
                .font(.subheadline.weight(.semibold))
            if let command = request.input["command"]?.stringValue {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("拒绝") {
                    model.approve(request, decision: .denied)
                }
                Button("允许") {
                    model.approve(request, decision: .approved)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ComposerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            TextEditor(text: $model.draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 74, maxHeight: 150)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .disabled(isRunning)

            HStack(spacing: 10) {
                Picker(
                    "Provider",
                    selection: Binding(
                        get: { model.selectedAgent },
                        set: { model.updateAgent($0) }
                    )
                    ) {
                    ForEach(model.providers) { provider in
                        Label(provider.kind.displayName, systemImage: provider.kind.systemImage)
                            .tag(provider.kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
                .disabled(isRunning)

                Picker(
                    "模型",
                    selection: Binding(
                        get: { model.selectedModelID },
                        set: { model.updateModel($0) }
                    )
                ) {
                    Text("默认模型").tag(nil as String?)
                    ForEach(model.selectedProvider?.models ?? []) { modelInfo in
                        Text(modelInfo.name).tag(Optional(modelInfo.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
                .disabled(isRunning)

                if let reasoningEfforts = model.selectedProvider?.models.first(where: { $0.id == model.selectedModelID })?.reasoningEfforts,
                   !reasoningEfforts.isEmpty
                {
                    Picker(
                        "推理",
                        selection: Binding(
                            get: { model.selectedReasoningEffort },
                            set: { model.updateReasoningEffort($0) }
                        )
                    ) {
                        Text("默认").tag(nil as ReasoningEffort?)
                        ForEach(reasoningEfforts, id: \.self) { effort in
                            Text(effort.rawValue).tag(Optional(effort))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 130)
                    .disabled(isRunning)
                }

                Picker(
                    "权限",
                    selection: Binding(
                        get: { model.selectedSandboxMode },
                        set: { model.updateSandboxMode($0) }
                    )
                ) {
                    Text("只读").tag(SandboxMode.readOnly)
                    Text("工作区可写").tag(SandboxMode.workspaceWrite)
                    Text("完全访问").tag(SandboxMode.dangerFullAccess)
                }
                .labelsHidden()
                .frame(maxWidth: 140)
                .disabled(isRunning || model.selectedAgent != .codex)

                Toggle("计划", isOn: $model.planMode)
                    .toggleStyle(.checkbox)
                    .disabled(isRunning || model.selectedProvider?.supportsPlan != true)

                Spacer()
                if isRunning {
                    Button("停止") {
                        model.cancelRun()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button {
                        model.sendPrompt()
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("发送（⌘↩）")
                }
            }
        }
        .padding(20)
    }

    private var isRunning: Bool {
        guard let selectedSessionID = model.selectedSessionID else { return false }
        return model.runningSessionIDs.contains(selectedSessionID)
    }
}
