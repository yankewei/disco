import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [ProjectInfo] = []
    @Published var sessionsByProject: [String: [SessionInfo]] = [:]
    @Published var providers: [ProviderInfo] = []
    @Published var selectedProjectID: String?
    @Published var selectedSessionID: String?
    @Published var messages: [ConversationMessage] = []
    @Published var draft = ""
    @Published var selectedAgent: BackendKind = .codex
    @Published var selectedModelID: String?
    @Published var selectedReasoningEffort: ReasoningEffort?
    @Published var selectedSandboxMode = defaultSandboxMode
    @Published var planMode = false
    @Published var runningSessionIDs: Set<String> = []
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
            await host.refreshBackends()
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

    func updateAgent(_ agent: BackendKind) {
        guard !isRunning else {
            workspaceError = "运行期间不能切换 Provider"
            return
        }
        if let session = selectedSession, session.agent != agent {
            if session.agentThreadID == nil && messages.isEmpty {
                guard let host else { return }
                do {
                    try host.updateSessionAgent(sessionID: session.id, agent: agent)
                    if var sessions = sessionsByProject[session.projectID],
                       let index = sessions.firstIndex(where: { $0.id == session.id })
                    {
                        sessions[index].agent = agent
                        sessions[index].modelID = nil
                        sessions[index].reasoningEffort = nil
                        sessionsByProject[session.projectID] = sessions
                    }
                } catch {
                    workspaceError = error.localizedDescription
                    return
                }
            } else {
                startNewSessionSelection()
            }
        }
        selectedAgent = agent
        selectedModelID = nil
        selectedReasoningEffort = nil
        lastAgentSelection = LastAgentSelection(agent: agent, modelID: nil, reasoningEffort: nil)
        saveLastAgentSelection()
    }

    func updateModel(_ modelID: String?) {
        guard !isRunning else {
            workspaceError = "运行期间不能切换模型"
            return
        }
        let nextReasoningEffort = modelID == selectedModelID ? selectedReasoningEffort : nil
        if let session = selectedSession, session.modelID != modelID {
            if session.agentThreadID == nil {
                guard let host else { return }
                do {
                    try host.updateSessionModel(
                        sessionID: session.id,
                        modelID: modelID,
                        reasoningEffort: nextReasoningEffort
                    )
                    if var sessions = sessionsByProject[session.projectID],
                       let index = sessions.firstIndex(where: { $0.id == session.id })
                    {
                        sessions[index].modelID = modelID
                        sessions[index].reasoningEffort = nextReasoningEffort
                        sessionsByProject[session.projectID] = sessions
                    }
                } catch {
                    workspaceError = error.localizedDescription
                    return
                }
            } else {
                startNewSessionSelection()
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
        if selectedSession != nil, selectedSession?.reasoningEffort != reasoningEffort {
            startNewSessionSelection()
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
        let currentSandboxMode = selectedSession?.sandboxMode ?? defaultSandboxMode
        if selectedSession != nil, currentSandboxMode != sandboxMode {
            startNewSessionSelection()
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
    }

    private var isRunning: Bool {
        guard let selectedSessionID else { return false }
        return runningSessionIDs.contains(selectedSessionID)
    }

    private func send(text: String, to session: SessionInfo, using host: AgentHost) {
        draft = ""
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
            createdAt: .timestamp()
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
            createdAt: .timestamp()
        )
        messages.append(activeAssistantMessage)
        runningSessionIDs.insert(session.id)
        activeTimelineBuilders[session.id] = TimelineBuilder()
        streamingRenderTasks.removeValue(forKey: session.id)?.cancel()

        let runMode: RunMode = planMode ? .plan : .agent
        Task {
            await host.prompt(
                sessionID: session.id,
                text: text,
                mode: runMode
            )
        }
    }

    fileprivate func handle(event: AgentEvent) {
        switch event {
        case let .runStarted(sessionID, _):
            runningSessionIDs.insert(sessionID)
            activeTimelineBuilders[sessionID] = TimelineBuilder()
            streamingRenderTasks.removeValue(forKey: sessionID)?.cancel()
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
            streamingRenderTasks.removeValue(forKey: sessionID)?.cancel()
            if let selectedSessionID, selectedSessionID == sessionID {
                if let sessionTitle {
                    updateSessionTitle(sessionID: sessionID, title: sessionTitle)
                }
                if let builder = activeTimelineBuilders[sessionID] {
                    var finalizedBuilder = builder
                    finalizedBuilder = finalizedBuilder.finalized(status: status)
                    let finalizedMessage = ConversationMessage(
                        id: UUID().uuidString,
                        role: .assistant,
                        text: finalizedBuilder.assistantText,
                        reasoning: finalizedBuilder.reasoning.isEmpty ? nil : finalizedBuilder.reasoning,
                        toolCalls: finalizedBuilder.toolCalls.isEmpty ? nil : finalizedBuilder.toolCalls,
                        items: finalizedBuilder.items.isEmpty ? nil : finalizedBuilder.items,
                        timeline: finalizedBuilder.timeline,
                        status: status,
                        error: error,
                        createdAt: .timestamp()
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
            createdAt: .timestamp()
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
