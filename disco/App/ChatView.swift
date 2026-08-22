import AppKit
import MarkdownView
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ConversationStore
    let projectID: UUID?
    let reconnectProject: (() -> Void)?
    @State private var isConfirmingClear = false
    @State private var isAtLatestMessage = true
    @State private var shouldFollowLatestMessage = true
    @State private var isUserScrolling = false
    @State private var selectedToolCallID: String?
    /// 防抖滚动任务：合并同一帧内的多次滚动请求，避免在 onChange 调用栈内同步 scrollTo
    @State private var scrollTask: Task<Void, Never>?

    private static let latestMessageAnchor = "latest-message-anchor"

    init(
        store: ConversationStore,
        projectID: UUID? = nil,
        reconnectProject: (() -> Void)? = nil
    ) {
        self.store = store
        self.projectID = projectID
        self.reconnectProject = reconnectProject
    }

    private var project: ProjectSnapshot? {
        guard let projectID else { return nil }
        return appState.projects.first { $0.id == projectID }
    }

    /// 防抖滚动到底部：合并同一帧内的多次请求，并在下一 run loop 异步执行。
    ///
    /// 流式消息时 `messages` 高频变化，若在 `onChange` 调用栈内同步 `scrollTo`，
    /// 滚动回调会在此期间修改视图状态，触发 SwiftUI 运行时警告
    /// （"Publishing changes from within view updates"）。
    private func scheduleScrollToLatest(_ proxy: ScrollViewProxy) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            proxy.scrollTo(Self.latestMessageAnchor, anchor: .bottom)
        }
    }

    private var projectUnavailable: Bool {
        guard let projectID else { return false }
        guard let availability = appState.projectAvailability[projectID] else { return true }
        if case .unavailable = availability { return true }
        return false
    }

    private var canUseConversation: Bool {
        appState.isActiveVendorConfigured && !projectUnavailable
    }

    private var providerHost: String {
        // 订阅服务商没有 Base URL，展示服务商名
        if appState.activeVendor == .chatgpt { return "Codex (OpenAI)" }
        return URL(string: appState.baseURL)?.host ?? appState.baseURL
    }

    private var conversationTitle: String {
        guard let text = store.messages.first(where: { $0.role == .user })?.text else {
            return "新对话"
        }
        return text.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? "新对话"
    }

    private var selectedToolCall: ChatMessage.ToolCallSnapshot? {
        guard let selectedToolCallID else { return nil }
        for message in store.messages {
            for part in message.parts {
                if case let .toolCall(call) = part, call.id == selectedToolCallID {
                    return call
                }
            }
        }
        return nil
    }

    private var isToolInspectorPresented: Binding<Bool> {
        Binding(
            get: { selectedToolCall != nil },
            set: { isPresented in
                if !isPresented {
                    selectedToolCallID = nil
                }
            }
        )
    }

    var body: some View {
        ZStack {
            DiscoTheme.canvas
                .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 32) {
                        if store.messages.isEmpty {
                            EmptyConversationView(
                                isConfigured: appState.isActiveVendorConfigured,
                                model: appState.model,
                                providerHost: providerHost
                            )
                            .containerRelativeFrame(.vertical, alignment: .center) { height, _ in
                                max(height - 150, 320)
                            }
                        } else {
                            ForEach(store.messages) { message in
                                MessageRow(
                                    message: message,
                                    isStreaming: store.isStreaming && message.id == store.messages.last?.id,
                                    errorMessage: message.id == store.messages.last?.id ? store.errorMessage : nil,
                                    canRetry: store.canRetry,
                                    retry: store.retryLastMessage,
                                    dismissError: store.dismissError,
                                    selectedToolCallID: selectedToolCallID,
                                    selectToolCall: { toolCallID in
                                        withAnimation(reduceMotion ? nil : DiscoMotion.spring) {
                                            selectedToolCallID = toolCallID
                                        }
                                    }
                                )
                                .id(message.id)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.latestMessageAnchor)
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 28)
                    .padding(.top, 36)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 24
                } action: { _, isAtLatest in
                    // 滚动几何回调可能在布局/视图更新期间触发，延迟到下一个
                    // run loop 写入状态，避免 SwiftUI 运行时警告
                    // （"Publishing changes from within view updates"）。
                    Task { @MainActor in
                        isAtLatestMessage = isAtLatest
                        if isAtLatest {
                            shouldFollowLatestMessage = true
                        } else if isUserScrolling {
                            shouldFollowLatestMessage = false
                        }
                    }
                }
                .onScrollPhaseChange { _, phase in
                    let isScrolling = phase.isScrolling && phase != .animating
                    Task { @MainActor in
                        isUserScrolling = isScrolling
                    }
                }
                .onChange(of: store.messages) {
                    guard shouldFollowLatestMessage else { return }
                    scheduleScrollToLatest(proxy)
                }
                .onAppear {
                    scheduleScrollToLatest(proxy)
                }
                .overlay(alignment: .bottom) {
                    if !isAtLatestMessage && !shouldFollowLatestMessage {
                        Button {
                            shouldFollowLatestMessage = true
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                proxy.scrollTo(Self.latestMessageAnchor, anchor: .bottom)
                            }
                        } label: {
                            Label("回到最新", systemImage: "arrow.down")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(DiscoTheme.elevatedSurface, in: Capsule())
                                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        }
                        .buttonStyle(DiscoPressButtonStyle())
                        .padding(.bottom, 12)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
                        )
                        .accessibilityLabel("回到最新消息")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let approval = store.pendingApproval {
                    ApprovalPromptView(
                        approval: approval,
                        onApprove: {
                            store.respondToApproval(decision: "approve_once")
                        },
                        onApproveForSession: {
                            store.respondToApproval(decision: "approve_for_session")
                        },
                        onDecline: {
                            store.respondToApproval(decision: "decline")
                        }
                    )
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .bottom))
                    )
                }

                ComposerView(
                    store: store,
                    isConfigured: canUseConversation,
                    projectUnavailable: projectUnavailable
                )
                .frame(maxWidth: 760)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.2),
                value: store.pendingApproval?.approvalId
            )
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: shouldFollowLatestMessage)
        .safeAreaInset(edge: .top, spacing: 0) {
            if projectUnavailable {
                ProjectUnavailableBanner(reconnect: reconnectProject)
            }
        }
        .navigationTitle(conversationTitle)
        .toolbar {
            if let project {
                ToolbarItem(placement: .navigation) {
                    WorkspaceMenu(
                        project: project,
                        unavailable: projectUnavailable,
                        reconnect: reconnectProject
                    )
                }
            }

            ToolbarSpacer(.flexible)

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("清空当前对话", systemImage: "trash", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .disabled(store.messages.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 20, height: 20)
                }
                .help("更多对话操作")
            }
        }
        .confirmationDialog(
            "清空当前对话？",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                store.clear()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这只会清空当前窗口中的消息。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .discoRequestClearConversation)) { _ in
            guard !store.messages.isEmpty else { return }
            isConfirmingClear = true
        }
        .onChange(of: store.messages) {
            if selectedToolCall != nil {
                return
            }
            selectedToolCallID = nil
        }
        .inspector(isPresented: isToolInspectorPresented) {
            if let selectedToolCall {
                ToolCallInspector(call: selectedToolCall) {
                    selectedToolCallID = nil
                }
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 340, max: 420)
        .task(id: "\(appState.activeVendor.rawValue):\(appState.model)") {
            await appState.refreshCodexModelCatalogIfNeeded()
        }
    }
}

