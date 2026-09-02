import Foundation

final class CodexBackend: AgentBackend {
    let supportsPlan = true

    private let appServer: CodexAppServer
    private let stateLock = NSLock()
    private var isInitialized = false
    private var initializationTask: Task<Void, Error>?
    private var activeRuns: [String: ActiveCodexRun] = [:]
    private var isShuttingDown = false

    init(executableURL: URL) {
        appServer = CodexAppServer(executableURL: executableURL)
    }

    func listModels() async -> [ModelInfo] {
        do {
            try await startIfNeeded()
            var models: [ModelInfo] = []
            var cursor: String?
            repeat {
                var params: [String: JSONValue] = [
                    "limit": .number(100),
                    "includeHidden": .boolean(false),
                ]
                if let cursor {
                    params["cursor"] = .string(cursor)
                }
                let response = try await appServer.request(method: "model/list", params: params)
                guard let responseObject = response.objectValue else { break }
                for model in jsonArray(responseObject["data"]).compactMap(modelInfo)
                    where !models.contains(where: { $0.id == model.id })
                {
                    models.append(model)
                }
                cursor = jsonString(responseObject["nextCursor"])
            } while cursor != nil
            return models
        } catch {
            return []
        }
    }

    func loadMessages(agentThreadID: String, workingDirectory: String) async throws -> [ConversationMessage] {
        try await startIfNeeded()
        let response = try await appServer.request(
            method: "thread/read",
            params: [
                "threadId": .string(agentThreadID),
                "includeTurns": .boolean(true),
            ]
        )
        let responseObject = response.objectValue ?? [:]
        let thread = jsonObject(responseObject["thread"]) ?? responseObject
        return parseCodexMessages(jsonArray(thread["turns"]))
    }

