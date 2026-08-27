import AppKit
import SwiftUI

private struct ProjectUIError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var projectError: ProjectUIError?
    @State private var projectPendingDeletion: ProjectSnapshot?
    @State private var isProjectDeletionConfirmationPresented = false

    var body: some View {
        NavigationSplitView {
            ConversationSidebar(
                expandedProjectIDs: $expandedProjectIDs,
                openProject: openProjectFromPicker,
                requestDeleteProject: {
                    projectPendingDeletion = $0
                    isProjectDeletionConfirmationPresented = true
                },
                reconnectProject: reconnectProject
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            if let conversation = appState.selectedConversation {
                ChatView(
                    store: conversation.store,
                    projectID: conversation.projectID,
                    reconnectProject: reconnectHandler(for: conversation.projectID)
                )
                .id(conversation.id)
            } else {
                ContentUnavailableView(
                    "选择一段对话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("从左侧选择会话，或点击项目行右侧的新建会话按钮。")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            expandSelectedProject()
        }
        .onChange(of: appState.selectedConversationID) { _, _ in
            expandSelectedProject()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            appState.refreshProjectAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: .discoRequestOpenProject)) { _ in
            openProjectFromPicker()
        }
        .alert(item: $projectError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
        .confirmationDialog(
            "删除项目？",
            isPresented: $isProjectDeletionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("删除项目", role: .destructive) {
                guard let project = projectPendingDeletion else { return }
                projectPendingDeletion = nil
                appState.deleteProject(id: project.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "将从 Disco 移除“\(projectPendingDeletion?.name ?? "此项目")”及其项目会话，"
                    + "但不会删除磁盘上的项目目录。"
            )
        }
        .background(DiscoScrollIndicatorHider())
    }

    private func expandSelectedProject() {
        guard let projectID = appState.selectedConversation?.projectID else { return }
        expandedProjectIDs.insert(projectID)
    }

    private func openProjectFromPicker() {
        guard let url = ProjectDirectoryPicker.chooseDirectory(mode: .openProject) else { return }
        do {
            let projectID = try appState.openProject(at: url)
            expandedProjectIDs.insert(projectID)
        } catch {
            showProjectError(title: "无法添加项目", error: error)
        }
    }

    private func reconnectHandler(for projectID: UUID?) -> (() -> Void)? {
        guard let projectID else { return nil }
        return { reconnectProject(id: projectID) }
    }

    private func reconnectProject(id: UUID) {
        guard let project = appState.projects.first(where: { $0.id == id }) else { return }
        let initialDirectory = project.workspaceRoot.deletingLastPathComponent()
        guard let url = ProjectDirectoryPicker.chooseDirectory(
            mode: .reconnect(initialDirectory: initialDirectory)
        ) else { return }
        do {
            try appState.reconnectProject(id: id, to: url)
        } catch {
            showProjectError(title: "无法重新关联项目", error: error)
        }
    }

    private func showProjectError(title: String, error: Error) {
        projectError = ProjectUIError(title: title, message: error.localizedDescription)
    }
}

private struct ConversationSidebar: View {
    @EnvironmentObject private var appState: AppState
    @Binding var expandedProjectIDs: Set<UUID>
    let openProject: () -> Void
    let requestDeleteProject: (ProjectSnapshot) -> Void
    let reconnectProject: (UUID) -> Void

    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool

    /// 当前服务商已保存 Key 但从未验证过连接时，提示用户去设置页验证
    private var needsVerificationAttention: Bool {
        guard let config = appState.config(for: appState.activeVendor) else { return false }
        return appState.activeVendor.requiresAPIKey
            && config.hasAPIKey
            && config.lastVerifiedAt == nil
    }

    private var temporaryConversations: [ConversationSession] {
        let projectIDs = Set(appState.projects.map(\.id))
        return appState.conversations.filter {
            guard let projectID = $0.projectID else { return true }
            return !projectIDs.contains(projectID)
        }
    }

    private var visibleTemporaryConversations: [ConversationSession] {
        temporaryConversations.filter {
            !$0.store.messages.isEmpty || $0.id == appState.selectedConversationID
        }
    }

    private var currentProject: ProjectSnapshot? {
        guard let projectID = appState.selectedConversation?.projectID else { return nil }
        return appState.projects.first { $0.id == projectID }
    }

    private var projectChoices: [ProjectSnapshot] {
        appState.projects.filter { $0.id != currentProject?.id }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 搜索命中：项目名或会话内任意消息文本（命中项目名时包含该项目全部会话）
    private func searchMatches(_ conversation: ConversationSession) -> Bool {
        let project = appState.projects.first { $0.id == conversation.projectID }
        return ConversationSearch.matches(
            query: searchText,
            project: project?.name,
            messages: conversation.store.messages
        )
    }

    private var searchResults: [ConversationSession] {
        appState.conversations.filter(searchMatches)
    }

    private enum SearchResultRow: Identifiable {
        case empty(query: String)
        case conversation(ConversationSession)

        var id: String {
            switch self {
            case .empty: "search-empty"
            case let .conversation(conversation): conversation.id.uuidString
            }
        }
    }

    private var searchResultRows: [SearchResultRow] {
        let results = searchResults
        guard !results.isEmpty else {
            return [.empty(query: searchText.trimmingCharacters(in: .whitespacesAndNewlines))]
        }
        return results.map { .conversation($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            sidebarSearchField

            Button(action: openProject) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .frame(width: 20)

                    Text("添加项目")
                        .font(.callout.weight(.medium))

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .help("把一个文件夹作为项目加入 Disco（⌘O）")

            ScrollViewReader { proxy in
                List {
                    if isSearching {
                        searchResultsSection
                    } else {
                        ForEach(appState.projects) { project in
                            ProjectConversationSection(
                                project: project,
                                conversations: appState.conversations.filter { $0.projectID == project.id },
                                isExpanded: expandedProjectIDs.contains(project.id),
                                toggle: { toggleProject(project.id) },
                                selectProject: {
                                    expandedProjectIDs.insert(project.id)
                                    appState.selectProject(id: project.id)
                                },
                                createConversation: {
                                    expandedProjectIDs.insert(project.id)
                                    appState.createConversation(projectID: project.id)
                                },
                                showFinder: {
                                    NSWorkspace.shared.activateFileViewerSelecting([project.workspaceRoot])
                                },
                                deleteProject: { requestDeleteProject(project) },
                                reconnect: { reconnectProject(project.id) }
                            )
                            .id(project.id)
                        }
                    }
                    // 注意：Section body 必须始终是同一类型的 ForEach。
                    // 在这里用 if/else 在占位 Text 与行列表之间切换，
                    // 会触发 macOS List（NSTableView 桥接）的行渲染丢失：
                    // 数据从空变为非空时新行不出现，表现为“点了没反应”。
                    // 搜索时隐藏：命中结果已由 searchResultsSection 平铺展示，
                    // 避免临时对话在两个分区重复出现。
                    if !isSearching {
                        Section {
                            ForEach(visibleTemporaryConversations) { conversation in
                                ConversationListRow(conversation: conversation)
                            }
                        } header: {
                            HStack {
                                Text("临时对话")
                            }
                            .textCase(nil)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollIndicators(.hidden)
                .background(DiscoScrollIndicatorHider())
                .scrollContentBackground(.hidden)
                .onAppear {
                    revealSelectedProject(using: proxy)
                }
                .onChange(of: appState.selectedConversationID) { _, _ in
                    revealSelectedProject(using: proxy)
                }
                .onChange(of: appState.projects) { _, _ in
                    revealSelectedProject(using: proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: .discoFocusSidebarSearch)) { _ in
                    isSearchFieldFocused = true
                }
            }

            if let storageError = appState.storageError {
                Label(storageError, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(storageError)
            }

            Divider()

            SettingsLink {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("连接设置")
                            .font(.callout.weight(.medium))
                        Text(appState.isActiveVendorConfigured ? appState.model : "尚未连接模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)

                    if needsVerificationAttention {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                            .help("连接已保存，尚未验证")
                    }
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .background(.regularMaterial)
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("搜索对话", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isSearchFieldFocused)
                .accessibilityLabel("搜索对话")
                .help("按项目名或消息内容搜索会话（⌘F）")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        Section {
            ForEach(searchResultRows) { result in
                switch result {
                case let .empty(query):
                    Text("没有匹配“\(query)”的对话")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                case let .conversation(conversation):
                    ConversationListRow(conversation: conversation)
                }
            }
        } header: {
            HStack {
                Text("搜索结果")
            }
            .textCase(nil)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 11) {
            DiscoMark(size: 27)

            VStack(alignment: .leading, spacing: 1) {
                Text("Disco")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("你的对话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            Menu {
                if let currentProject {
                    Button {
                        expandedProjectIDs.insert(currentProject.id)
                        appState.createConversation(projectID: currentProject.id)
                    } label: {
                        Label("在“\(currentProject.name)”中新建对话", systemImage: "plus.bubble")
                    }

                    Divider()
                }

                Button {
                    appState.createConversation(projectID: nil)
                } label: {
                    Label("新建临时对话", systemImage: "bubble.left")
                }

                if !projectChoices.isEmpty {
                    Divider()

                    Menu(currentProject == nil ? "新建项目对话" : "新建到其他项目") {
                        ForEach(projectChoices) { project in
                            Button {
                                expandedProjectIDs.insert(project.id)
                                appState.createConversation(projectID: project.id)
                            } label: {
                                Label(project.name, systemImage: "folder")
                            }
                        }
                    }
                }

            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("新建对话")
                        .font(.callout.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(DiscoPressButtonStyle())
            .accessibilityLabel("新建对话")
            .help("选择新对话的创建位置（⌘N）")
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 12)
    }

    private func toggleProject(_ id: UUID) {
        if expandedProjectIDs.contains(id) {
            expandedProjectIDs.remove(id)
        } else {
            expandedProjectIDs.insert(id)
        }
    }

    private func revealSelectedProject(using proxy: ScrollViewProxy) {
        guard let projectID = appState.selectedConversation?.projectID else { return }
        expandedProjectIDs.insert(projectID)
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(projectID, anchor: .top)
            }
        }
    }
}

private struct ConversationListRow: View {
    @EnvironmentObject private var appState: AppState
    let conversation: ConversationSession

    @State private var isHovered = false

    private var isSelected: Bool {
        appState.selectedConversationID == conversation.id
    }

    var body: some View {
        Button {
            appState.selectedConversationID = conversation.id
        } label: {
            ConversationRow(conversation: conversation, isSelected: isSelected)
                .padding(.horizontal, 10)
                .discoRowStyle(isSelected: isSelected, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityValue(isSelected ? "当前会话" : "")
        .contextMenu {
            Button("删除对话", role: .destructive) {
                appState.deleteConversation(id: conversation.id)
            }
        }
    }
}

private struct ProjectConversationSection: View {
    @EnvironmentObject private var appState: AppState
    let project: ProjectSnapshot
    let conversations: [ConversationSession]
    let isExpanded: Bool
    let toggle: () -> Void
    let selectProject: () -> Void
    let createConversation: () -> Void
    let showFinder: () -> Void
    let deleteProject: () -> Void
    let reconnect: () -> Void

    @State private var isHovered = false

    private var unavailable: Bool {
        guard let availability = appState.projectAvailability[project.id] else { return true }
        if case .unavailable = availability { return true }
        return false
    }

    private var isCurrentProject: Bool {
        appState.selectedConversation?.projectID == project.id
    }

    private var showsProjectActions: Bool {
        isHovered || isCurrentProject
    }

    var body: some View {
        Section {
            if isExpanded {
                if conversations.isEmpty {
                    Text("点击项目行右侧的新建会话按钮")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 42)
                        .padding(.vertical, 4)
                } else {
                    ForEach(conversations) { conversation in
                        ConversationListRow(conversation: conversation)
                    }
                }
            }
        } header: {
            HStack(spacing: 2) {
                Button(action: toggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "收起" : "展开")项目 \(project.name)")
                .help(isExpanded ? "收起项目" : "展开项目")

                Button(action: selectProject) {
                    HStack(spacing: 6) {
                        Image(systemName: unavailable ? "folder.badge.questionmark" : "folder")
                            .foregroundStyle(unavailable ? .orange : DiscoTheme.accent)
                        Text(project.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .frame(minHeight: 40)
                .accessibilityLabel("打开项目 \(project.name)")
                .help("打开项目")

                Menu {
                    Button("在 Finder 中显示", action: showFinder)
                        .disabled(unavailable)
                    Button("重新关联目录…", action: reconnect)
                    Divider()
                    Button("删除项目…", role: .destructive, action: deleteProject)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 40, height: 40)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(DiscoPressButtonStyle())
                .opacity(showsProjectActions ? 1 : 0)
                .allowsHitTesting(showsProjectActions)
                .accessibilityHidden(!showsProjectActions)
                .accessibilityLabel("项目操作")
                .help("项目操作")

                Button(action: createConversation) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 40)
                }
                .buttonStyle(DiscoPressButtonStyle())
                .opacity(showsProjectActions ? 1 : 0)
                .allowsHitTesting(showsProjectActions)
                .accessibilityHidden(!showsProjectActions)
                .accessibilityLabel("在“\(project.name)”中新建会话")
                .help("在“\(project.name)”中新建会话")
            }
            .textCase(nil)
            .onHover { isHovered = $0 }
        }
    }
}

private struct ConversationRow: View {
    let conversation: ConversationSession
    let isSelected: Bool

    @ObservedObject private var store: ConversationStore

    init(conversation: ConversationSession, isSelected: Bool) {
        self.conversation = conversation
        self.isSelected = isSelected
        store = conversation.store
    }

    private var title: String {
        store.messages.first(where: { $0.role == .user })?.text ?? "新对话"
    }

    private var preview: String {
        store.messages.last?.text.isEmpty == false
            ? store.messages.last?.text ?? ""
            : "开始一段新的对话"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DiscoMark(size: 19, isActive: store.isStreaming)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if store.pendingApproval != nil {
                        Circle()
                            .fill(DiscoTheme.accent)
                            .frame(width: 7, height: 7)
                            .help("等待你的确认")
                    } else if store.hasUnreadResult && !isSelected {
                        Circle()
                            .fill(.green)
                            .frame(width: 7, height: 7)
                            .help("有新的运行结果")
                    }

                    Text(conversation.updatedAt, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Text(store.runStatusText ?? preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