private struct WorkspaceMenu: View {
    let project: ProjectSnapshot
    let unavailable: Bool
    let reconnect: (() -> Void)?

    var body: some View {
        Menu {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([project.workspaceRoot])
            }
            .disabled(unavailable)

            if let reconnect {
                Button("重新关联目录…", action: reconnect)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: unavailable ? "folder.badge.questionmark" : "folder")
                    .foregroundStyle(unavailable ? .orange : DiscoTheme.accent)
                Text(project.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .help(project.workspaceRoot.path)
        .accessibilityLabel("Workspace：\(project.name)")
    }
}

private struct ProjectUnavailableBanner: View {
    let reconnect: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("项目目录不可用，重新关联后才能继续对话。")
                .font(.caption)
            Spacer(minLength: 8)
            if let reconnect {
                Button("重新关联目录", action: reconnect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct EmptyConversationView: View {
    let isConfigured: Bool
    let model: String
    let providerHost: String

    private var title: String {
        isConfigured ? "开始一段对话" : "连接你的模型"
    }

    var body: some View {
        HStack(spacing: 26) {
            DiscoMark(size: 76)

            VStack(alignment: .leading, spacing: 11) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))

                if isConfigured {
                    Text("Disco 已准备好。输入问题、想法或一段需要继续完成的文字。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("\(model)  ·  \(providerHost)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("添加 Base URL 和 API Key，再选择一个模型。凭据只保存在这台 Mac。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SettingsLink {
                        Label("打开连接设置", systemImage: "arrow.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .background(DiscoTheme.accent, in: Capsule())
                    }
                    .buttonStyle(DiscoPressButtonStyle())
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    let errorMessage: String?
    let canRetry: Bool
    let retry: () -> Void
    let dismissError: () -> Void
    let selectedToolCallID: String?
    let selectToolCall: (String) -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 8) {
            if message.role == .user {
                HStack(alignment: .top) {
                    Spacer(minLength: 100)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(message.text)
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 11)
                            .background(DiscoTheme.accent.opacity(0.11))
                            .clipShape(RoundedRectangle(cornerRadius: DiscoRadius.medium, style: .continuous))

                        if !message.text.isEmpty {
                            messageActionButton(action: copyMessage)
                                .opacity(isHovered ? 1 : 0.45)
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 13) {
                    VStack(alignment: .leading, spacing: 10) {
                        // 无 reasoning 内容的生成中用扫光占位；有 reasoning 时由活动轨道承担状态展示。
                        if message.isEmpty && isStreaming && !message.parts.contains(where: { part in
                            if case .reasoning = part { return true }
                            return false
                        }) {
                            ActivityTimelineRow(kind: .thinking(isActive: true)) {
                                ThinkingIndicator()
                            }
                        }

                        ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                            switch part {
                            case let .text(content):
                                if !content.text.isEmpty {
                                    ActivityTimelineRow(kind: .response) {
                                        MarkdownView(content.text)
                                    }
                                }
                            case let .reasoning(reasoning):
                                ActivityTimelineRow(
                                    kind: .thinking(
                                        isActive: isStreaming
                                            && message.text.isEmpty
                                            && !message.hasRunningToolCall
                                    )
                                ) {
                                    ReasoningDisclosure(
                                        reasoning: reasoning,
                                        isThinking: isStreaming
                                            && message.text.isEmpty
                                            && !message.hasRunningToolCall
                                    )
                                }
                            case let .toolCall(call):
                                ActivityTimelineRow(kind: .tool(isCompleted: call.isCompleted)) {
                                    ToolCallRow(
                                        call: call,
                                        isSelected: selectedToolCallID == call.id,
                                        select: { selectToolCall(call.id) }
                                    )
                                }
                            case let .hostedTool(tool):
                                ActivityTimelineRow(kind: .web(isCompleted: tool.status == .completed)) {
                                    HostedWebSearchRow(tool: tool, isStreaming: isStreaming)
                                }
                            }
                        }

                        if !isStreaming && !message.text.isEmpty {
                            HStack {
                                Spacer(minLength: 0)
                                messageActionButton(action: copyMessage)
                                    .opacity(isHovered ? 1 : 0.55)
                            }
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .overlay(alignment: .leading) {
                        if !message.parts.isEmpty || (message.isEmpty && isStreaming) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.10))
                                .frame(width: 1)
                                .padding(.leading, 10.5)
                                .padding(.vertical, 10)
                        }
                    }

                    Spacer(minLength: 40)
                }
            }

            if let errorMessage {
                HStack {
                    if message.role == .user {
                        Spacer(minLength: 100)
                    }

                    ChatInlineError(
                        message: errorMessage,
                        canRetry: canRetry,
                        retry: retry,
                        dismiss: dismissError
                    )
                    .frame(maxWidth: message.role == .user ? 520 : 680)

                    if message.role == .assistant {
                        Spacer(minLength: 40)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
        .contextMenu {
            if !message.text.isEmpty {
                Button("复制") {
                    copyMessage()
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: errorMessage)
    }

    private func messageActionButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(DiscoPressButtonStyle())
        .help("复制")
        .accessibilityLabel("复制消息")
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
}

private enum ActivityMarkerKind {
    case thinking(isActive: Bool)
    case tool(isCompleted: Bool)
    case response
    case web(isCompleted: Bool)
}

private struct ActivityTimelineRow<Content: View>: View {
    let kind: ActivityMarkerKind
    let content: Content

    init(
        kind: ActivityMarkerKind,
        @ViewBuilder content: () -> Content
    ) {
        self.kind = kind
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ActivityMarker(kind: kind)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ActivityMarker: View {
    let kind: ActivityMarkerKind

    private var icon: String {
        switch kind {
        case let .thinking(isActive): return isActive ? "brain" : "checkmark"
        case let .tool(isCompleted): return isCompleted ? "checkmark" : "terminal"
        case .response: return "sparkles"
        case .web: return "globe"
        }
    }

    private var color: Color {
        switch kind {
        case .thinking: return DiscoTheme.reasoningAccent
        case let .tool(isCompleted): return isCompleted ? .green : .orange
        case .response: return DiscoTheme.accent
        case let .web(isCompleted): return isCompleted ? .blue : .orange
        }
    }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .background(color.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct ThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("思考中")
            .font(.callout)
            .foregroundStyle(.secondary)
            .modifier(ShimmerModifier(reduceMotion: reduceMotion))
    }
}

/// 从左到右扫光：一个高光条在文字形状内循环掠过。
private struct ShimmerModifier: ViewModifier {
    let reduceMotion: Bool
    var duration: Double = 2.0

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            if reduceMotion {
                content
            } else {
                let progress = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: duration) / duration
                let position = -0.4 + progress * 1.8

                content
                    .overlay {
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.85), .clear],
                            startPoint: UnitPoint(x: position - 0.25, y: 0.5),
                            endPoint: UnitPoint(x: position + 0.25, y: 0.5)
                        )
                    }
                    .mask(content)
            }
        }
    }
}

private struct ReasoningDisclosure: View {
    let reasoning: String
    /// 思考阶段默认保持紧凑，用户主动展开后不再自动改变其选择。
    let isThinking: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var thinkingStartedAt: Date?
    @State private var completedThinkingDuration: Int?

    private var preview: String {
        reasoning
            .split(whereSeparator: \Character.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : DiscoMotion.spring) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    VStack(alignment: .leading, spacing: 2) {
                        reasoningStatus
                        if !isExpanded && !preview.isEmpty {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer(minLength: 10)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isThinking ? "思考中" : (isExpanded ? "收起思考摘要" : "展开思考摘要"))

            if isExpanded {
                Group {
                    if isThinking {
                        // 流式摘要限高滚动；完成后交给 MarkdownView，保留列表和代码格式。
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(reasoning)
                                    .id("bottom")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(maxHeight: 240)
                            .onChange(of: reasoning.count) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    } else {
                        MarkdownView(reasoning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(DiscoTheme.reasoningAccent.opacity(0.055))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(DiscoTheme.reasoningAccent.opacity(0.55))
                        .frame(width: 2)
                        .padding(.vertical, 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: DiscoRadius.small, style: .continuous))
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            if isThinking { thinkingStartedAt = Date() }
        }
        .onChange(of: isThinking) { _, thinking in
            if thinking {
                thinkingStartedAt = Date()
                completedThinkingDuration = nil
            } else if let thinkingStartedAt {
                completedThinkingDuration = max(1, Int(Date().timeIntervalSince(thinkingStartedAt)))
                self.thinkingStartedAt = nil
            }
        }
    }

    @ViewBuilder
    private var reasoningStatus: some View {
        if isThinking {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(thinkingStartedAt ?? context.date)))
                Text("正在思考 · \(elapsed) 秒")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DiscoTheme.reasoningAccent)
                    .modifier(ShimmerModifier(reduceMotion: reduceMotion))
            }
        } else if let completedThinkingDuration {
            Text("思考摘要 · \(completedThinkingDuration) 秒")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DiscoTheme.reasoningAccent)
        } else {
            Text("思考摘要")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DiscoTheme.reasoningAccent)
        }
    }
}

/// 供应商托管的网络搜索块；只展示状态，不参与本地 Tool 审批或执行。
private struct HostedWebSearchRow: View {
    let tool: HostedToolSnapshot
    let isStreaming: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : DiscoMotion.spring) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    if let statusTitle {
                        Text(statusTitle)
                            .font(.caption.weight(.medium))
                            .modifier(ShimmerModifier(
                                reduceMotion: reduceMotion || tool.status == .completed
                            ))
                    }
                    if let summary = actionSummary {
                        Text("· \(summary)")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    if hasDetails {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasDetails)
            .accessibilityLabel(accessibilityTitle)

            if isExpanded && hasDetails {
                VStack(alignment: .leading, spacing: 7) {
                    if let action = tool.action {
                        HostedToolActionDetails(action: action)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: DiscoRadius.small, style: .continuous)
                )
            }
        }
    }