    func run(context: BackendRunContext) async throws -> String {
        if context.cancellation.isCancelled {
            throw CodexBackendError.cancelled
        }
        try await startIfNeeded()

        let sandbox: SandboxMode
        let approvalPolicy: String
        if context.mode == .plan {
            sandbox = .readOnly
            approvalPolicy = "never"
        } else {
            sandbox = context.sandboxMode ?? defaultSandboxMode
            approvalPolicy = "on-request"
        }
        var threadParams: [String: JSONValue] = [
            "cwd": .string(context.workingDirectory),
            "approvalPolicy": .string(approvalPolicy),
            "sandbox": .string(sandbox.rawValue),
        ]
        if let modelID = context.modelID {
            threadParams["model"] = .string(modelID)
        }

        let threadResponse: JSONValue
        if let agentThreadID = context.agentThreadID {
            threadParams["threadId"] = .string(agentThreadID)
            threadResponse = try await appServer.request(
                method: "thread/resume",
                params: threadParams
            )
        } else {
            threadResponse = try await appServer.request(
                method: "thread/start",
                params: threadParams
            )
        }
        guard
            let threadID = jsonObject(threadResponse)?["thread"]
            .flatMap(jsonObject)?["id"]
            .flatMap(jsonString)
        else {
            throw CodexBackendError.invalidResponse("Codex 未返回线程 ID")
        }
        context.reportAgentThreadID(threadID)

        let activeRun = ActiveCodexRun(threadID: threadID, context: context)
        withStateLock {
            activeRuns[threadID] = activeRun
        }
        context.cancellation.onCancel = { [weak self, weak activeRun] in
            guard let self, let activeRun else { return }
            Task { await self.interrupt(activeRun) }
        }
        defer {
            context.cancellation.onCancel = nil
            _ = withStateLock {
                activeRuns.removeValue(forKey: threadID)
            }
        }

        var turnParams: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(context.prompt),
                ]),
            ]),
        ]
        if let reasoningEffort = context.reasoningEffort {
            turnParams["effort"] = .string(reasoningEffort.rawValue)
        }
        let turnResponse = try await appServer.request(
            method: "turn/start",
            params: turnParams
        )
        guard
            let turnID = jsonObject(turnResponse)?["turn"]
            .flatMap(jsonObject)?["id"]
            .flatMap(jsonString)
        else {
            throw CodexBackendError.invalidResponse("Codex 未返回回合 ID")
        }
        activeRun.turnID = turnID
        if context.cancellation.isCancelled {
            await interrupt(activeRun)
        }

        try await withTaskCancellationHandler {
            try await activeRun.waitForCompletion()
        } onCancel: {
            Task { [weak self, weak activeRun] in
                guard let self, let activeRun else { return }
                await interrupt(activeRun)
            }
        }
        if context.cancellation.isCancelled {
            throw CodexBackendError.cancelled
        }
        return threadID
    }

    func shutdown() {
        let (activeRuns, initializationTask) = withStateLock {
            isShuttingDown = true
            isInitialized = false
            let activeRuns = Array(self.activeRuns.values)
            self.activeRuns.removeAll()
            let initializationTask = self.initializationTask
            self.initializationTask = nil
            return (activeRuns, initializationTask)
        }
        initializationTask?.cancel()
        for activeRun in activeRuns {
            activeRun.finish(error: CodexBackendError.shuttingDown)
        }
        appServer.close()
    }

    private func startIfNeeded() async throws {
        let initializationTask = try withStateLock { () -> Task<Void, Error>? in
            guard !isShuttingDown else { throw CodexBackendError.shuttingDown }
            if isInitialized {
                return nil
            }
            if let existingTask = self.initializationTask {
                return existingTask
            }
            let startupTask = Task { [weak self] in
                guard let self else { throw CodexBackendError.shuttingDown }
                try await initializeServer()
            }
            self.initializationTask = startupTask
            return startupTask
        }
        try await initializationTask?.value
    }

    private func initializeServer() async throws {
        defer {
            withStateLock {
                initializationTask = nil
            }
        }
        try appServer.start(
            serverRequestHandler: { [weak self] request in
                guard let self else { throw CodexBackendError.shuttingDown }
                return try await handleServerRequest(request)
            },
            notificationHandler: { [weak self] method, params in
                self?.handleNotification(method: method, params: params)
            },
            closeHandler: { [weak self] in
                self?.handleServerClosed()
            }
        )
        do {
            _ = try await appServer.request(method: "initialize", params: [
                "clientInfo": .object([
                    "name": .string("disco"),
                    "title": .string("Disco"),
                    "version": .string("0.1.0"),
                ]),
                "capabilities": .object(["experimentalApi": .boolean(false)]),
            ])
            try appServer.notify(method: "initialized")
            try withStateLock {
                guard !isShuttingDown else { throw CodexBackendError.shuttingDown }
                isInitialized = true
            }
        } catch {
            appServer.close()
            throw error
        }
    }

    private func handleServerClosed() {
        let activeRuns = withStateLock {
            isInitialized = false
            return Array(self.activeRuns.values)
        }
        for activeRun in activeRuns {
            activeRun.finish(error: CodexBackendError.backend("Codex app-server 已退出"))
        }
    }

    private func handleNotification(method: String, params: JSONValue?) {
        guard let paramsObject = jsonObject(params) else { return }
        let threadID = jsonString(
            paramsObject["threadId"] ?? paramsObject["conversationId"]
        )
        let processID = jsonString(
            paramsObject["processId"] ?? paramsObject["processHandle"]
        )
        let itemID = jsonString(paramsObject["itemId"])
        let activeRun = findActiveRun(
            threadID: threadID,
            processID: processID,
            itemID: itemID
        )
        guard let activeRun else { return }

        switch method {
        case "turn/completed":
            handleTurnCompleted(activeRun, params: paramsObject)
        case "error":
            if jsonBoolean(paramsObject["willRetry"]) != true {
                let errorMessage = jsonObject(paramsObject["error"])
                    .flatMap { jsonString($0["message"]) }
                    ?? "Codex app-server 执行失败"
                activeRun.finish(error: CodexBackendError.backend(errorMessage))
            }
        case "item/agentMessage/delta":
            emitTextDelta(activeRun, params: paramsObject)
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            emitReasoningDelta(activeRun, params: paramsObject)
        case "item/commandExecution/outputDelta", "command/exec/outputDelta":
            emitCommandOutputDelta(activeRun, params: paramsObject)
        case "process/outputDelta":
            emitProcessOutputDelta(activeRun, params: paramsObject)
        case "process/exited":
            emitProcessExited(activeRun, params: paramsObject)
        case "item/commandExecution/terminalInteraction":
            emitTerminalInteraction(activeRun, params: paramsObject)
        case "item/fileChange/patchUpdated":
            emitFileChangeUpdate(activeRun, params: paramsObject)
        case "item/fileChange/outputDelta":
            emitFileChangeOutput(activeRun, params: paramsObject)
        case "item/mcpToolCall/progress":
            emitMCPProgress(activeRun, params: paramsObject)
        case "item/plan/delta":
            emitPlanDelta(activeRun, params: paramsObject)
        case "turn/plan/updated":
            emitPlanUpdate(activeRun, params: paramsObject)
        case "turn/diff/updated":
            emitCodexEvent(activeRun, eventType: method, params: paramsObject)
        case "warning", "guardianWarning":
            emitCodexEvent(activeRun, eventType: method, params: paramsObject)
        case "item/started", "item/updated", "item/completed":
            emitItemNotification(activeRun, method: method, params: paramsObject)
        default:
            if paramsObject["turnId"] != nil || paramsObject["itemId"] != nil {
                emitCodexEvent(activeRun, eventType: method, params: paramsObject)
            }
        }
    }

    private func findActiveRun(
        threadID: String?,
        processID: String?,
        itemID: String?
    ) -> ActiveCodexRun? {
        let activeRuns = withStateLock { Array(self.activeRuns.values) }
        if let threadID, let activeRun = activeRuns.first(where: { $0.threadID == threadID }) {
            return activeRun
        }
        for activeRun in activeRuns {
            if let processID, activeRun.commandProcessIDs.contains(processID) {
                return activeRun
            }
            if let itemID, activeRun.items[itemID] != nil {
                return activeRun
            }
        }
        return nil
    }

    private func handleTurnCompleted(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue]
    ) {
        let turn = jsonObject(params["turn"])
        let status = jsonString(turn?["status"])
        switch status {
        case "completed":
            activeRun.finish()
        case "interrupted":
            activeRun.finish(error: CodexBackendError.cancelled)
        default:
            let errorMessage = jsonObject(turn?["error"])
                .flatMap { jsonString($0["message"]) }
                ?? "Codex turn 执行失败"
            activeRun.finish(error: CodexBackendError.backend(errorMessage))
        }
    }

    private func emitTextDelta(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue]
    ) {
        guard
            let itemID = jsonString(params["itemId"]),
            let delta = jsonString(params["delta"]),
            !delta.isEmpty
        else { return }
        activeRun.streamedTextItemIDs.insert(itemID)
        activeRun.context.emit(.text(text: delta, itemID: itemID))
    }

    private func emitReasoningDelta(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue]
    ) {
        guard
            let itemID = jsonString(params["itemId"]),
            let delta = jsonString(params["delta"]),
            !delta.isEmpty
        else { return }
        activeRun.streamedReasoningItemIDs.insert(itemID)
        activeRun.context.emit(.reasoning(text: delta, itemID: itemID))
    }

    private func emitCommandOutputDelta(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue]
    ) {
        guard
            let itemID = jsonString(params["itemId"]),
            let delta = jsonString(params["delta"]),
            case let .commandExecution(_, command, output, processID, exitCode, durationMs, terminalInput, _) = activeRun.items[itemID]
        else { return }
        let item = MessageItem.commandExecution(
            id: itemID,
            command: command,
            output: output + delta,
            processID: processID,
            exitCode: exitCode,
            durationMs: durationMs,
            terminalInput: terminalInput,
            state: .updated
        )
        emitItem(activeRun, item: item)
    }

    private func emitProcessOutputDelta(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue]
    ) {
        let processID = jsonString(params["processId"] ?? params["processHandle"])
        let itemID = jsonString(params["itemId"])
        let delta: String? = if let deltaBase64 = jsonString(params["deltaBase64"]),
                                let data = Data(base64Encoded: deltaBase64)
        {
            String(data: data, encoding: .utf8)
        } else {
            jsonString(params["delta"])
        }
        guard let delta else { return }
        let commandItemID = itemID ?? processID.flatMap { processID in
            activeRun.items.first { item in
                if case let .commandExecution(_, _, _, itemProcessID, _, _, _, _) = item.value {
                    return itemProcessID == processID
                }
                return false
            }?.key
        }
        guard
            let commandItemID,
            case let .commandExecution(_, command, output, itemProcessID, exitCode, durationMs, terminalInput, _) = activeRun.items[commandItemID]
        else { return }
        emitItem(
            activeRun,
            item: .commandExecution(
                id: commandItemID,
                command: command,
                output: output + delta,
                processID: itemProcessID,
                exitCode: exitCode,
                durationMs: durationMs,
                terminalInput: terminalInput,
                state: .updated
            )
        )
    }

    private func emitProcessExited(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue]
    ) {
        guard
            let processID = jsonString(params["processHandle"] ?? params["processId"]),
            let exitCode = jsonInteger(params["exitCode"]),
            let itemID = activeRun.items.first(where: { item in
                if case let .commandExecution(_, _, _, itemProcessID, _, _, _, _) = item.value {
                    return itemProcessID == processID
                }
                return false
            })?.key,
            case let .commandExecution(_, command, output, itemProcessID, _, durationMs, terminalInput, _) = activeRun.items[itemID]
        else { return }
        let stdout = jsonString(params["stdout"]) ?? ""
        let stderr = jsonString(params["stderr"]) ?? ""
        let bufferedOutput = stdout + stderr
        let finalOutput: String = if bufferedOutput.isEmpty {
            output
        } else if output.isEmpty {
            bufferedOutput
        } else {
            output + "\n" + bufferedOutput
        }
        emitItem(
            activeRun,
            item: .commandExecution(
                id: itemID,
                command: command,
                output: finalOutput,
                processID: itemProcessID,
                exitCode: exitCode,
                durationMs: durationMs,
                terminalInput: terminalInput,
                state: exitCode == 0 ? .completed : .failed
            )
        )
    }

    private func emitTerminalInteraction(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue]
    ) {
        guard
            let itemID = jsonString(params["itemId"]),
            let stdin = jsonString(params["stdin"]),
            case let .commandExecution(_, command, output, processID, exitCode, durationMs, terminalInput, _) = activeRun.items[itemID]
        else { return }
        let updatedTerminalInput = (terminalInput ?? "") + stdin
        emitItem(
            activeRun,
            item: .commandExecution(
                id: itemID,
                command: command,
                output: output,
                processID: processID,
                exitCode: exitCode,
                durationMs: durationMs,
                terminalInput: updatedTerminalInput,
                state: .updated
            )
        )
    }

    private func emitFileChangeUpdate(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue]
    ) {
        guard let itemID = jsonString(params["itemId"]) else { return }
        let changes = parseFileChanges(params["changes"])
        let existingPatchOutput: String? = if case let .fileChange(_, _, patchOutput, _) = activeRun.items[itemID] {
            patchOutput
        } else {
            nil
        }
        emitItem(
            activeRun,
            item: .fileChange(
                id: itemID,
                changes: changes,
                patchOutput: existingPatchOutput,
                state: .updated
            )
        )
    }

    private func emitFileChangeOutput(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue]
    ) {
        guard
            let itemID = jsonString(params["itemId"]),
            let delta = jsonString(params["delta"])
        else { return }
        guard case let .fileChange(_, changes, patchOutput, _) = activeRun.items[itemID] else { return }
        emitItem(
            activeRun,
            item: .fileChange(
                id: itemID,
                changes: changes,
                patchOutput: (patchOutput ?? "") + delta,
                state: .updated
            )
        )
    }

    private func emitMCPProgress(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue]
    ) {
        guard
            let itemID = jsonString(params["itemId"]),
            let message = jsonString(params["message"]),
            case let .mcpToolCall(_, server, tool, arguments, result, error, progress, _) = activeRun.items[itemID]
        else { return }
        emitItem(
            activeRun,
            item: .mcpToolCall(
                id: itemID,
                server: server,
                tool: tool,
                arguments: arguments,
                result: result,
                error: error,
                progress: (progress ?? []) + [message],
                state: .updated
            )
        )
    }

    private func emitPlanDelta(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue]
    ) {
        guard
            let itemID = jsonString(params["itemId"]),
            let delta = jsonString(params["delta"])
        else { return }
        let text = (activeRun.planText[itemID] ?? "") + delta
        activeRun.planText[itemID] = text
        emitItem(
            activeRun,
            item: .todoList(
                id: itemID,
                items: planTextItems(text),
                state: .updated
            )
        )
    }

    private func emitPlanUpdate(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue]
    ) {
        guard let turnID = jsonString(params["turnId"]) ?? activeRun.turnID else { return }
        let itemID = activeRun.planItemID ?? "plan-\(turnID)"
        activeRun.planItemID = itemID
        let items = parseTodoEntries(params["plan"])
        emitItem(
            activeRun,
            item: .todoList(id: itemID, items: items, state: .updated)
        )
    }

    private func emitItemNotification(
        _ activeRun: ActiveCodexRun,
        method: String,
        params: [String: JSONValue]
    ) {
        guard
            let itemObject = jsonObject(params["item"]),
            let itemID = jsonString(itemObject["id"]),
            let itemType = jsonString(itemObject["type"])
        else { return }
        let state: MessageItemState = switch method {
        case "item/started": .started
        case "item/completed": .completed
        default: .updated
        }
        if itemType == "agentMessage" || itemType == "agent_message" {
            if method == "item/completed", !activeRun.streamedTextItemIDs.contains(itemID),
               let item = makeMessageItem(itemObject, state: state)
            {
                emitItem(activeRun, item: item)
            }
            return
        }
        if itemType == "reasoning" {
            if method == "item/completed", !activeRun.streamedReasoningItemIDs.contains(itemID),
               let item = makeMessageItem(itemObject, state: state)
            {
                emitItem(activeRun, item: item)
            }
            return
        }
        if itemType == "plan" || itemType == "todo_list" {
            activeRun.planItemID = activeRun.planItemID ?? itemID
        }
        if let item = makeMessageItem(itemObject, state: state) {
            emitItem(activeRun, item: item)
        }
    }

    private func emitCodexEvent(
        _ activeRun: ActiveCodexRun,
        eventType: String,
        params: [String: JSONValue]
    ) {
        let itemID = jsonString(params["itemId"])
        let eventID = itemID.map { "codex-\(eventType)-\($0)" }
            ?? "codex-\(eventType)-\(activeRun.items.count)"
        emitItem(
            activeRun,
            item: .codexEvent(
                id: eventID,
                eventType: eventType,
                payload: params,
                state: .updated
            )
        )
    }

    private func emitItem(_ activeRun: ActiveCodexRun, item: MessageItem) {
        activeRun.items[item.id] = item
        if case let .commandExecution(_, _, _, processID, _, _, _, _) = item,
           let processID
        {
            activeRun.commandProcessIDs.insert(processID)
        }
        activeRun.context.emit(.item(item))
    }

    private func handleServerRequest(_ request: JSONRPCRequest) async throws -> JSONValue {
        guard
            let params = jsonObject(request.params),
            let threadID = jsonString(params["threadId"] ?? params["conversationId"]),
            let activeRun = withStateLock({ activeRuns[threadID] })
        else {
            throw CodexBackendError.invalidResponse("没有对应的 Codex 运行")
        }

        switch request.method {
        case "item/commandExecution/requestApproval":
            return try await commandApproval(activeRun, params: params, legacy: false)
        case "execCommandApproval":
            return try await commandApproval(activeRun, params: params, legacy: true)
        case "item/fileChange/requestApproval":
            return try await fileApproval(activeRun, params: params, legacy: false)
        case "applyPatchApproval":
            return try await fileApproval(activeRun, params: params, legacy: true)
        case "item/permissions/requestApproval":
            let decision = await activeRun.context.requestApproval(
                "Codex 权限请求",
                jsonString(params["reason"]) ?? "Codex 请求额外权限",
                params
            )
            let permissions = decision == .approved
                ? (jsonObject(params["permissions"]) ?? [:]).filter { $0.value != .null }
                : [:]
            return .object([
                "permissions": .object(permissions),
                "scope": .string("turn"),
            ])
        default:
            throw CodexBackendError.unsupportedRequest(request.method)
        }
    }

    private func commandApproval(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue],
        legacy: Bool
    ) async throws -> JSONValue {
        let command: String = if let value = jsonString(params["command"]) {
            value
        } else {
            jsonStringArray(params["command"]).joined(separator: " ")
        }
        var input = params
        input["command"] = .string(command)
        let decision = await activeRun.context.requestApproval(
            "Codex 命令执行",
            jsonString(params["reason"]) ?? "Codex 请求执行命令",
            input
        )
        if legacy {
            return decision == .approved
                ? .object(["decision": .string("approved")])
                : .object(["decision": .object([
                    "denied": .object(["rejection": .string("用户拒绝")]),
                ])])
        }
        return .object(["decision": .string(decision == .approved ? "accept" : "decline")])
    }

    private func fileApproval(
        _ activeRun: ActiveCodexRun,
        params: [String: JSONValue],
        legacy: Bool
    ) async throws -> JSONValue {
        let decision = await activeRun.context.requestApproval(
            "Codex 文件变更",
            jsonString(params["reason"]) ?? "Codex 请求修改文件",
            params
        )
        if legacy {
            return decision == .approved
                ? .object(["decision": .string("approved")])
                : .object(["decision": .object([
                    "denied": .object(["rejection": .string("用户拒绝")]),
                ])])
        }
        return .object(["decision": .string(decision == .approved ? "accept" : "decline")])
    }

    private func withStateLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try operation()
    }

    private func interrupt(_ activeRun: ActiveCodexRun) async {
        guard let turnID = activeRun.turnID else { return }
        do {
            _ = try await appServer.request(
                method: "turn/interrupt",
                params: [
                    "threadId": .string(activeRun.threadID),
                    "turnId": .string(turnID),
                ]
            )
        } catch {
            activeRun.finish(error: error)
        }
    }
}

