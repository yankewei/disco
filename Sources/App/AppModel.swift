import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [ProjectInfo] = []
    @Published var sessionsByProject: [String: [SessionInfo]] = [:]
    @Published var providers: [ProviderInfo] = []
    @Published var localAgents: [LocalAgentConfiguration] = []
    @Published var selectedProjectID: String?
    @Published var selectedSessionID: String?
    @Published var messages: [ConversationMessage] = []
    @Published var draft = ""
    @Published var selectedAgent: AgentID = .codex
    @Published var selectedModelID: String?
    @Published var selectedReasoningEffort: ReasoningEffort?
    @Published var selectedSandboxMode = defaultSandboxMode
    @Published var planMode = false
    @Published var runningSessionIDs: Set<String> = []
    @Published private(set) var planCompletionSessionID: String?
    @Published var userInputRequests: [UserInputRequest] = []
    @Published var approvalRequests: [ApprovalRequest] = []
    @Published var workspaceError: String?
    @Published var isLoading = false

    let databaseURL: URL?
    private let store: SQLiteStore?
    private let host: AgentHost?
    private var activeTimelineBuilders: [String: TimelineBuilder] = [:]
    private var streamingRenderTasks: [String: Task<Void, Never>] = [:]
    private let streamingRenderIntervalNanoseconds: UInt64 = 33_000_000
    private var lastAgentSelection = LastAgentSelection(
        agent: .codex,
        modelID: nil,
        reasoningEffort: nil
    )
    private var runModeBySession: [String: RunMode] = [:]
    private var isShuttingDown = false

    var selectedProject: ProjectInfo? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedSession: SessionInfo? {
        guard let selectedProjectID, let selectedSessionID else { return nil }
        return sessionsByProject[selectedProjectID]?.first { $0.id == selectedSessionID }
    }

    var selectedProvider: ProviderInfo? {
        providers.first { $0.kind == selectedAgent }
    }

    var availableProviders: [ProviderInfo] {
        providers.filter(\.available)
    }

    /// 会话尚未开始 Agent 对话（空会话）时仍可调整 Provider / 模型；
    /// 一旦已有对话记录，Provider / 模型就锁定为会话级选择，需新建会话再改。
    var canChooseProviderAndModel: Bool {
        guard let session = selectedSession else { return true }
        return session.agentThreadID == nil && messages.isEmpty
    }

    /// 最近一次运行是成功的 Plan 且用户尚未接管时，可一键切到 Build 开始实现。
    var canBeginImplementation: Bool {
        guard let planCompletionSessionID, planCompletionSessionID == selectedSessionID else { return false }
        guard !isRunning else { return false }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        var resolvedDatabaseURL: URL?
        var resolvedStore: SQLiteStore?
        var resolvedHost: AgentHost?
        let relay = AppEventRelay()
        do {
            let dependencies = try AppDependencies.live {
                relay.send($0)
            }
            resolvedDatabaseURL = dependencies.databaseURL
            resolvedStore = dependencies.store
            resolvedHost = dependencies.agentHost
        } catch {
            workspaceError = error.localizedDescription
        }
        databaseURL = resolvedDatabaseURL
        store = resolvedStore
        host = resolvedHost
        relay.model = self
    }

    func refresh() async {
        guard let host, !isShuttingDown else { return }
        if isLoading {
            while isLoading, !isShuttingDown {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            localAgents = try LocalAgentConfigurationStore().load()
            // Load local projects and sessions first so the sidebar renders
            // without waiting for provider processes to be discovered or booted.
            let projectList = try host.listProjects()
            projects = projectList
            var nextSessions: [String: [SessionInfo]] = [:]
            for project in projectList {
                nextSessions[project.id] = try host.listSessions(projectID: project.id)
            }
            sessionsByProject = nextSessions

            // Provider discovery, model enumeration and version probing are slow
            // (they spawn login shells and provider processes); do them only
            // after the local data is already on screen.
            try await host.refreshBackends()
            providers = host.providers()
            await withTaskGroup(of: ProviderInfo.self) { group in
                for provider in providers where provider.available {
                    group.addTask {
                        await host.refreshProvider(provider.kind)
                    }
                }
                for await provider in group {
                    if let index = providers.firstIndex(where: { $0.kind == provider.kind }) {
                        providers[index] = provider
                    }
                }
            }
            guard !isShuttingDown else { return }
            if let savedAgentSelection = try host.lastAgentSelection() {
                lastAgentSelection = savedAgentSelection
            }

            if selectedProjectID == nil || !projectList.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = projectList.first?.id
            }
            if let selectedProjectID {
                let sessions = nextSessions[selectedProjectID] ?? []
                if selectedSessionID == nil || !sessions.contains(where: { $0.id == selectedSessionID }) {
                    if let session = sessions.first {
                        selectSession(session)
                    } else {
                        selectedSessionID = nil
                        messages = []
                        applyLastAgentSelection()
                    }
                }
            } else {
                selectedSessionID = nil
                messages = []
                applyLastAgentSelection()
            }
            if selectedSession == nil, !availableProviders.contains(where: { $0.kind == selectedAgent }) {
                selectedAgent = availableProviders.first?.kind ?? .codex
                selectedModelID = nil
                selectedReasoningEffort = nil
            }
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func selectProject(_ project: ProjectInfo) {
        selectedProjectID = project.id
        selectedSessionID = nil
        messages = []
        planCompletionSessionID = nil
        if let host {
            try? host.activateProject(projectID: project.id)
        }
        let sessions = sessionsByProject[project.id] ?? []
        if let session = sessions.first {
            selectSession(session)
        } else {
            applyLastAgentSelection()
        }
    }

    func saveLocalAgents(_ agents: [LocalAgentConfiguration]) async -> Bool {
        guard runningSessionIDs.isEmpty else {
            workspaceError = "请等待当前任务结束后再修改 Agent 配置。"
            return false
        }
        do {
            try LocalAgentConfigurationStore().save(agents)
            localAgents = agents
            await refresh()
            return true
        } catch {
            workspaceError = "保存 Agent 配置失败：\(error.localizedDescription)"
            return false
        }
    }

    func selectSession(_ session: SessionInfo) {
        selectedProjectID = session.projectID
        selectedSessionID = session.id
        selectedAgent = session.agent
        let providerModels = providers.first { $0.kind == session.agent }?.models ?? []
        selectedModelID = providerModels.contains(where: { $0.id == session.modelID }) ? session.modelID : nil
        selectedReasoningEffort = session.reasoningEffort
        selectedSandboxMode = session.sandboxMode ?? defaultSandboxMode
        planMode = false
        messages = []
        if let host {
            try? host.activateSession(sessionID: session.id)
        }
        Task { [weak self] in
            await self?.loadMessages(sessionID: session.id)
        }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let projectPath = panel.url?.path else { return }
            Task { @MainActor [weak self] in
                self?.createProject(projectPath: projectPath)
            }
        }
    }

    func createProject(projectPath: String) {
        guard let host else { return }
        do {
            let project = try host.createProject(projectPath: projectPath)
            let sessions = try host.listSessions(projectID: project.id)
            projects.removeAll { $0.id == project.id }
            projects.insert(project, at: 0)
            sessionsByProject[project.id] = sessions
            selectProject(project)
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func startNewSession() {
        guard selectedProject != nil else {
            workspaceError = "请先选择一个项目"
            return
        }
        guard !isRunning else {
            workspaceError = "运行期间不能新建会话"
            return
        }
        startNewSessionSelection()
    }

    func createSession() {
        guard let project = selectedProject else {
            workspaceError = "请先选择一个项目"
            return
        }
        createSession(in: project)
    }

    func createSession(in project: ProjectInfo) {
        guard let host else { return }
        let provider = providers.first { $0.kind == lastAgentSelection.agent }
        guard provider?.available == true else {
            workspaceError = "Provider 不可用：\(lastAgentSelection.agent.displayName)"
            return
        }
        do {
            let session = try host.createSession(
                projectID: project.id,
                agent: lastAgentSelection.agent,
                modelID: lastAgentSelection.modelID,
                reasoningEffort: lastAgentSelection.reasoningEffort,
                sandboxMode: selectedSandboxMode
            )
            sessionsByProject[project.id, default: []].insert(session, at: 0)
            selectedProjectID = project.id
            selectedSessionID = session.id
            selectedAgent = session.agent
            selectedModelID = session.modelID
            selectedReasoningEffort = session.reasoningEffort
            selectedSandboxMode = session.sandboxMode ?? defaultSandboxMode
            messages = []
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func deleteProject(_ project: ProjectInfo) {
        guard let host else { return }
        let sessionIDs = Set((sessionsByProject[project.id] ?? []).map(\.id))
        do {
            try host.deleteProject(projectID: project.id)
            projects.removeAll { $0.id == project.id }
            sessionsByProject.removeValue(forKey: project.id)
            if let pendingSessionID = planCompletionSessionID, sessionIDs.contains(pendingSessionID) {
                planCompletionSessionID = nil
            }
            approvalRequests.removeAll { sessionIDs.contains($0.sessionID) }
            for sessionID in sessionIDs {
                activeTimelineBuilders.removeValue(forKey: sessionID)
                streamingRenderTasks.removeValue(forKey: sessionID)?.cancel()
                runningSessionIDs.remove(sessionID)
            }

            guard selectedProjectID == project.id else { return }
            if let nextProject = projects.first {
                selectProject(nextProject)
            } else {
                selectedProjectID = nil
                selectedSessionID = nil
                messages = []
            }
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func deleteSession(_ session: SessionInfo) {
        guard let host else { return }
        do {
            try host.deleteSession(sessionID: session.id)
            sessionsByProject[session.projectID]?.removeAll { $0.id == session.id }
            if planCompletionSessionID == session.id {
                planCompletionSessionID = nil
            }
            approvalRequests.removeAll { $0.sessionID == session.id }
            activeTimelineBuilders.removeValue(forKey: session.id)
            streamingRenderTasks.removeValue(forKey: session.id)?.cancel()
            runningSessionIDs.remove(session.id)

            guard selectedSessionID == session.id else { return }
            selectedSessionID = nil
            messages = []
            planMode = false
            if let nextSession = sessionsByProject[session.projectID]?.first {
                selectSession(nextSession)
            } else {
                applyLastAgentSelection()
            }
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func updateAgent(_ agent: AgentID) {
        guard !isRunning else {
            workspaceError = "运行期间不能切换 Provider"
            return
        }
        if let session = selectedSession {
            guard canChooseProviderAndModel else { return }
            guard session.agent != agent else { return }
            guard let host else { return }
            do {
                try host.updateSessionAgent(sessionID: session.id, agent: agent)
                reflectSession(id: session.id, in: session.projectID) { updated in
                    updated.agent = agent
                    updated.modelID = nil
                    updated.reasoningEffort = nil
                }
            } catch {
                workspaceError = error.localizedDescription
                return
            }
        }
        selectedAgent = agent
        selectedModelID = nil
        selectedReasoningEffort = nil
        if selectedProvider?.supportsPlan != true {
            planMode = false
        }
        lastAgentSelection = LastAgentSelection(agent: agent, modelID: nil, reasoningEffort: nil)
        saveLastAgentSelection()
    }

    func updateModel(_ modelID: String?) {
        guard !isRunning else {
            workspaceError = "运行期间不能切换模型"
            return
        }
        let nextReasoningEffort = modelID == selectedModelID ? selectedReasoningEffort : nil
        if let session = selectedSession {
            guard canChooseProviderAndModel else { return }
            guard session.modelID != modelID else { return }
            guard let host else { return }
            do {
                try host.updateSessionModel(
                    sessionID: session.id,
                    modelID: modelID,
                    reasoningEffort: nextReasoningEffort
                )
                reflectSession(id: session.id, in: session.projectID) { updated in
                    updated.modelID = modelID
                    updated.reasoningEffort = nextReasoningEffort
                }
            } catch {
                workspaceError = error.localizedDescription
                return
            }
        }
        selectedModelID = modelID
        selectedReasoningEffort = nextReasoningEffort
        lastAgentSelection.modelID = modelID
        lastAgentSelection.reasoningEffort = nextReasoningEffort
        saveLastAgentSelection()
    }

    func updateReasoningEffort(_ reasoningEffort: ReasoningEffort?) {
        guard !isRunning else {
            workspaceError = "运行期间不能切换推理深度"
            return
        }
        if let session = selectedSession {
            guard let host else { return }
            do {
                try host.updateSessionSettings(
                    sessionID: session.id,
                    reasoningEffort: reasoningEffort,
                    sandboxMode: session.sandboxMode
                )
                reflectSession(id: session.id, in: session.projectID) { updated in
                    updated.reasoningEffort = reasoningEffort
                }
            } catch {
                workspaceError = error.localizedDescription
                return
            }
        }
        selectedReasoningEffort = reasoningEffort
        lastAgentSelection.reasoningEffort = reasoningEffort
        saveLastAgentSelection()
    }

    func updateSandboxMode(_ sandboxMode: SandboxMode) {
        guard !isRunning else {
            workspaceError = "运行期间不能切换权限"
            return
        }
        if let session = selectedSession {
            guard let host else { return }
            do {
                try host.updateSessionSettings(
                    sessionID: session.id,
                    reasoningEffort: session.reasoningEffort,
                    sandboxMode: sandboxMode
                )
                reflectSession(id: session.id, in: session.projectID) { updated in
                    updated.sandboxMode = sandboxMode
                }
            } catch {
                workspaceError = error.localizedDescription
                return
            }
        }
        selectedSandboxMode = sandboxMode
    }

    func sendPrompt() {
        guard !isRunning else {
            workspaceError = "当前会话正在运行"
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let host else { return }
        guard let session = selectedSession else {
            createSession()
            guard let newSession = selectedSession else {
                workspaceError = "无法创建会话"
                return
            }
            send(text: text, to: newSession, using: host)
            return
        }
        send(text: text, to: session, using: host)
    }

    func cancelRun() {
        guard let selectedSessionID else { return }
        host?.cancel(sessionID: selectedSessionID)
    }

    func answerUserInput(_ request: UserInputRequest, answers: [[String]]?) {
        userInputRequests.removeAll { $0.id == request.id }
        host?.answerUserInput(id: request.id, answers: answers)
    }

    func approve(_ request: ApprovalRequest, decision: ApprovalDecision) {
        approvalRequests.removeAll { $0.id == request.id }
        host?.approve(approvalID: request.id, decision: decision)
    }

    func shutdown() async {
        isShuttingDown = true
        while isLoading {
            await Task.yield()
        }
        streamingRenderTasks.values.forEach { $0.cancel() }
        streamingRenderTasks.removeAll()
        await host?.shutdown()
        store?.close()
    }

    private func applyLastAgentSelection() {
        selectedAgent = lastAgentSelection.agent
        selectedModelID = lastAgentSelection.modelID
        selectedReasoningEffort = lastAgentSelection.reasoningEffort
    }

    private func saveLastAgentSelection() {
        guard let host else { return }
        do {
            try host.saveLastAgentSelection(lastAgentSelection)
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    private func startNewSessionSelection() {
        selectedSessionID = nil
        messages = []
        planMode = false
        planCompletionSessionID = nil
    }

    private var isRunning: Bool {
        guard let selectedSessionID else { return false }
        return runningSessionIDs.contains(selectedSessionID)
    }

    private func send(text: String, to session: SessionInfo, using host: AgentHost) {
        draft = ""
        let runMode: RunMode = planMode ? .plan : .agent
        let userMessage = ConversationMessage(
            id: UUID().uuidString,
            role: .user,
            text: text,
            reasoning: nil,
            toolCalls: nil,
            items: nil,
            timeline: nil,
            status: nil,
            error: nil,
            createdAt: .timestamp(),
            isPlan: false
        )
        messages.append(userMessage)
        let activeAssistantMessage = ConversationMessage(
            id: "active-\(session.id)",
            role: .assistant,
            text: "",
            reasoning: nil,
            toolCalls: nil,
            items: nil,
            timeline: [],
            status: nil,
            error: nil,
            createdAt: .timestamp(),
            isPlan: runMode == .plan
        )
        messages.append(activeAssistantMessage)
        runningSessionIDs.insert(session.id)
        activeTimelineBuilders[session.id] = TimelineBuilder()
        streamingRenderTasks.removeValue(forKey: session.id)?.cancel()

        runModeBySession[session.id] = runMode
        if planCompletionSessionID == session.id {
            planCompletionSessionID = nil
        }
        Task {
            await host.prompt(
                sessionID: session.id,
                text: text,
                mode: runMode
            )
        }
    }

    /// Plan 运行完成后的“开始实现”：切到 Build 并向同一会话发送一条实现提示。
    func beginImplementation() {
        guard canBeginImplementation, let session = selectedSession, let host else { return }
        planCompletionSessionID = nil
        planMode = false
        send(text: "请按照上面的计划开始实现。", to: session, using: host)
    }

    /// 会话配置变更后同步侧边栏缓存（不可在 SwiftUI 状态更新里直接改旧对象/旧集合）。
    private func reflectSession(
        id sessionID: String,
        in projectID: String,
        _ update: (inout SessionInfo) -> Void
    ) {
        guard var sessions = sessionsByProject[projectID],
              let index = sessions.firstIndex(where: { $0.id == sessionID })
        else { return }
        update(&sessions[index])
        sessionsByProject[projectID] = sessions
    }

    fileprivate func handle(event: AgentEvent) {
        switch event {
        case let .runStarted(sessionID, _):
            runningSessionIDs.insert(sessionID)
            activeTimelineBuilders[sessionID] = TimelineBuilder()
            streamingRenderTasks.removeValue(forKey: sessionID)?.cancel()
            if planCompletionSessionID == sessionID {
                planCompletionSessionID = nil
            }
        case let .sessionAgentThreadIDUpdated(sessionID, agentThreadID):
            updateSessionAgentThreadID(sessionID: sessionID, agentThreadID: agentThreadID)
        case let .text(sessionID, _, text, itemID):
            apply(
                .text(text: text, itemID: itemID),
                sessionID: sessionID
            )
        case let .reasoning(sessionID, _, text, itemID):
            apply(
                .reasoning(text: text, itemID: itemID),
                sessionID: sessionID
            )
        case let .item(sessionID, _, item):
            apply(.item(item), sessionID: sessionID)
        case let .tool(sessionID, _, id, title, state, input, output, error):
            apply(
                .tool(id: id, title: title, state: state, input: input, output: output, error: error),
                sessionID: sessionID
            )
        case let .userInputRequested(request):
            userInputRequests.append(request)
        case let .userInputResolved(id):
            userInputRequests.removeAll { $0.id == id }
        case let .approvalRequested(sessionID, runID, approvalID, toolName, title, input):
            approvalRequests.append(
                ApprovalRequest(
                    id: approvalID,
                    sessionID: sessionID,
                    runID: runID,
                    toolName: toolName,
                    title: title,
                    input: input
                )
            )
        case let .approvalResolved(_, _, approvalID):
            approvalRequests.removeAll { $0.id == approvalID }
        case let .runFinished(sessionID, _, status, sessionTitle, error):
            runningSessionIDs.remove(sessionID)
            let runMode = runModeBySession[sessionID]
            if status == .completed, runMode == .plan,
               !userInputRequests.contains(where: { $0.sessionID == sessionID })
            {
                planCompletionSessionID = sessionID
            }
            runModeBySession.removeValue(forKey: sessionID)
            streamingRenderTasks.removeValue(forKey: sessionID)?.cancel()
            if let selectedSessionID, selectedSessionID == sessionID {
                if let sessionTitle {
                    updateSessionTitle(sessionID: sessionID, title: sessionTitle)
                }
                if let builder = activeTimelineBuilders[sessionID] {
                    var finalizedBuilder = builder
                    finalizedBuilder = finalizedBuilder.finalized(status: status)
                    let isPlan = runMode == .plan
                    let planText = isPlan
                        ? (lastTextPartText(in: finalizedBuilder.timeline) ?? finalizedBuilder.assistantText)
                        : finalizedBuilder.assistantText
                    let finalizedMessage = ConversationMessage(
                        id: UUID().uuidString,
                        role: .assistant,
                        text: planText,
                        reasoning: finalizedBuilder.reasoning.isEmpty ? nil : finalizedBuilder.reasoning,
                        toolCalls: finalizedBuilder.toolCalls.isEmpty ? nil : finalizedBuilder.toolCalls,
                        items: finalizedBuilder.items.isEmpty ? nil : finalizedBuilder.items,
                        timeline: finalizedBuilder.timeline,
                        status: status,
                        error: error,
                        createdAt: .timestamp(),
                        isPlan: isPlan
                    )
                    let activeMessageID = "active-\(sessionID)"
                    if let activeMessageIndex = messages.lastIndex(where: { $0.id == activeMessageID }) {
                        messages[activeMessageIndex] = finalizedMessage
                    } else {
                        messages.append(finalizedMessage)
                    }
                }
                if status == .failed, let error {
                    workspaceError = error
                }
            }
            activeTimelineBuilders.removeValue(forKey: sessionID)
        }
    }

    private func apply(_ event: BackendEvent, sessionID: String) {
        var builder = activeTimelineBuilders[sessionID] ?? TimelineBuilder()
        builder.apply(event)
        activeTimelineBuilders[sessionID] = builder
        guard selectedSessionID == sessionID, streamingRenderTasks[sessionID] == nil else { return }

        streamingRenderTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: streamingRenderIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            streamingRenderTasks.removeValue(forKey: sessionID)
            renderActiveMessage(sessionID: sessionID)
        }
    }

    private func renderActiveMessage(sessionID: String) {
        guard selectedSessionID == sessionID, let builder = activeTimelineBuilders[sessionID] else { return }
        let renderedMessage = ConversationMessage(
            id: "active-\(sessionID)",
            role: .assistant,
            text: builder.assistantText,
            reasoning: builder.reasoning.isEmpty ? nil : builder.reasoning,
            toolCalls: builder.toolCalls.isEmpty ? nil : builder.toolCalls,
            items: builder.items.isEmpty ? nil : builder.items,
            timeline: builder.timeline,
            status: nil,
            error: nil,
            createdAt: .timestamp(),
            isPlan: false
        )
        if let lastIndex = messages.lastIndex(where: { $0.role == .assistant && $0.id.hasPrefix("active-") }) {
            messages[lastIndex] = renderedMessage
        } else {
            messages.append(renderedMessage)
        }
    }

    private func loadMessages(sessionID: String) async {
        guard let host else { return }
        do {
            let loadedMessages = try await host.loadMessages(sessionID: sessionID)
            guard selectedSessionID == sessionID else { return }
            messages = loadedMessages
        } catch {
            guard selectedSessionID == sessionID else { return }
            workspaceError = error.localizedDescription
        }
    }

    private func updateSessionAgentThreadID(sessionID: String, agentThreadID: String) {
        for projectID in sessionsByProject.keys {
            guard let index = sessionsByProject[projectID]?.firstIndex(where: { $0.id == sessionID }) else {
                continue
            }
            sessionsByProject[projectID]?[index].agentThreadID = agentThreadID
            break
        }
    }

    private func updateSessionTitle(sessionID: String, title: String) {
        for projectID in sessionsByProject.keys {
            guard let index = sessionsByProject[projectID]?.firstIndex(where: { $0.id == sessionID }) else { continue }
            sessionsByProject[projectID]?[index].title = title
            break
        }
    }
}

struct ApprovalRequest: Identifiable {
    let id: String
    let sessionID: String
    let runID: String
    let toolName: String
    let title: String?
    let input: [String: JSONValue]
}

private final class AppEventRelay {
    weak var model: AppModel?

    func send(_ event: AgentEvent) {
        Task { @MainActor [weak model] in
            model?.handle(event: event)
        }
    }
}