    private var statusTitle: String? {
        guard isStreaming || tool.status == .completed else { return nil }
        switch tool.status {
        case .inProgress: return "准备搜索网络"
        case .searching: return "正在搜索网络"
        case .completed: return "已完成网络搜索"
        }
    }

    private var actionSummary: String? {
        switch tool.action {
        case let .search(queries): queries.first
        case let .openPage(url): URL(string: url)?.host ?? url
        case let .findInPage(_, pattern): pattern
        case nil: nil
        }
    }

    private var hasDetails: Bool {
        tool.action != nil
    }

    private var accessibilityTitle: String {
        [statusTitle, actionSummary].compactMap { $0 }.joined(separator: "，")
    }
}

private struct HostedToolActionDetails: View {
    let action: HostedToolAction

    var body: some View {
        switch action {
        case let .search(queries):
            if queries.isEmpty {
                Label("搜索网络", systemImage: "magnifyingglass")
            } else {
                ForEach(Array(queries.enumerated()), id: \.offset) { _, query in
                    Label(query, systemImage: "magnifyingglass")
                }
            }
        case let .openPage(url):
            Label(URL(string: url)?.host ?? url, systemImage: "doc.text.magnifyingglass")
        case let .findInPage(url, pattern):
            Label("在 \(URL(string: url)?.host ?? url) 中查找“\(pattern)”", systemImage: "text.magnifyingglass")
        }
    }
}

