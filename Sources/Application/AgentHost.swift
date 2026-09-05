import Foundation

final class AgentHost {
    typealias EventHandler = (AgentEvent) -> Void

    private let store: SQLiteStore
    private let eventHandler: EventHandler
    private let executableURLProvider: () async -> [BackendKind: URL]
    private var backends: [BackendKind: AgentBackend]
    private var executableURLs: [BackendKind: URL]
    private let stateLock = NSLock()
    private var activeRuns: [String: ActiveRun] = [:]
    private var pendingUserInputs: [String: PendingUserInput] = [:]
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var deletingProjectIDs: Set<String> = []
    private var deletingSessionIDs: Set<String> = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShuttingDown = false

    init(
        store: SQLiteStore,
        eventHandler: @escaping EventHandler,
        backends: [BackendKind: AgentBackend],
        executableURLs: [BackendKind: URL],
        executableURLProvider: @escaping () async -> [BackendKind: URL]
    ) {
        self.store = store
        self.eventHandler = eventHandler
        self.backends = backends
        self.executableURLs = executableURLs
        self.executableURLProvider = executableURLProvider
    }

    func listProjects() throws -> [ProjectInfo] {
        try store.listProjects()
    }

    func createProject(projectPath: String) throws -> ProjectInfo {
        let normalizedURL = URL(fileURLWithPath: projectPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentHostError.invalidWorkspace
        }
        if let existingProject = try store.project(projectPath: normalizedURL.path) {
            return existingProject
        }
        let project = ProjectInfo(
            projectID: UUID().uuidString,
            name: normalizedURL.lastPathComponent,
            projectPath: normalizedURL.path,
            createdAt: .timestamp(),
            activatedAt: .timestamp()
        )
        try store.createProject(project)
        return project
    }

    func listSessions(projectID: String) throws -> [SessionInfo] {
        try store.listSessions(projectID: projectID)
    }

    func activateProject(projectID: String) throws {
        try store.touchProject(projectID: projectID)
    }

    func activateSession(sessionID: String) throws {
        try store.touchSession(sessionID: sessionID)
    }

    func lastAgentSelection() throws -> LastAgentSelection? {
        try store.lastAgentSelection()
    }

    func saveLastAgentSelection(_ selection: LastAgentSelection) throws {
        try store.saveLastAgentSelection(selection)
    }

    func updateSessionSettings(
        sessionID: String,
        reasoningEffort: ReasoningEffort?,
        sandboxMode: SandboxMode?
    ) throws {
        guard try store.session(id: sessionID) != nil else {
            throw AgentHostError.sessionNotFound
        }
        try store.updateSessionSettings(
            sessionID: sessionID,
            reasoningEffort: reasoningEffort,
            sandboxMode: sandboxMode
        )
    }

    func updateSessionAgent(sessionID: String, agent: BackendKind) throws {
        guard let session = try store.session(id: sessionID) else {
            throw AgentHostError.sessionNotFound
        }
        guard session.agentThreadID == nil else {
            throw AgentHostError.sessionHasAgentConversation
        }
        guard backend(for: agent) != nil else {
            throw AgentHostError.providerUnavailable(agent.displayName)
        }
        try store.updateSessionAgent(sessionID: sessionID, agent: agent)
    }

    func updateSessionModel(
        sessionID: String,
        modelID: String?,
        reasoningEffort: ReasoningEffort?
    ) throws {
        guard let session = try store.session(id: sessionID) else {
            throw AgentHostError.sessionNotFound
        }
        guard session.agentThreadID == nil else {
            throw AgentHostError.sessionHasAgentConversation
        }
        try store.updateSessionModel(
            sessionID: sessionID,
            modelID: modelID,
            reasoningEffort: reasoningEffort
        )
    }

    func createSession(
        projectID: String,
        agent: BackendKind,
        modelID: String?,
        reasoningEffort: ReasoningEffort?,
        sandboxMode: SandboxMode?
    ) throws -> SessionInfo {
        guard try store.project(id: projectID) != nil else {
            throw AgentHostError.projectNotFound
        }
        guard self.backend(for: agent) != nil else {
            throw AgentHostError.providerUnavailable(agent.displayName)
        }
        let session = SessionInfo(
            sessionID: UUID().uuidString,
            projectID: projectID,
            agent: agent,
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            sandboxMode: sandboxMode,
            agentThreadID: nil,
            title: "新对话",
            createdAt: .timestamp(),
            activatedAt: nil
        )
        try store.createSession(session)
        return session
    }

