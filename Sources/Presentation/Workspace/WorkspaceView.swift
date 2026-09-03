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
    @State private var hoveredProjectID: String?
    @State private var projectToDelete: ProjectInfo?
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
                    Button {
                        toggleProject(project)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: expandedProjectIDs.contains(project.id) ? "folder.fill" : "folder")
                                .foregroundStyle(.secondary)
                            Text(project.name)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        hoveredProjectID == project.id
                            ? Color.black.opacity(0.06)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        if isHovering {
                            hoveredProjectID = project.id
                        } else if hoveredProjectID == project.id {
                            hoveredProjectID = nil
                        }
                    }
                    .contextMenu {
                        Button {
                            revealProject(project)
                        } label: {
                            Label("在 Finder 中显示", systemImage: "folder")
                        }

                        Divider()

                        Button(role: .destructive) {
                            projectToDelete = project
                        } label: {
                            Label("删除项目", systemImage: "xmark")
                        }
                    }
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    if expandedProjectIDs.contains(project.id) {
                        ForEach(model.sessionsByProject[project.id] ?? []) { session in
                            SessionRow(session: session, sessionToDelete: $sessionToDelete)
                                .padding(.leading, 18)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                if let session = model.selectedSession {
                    sessionToDelete = session
                } else if let project = model.selectedProject {
                    projectToDelete = project
                }
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
        .alert(
            "删除项目？",
            isPresented: Binding(
                get: { projectToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        projectToDelete = nil
                    }
                }
            )
        ) {
            Button("取消", role: .cancel) {
                projectToDelete = nil
            }
            Button("删除", role: .destructive) {
                guard let project = projectToDelete else { return }
                projectToDelete = nil
                model.deleteProject(project)
            }
        } message: {
            Text("将从 Disco 中删除项目“\(projectToDelete?.name ?? "")”及其本地会话和消息；Provider 中的历史不会被删除。")
        }
    }

    private func revealProject(_ project: ProjectInfo) {
        NSWorkspace.shared.open(URL(fileURLWithPath: project.projectPath))
    }

    private func toggleProject(_ project: ProjectInfo) {
        if expandedProjectIDs.contains(project.id) {
            expandedProjectIDs.remove(project.id)
        } else {
            expandedProjectIDs.insert(project.id)
        }
        model.selectProject(project)
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
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        messageList
                        Divider()
                        ApprovalList()
                        ComposerView(availableHeight: geometry.size.height)
                    }
                    .frame(
                        minWidth: chatColumnMinimumWidth,
                        idealWidth: chatColumnIdealWidth,
                        maxWidth: chatColumnMaximumWidth,
                        maxHeight: .infinity
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                }
            } else {
                WelcomeView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private let chatColumnMinimumWidth: CGFloat = 420
    private let chatColumnIdealWidth: CGFloat = 640
    private let chatColumnMaximumWidth: CGFloat = 720

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
                        MessageView(
                            message: message,
                            isStreaming: model.selectedSessionID.map { sessionID in
                                model.runningSessionIDs.contains(sessionID)
                                    && message.id == "active-\(sessionID)"
                            } ?? false
                        )
                            .id(message.id)
                    }
                }
                .padding(24)
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
    let isStreaming: Bool

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 0)
                Text(message.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.92, green: 0.92, blue: 0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: 620, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let status = message.status {
                    HStack {
                        Spacer()
                        Text(statusLabel(status))
                            .font(.caption)
                            .foregroundStyle(status == .failed ? .red : .secondary)
                    }
                }
                let visibleTimeline = (message.timeline ?? []).filter { item in
                    if case .codexEvent = item {
                        return false
                    }
                    return true
                }
                if !visibleTimeline.isEmpty {
                    ForEach(visibleTimeline) { item in
                        MessageItemView(item: item)
                    }
                } else if !message.text.isEmpty {
                    MarkdownText(text: message.text)
                }
                if isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
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
        case let .notice(_, message, _):
            Text(message)
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        case let .error(_, message, state):
            ToolCard(title: "错误", state: stateLabel(state), input: nil, output: nil, error: message)
        case .codexEvent:
            EmptyView()
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
    let availableHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.draft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .disabled(isRunning)

                    if model.draft.isEmpty {
                        Text("做什么都可以…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 17)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: editorHeight)

                HStack(spacing: 8) {
                    agentModelMenu
                    reasoningMenu
                    sandboxMenu
                    modeSwitcher

                    Spacer(minLength: 0)

                    sendButton
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: composerHeight)
    }

    private var isRunning: Bool {
        guard let selectedSessionID = model.selectedSessionID else { return false }
        return model.runningSessionIDs.contains(selectedSessionID)
    }

    private var selectedModelName: String {
        guard let selectedModelID = model.selectedModelID else { return "默认模型" }
        return model.selectedProvider?.models.first { $0.id == selectedModelID }?.name ?? selectedModelID
    }

    private var selectedReasoningEfforts: [ReasoningEffort] {
        model.selectedProvider?.models.first { $0.id == model.selectedModelID }?.reasoningEfforts ?? []
    }

    private var supportsPlan: Bool {
        model.selectedProvider?.supportsPlan == true
    }

    private var composerHeight: CGFloat {
        max(104, availableHeight * 0.05)
    }

    private var editorHeight: CGFloat {
        max(42, composerHeight - 62)
    }

    private var agentModelMenu: some View {
        HStack(spacing: 6) {
            agentIcon

            Menu {
                Section("Agent") {
                    ForEach(model.availableProviders) { provider in
                        Button {
                            model.updateAgent(provider.kind)
                        } label: {
                            Label(provider.kind.displayName, systemImage: provider.kind.systemImage)
                        }
                    }
                }

                Section("模型") {
                    Button("默认模型") {
                        model.updateModel(nil)
                    }
                    ForEach(model.selectedProvider?.models ?? []) { modelInfo in
                        Button(modelInfo.name) {
                            model.updateModel(modelInfo.id)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedModelName)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .help("切换 Agent 和模型")
            .disabled(isRunning)
        }
        .frame(maxWidth: 130, alignment: .leading)
    }

    @ViewBuilder
    private var agentIcon: some View {
        if let provider = model.selectedProvider {
            Image(provider.kind.iconAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .clipped()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
        }
    }

    private var reasoningMenu: some View {
        Menu {
            Button("默认") {
                model.updateReasoningEffort(nil)
            }
            ForEach(selectedReasoningEfforts, id: \.self) { effort in
                Button(reasoningLabel(effort)) {
                    model.updateReasoningEffort(effort)
                }
            }
        } label: {
            Text(reasoningLabel(model.selectedReasoningEffort))
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .disabled(isRunning || selectedReasoningEfforts.isEmpty)
        .help("思考级别")
    }

    private var sandboxMenu: some View {
        Menu {
            ForEach(SandboxMode.allCases, id: \.self) { sandboxMode in
                Button {
                    model.updateSandboxMode(sandboxMode)
                } label: {
                    Label(sandboxLabel(sandboxMode), systemImage: sandboxIcon(sandboxMode))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "lock")
                Text(authorizationLabel)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .disabled(isRunning || model.selectedAgent != .codex)
        .help("授权级别")
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            Button("Build") {
                model.planMode = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(model.planMode ? Color.primary : Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(model.planMode ? Color.clear : Color.black, in: Capsule())
            .disabled(isRunning)

            Button("Plan") {
                model.planMode = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(model.planMode ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(model.planMode ? Color.black : Color.clear, in: Capsule())
            .disabled(isRunning || !supportsPlan)
        }
        .padding(2)
        .background(Color.black.opacity(0.07), in: Capsule())
        .opacity(isRunning ? 0.55 : 1)
        .help("切换 Build 和 Plan 模式")
    }

    private var sendButton: some View {
        Button {
            if isRunning {
                model.cancelRun()
            } else {
                model.sendPrompt()
            }
        } label: {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(canSend || isRunning ? .white : .black)
                .background(
                    (canSend || isRunning ? Color.black : Color(red: 0.82, green: 0.82, blue: 0.82)),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canSend && !isRunning)
        .help(isRunning ? "停止（Esc）" : "发送（⌘↩）")
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reasoningLabel(_ effort: ReasoningEffort?) -> String {
        switch effort {
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "XHigh"
        case .max: "Max"
        case .ultra: "Ultra"
        case .persistent: "Persistent"
        case nil: "默认"
        }
    }

    private func sandboxLabel(_ sandboxMode: SandboxMode) -> String {
        switch sandboxMode {
        case .readOnly: "只读"
        case .workspaceWrite: "工作区可写"
        case .dangerFullAccess: "完全访问"
        }
    }

    private var authorizationLabel: String {
        switch model.selectedSandboxMode {
        case .readOnly: "只读"
        case .workspaceWrite: "工作区"
        case .dangerFullAccess: "完全访问"
        }
    }

    private func sandboxIcon(_ sandboxMode: SandboxMode) -> String {
        switch sandboxMode {
        case .readOnly: "lock"
        case .workspaceWrite: "lock.open"
        case .dangerFullAccess: "lock.open.fill"
        }
    }
}