/// 历史消息中的工具调用块；实时事件和历史 parts 共享同一套展示。
private struct ToolCallRow: View {
    let call: ChatMessage.ToolCallSnapshot
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        ToolExecutionView(call: call, isSelected: isSelected, onSelect: select)
    }
}

private struct ChatInlineError: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)

            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if canRetry {
                Button("重试", action: retry)
                    .buttonStyle(DiscoPressButtonStyle())
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(DiscoPressButtonStyle())
            .foregroundStyle(.secondary)
            .help("关闭错误")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: DiscoRadius.medium))
    }
}

private struct ComposerView: View {
    @ObservedObject var store: ConversationStore
    let isConfigured: Bool
    let projectUnavailable: Bool

    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isModelDrawerPresented = false
    @State private var isReasoningSettingsPresented = false
    @State private var isContextUsagePresented = false
    @State private var isModelTriggerHovered = false
    @State private var isReasoningTriggerHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                "",
                text: $store.draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...6)
            .focused($isFocused)
            .disabled(!isConfigured)
            .onKeyPress(.return, phases: .down) { keyPress in
                // 输入法（拼音等）组字期间，回车属于输入法（确认候选词），
                // 放行给文本系统处理，避免误发送。
                if isIMEComposing {
                    return .ignored
                }
                if keyPress.modifiers.contains(.shift) {
                    store.draft.append("\n")
                    return .handled
                }
                store.send()
                return .handled
            }

            HStack(spacing: 8) {
                if isConfigured {
                    modelDrawerTrigger
                    reasoningSettingsTrigger
                } else if projectUnavailable {
                    Image(systemName: "folder.badge.questionmark")
                    Text("项目目录不可用")
                } else {
                    Image(systemName: "lock.fill")
                    Text("API Key 仅保存在本机")
                }

                Spacer(minLength: 12)

                if let runStatusText = store.runStatusText {
                    Text(runStatusText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if isConfigured {
                    // 已配置：不显示任何提示文案
                    EmptyView()
                } else if projectUnavailable {
                    Text("重新关联后继续")
                        .foregroundStyle(.tertiary)
                } else {
                    SettingsLink {
                        Text("连接")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(DiscoTheme.accent)
                    }
                    .buttonStyle(.plain)
                }

                if isConfigured {
                    contextUsageTrigger
                }
                composerActionButton
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DiscoRadius.large, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 7)
        .onAppear {
            if isConfigured {
                isFocused = true
            }
        }
        .onChange(of: isConfigured) { _, configured in
            if configured {
                isFocused = true
            }
        }
        .onChange(of: isModelDrawerPresented) { _, presented in
            if !presented { isFocused = true }
        }
        .onChange(of: isReasoningSettingsPresented) { _, presented in
            if !presented { isFocused = true }
        }
    }

    // MARK: - 配置行控件

    /// 焦点输入框是否处于输入法组字状态（marked text）。
    private var isIMEComposing: Bool {
        if let client = NSTextInputContext.current?.client, client.hasMarkedText() {
            return true
        }
        if let responder = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
           responder.hasMarkedText() {
            return true
        }
        return false
    }

    /// 模型入口直接打开双栏选择器，不再经过综合设置菜单。
    private var modelDrawerTrigger: some View {
        let backgroundOpacity: Double
        let borderOpacity: Double
        if isModelDrawerPresented {
            backgroundOpacity = 0.20
            borderOpacity = 0.52
        } else if isModelTriggerHovered {
            backgroundOpacity = 0.16
            borderOpacity = 0.40
        } else {
            backgroundOpacity = 0.11
            borderOpacity = 0.28
        }

        return Button {
            isModelDrawerPresented = true
        } label: {
            HStack(spacing: 6) {
                VendorBrandIcon(vendor: appState.activeVendor)
                Text(modelLabel)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DiscoTheme.accent)
            }
            .contentTransition(.opacity)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 11)
            .frame(minHeight: 30)
            .background(DiscoTheme.accent.opacity(backgroundOpacity), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(DiscoTheme.accent.opacity(borderOpacity), lineWidth: 1)
            }
        }
        .buttonStyle(DiscoPressButtonStyle())
        .disabled(store.isStreaming)
        .opacity(store.isStreaming ? 0.52 : 1)
        .onHover { isModelTriggerHovered = $0 }
        .help(store.isStreaming ? "回复完成后可切换模型" : "选择服务商与模型")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: modelLabel)
        .popover(isPresented: $isModelDrawerPresented, arrowEdge: .bottom) {
            ModelDrawer(dismiss: { isModelDrawerPresented = false })
        }
    }

    private var reasoningSettingsTrigger: some View {
        let vendor = appState.activeVendor
        let efforts = appState.reasoningEfforts(for: vendor)
        let capabilityIsMissing = vendor == .chatgpt
            && appState.modelCatalogEntry(for: vendor, model: appState.model)?
                .supportedReasoningEfforts == nil
        let title = reasoningSelectionTitle(appState: appState, vendor: vendor)
        let isDisabled = store.isStreaming || (efforts.isEmpty && vendor != .chatgpt)
        let backgroundOpacity: Double
        let borderOpacity: Double
        if isReasoningSettingsPresented {
            backgroundOpacity = 0.20
            borderOpacity = 0.54
        } else if isReasoningTriggerHovered {
            backgroundOpacity = 0.16
            borderOpacity = 0.42
        } else {
            backgroundOpacity = 0.11
            borderOpacity = 0.30
        }

        return Button {
            isReasoningSettingsPresented = true
        } label: {
            HStack(spacing: 5) {
                if appState.isRefreshingCodexModelCatalog && capabilityIsMissing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DiscoTheme.reasoningAccent)
                } else {
                    Image(systemName: "brain")
                }
                Text("\(vendor == .chatgpt || efforts.count > 2 ? "推理" : "思考")：\(title)")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(DiscoTheme.reasoningAccent)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(DiscoTheme.reasoningAccent.opacity(backgroundOpacity), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(DiscoTheme.reasoningAccent.opacity(borderOpacity), lineWidth: 1)
            }
        }
        .buttonStyle(DiscoPressButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.52 : 1)
        .onHover { isReasoningTriggerHovered = $0 }
        .help(store.isStreaming ? "回复完成后可调整推理设置" : "调整推理设置")
        .popover(isPresented: $isReasoningSettingsPresented, arrowEdge: .bottom) {
            ReasoningSettingsPopover(dismiss: { isReasoningSettingsPresented = false })
        }
    }

    private var contextUsageTrigger: some View {
        let usage = store.contextUsage
        let configuredLimit = appState.contextWindow(
            for: appState.activeVendor,
            model: appState.model
        )
        let limit = configuredLimit ?? usage?.contextWindow
        let current = usage?.current.inputTokens
        let usageColor = contextUsageColor(estimate: current, limit: limit)

        return Button {
            isContextUsagePresented = true
        } label: {
            HStack(spacing: 7) {
                ContextUsageRing(estimate: current, limit: limit, color: usageColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text("上下文")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(contextUsageSummary(current: current, limit: limit))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.045), in: Capsule())
        }
        .buttonStyle(DiscoPressButtonStyle())
        .help("查看上下文占用")
        .accessibilityLabel("查看上下文占用")
        .popover(isPresented: $isContextUsagePresented, arrowEdge: .bottom) {
            ContextUsagePopover(
                store: store,
                vendor: appState.activeVendor,
                model: appState.model,
                usage: usage,
                limit: limit
            )
        }
    }

    private func contextUsageColor(estimate: Int?, limit: Int?) -> Color {
        guard let estimate, let limit, limit > 0 else { return .secondary }
        let ratio = Double(estimate) / Double(limit)
        if ratio > 0.75 { return .red }
        if ratio >= 0.60 { return .orange }
        return .green
    }

    private func contextUsageSummary(current: Int?, limit: Int?) -> String {
        let currentText = current.map(formatCompactTokenCount) ?? "—"
        guard let limit else { return current == nil ? "等待数据" : currentText }
        return "\(currentText) / \(formatCompactTokenCount(limit))"
    }

    /// 当前选择文案：服务商 · 模型（未选模型时只显示服务商）
    private var modelLabel: String {
        appState.model.isEmpty ? appState.activeVendor.title : "\(appState.activeVendor.title) · \(appState.model)"
    }

    @ViewBuilder
    private var composerActionButton: some View {
        if store.isStreaming {
            Button(action: store.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.72), in: Circle())
            }
            .buttonStyle(DiscoPressButtonStyle())
            .help("停止生成")
        } else {
            Button(action: store.send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(DiscoTheme.accent, in: Circle())
            }
            .buttonStyle(DiscoPressButtonStyle())
            .disabled(!store.canSend)
            .opacity(store.canSend ? 1 : 0.38)
            // 不用 keyboardShortcut(.return)：窗口级生效，模型/推理弹层聚焦时按回车会误发；
            // 发送统一由输入框的 onKeyPress(.return) 处理（Shift+Return 换行）。
            .help("发送")
        }
    }
}