private final class ActiveCodexRun {
    let threadID: String
    let context: BackendRunContext
    private let stateLock = NSLock()
    private var storedTurnID: String?
    var turnID: String? {
        get { withStateLock { storedTurnID } }
        set { withStateLock { storedTurnID = newValue } }
    }

    var items: [String: MessageItem] = [:]
    var commandProcessIDs: Set<String> = []
    var streamedTextItemIDs: Set<String> = []
    var streamedReasoningItemIDs: Set<String> = []
    var planText: [String: String] = [:]
    var planItemID: String?
    private var completion: CheckedContinuation<Void, Error>?
    private var completionError: Error?
    private var isCompleted = false

    init(threadID: String, context: BackendRunContext) {
        self.threadID = threadID
        self.context = context
    }

    func waitForCompletion() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let completionState = withStateLock {
                if isCompleted {
                    return (true, completionError)
                }
                completion = continuation
                return (false, nil)
            }
            guard completionState.0 else { return }
            if let error = completionState.1 {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    func finish(error: Error? = nil) {
        let completion: CheckedContinuation<Void, Error>? = withStateLock {
            guard !isCompleted else { return nil }
            isCompleted = true
            completionError = error
            let completion = self.completion
            self.completion = nil
            return completion
        }
        guard let completion else { return }
        if let error {
            completion.resume(throwing: error)
        } else {
            completion.resume()
        }
    }

    private func withStateLock<Value>(_ operation: () -> Value) -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }
}

