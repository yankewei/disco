import AppKit
import SwiftUI
import Textual

private let modelPickerWidth: CGFloat = 500
private let modelPickerHeight: CGFloat = 340

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedProjectIDs: Set<String> = []

    var body: some View {
        NavigationSplitView {
            SidebarView(expandedProjectIDs: $expandedProjectIDs)
                .navigationSplitViewColumnWidth(DiscoTheme.Metrics.sidebarWidth)
        } detail: {
            ConversationView()
        }
        .background(DiscoTheme.Palette.canvas)
        .font(DiscoTheme.Typography.body)
        .tint(DiscoTheme.Palette.accent)
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
                    .font(DiscoTheme.Typography.sidebarHeading)
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
                    HStack(spacing: 0) {
                        Button {
                            toggleProject(project)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: expandedProjectIDs.contains(project.id) ? "folder.fill" : "folder")
                                    .foregroundStyle(model.selectedProjectID == project.id ? DiscoTheme.Palette.accent : .secondary)
                                Text(project.name)
                                    .font(DiscoTheme.Typography.sidebar)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 0) {
                            if hoveredProjectID == project.id {
                                Menu {
                                    projectContextMenu(project)
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                        .foregroundStyle(.secondary)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .help("更多操作")
                                .accessibilityLabel("更多操作")

                                Button {
                                    expandedProjectIDs.insert(project.id)
                                    model.createSession(in: project)
                                } label: {
                                    Image(systemName: "plus")
                                        .frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("新建会话")
                                .accessibilityLabel("新建会话")
                            } else {
                                Color.clear
                                    .frame(width: 44, height: 22)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        model.selectedProjectID == project.id
                            ? DiscoTheme.Palette.selection
                            : hoveredProjectID == project.id
                                ? DiscoTheme.Palette.hover
                                : Color.clear,
                        in: RoundedRectangle(cornerRadius: DiscoTheme.Metrics.rowCornerRadius, style: .continuous)
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
                        projectContextMenu(project)
                    }
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    if expandedProjectIDs.contains(project.id) {
                        ForEach(model.sessionsByProject[project.id] ?? []) { session in
                            SessionRow(session: session, sessionToDelete: $sessionToDelete)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(DiscoTheme.Palette.sidebar)
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
            .background(DiscoTheme.Palette.sidebar)
        }
        .background(DiscoTheme.Palette.sidebar)
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

    @ViewBuilder
    private func projectContextMenu(_ project: ProjectInfo) -> some View {
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
    @State private var isHovering = false

    private var isSelected: Bool {
        model.selectedSessionID == session.id
    }

    var body: some View {
        Button {
            model.selectSession(session)
        } label: {
            HStack(spacing: 8) {
                Color.clear
                    .frame(width: 10, height: 1)
                Image(session.agent.iconAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(session.title)
                    .lineLimit(1)
                Spacer()
                if model.runningSessionIDs.contains(session.id) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            isSelected
                ? DiscoTheme.Palette.selection
                : isHovering ? DiscoTheme.Palette.hover : Color.clear,
            in: RoundedRectangle(cornerRadius: DiscoTheme.Metrics.rowCornerRadius, style: .continuous)
        )
        .onHover { isHovering = $0 }
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
            if model.selectedSession != nil {
                GeometryReader { geometry in
                    messageList
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            VStack(spacing: 0) {
                                ApprovalList()
                                ComposerView(availableHeight: geometry.size.height)
                            }
                            .frame(maxWidth: chatColumnMaximumWidth)
                            .frame(maxWidth: .infinity)
                            .background(DiscoTheme.Palette.surface)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DiscoTheme.Palette.surface)
                        .background(ScrollWheelRouter())
                }
            } else {
                WelcomeView()
            }
        }
        .background(DiscoTheme.Palette.canvas)
    }

    private let chatColumnMaximumWidth: CGFloat = 720
    private let messageListEndID = "message-list-end"

    private var messageList: some View {
        ScrollViewReader { proxy in
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
                    }
                    Color.clear
                        .frame(height: 0)
                        .id(messageListEndID)
                }
                .frame(maxWidth: chatColumnMaximumWidth)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(messageListEndID, anchor: .bottom)
                }
            }
            .onChange(of: model.messages.count) { _ in
                DispatchQueue.main.async {
                    proxy.scrollTo(messageListEndID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let hasSelectedProject = model.selectedProject != nil
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(DiscoTheme.Palette.accent.opacity(0.72))
            Text(hasSelectedProject ? "开始新的会话" : "开始使用 Disco")
                .font(DiscoTheme.Typography.pageTitle)
            Text(hasSelectedProject
                ? "选择 Provider 后开始与项目协作。"
                : "添加一个项目，然后开始与 Codex 或 OpenCode 协作。")
                .font(DiscoTheme.Typography.body)
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
                    .font(DiscoTheme.Typography.body)
                    .lineSpacing(DiscoTheme.Typography.messageLineSpacing)
                    .tracking(DiscoTheme.Typography.messageTracking)
                    .background(DiscoTheme.Palette.userMessageSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: 620, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let status = message.status {
                    HStack {
                        Spacer()
                        Text(statusLabel(status))
                            .font(DiscoTheme.Typography.caption)
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
                        MessageItemView(item: item, isStreaming: isStreaming)
                    }
                } else if !message.text.isEmpty {
                    MarkdownText(text: message.text, isTextSelectionEnabled: !isStreaming)
                }
                if isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                }
                if let error = message.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(DiscoTheme.Typography.body)
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
    let isStreaming: Bool

    var body: some View {
        switch item {
        case let .text(_, text, _):
            MarkdownText(text: text, isTextSelectionEnabled: !isStreaming)
        case let .reasoning(_, text, state):
            DisclosureGroup("分析过程 · \(stateLabel(state))") {
                Text(text)
                    .font(DiscoTheme.Typography.body)
                    .lineSpacing(DiscoTheme.Typography.messageLineSpacing)
                    .tracking(DiscoTheme.Typography.messageTracking)
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
                    .font(DiscoTheme.Typography.bodyEmphasized)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label(item.text, systemImage: item.completed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.completed ? .secondary : .primary)
                }
            }
            .padding(12)
            .background(DiscoTheme.Palette.insetSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DiscoTheme.Palette.border, lineWidth: 1)
            }
        case let .notice(_, message, _):
            Text(message)
                .font(DiscoTheme.Typography.body)
                .foregroundStyle(.orange)
                .padding(10)
                .background(DiscoTheme.Palette.warningSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                        .font(DiscoTheme.Typography.code)
                        .textSelection(.enabled)
                }
                if let output, !output.isEmpty {
                    Divider()
                    Text(output)
                        .font(DiscoTheme.Typography.code)
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
        .background(DiscoTheme.Palette.insetSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DiscoTheme.Palette.border, lineWidth: 1)
        }
    }
}

private struct MarkdownText: View {
    let text: String
    let isTextSelectionEnabled: Bool

    var body: some View {
        Group {
            if isTextSelectionEnabled {
                markdown.textual.textSelection(.enabled)
            } else {
                markdown
            }
        }
    }

    private var markdown: some View {
        StructuredText(markdown: text)
            .textual.structuredTextStyle(.gitHub)
            .textual.paragraphStyle(DiscoMarkdownParagraphStyle())
            .textual.overflowMode(.wrap)
            .font(DiscoTheme.Typography.body)
            .foregroundStyle(.primary)
            .tracking(DiscoTheme.Typography.messageTracking)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiscoMarkdownParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(0.45))
            .textual.blockSpacing(.fontScaled(top: 0, bottom: 1.1))
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
                .font(DiscoTheme.Typography.bodyEmphasized)
            if let command = request.input["command"]?.stringValue {
                Text(command)
                    .font(DiscoTheme.Typography.code)
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
        .background(DiscoTheme.Palette.warningSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    let availableHeight: CGFloat
    @StateObject private var modelPickerPanel = AgentModelPickerPanelController()
    @State private var isModelControlHovered = false
    @State private var isSendButtonHovered = false
    @State private var editorHeight: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    GrowingTextEditor(
                        text: $model.draft,
                        height: $editorHeight,
                        isEditable: !isRunning,
                        maxHeight: maxEditorHeight
                    )

                    if model.draft.isEmpty {
                        Text("做什么都可以…")
                            .font(DiscoTheme.Typography.body)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 9)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: editorHeight)

                HStack(spacing: 8) {
                    agentModelControl
                    reasoningMenu
                    sandboxMenu
                    modeSwitcher

                    Spacer(minLength: 0)

                    sendButton
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .background(DiscoTheme.Palette.surface, in: RoundedRectangle(cornerRadius: DiscoTheme.Metrics.composerCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DiscoTheme.Metrics.composerCornerRadius, style: .continuous)
                    .strokeBorder(DiscoTheme.Palette.border, lineWidth: 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onExitCommand {
            if isRunning {
                model.cancelRun()
            }
        }
    }

    private var isRunning: Bool {
        guard let selectedSessionID = model.selectedSessionID else { return false }
        return model.runningSessionIDs.contains(selectedSessionID)
    }

    private var selectedModelName: String {
        guard let selectedModelID = model.selectedModelID else { return "Provider 默认" }
        return model.selectedProvider?.models.first { $0.id == selectedModelID }?.name ?? selectedModelID
    }

    private var selectedReasoningEfforts: [ReasoningEffort] {
        model.selectedProvider?.models.first { $0.id == model.selectedModelID }?.reasoningEfforts ?? []
    }

    private var supportsPlan: Bool {
        model.selectedProvider?.supportsPlan == true
    }

    private var maxEditorHeight: CGFloat {
        max(140, min(280, availableHeight * 0.55))
    }

    private var agentModelControl: some View {
        Button {
            modelPickerPanel.toggle(model: model)
        } label: {
            HStack(spacing: 6) {
                agentLogo
                Text(selectedModelName)
                    .lineLimit(1)
                    .font(DiscoTheme.Typography.bodyEmphasized)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                isModelControlHovered || modelPickerPanel.isPresented
                    ? DiscoTheme.Palette.hover
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: DiscoTheme.Metrics.rowCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isModelControlHovered = $0 }
        .disabled(isRunning)
        .help("切换 Agent 和模型")
        .background {
            ModelPickerPanelAnchor { anchorView in
                modelPickerPanel.setAnchorView(anchorView)
            }
        }
    }

    @ViewBuilder
    private var agentLogo: some View {
        if let provider = model.selectedProvider {
            Image(provider.kind.iconAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "sparkles")
                .font(DiscoTheme.Typography.control)
                .frame(width: 18, height: 18)
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
                .font(DiscoTheme.Typography.control)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(DiscoTheme.Palette.controlSurface, in: Capsule())
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
            .font(DiscoTheme.Typography.control)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(DiscoTheme.Palette.controlSurface, in: Capsule())
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
            .font(DiscoTheme.Typography.captionEmphasized)
            .foregroundStyle(model.planMode ? Color.primary : Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(model.planMode ? Color.clear : DiscoTheme.Palette.accent, in: Capsule())
            .disabled(isRunning)

            Button("Plan") {
                model.planMode = true
            }
            .buttonStyle(.plain)
            .font(DiscoTheme.Typography.captionEmphasized)
            .foregroundStyle(model.planMode ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(model.planMode ? DiscoTheme.Palette.accent : Color.clear, in: Capsule())
            .disabled(isRunning || !supportsPlan)
        }
        .padding(2)
        .background(DiscoTheme.Palette.controlSurface, in: Capsule())
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
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(canSend || isRunning ? .white : .secondary)
                .background(
                    canSend || isRunning
                        ? (isSendButtonHovered ? DiscoTheme.Palette.accent.opacity(0.84) : DiscoTheme.Palette.accent)
                        : DiscoTheme.Palette.insetSurface,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canSend && !isRunning)
        .onHover { isSendButtonHovered = $0 }
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

// Marker subclass so ScrollWheelRouter can recognize the composer's editor.
private final class ComposerScrollView: NSScrollView {}

// Routes scroll wheel events over the composer chrome and approval cards to the
// message list, so the whole conversation column scrolls. The message list's
// own region and the sidebar are handled natively and pass through untouched.
private struct ScrollWheelRouter: NSViewRepresentable {
    func makeNSView(context: Context) -> RouterView {
        RouterView()
    }

    func updateNSView(_ nsView: RouterView, context: Context) {}

    final class RouterView: NSView {
        private var monitor: Any?
        private weak var messageListScrollView: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.route(event) ?? event
                }
            } else if window == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func route(_ event: NSEvent) -> NSEvent? {
            guard let window = event.window, window === self.window,
                let hitView = window.contentView?.hitTest(event.locationInWindow)
            else { return event }

            var enclosingScrollView: NSScrollView?
            var current: NSView? = hitView
            while let view = current, enclosingScrollView == nil {
                enclosingScrollView = view as? NSScrollView
                current = view.superview
            }

            if let scrollView = enclosingScrollView {
                // Scroll views handle their own events; the composer editor is the
                // exception: it only needs them once its content overflows.
                let isComposerEditor = scrollView is ComposerScrollView
                if !isComposerEditor {
                    return event
                }
                let contentHeight = scrollView.documentView?.frame.height ?? 0
                if contentHeight > scrollView.contentView.bounds.height {
                    return event
                }
            }

            guard let messageListScrollView = resolveMessageListScrollView() else { return event }
            let frame = messageListScrollView.convert(messageListScrollView.bounds, to: nil)
            let location = event.locationInWindow
            let isOverMessageColumn = (frame.minX...frame.maxX).contains(location.x)
                && location.y <= frame.maxY
            guard isOverMessageColumn else { return event }

            messageListScrollView.scrollWheel(with: event)
            return nil
        }

        private func resolveMessageListScrollView() -> NSScrollView? {
            if let messageListScrollView, messageListScrollView.window === window {
                return messageListScrollView
            }
            guard let contentView = window?.contentView else { return nil }
            // The message list is the widest scroll view in the window; the editor
            // and the sidebar's list are both narrower.
            var stack: [NSView] = [contentView]
            var widest: NSScrollView?
            while let view = stack.popLast() {
                if let scrollView = view as? NSScrollView, !(scrollView is ComposerScrollView),
                    widest == nil || scrollView.frame.width > widest!.frame.width
                {
                    widest = scrollView
                }
                stack.append(contentsOf: view.subviews)
            }
            messageListScrollView = widest
            return widest
        }
    }
}

private struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let isEditable: Bool
    let maxHeight: CGFloat

    private let minHeight: CGFloat = 42

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            height: $height,
            minHeight: minHeight,
            maxHeight: maxHeight
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 1, height: minHeight))
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 12, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 1,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.maxHeight = maxHeight
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        textView.isEditable = isEditable
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        if textView.string != text {
            textView.delegate = nil
            textView.string = text
            textView.delegate = context.coordinator
        }

        context.coordinator.updateHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        let height: Binding<CGFloat>
        let minHeight: CGFloat
        var maxHeight: CGFloat
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        init(
            text: Binding<String>,
            height: Binding<CGFloat>,
            minHeight: CGFloat,
            maxHeight: CGFloat
        ) {
            self.text = text
            self.height = height
            self.minHeight = minHeight
            self.maxHeight = maxHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView,
                  let changedTextView = notification.object as? NSTextView,
                  changedTextView === textView else { return }
            text.wrappedValue = textView.string
            updateHeight()
        }

        func updateHeight() {
            guard let textView, let textContainer = textView.textContainer else { return }

            if let scrollView {
                let contentWidth = scrollView.contentView.bounds.width
                if contentWidth > 0 {
                    var frame = textView.frame
                    frame.size.width = contentWidth
                    textView.frame = frame
                    textContainer.containerSize = NSSize(
                        width: contentWidth,
                        height: CGFloat.greatestFiniteMagnitude
                    )
                }
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
            }

            textView.layoutManager?.ensureLayout(for: textContainer)
            let usedHeight = textView.layoutManager?.usedRect(for: textContainer).height ?? minHeight
            let fittingHeight = ceil(usedHeight + textView.textContainerInset.height * 2 + 2)
            let nextHeight = min(maxHeight, max(minHeight, fittingHeight))

            var frame = textView.frame
            frame.size.height = nextHeight
            textView.frame = frame

            guard abs(height.wrappedValue - nextHeight) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.height.wrappedValue - nextHeight) > 0.5 else { return }
                self.height.wrappedValue = nextHeight
            }
        }
    }
}

private struct ModelPickerPanelAnchor: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.postsFrameChangedNotifications = true
        onResolve(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onResolve(nsView)
    }
}

@MainActor
private final class AgentModelPickerPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPresented = false

    private var panel: AgentModelPickerPanel?
    private weak var anchorView: NSView?
    private var outsideClickMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    func setAnchorView(_ anchorView: NSView) {
        self.anchorView = anchorView
    }

    func toggle(model: AppModel) {
        if panel == nil {
            present(model: model)
        } else {
            close()
        }
    }

    func close() {
        removeObservers()
        panel?.onCancel = nil
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel = nil
        isPresented = false
    }

    private func present(model: AppModel) {
        guard let anchorView, let anchorWindow = anchorView.window else { return }

        let pickerView = AgentModelPickerView(initialAgent: model.selectedAgent) { [weak self] in
            self?.close()
        }
        .environmentObject(model)

        let hostingView = NSHostingView(rootView: pickerView)
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: modelPickerWidth, height: modelPickerHeight)
        )
        hostingView.autoresizingMask = [.width, .height]

        let panel = AgentModelPickerPanel(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: modelPickerWidth, height: modelPickerHeight)
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.hidesOnDeactivate = true
        panel.acceptsMouseMovedEvents = true
        panel.onCancel = { [weak self] in
            self?.close()
        }
        panel.delegate = self

        self.panel = panel
        isPresented = true
        observe(anchorView: anchorView, window: anchorWindow)
        repositionPanel()
        panel.makeKeyAndOrderFront(nil)
    }

    private func observe(anchorView: NSView, window: NSWindow) {
        let notificationCenter = NotificationCenter.default
        windowObservers = [
            notificationCenter.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.repositionPanel()
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.repositionPanel()
                }
            },
            notificationCenter.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: anchorView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.repositionPanel()
                }
            },
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.close()
                }
            }
        ]

        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }

            let location = NSEvent.mouseLocation
            let isInsidePanel = panel.frame.contains(location)
            let isInsideAnchor = self.anchorView.flatMap { self.screenFrame(for: $0)?.contains(location) } ?? false
            if !isInsidePanel && !isInsideAnchor {
                self.close()
            }
            return event
        }
    }

    private func repositionPanel() {
        guard let panel, let anchorView, let screenRect = screenFrame(for: anchorView) else { return }
        let visibleFrame = anchorView.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let visibleFrame else { return }

        var origin = NSPoint(x: screenRect.minX, y: screenRect.maxY + 8)
        if origin.y + panel.frame.height > visibleFrame.maxY {
            origin.y = screenRect.minY - panel.frame.height - 8
        }

        let minimumX = visibleFrame.minX + 8
        let maximumX = visibleFrame.maxX - panel.frame.width - 8
        origin.x = min(max(origin.x, minimumX), maximumX)
        panel.setFrameOrigin(origin)
    }

    private func screenFrame(for view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func removeObservers() {
        let notificationCenter = NotificationCenter.default
        windowObservers.forEach(notificationCenter.removeObserver)
        windowObservers.removeAll()

        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}

private final class AgentModelPickerPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private struct AgentModelPickerView: View {
    @EnvironmentObject private var model: AppModel
    let onDismiss: () -> Void
    @State private var highlightedAgent: BackendKind
    @State private var hoveredAgent: BackendKind?
    @State private var modelSearchText = ""

    init(initialAgent: BackendKind, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        _highlightedAgent = State(initialValue: initialAgent)
    }

    private var highlightedProvider: ProviderInfo? {
        model.availableProviders.first { $0.kind == highlightedAgent }
    }

    var body: some View {
        HStack(spacing: 0) {
            agentList
                .frame(width: 58)
            Divider()
            modelList
                .frame(maxWidth: .infinity)
        }
        .frame(width: modelPickerWidth, height: modelPickerHeight)
        .background(DiscoTheme.Palette.surface, in: RoundedRectangle(cornerRadius: DiscoTheme.Metrics.cardCornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: DiscoTheme.Metrics.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DiscoTheme.Metrics.cardCornerRadius, style: .continuous)
                .stroke(DiscoTheme.Palette.border, lineWidth: 1)
        }
    }

    private var agentList: some View {
        List {
            ForEach(model.availableProviders) { provider in
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        highlightedAgent = provider.kind
                        modelSearchText = ""
                    } label: {
                        Image(provider.kind.iconAssetName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                    .background(
                        agentBackground(for: provider.kind),
                        in: RoundedRectangle(cornerRadius: DiscoTheme.Metrics.rowCornerRadius, style: .continuous)
                    )
                    .help(provider.kind.displayName)
                    .accessibilityLabel(provider.kind.displayName)
                    .onHover { isHovering in
                        if isHovering {
                            hoveredAgent = provider.kind
                        } else if hoveredAgent == provider.kind {
                            hoveredAgent = nil
                        }
                    }
                    Spacer(minLength: 0)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(DiscoTheme.Palette.sidebar)
    }

    private func agentBackground(for agent: BackendKind) -> Color {
        if highlightedAgent == agent {
            return DiscoTheme.Palette.selectionStrong
        }
        if hoveredAgent == agent {
            return DiscoTheme.Palette.hover
        }
        return .clear
    }

    private var filteredModels: [ModelInfo] {
        let normalizedSearchText = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSearchText.isEmpty else {
            return highlightedProvider?.models ?? []
        }
        return (highlightedProvider?.models ?? []).filter {
            $0.name.localizedCaseInsensitiveContains(normalizedSearchText)
                || $0.id.localizedCaseInsensitiveContains(normalizedSearchText)
        }
    }

    private var modelsByProvider: [(providerID: String, models: [ModelInfo])] {
        let modelsByProviderID = Dictionary(grouping: filteredModels) { model in
            model.id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? highlightedAgent.displayName
        }
        return modelsByProviderID
            .map { (providerID: $0.key, models: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.providerID < $1.providerID }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("模型")
                .font(DiscoTheme.Typography.captionEmphasized)
                .foregroundStyle(.secondary)

            if highlightedProvider?.isLoadingModels == true {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载模型")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 8)
            } else if let highlightedProvider, !highlightedProvider.models.isEmpty {
                TextField("搜索模型", text: $modelSearchText)
                    .textFieldStyle(.roundedBorder)

                List {
                    PickerRow(selected: model.selectedAgent == highlightedAgent && model.selectedModelID == nil) {
                        selectModel(nil)
                    } label: {
                        Text("Provider 默认")
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)

                    ForEach(modelsByProvider, id: \.providerID) { providerModels in
                        Section(providerModels.providerID) {
                            ForEach(providerModels.models) { modelInfo in
                                PickerRow(selected: model.selectedAgent == highlightedAgent && model.selectedModelID == modelInfo.id) {
                                    selectModel(modelInfo.id)
                                } label: {
                                    Text(modelInfo.name)
                                        .lineLimit(1)
                                }
                                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                                .listRowBackground(Color.clear)
                            }
                        }
                    }

                    if modelsByProvider.isEmpty {
                        Text("未找到匹配的模型")
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
            } else {
                Text(highlightedProvider?.modelLoadFailureDescription ?? "暂无模型")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
            }
        }
        .padding(8)
    }

    private func selectModel(_ modelID: String?) {
        if model.selectedAgent != highlightedAgent {
            model.updateAgent(highlightedAgent)
        }
        model.updateModel(modelID)
        onDismiss()
    }
}

private struct PickerRow<Label: View>: View {
    let selected: Bool
    private let label: Label
    private let action: () -> Void
    @State private var isHovering = false

    init(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.selected = selected
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                label
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(DiscoTheme.Typography.captionEmphasized)
                        .foregroundStyle(.secondary)
                }
            }
            .font(DiscoTheme.Typography.body)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: DiscoTheme.Metrics.rowCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if selected {
            return DiscoTheme.Palette.selection
        }
        return isHovering ? DiscoTheme.Palette.hover : .clear
    }
}