private struct ContextUsageRing: View {
    let estimate: Int?
    let limit: Int?
    let color: Color

    @State private var isHovered = false

    private var progress: Double? {
        guard let estimate, let limit, limit > 0 else { return nil }
        return min(1, max(0, Double(estimate) / Double(limit)))
    }

    private var percentage: String {
        guard let progress else { return "?" }
        if progress < 0.01 { return "<1%" }
        return "\(Int((progress * 100).rounded()))%"
    }

    private var helpText: String {
        guard let progress, let estimate else { return "上下文占用：等待数据" }
        let current = formatCompactTokenCount(estimate)
        if let limit {
            let total = formatCompactTokenCount(limit)
            let remaining = formatCompactTokenCount(max(0, limit - estimate))
            return "上下文占用 \(percentage) · 当前 \(current) / \(total) tokens\n剩余约 \(remaining) tokens"
        }
        return "上下文占用 \(percentage)"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.13), lineWidth: 2)
            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        color.opacity(isHovered ? 1 : 0.85),
                        style: StrokeStyle(lineWidth: isHovered ? 2.5 : 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            Text(percentage)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 30, height: 30)
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .help(helpText)
    }
}

private struct ContextUsagePopover: View {
    @ObservedObject var store: ConversationStore
    let vendor: ProviderVendor
    let model: String
    let usage: ContextUsageSnapshot?
    let limit: Int?