enum CodexBackendError: LocalizedError {
    case cancelled
    case shuttingDown
    case invalidResponse(String)
    case backend(String)
    case unsupportedRequest(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "运行已取消"
        case .shuttingDown:
            "Disco 正在关闭"
        case let .invalidResponse(message):
            message
        case let .backend(message):
            message
        case let .unsupportedRequest(method):
            "不支持 Codex 请求：\(method)"
        }
    }
}

private func makeMessageItem(
    _ item: [String: JSONValue],
    state: MessageItemState,
    idOverride: String? = nil
) -> MessageItem? {
    guard
        let id = idOverride ?? jsonString(item["id"]),
        let type = jsonString(item["type"])
    else { return nil }

    switch type {
    case "agentMessage", "agent_message":
        return .text(
            id: id,
            text: jsonString(item["text"]) ?? jsonTextParts([item["content"]]),
            state: state
        )
    case "reasoning":
        let reasoningText = jsonTextParts([item["summary"], item["content"]])
        return .reasoning(
            id: id,
            text: reasoningText.isEmpty ? jsonString(item["text"]) ?? "" : reasoningText,
            state: state
        )
    case "commandExecution", "command_execution":
        let itemState = mapItemState(jsonString(item["status"]), fallback: state)
        return .commandExecution(
            id: id,
            command: jsonString(item["command"]) ?? "",
            output: jsonString(item["aggregatedOutput"] ?? item["aggregated_output"]) ?? "",
            processID: jsonString(item["processId"] ?? item["process_id"]),
            exitCode: jsonInteger(item["exitCode"] ?? item["exit_code"]),
            durationMs: jsonInteger(item["durationMs"] ?? item["duration_ms"]),
            terminalInput: nil,
            state: itemState
        )
    case "fileChange", "file_change":
        return .fileChange(
            id: id,
            changes: parseFileChanges(item["changes"]),
            patchOutput: nil,
            state: mapItemState(jsonString(item["status"]), fallback: state)
        )
    case "mcpToolCall", "mcp_tool_call":
        return .mcpToolCall(
            id: id,
            server: jsonString(item["server"]) ?? "",
            tool: jsonString(item["tool"]) ?? "",
            arguments: item["arguments"] ?? .null,
            result: item["result"],
            error: jsonObject(item["error"]).flatMap { jsonString($0["message"]) } ?? jsonString(item["error"]),
            progress: nil,
            state: mapItemState(jsonString(item["status"]), fallback: state)
        )
    case "webSearch", "web_search":
        return .webSearch(id: id, query: jsonString(item["query"]) ?? "", state: state)
    case "plan", "todo_list":
        let items = parseTodoEntries(item["items"])
        return .todoList(
            id: id,
            items: items.isEmpty ? planTextItems(jsonString(item["text"]) ?? "") : items,
            state: state
        )
    case "error":
        return .error(id: id, message: jsonString(item["message"]) ?? "Codex item 执行失败", state: state)
    default:
        return .codexEvent(id: id, eventType: type, payload: item, state: mapItemState(jsonString(item["status"]), fallback: state))
    }
}