    func deleteProject(projectID: String) throws {
        guard try store.project(id: projectID) != nil else {
            throw AgentHostError.projectNotFound
        }
        let sessions = try store.listSessions(projectID: projectID)
        try withStateLock {
            guard sessions.allSatisfy({ activeRuns[$0.sessionID] == nil }) else {
                throw AgentHostError.projectHasRunningSession
            }
            guard deletingProjectIDs.insert(projectID).inserted else {
                throw AgentHostError.projectDeletionInProgress
            }
        }
        defer {
            _ = withStateLock {
                deletingProjectIDs.remove(projectID)
            }
        }
        try store.deleteProject(projectID: projectID)
    }

    func deleteSession(sessionID: String) throws {
        guard try store.session(id: sessionID) != nil else {
            throw AgentHostError.sessionNotFound
        }
        try withStateLock {
            guard activeRuns[sessionID] == nil else {
                throw AgentHostError.sessionAlreadyRunning
            }
            guard deletingSessionIDs.insert(sessionID).inserted else {
                throw AgentHostError.sessionDeletionInProgress
            }
        }
        defer {
            _ = withStateLock {
                deletingSessionIDs.remove(sessionID)
            }
        }
        try store.deleteSession(sessionID: sessionID)
    }

    func loadMessages(sessionID: String) async throws -> [ConversationMessage] {
        guard let session = try store.session(id: sessionID) else {
            throw AgentHostError.sessionNotFound
        }
        guard let project = try store.project(id: session.projectID) else {
            throw AgentHostError.projectNotFound
        }
        guard let agentThreadID = session.agentThreadID else {
            return []
        }
        guard let backend = self.backend(for: session.agent) else {
            throw AgentHostError.providerUnavailable(session.agent.displayName)
        }
        return try await backend.loadMessages(
            agentThreadID: agentThreadID,
            workingDirectory: project.projectPath
        )
    }

    func refreshBackends() async {
        guard withStateLock({ !isShuttingDown && activeRuns.isEmpty }) else { return }
        let configuration = AgentBackendConfiguration(
            executableURLs: await executableURLProvider()
        )
        let previousBackends = withStateLock { () -> [AgentBackend] in
            guard !isShuttingDown, activeRuns.isEmpty else { return [] }
            guard executableURLs != configuration.executableURLs else { return [] }
            let previousBackends = Array(backends.values)
            backends = configuration.backends
            executableURLs = configuration.executableURLs
            return previousBackends
        }
        for backend in previousBackends {
            backend.shutdown()
        }
    }

    func providers() -> [ProviderInfo] {
        let (backends, executableURLs) = withStateLock { (self.backends, self.executableURLs) }
        return BackendKind.allCases.map { backendKind in
            guard let backend = backends[backendKind] else {
                return unavailableProviderInfo(for: backendKind)
            }
            return ProviderInfo(
                kind: backendKind,
                available: true,
                detail: "已检测到 \(backendKind.displayName)",
                version: nil,
                executablePath: executableURLs[backendKind]?.path,
                supportsPlan: backend.supportsPlan,
                isLoadingModels: true,
                models: [],
                modelLoadFailureDescription: nil
            )
        }
    }

    func refreshProvider(_ backendKind: BackendKind) async -> ProviderInfo {
        let (backend, executableURL) = withStateLock {
            (backends[backendKind], executableURLs[backendKind])
        }
        guard let backend else {
            return unavailableProviderInfo(for: backendKind)
        }

        async let modelListResult = backend.listModels()
        let version: String?
        if let executableURL {
            version = await Task.detached(priority: .utility) {
                ExecutableMetadataLocator.version(for: executableURL)
            }.value
        } else {
            version = nil
        }
        let resolvedModelListResult = await modelListResult
        return ProviderInfo(
            kind: backendKind,
            available: true,
            detail: "已检测到 \(backendKind.displayName)",
            version: version,
            executablePath: executableURL?.path,
            supportsPlan: backend.supportsPlan,
            isLoadingModels: false,
            models: resolvedModelListResult.models,
            modelLoadFailureDescription: resolvedModelListResult.failureDescription
        )
    }

