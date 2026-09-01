import Foundation

final class AgentHost {
    typealias EventHandler = (AgentEvent) -> Void

    private let store: SQLiteStore
    private let eventHandler: EventHandler
    private let backends: [BackendKind: AgentBackend]
    private let stateLock = NSLock()
    private var activeRuns: [String: ActiveRun] = [:]
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShuttingDown = false

    init(
        store: SQLiteStore,
        eventHandler: @escaping EventHandler,
        codexExecutableURL: URL?,
        openCodeExecutableURL: URL?
    ) {
        self.store = store
        self.eventHandler = eventHandler
        var backends: [BackendKind: AgentBackend] = [:]
        if let codexExecutableURL {
            backends[.codex] = CodexBackend(executableURL: codexExecutableURL)
        }
        if let openCodeExecutableURL {
            backends[.opencode] = OpenCodeBackend(executableURL: openCodeExecutableURL)
        }
        self.backends = backends
    }

    func listProjects() throws -> [ProjectInfo] {
        try store.listProjects()
    }

    func createProject(path: String) throws -> ProjectInfo {
        let normalizedURL = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentHostError.invalidWorkspace
        }
        if let existingProject = try store.project(path: normalizedURL.path) {
            return existingProject
        }
        let project = ProjectInfo(
            id: UUID().uuidString,
            name: normalizedURL.lastPathComponent,
            path: normalizedURL.path,
            createdAt: .timestamp()
        )
        try store.createProject(project)
        return project
    }

    func listSessions(projectID: String) throws -> [SessionInfo] {
        try store.listSessions(projectID: projectID)
    }

    func createSession(
        projectID: String,
        backend: BackendKind,
        modelID: String?,
        reasoningEffort: ReasoningEffort?,
        sandboxMode: SandboxMode?
    ) throws -> SessionInfo {
        guard try store.project(id: projectID) != nil else {
            throw AgentHostError.projectNotFound
        }
        guard backends[backend] != nil else {
            throw AgentHostError.providerUnavailable(backend.displayName)
        }
        let session = SessionInfo(
            sessionID: UUID().uuidString,
            projectID: projectID,
            backend: backend,
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            sandboxMode: sandboxMode,
            backendSessionID: nil,
            title: "新对话",
            updatedAt: .timestamp()
        )
        try store.createSession(session)
        return session
    }

    func messages(sessionID: String) throws -> [StoredMessage] {
        try store.messages(sessionID: sessionID)
    }

    func providers() async -> [ProviderInfo] {
        var providers: [ProviderInfo] = []
        for backendKind in BackendKind.allCases {
            guard let backend = backends[backendKind] else {
                providers.append(
                    ProviderInfo(
                        kind: backendKind,
                        available: false,
                        detail: "未找到 \(backendKind.displayName) 命令",
                        supportsPlan: backendKind == .codex,
                        models: []
                    )
                )
                continue
            }
            let models = await backend.listModels()
            providers.append(
                ProviderInfo(
                    kind: backendKind,
                    available: true,
                    detail: "已检测到 \(backendKind.displayName)",
                    supportsPlan: backend.supportsPlan,
                    models: models
                )
            )
        }
        return providers
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
            guard let backend = backends[session.backend] else {
                throw AgentHostError.providerUnavailable(session.backend.displayName)
            }
            guard mode != .plan || backend.supportsPlan else {
                throw AgentHostError.planModeUnsupported
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentHostError.emptyPrompt
            }
            try withStateLock {
                guard !isShuttingDown else { throw AgentHostError.shuttingDown }
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
        var timelineBuilder = TimelineBuilder()
        var runStatus = RunStatus.completed
        var runError: String?
        var sessionTitle: String?
        let session = try? store.session(id: sessionID)
        let project: ProjectInfo? = if let session {
            try? store.project(id: session.projectID)
        } else {
            nil
        }
        guard let session, let project, let backend = backends[session.backend] else {
            finishRun(sessionID: sessionID, runID: runID, status: .failed, title: nil, error: "运行配置无效")
            return
        }

        do {
            try store.appendMessage(
                sessionID: sessionID,
                message: StoredMessage(
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
            )
            if session.title == "新对话" {
                let title = titleFromPrompt(text)
                sessionTitle = title
                try store.updateSessionTitle(sessionID: sessionID, title: title)
            }
            let context = BackendRunContext(
                backendSessionID: session.backendSessionID,
                modelID: session.modelID,
                reasoningEffort: session.reasoningEffort,
                sandboxMode: session.sandboxMode,
                workingDirectory: project.path,
                prompt: text,
                mode: mode,
                emit: { [weak self] event in
                    timelineBuilder.apply(event)
                    self?.emitBackendEvent(event, sessionID: sessionID, runID: runID)
                },
                cancellation: cancellation,
                reportBackendSessionID: { [weak self] backendSessionID in
                    try? self?.store.updateBackendSessionID(
                        sessionID: sessionID,
                        backendSessionID: backendSessionID
                    )
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

        let finalizedBuilder = timelineBuilder.finalized(status: runStatus)
        if !finalizedBuilder.timeline.isEmpty || !finalizedBuilder.assistantText.isEmpty || !finalizedBuilder.reasoning.isEmpty || !finalizedBuilder.toolCalls.isEmpty || runStatus != .completed {
            do {
                try store.appendMessage(
                    sessionID: sessionID,
                    message: StoredMessage(
                        id: UUID().uuidString,
                        role: .assistant,
                        text: finalizedBuilder.assistantText,
                        reasoning: finalizedBuilder.reasoning.isEmpty ? nil : finalizedBuilder.reasoning,
                        toolCalls: finalizedBuilder.toolCalls.isEmpty ? nil : finalizedBuilder.toolCalls,
                        items: finalizedBuilder.items.isEmpty ? nil : finalizedBuilder.items,
                        timeline: finalizedBuilder.timeline,
                        status: runStatus == .completed ? nil : runStatus,
                        error: runError,
                        createdAt: .timestamp()
                    )
                )
            } catch {
                runStatus = .failed
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
        clearApprovals(sessionID: sessionID, runID: activeRun?.runID)
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
        for backend in backends.values {
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

    private func clearApprovals(sessionID: String, runID: String?) {
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
        clearApprovals(sessionID: sessionID, runID: runID)
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