private func parseCodexMessages(_ turns: [JSONValue]) -> [ConversationMessage] {
    var messages: [ConversationMessage] = []
    for (turnIndex, turnValue) in turns.enumerated() {
        guard let turn = jsonObject(turnValue) else { continue }
        let turnID = jsonString(turn["id"]) ?? "turn-\(turnIndex)"
        let createdAt = jsonString(turn["createdAt"] ?? turn["created_at"]) ?? .timestamp()
        let completedAt = jsonString(turn["updatedAt"] ?? turn["updated_at"]) ?? createdAt
        var userText = ""
        var assistantText = ""
        var reasoning = ""
        var timeline: [MessageItem] = []

        for itemValue in jsonArray(turn["items"]) {
            guard let item = jsonObject(itemValue), let type = jsonString(item["type"]) else { continue }
            if type == "userMessage" || type == "user_message" {
                userText = jsonString(item["text"]) ?? jsonTextParts([item["content"], item["parts"]])
                continue
            }
            guard let messageItem = makeMessageItem(item, state: .completed) else { continue }
            timeline.append(messageItem)
            switch messageItem {
            case let .text(_, text, _):
                assistantText += text
            case let .reasoning(_, text, _):
                reasoning += text
            default:
                break
            }
        }

        if !userText.isEmpty {
            messages.append(
                ConversationMessage(
                    id: "\(turnID)-user",
                    role: .user,
                    text: userText,
                    reasoning: nil,
                    toolCalls: nil,
                    items: nil,
                    timeline: nil,
                    status: nil,
                    error: nil,
                    createdAt: createdAt
                )
            )
        }
        if !assistantText.isEmpty || !reasoning.isEmpty || !timeline.isEmpty {
            messages.append(
                ConversationMessage(
                    id: "\(turnID)-assistant",
                    role: .assistant,
                    text: assistantText,
                    reasoning: reasoning.isEmpty ? nil : reasoning,
                    toolCalls: nil,
                    items: timeline.isEmpty ? nil : timeline,
                    timeline: timeline.isEmpty ? nil : timeline,
                    status: nil,
                    error: nil,
                    createdAt: completedAt
                )
            )
        }
    }
    return messages
}