    func prompt(
        sessionID: String,
        text: String,
        mode: RunMode
    ) async {
        let runID = UUID().uuidString
        let cancellation = CancellationToken()
        do {
            guard let session = try store.session(id: sessionID) else {
                throw AgentHostError.sessionNotFound
            }
            guard try store.project(id: session.projectID) != nil else {
                throw AgentHostError.projectNotFound
            }
            guard let backend = self.backend(for: session.agent) else {
                throw AgentHostError.providerUnavailable(session.agent.displayName)
            }
            guard mode != .plan || backend.supportsPlan else {
                throw AgentHostError.planModeUnsupported
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentHostError.emptyPrompt
            }
            try withStateLock {
                guard !isShuttingDown else { throw AgentHostError.shuttingDown }
                guard !deletingProjectIDs.contains(session.projectID) else {
                    throw AgentHostError.projectDeletionInProgress
                }
                guard !deletingSessionIDs.contains(sessionID) else {
                    throw AgentHostError.sessionDeletionInProgress
                }
                guard activeRuns[sessionID] == nil else {
                    throw AgentHostError.sessionAlreadyRunning
                }
                activeRuns[sessionID] = ActiveRun(runID: runID, cancellation: cancellation)
            }
        } catch {
            eventHandler(.runFinished(
                sessionID: sessionID,
                runID: runID,
                status: .failed,
                sessionTitle: nil,
                error: error.localizedDescription
            ))
            return
        }

        eventHandler(.runStarted(sessionID: sessionID, runID: runID))
        var runStatus = RunStatus.completed
        var runError: String?
        var sessionTitle: String?
        let session = try? store.session(id: sessionID)
        let project: ProjectInfo? = if let session {
            try? store.project(id: session.projectID)
        } else {
            nil
        }
        guard let session, let project, let backend = self.backend(for: session.agent) else {
            finishRun(sessionID: sessionID, runID: runID, status: .failed, title: nil, error: "运行配置无效")
            return
        }

        do {
            try store.touchSession(sessionID: sessionID)
            if session.title == "新对话" {
                let title = titleFromPrompt(text)
                sessionTitle = title
                try store.updateSessionTitle(sessionID: sessionID, title: title)
            }
            let context = BackendRunContext(
                agentThreadID: session.agentThreadID,
                modelID: session.modelID,
                reasoningEffort: session.reasoningEffort,
                sandboxMode: session.sandboxMode,
                workingDirectory: project.projectPath,
                prompt: text,
                mode: mode,
                emit: { [weak self] event in
                    self?.emitBackendEvent(event, sessionID: sessionID, runID: runID)
                },
                cancellation: cancellation,
                reportAgentThreadID: { [weak self] agentThreadID in
                    guard let self else { return }
                    do {
                        try self.store.updateAgentThreadID(
                            sessionID: sessionID,
                            agentThreadID: agentThreadID
                        )
                        self.eventHandler(.sessionAgentThreadIDUpdated(
                            sessionID: sessionID,
                            agentThreadID: agentThreadID
                        ))
                    } catch {
                        return
                    }
                },
                requestUserInput: { [weak self] questions in
                    guard let self else { return nil }
                    return await waitForUserInput(sessionID: sessionID, runID: runID, questions: questions)
                },
                requestApproval: { [weak self] toolName, title, input in
                    guard let self else { return .denied }
                    return await waitForApproval(
                        sessionID: sessionID,
                        runID: runID,
                        toolName: toolName,
                        title: title,
                        input: input
                    )
                }
            )
            _ = try await backend.run(context: context)
            if cancellation.isCancelled {
                runStatus = .cancelled
            }
        } catch {
            runStatus = cancellation.isCancelled || error.isRunCancellation
                ? .cancelled
                : .failed
            if runStatus == .failed {
                runError = error.localizedDescription
            }
        }

        finishRun(
            sessionID: sessionID,
            runID: runID,
            status: runStatus,
            title: sessionTitle,
            error: runError
        )
    }

    func cancel(sessionID: String) {
        let activeRun = withStateLock { activeRuns[sessionID] }
        activeRun?.cancellation.cancel()
        clearPendingInteractions(sessionID: sessionID, runID: activeRun?.runID)
    }