    private var isCodex: Bool { vendor == .chatgpt }
    private var current: Int { usage?.current.inputTokens ?? 0 }
    private var sourceTitle: String {
        switch usage?.source {
        case .provider: "服务商返回"
        case .codex: "Codex 服务端返回"
        default: "本地估算"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("上下文占用")
                    .font(.headline)
                Text("\(vendor.title) · \(model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            usageRow(label: "当前占用（\(sourceTitle)）", value: "约 \(formatCompactTokenCount(current)) tokens")
            usageRow(
                label: "模型窗口",
                value: limit.map { "\(formatCompactTokenCount($0)) tokens" } ?? "未知"
            )
            if let limit {
                usageRow(
                    label: "剩余",
                    value: "约 \(formatCompactTokenCount(max(0, limit - current)) ) tokens"
                )
            }

            if store.activeCompaction != nil {
                Label("正在压缩上下文…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if let compaction = store.lastSuccessfulCompaction {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近一次压缩")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("\(compaction.trigger == .manual ? "手动" : "自动") · \(compaction.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                    if let before = compaction.beforeTokens, let after = compaction.afterTokens {
                        Text("约 \(formatCompactTokenCount(before)) → \(formatCompactTokenCount(after)) tokens")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                store.compactContext()
            } label: {
                Label("立即压缩", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canCompactContext || store.isStreaming)

            Text(isCodex
                ? "Codex 由服务端维护历史上下文和自动压缩。"
                : "本地估算只用于阈值决策；原始聊天记录不会被删除。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private func usageRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }
}

private func formatCompactTokenCount(_ count: Int) -> String {
    let value = Double(max(0, count))
    if value >= 1_000_000 {
        return formatCompactUnit(value / 1_000_000, suffix: "M")
    }
    if value >= 1_000 {
        return formatCompactUnit(value / 1_000, suffix: "K")
    }
    return String(Int(value))
}

private func formatCompactUnit(_ value: Double, suffix: String) -> String {
    let rounded = (value * 10).rounded() / 10
    if rounded == rounded.rounded() {
        return "\(Int(rounded))\(suffix)"
    }
    return "\(String(format: "%.1f", rounded))\(suffix)"
}

/// 独立推理设置菜单，模型切换不再经过这里。
private struct ReasoningSettingsPopover: View {
    @EnvironmentObject private var appState: AppState

    let dismiss: () -> Void

    private var vendor: ProviderVendor { appState.activeVendor }
    private var efforts: [String] { appState.reasoningEfforts(for: vendor) }
    private var selectedEffort: String? { appState.selectedReasoningEffort(for: vendor) }
    private var codexCapabilityIsMissing: Bool {
        vendor == .chatgpt
            && appState.modelCatalogEntry(for: vendor, model: appState.model)?
                .supportedReasoningEfforts == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(vendor == .chatgpt || efforts.count > 2 ? "推理强度" : "思考模式")
                    .font(.headline)
                Spacer()
                Text(reasoningSelectionTitle(appState: appState, vendor: vendor))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if vendor == .chatgpt && efforts.isEmpty {
                codexUnavailableState
            } else {
                if vendor == .chatgpt {
                    effortRow(nil)
                }

                LazyVStack(spacing: 0) {
                    ForEach(efforts, id: \.self) { effort in
                        effortRow(effort)
                    }
                }

                Divider()

                Button {
                    appState.resetReasoningSettings(for: vendor)
                    dismiss()
                } label: {
                    Label("恢复默认设置", systemImage: "arrow.counterclockwise")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DiscoPressButtonStyle())
            }
        }
        .frame(width: 240)
        .task {
            guard codexCapabilityIsMissing else { return }
            await appState.refreshCodexModelCatalogIfNeeded()
        }
    }

    @ViewBuilder
    private var codexUnavailableState: some View {
        VStack(spacing: 10) {
            if appState.isRefreshingCodexModelCatalog {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取当前模型的推理能力…")
                    .foregroundStyle(.secondary)
            } else if let error = appState.codexModelCatalogError, codexCapabilityIsMissing {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("重新加载") {
                    Task { await appState.refreshCodexModelCatalogIfNeeded() }
                }
            } else if codexCapabilityIsMissing {
                Text("尚未加载当前模型的推理能力。")
                    .foregroundStyle(.secondary)

                Button("加载推理强度") {
                    Task { await appState.refreshCodexModelCatalogIfNeeded() }
                }
            } else {
                Label("当前模型不支持调整推理强度。", systemImage: "brain.head.profile")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .font(.caption)
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private func effortRow(_ effort: String?) -> some View {
        let title: String
        if let effort {
            title = ProviderVendor.reasoningEffortTitle(effort)
        } else {
            title = "默认"
        }

        return Button {
            appState.setReasoningEffort(effort, for: vendor)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Text(title)
                Spacer()
                if selectedEffort == effort {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DiscoTheme.reasoningAccent)
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(DiscoPressButtonStyle())
    }
}

private func reasoningSelectionTitle(appState: AppState, vendor: ProviderVendor) -> String {
    let efforts = appState.reasoningEfforts(for: vendor)
    if vendor == .chatgpt {
        let capabilityIsMissing = appState.modelCatalogEntry(for: vendor, model: appState.model)?
            .supportedReasoningEfforts == nil
        if capabilityIsMissing && appState.isRefreshingCodexModelCatalog {
            return "正在加载"
        }
        if capabilityIsMissing && appState.codexModelCatalogError != nil {
            return "不可用"
        }
        if capabilityIsMissing {
            return "待加载"
        }
        if efforts.isEmpty {
            return "不支持"
        }
    }
    guard !efforts.isEmpty else { return "关闭" }
    let selectedEffort = appState.selectedReasoningEffort(for: vendor)
    if efforts.count <= 2 {
        return selectedEffort == "none" ? "关闭" : "开启"
    }
    if let selectedEffort {
        return ProviderVendor.reasoningEffortTitle(selectedEffort)
    }
    if let defaultEffort = appState.defaultReasoningEffort(for: vendor) {
        return ProviderVendor.reasoningEffortTitle(defaultEffort)
    }
    return "默认"
}

/// 模型抽屉：左列选服务商、右列展示该服务商全部模型；选中模型后切换并关闭
private struct ModelDrawer: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    /// 关闭抽屉（选中模型或打开设置后调用）
    let dismiss: () -> Void

    /// 抽屉内当前高亮的服务商；打开时默认跟随当前服务商
    @State private var selectedVendor: ProviderVendor?

    /// 已配置 API Key 的服务商
    private var vendors: [ProviderVendor] {
        ProviderVendor.allCases.filter {
            $0.isAvailable && $0.isConfigured(appState.config(for: $0))
        }
    }

    private var highlightedVendor: ProviderVendor {
        selectedVendor ?? appState.activeVendor
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                vendorPane

                Divider()

                modelPane
                    .id(highlightedVendor)
            }
            .frame(maxHeight: .infinity)

            Divider()

            Button {
                dismiss()
                openSettings()
            } label: {
                Label("管理连接…", systemImage: "slider.horizontal.3")
                    .font(.callout)
                    .foregroundStyle(DiscoTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 460, height: 300)
        .onAppear { selectedVendor = appState.activeVendor }
    }

    // MARK: 左列：服务商

    private var vendorPane: some View {
        VStack(spacing: 0) {
            Text("服务商")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(vendors) { vendor in
                        vendorRow(vendor)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 168)
    }

    private func vendorRow(_ vendor: ProviderVendor) -> some View {
        Button {
            // 切换服务商后，右侧模型栏随之更新
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                selectedVendor = vendor
            }
        } label: {
            HStack(spacing: 8) {
                Text(vendor.title)
                    .font(.callout.weight(highlightedVendor == vendor ? .semibold : .regular))
                    .foregroundStyle(highlightedVendor == vendor ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                highlightedVendor == vendor ? DiscoTheme.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: DiscoRadius.small)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 右列：模型

    @ViewBuilder
    private var modelPane: some View {
        let vendor = highlightedVendor
        let models = appState.config(for: vendor)?.models ?? []

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(vendor.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if appState.reasoningEfforts(for: vendor).count > 2 {
                    Label("支持推理强度", systemImage: "brain")
                        .font(.caption2)
                        .foregroundStyle(DiscoTheme.accent)
                } else if models.isEmpty {
                    Text("尚未加载模型列表")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if models.isEmpty {
                Spacer()
                Text("请先在设置中验证连接，加载模型列表")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(models, id: \.self) { name in
                            modelRow(name, vendor: vendor)

                            if name != models.last {
                                Divider()
                                    .padding(.leading, 14)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
        ))
    }

    private func modelRow(_ name: String, vendor: ProviderVendor) -> some View {
        Button {
            selectModel(vendor, name)
        } label: {
            HStack(spacing: 10) {
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if vendor == appState.activeVendor && name == appState.model {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DiscoTheme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 选中模型：跨服务商时先切换服务商，再设置模型并关闭抽屉
    private func selectModel(_ vendor: ProviderVendor, _ name: String) {
        if vendor != appState.activeVendor {
            appState.setActiveVendor(vendor)
        }
        appState.setActiveModel(name, for: vendor)
        dismiss()
    }
}

// MARK: - 预览

/// 预览用 AppState：内存替身 + 独立 UserDefaults，绝不读写真实凭据/数据库
@MainActor
private func makePreviewAppState() -> AppState {
    let appState = AppState(
        keychain: InMemoryAuthStore(),
        defaults: UserDefaults(suiteName: "disco.preview.\(UUID().uuidString)")!,
        persistence: VolatileConversationPersistence()
    )
    try? appState.saveProviderConfig(
        vendor: .deepseek,
        baseURL: "https://api.deepseek.com/v1",
        apiKey: "sk-preview-deepseek",
        model: "deepseek-chat",
        models: ["deepseek-chat", "deepseek-reasoner"]
    )
    try? appState.saveProviderConfig(
        vendor: .openai,
        baseURL: "https://api.openai.com/v1",
        apiKey: "sk-preview-openai",
        model: "gpt-4o-mini",
        models: ["gpt-4o-mini", "gpt-4o"]
    )
    return appState
}

/// 预览用示例对话（含思考过程与正文）
@MainActor
private func makePreviewConversation() -> ConversationSession {
    ConversationSession(
        messages: [
            ChatMessage(role: .user, text: "用 Swift 写一个冒泡排序"),
            ChatMessage(
                role: .assistant,
                text: "```swift\nfunc bubbleSort(_ arr: inout [Int]) {\n    for i in 0..<arr.count {\n        for j in 0..<(arr.count - i - 1) {\n            if arr[j] > arr[j + 1] {\n                arr.swapAt(j, j + 1)\n            }\n        }\n    }\n}\n```\n\n这是冒泡排序的实现，最坏时间复杂度 O(n²)。",
                reasoning: "用户要求用 Swift 实现冒泡排序。直接给出可运行的实现，并补充复杂度说明。"
            ),
        ]
    )
}