private func modelInfo(_ value: JSONValue) -> ModelInfo? {
    guard let object = jsonObject(value), let id = jsonString(object["id"]), jsonBoolean(object["hidden"]) != true else { return nil }
    let advertisedEfforts = jsonArray(object["supportedReasoningEfforts"]).compactMap { value in
        jsonString(jsonObject(value)?["reasoningEffort"])
    }
    let legacyEfforts = jsonStringArray(object["reasoningEfforts"])
    var efforts: [ReasoningEffort] = []
    for effort in (advertisedEfforts + legacyEfforts).compactMap(ReasoningEffort.init(rawValue:)) {
        if !efforts.contains(effort) {
            efforts.append(effort)
        }
    }
    return ModelInfo(
        id: id,
        name: jsonString(object["displayName"] ?? object["name"] ?? object["model"]) ?? id,
        reasoningEfforts: efforts.isEmpty ? nil : efforts
    )
}

private func parseFileChanges(_ value: JSONValue?) -> [FileChange] {
    jsonArray(value).compactMap { value in
        guard let object = jsonObject(value), let path = jsonString(object["path"]) else { return nil }
        let kindValue = object["kind"]
        let kind = jsonString(kindValue) ?? jsonObject(kindValue).flatMap { jsonString($0["type"]) }
        guard let kind, let changeKind = FileChange.ChangeKind(rawValue: kind) else { return nil }
        return FileChange(path: path, kind: changeKind, diff: jsonString(object["diff"]))
    }
}

private func mapItemState(_ value: String?, fallback: MessageItemState) -> MessageItemState {
    switch value {
    case "completed": .completed
    case "failed", "declined": .failed
    case "inProgress", "in_progress": .started
    default: fallback
    }
}

private func parseTodoEntries(_ value: JSONValue?) -> [TodoEntry] {
    jsonArray(value).compactMap { value in
        guard let object = jsonObject(value),
              let text = jsonString(object["step"] ?? object["text"])
        else { return nil }
        return TodoEntry(
            text: text,
            completed: jsonString(object["status"]) == "completed" || jsonBoolean(object["completed"]) == true
        )
    }
}

private func planTextItems(_ text: String) -> [TodoEntry] {
    text
        .split(separator: "\n")
        .map { line in
            line.replacingOccurrences(of: "^\\s*(?:[-*]|\\d+[.)])\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .map { TodoEntry(text: $0, completed: false) }
}