    func approve(approvalID: String, decision: ApprovalDecision) {
        let pendingApproval = withStateLock {
            pendingApprovals.removeValue(forKey: approvalID)
        }
        guard let pendingApproval else { return }
        pendingApproval.continuation.resume(returning: decision)
        eventHandler(.approvalResolved(
            sessionID: pendingApproval.sessionID,
            runID: pendingApproval.runID,
            approvalID: approvalID
        ))
    }

    func shutdown() async {
        let (runs, approvals, isFirstShutdown) = withStateLock {
            let isFirstShutdown = !isShuttingDown
            isShuttingDown = true
            let runs = isFirstShutdown ? Array(activeRuns.values) : []
            let approvals = isFirstShutdown ? pendingApprovals : [:]
            if isFirstShutdown {
                pendingApprovals.removeAll()
            }
            return (runs, approvals, isFirstShutdown)
        }
        guard isFirstShutdown else {
            await waitForShutdown()
            return
        }
        for run in runs {
            run.cancellation.cancel()
        }
        for approval in approvals.values {
            approval.continuation.resume(returning: .denied)
        }
        let inputIDs = withStateLock { Array(pendingUserInputs.keys) }
        for id in inputIDs {
            answerUserInput(id: id, answers: nil)
        }
        let backendList = withStateLock { Array(backends.values) }
        for backend in backendList {
            backend.shutdown()
        }
        await waitForShutdown()
    }

    private func waitForApproval(
        sessionID: String,
        runID: String,
        toolName: String,
        title: String?,
        input: [String: JSONValue]
    ) async -> ApprovalDecision {
        let approvalID = UUID().uuidString
        return await withCheckedContinuation { continuation in
            let activeRun = withStateLock { () -> ActiveRun? in
                guard let activeRun = activeRuns[sessionID], activeRun.runID == runID else {
                    return nil
                }
                pendingApprovals[approvalID] = PendingApproval(
                    sessionID: sessionID,
                    runID: runID,
                    continuation: continuation
                )
                return activeRun
            }
            guard let activeRun else {
                continuation.resume(returning: .denied)
                return
            }
            eventHandler(.approvalRequested(
                sessionID: sessionID,
                runID: runID,
                approvalID: approvalID,
                toolName: toolName,
                title: title,
                input: input
            ))
            if activeRun.cancellation.isCancelled {
                approve(approvalID: approvalID, decision: .denied)
            }
        }
    }

    func answerUserInput(id: String, answers: [[String]]?) {
        let pending = withStateLock { pendingUserInputs.removeValue(forKey: id) }
        guard let pending else { return }
        pending.continuation.resume(returning: answers)
        eventHandler(.userInputResolved(id: id))
    }

    private func waitForUserInput(
        sessionID: String,
        runID: String,
        questions: [UserInputQuestion]
    ) async -> [[String]]? {
        let request = UserInputRequest(id: UUID().uuidString, sessionID: sessionID, runID: runID, questions: questions)
        return await withCheckedContinuation { continuation in
            let activeRun = withStateLock { () -> ActiveRun? in
                guard !isShuttingDown, let run = activeRuns[sessionID], run.runID == runID else { return nil }
                pendingUserInputs[request.id] = PendingUserInput(request: request, continuation: continuation)
                return run
            }
            guard let activeRun else {
                continuation.resume(returning: nil)
                return
            }
            eventHandler(.userInputRequested(request))
            if activeRun.cancellation.isCancelled {
                answerUserInput(id: request.id, answers: nil)
            }
        }
    }

    private func clearPendingInteractions(sessionID: String, runID: String?) {
        let inputIDs = withStateLock {
            pendingUserInputs.filter {
                $0.value.request.sessionID == sessionID && (runID == nil || $0.value.request.runID == runID)
            }.map(\.key)
        }
        for id in inputIDs {
            answerUserInput(id: id, answers: nil)
        }
        let approvals = withStateLock {
            let approvals = pendingApprovals.filter { $0.value.sessionID == sessionID && (runID == nil || $0.value.runID == runID) }
            for approvalID in approvals.keys {
                pendingApprovals.removeValue(forKey: approvalID)
            }
            return approvals
        }
        for (approvalID, approval) in approvals {
            approval.continuation.resume(returning: .denied)
            eventHandler(.approvalResolved(
                sessionID: approval.sessionID,
                runID: approval.runID,
                approvalID: approvalID
            ))
        }
    }

    private func emitBackendEvent(_ event: BackendEvent, sessionID: String, runID: String) {
        switch event {
        case let .text(text, itemID):
            eventHandler(.text(sessionID: sessionID, runID: runID, text: text, itemID: itemID))
        case let .reasoning(text, itemID):
            eventHandler(.reasoning(sessionID: sessionID, runID: runID, text: text, itemID: itemID))
        case let .item(item):
            eventHandler(.item(sessionID: sessionID, runID: runID, item: item))
        case let .tool(id, title, state, input, output, error):
            eventHandler(.tool(sessionID: sessionID, runID: runID, id: id, title: title, state: state, input: input, output: output, error: error))
        }
    }

    private func finishRun(
        sessionID: String,
        runID: String,
        status: RunStatus,
        title: String?,
        error: String?
    ) {
        let shutdownWaiters: [CheckedContinuation<Void, Never>] = withStateLock {
            activeRuns.removeValue(forKey: sessionID)
            guard isShuttingDown, activeRuns.isEmpty else { return [] }
            let waiters = self.shutdownWaiters
            self.shutdownWaiters.removeAll()
            return waiters
        }
        clearPendingInteractions(sessionID: sessionID, runID: runID)
        for waiter in shutdownWaiters {
            waiter.resume()
        }
        eventHandler(.runFinished(
            sessionID: sessionID,
            runID: runID,
            status: status,
            sessionTitle: title,
            error: error
        ))
    }

    private func waitForShutdown() async {
        await withCheckedContinuation { continuation in
            let shouldResume = withStateLock {
                if activeRuns.isEmpty {
                    return true
                }
                shutdownWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func withStateLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try operation()
    }

    private func backend(for kind: BackendKind) -> AgentBackend? {
        withStateLock { backends[kind] }
    }

    private func unavailableProviderInfo(for backendKind: BackendKind) -> ProviderInfo {
        ProviderInfo(
            kind: backendKind,
            available: false,
            detail: "未找到 \(backendKind.displayName) 命令",
            version: nil,
            executablePath: nil,
            supportsPlan: true,
            isLoadingModels: false,
            models: [],
            modelLoadFailureDescription: nil
        )
    }

    private func titleFromPrompt(_ prompt: String) -> String {
        let compactPrompt = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compactPrompt.count > 40 ? String(compactPrompt.prefix(40)) + "…" : compactPrompt
    }
}

private final class ActiveRun {
    let runID: String
    let cancellation: CancellationToken

    init(runID: String, cancellation: CancellationToken) {
        self.runID = runID
        self.cancellation = cancellation
    }
}

private struct PendingUserInput {
    let request: UserInputRequest
    let continuation: CheckedContinuation<[[String]]?, Never>
}

private struct PendingApproval {
    let sessionID: String
    let runID: String
    let continuation: CheckedContinuation<ApprovalDecision, Never>
}

enum AgentHostError: LocalizedError {
    case shuttingDown
    case invalidWorkspace
    case projectNotFound
    case sessionNotFound
    case providerUnavailable(String)
    case planModeUnsupported
    case emptyPrompt
    case sessionAlreadyRunning
    case sessionHasAgentConversation
    case sessionDeletionInProgress
    case projectHasRunningSession
    case projectDeletionInProgress

    var errorDescription: String? {
        switch self {
        case .shuttingDown: "Disco 正在关闭"
        case .invalidWorkspace: "请选择有效的工作区目录"
        case .projectNotFound: "项目不存在"
        case .sessionNotFound: "会话不存在"
        case let .providerUnavailable(name): "Provider 不可用：\(name)"
        case .planModeUnsupported: "当前 Provider 不支持计划模式"
        case .emptyPrompt: "请输入内容"
        case .sessionAlreadyRunning: "该会话正在运行"
        case .sessionHasAgentConversation: "该会话已经开始与 Agent 对话"
        case .sessionDeletionInProgress: "该会话正在删除"
        case .projectHasRunningSession: "项目中有会话正在运行"
        case .projectDeletionInProgress: "该项目正在删除"
        }
    }
}

private extension Error {
    var isRunCancellation: Bool {
        if self is CancellationError {
            return true
        }
        if let error = self as? CodexBackendError, case .cancelled = error {
            return true
        }
        if let error = self as? OpenCodeBackendError, case .cancelled = error {
            return true
        }
        return false
    }
}
