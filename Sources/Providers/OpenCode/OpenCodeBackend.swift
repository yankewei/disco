import Darwin
import Foundation

final class OpenCodeBackend: AgentBackend {
    let supportsPlan = true

    private let executableURL: URL
    private let session: URLSession
    private let stateLock = NSLock()
    private var sharedServer: RunningOpenCodeServer?
    private var startTask: Task<RunningOpenCodeServer, Error>?
    private var isShuttingDown = false

    init(executableURL: URL, session: URLSession = OpenCodeBackend.makeLoopbackSession()) {
        self.executableURL = executableURL
        self.session = session
        // Clean up servers orphaned by a previous crash or force-quit.
        ProviderProcessRegistry.shared.reapOrphanedProcesses(executablePath: executableURL.path)
    }

    /// OpenCode is reached over loopback HTTP; never route it through system
    /// proxies, which may be slow or down and would break the readiness probe.
    /// Several runs may stream events concurrently over one shared server.
    private static func makeLoopbackSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: configuration)
    }

    func listModels() async -> ModelListResult {
        do {
            let server = try await acquireServer()
            let response = try await requestJSON(
                baseURL: server.baseURL,
                path: "/config/providers",
                method: "GET",
                body: nil,
                cancellation: CancellationToken()
            )
            return ModelListResult(
                models: parseOpenCodeModels(response),
                failureDescription: nil
            )
        } catch {
            return ModelListResult(
                models: [],
                failureDescription: "无法加载模型，请检查 OpenCode 登录状态后重试"
            )
        }
    }

    func loadMessages(agentThreadID: String, workingDirectory: String) async throws -> [ConversationMessage] {
        let server = try await acquireServer()
        let response = try await requestJSON(
            baseURL: server.baseURL,
            path: directoryPath(
                "/session/\(agentThreadID)/message",
                directory: workingDirectory
            ),
            method: "GET",
            body: nil,
            cancellation: CancellationToken()
        )
        return parseOpenCodeMessages(response)
    }

    func run(context: BackendRunContext) async throws -> String {
        let cancellation = context.cancellation
        guard !cancellation.isCancelled else { throw OpenCodeBackendError.cancelled }
        let server = try await acquireServer(cancellation: cancellation)

        var sessionID = context.agentThreadID
        if sessionID == nil {
            let response = try await requestJSON(
                baseURL: server.baseURL,
                path: directoryPath("/session", directory: context.workingDirectory),
                method: "POST",
                body: .object(["title": .string("新对话")]),
                cancellation: cancellation
            )
            sessionID = jsonObject(response)?["id"].flatMap(jsonString)
            guard let sessionID else {
                throw OpenCodeBackendError.invalidResponse("OpenCode 未返回会话 ID")
            }
            context.reportAgentThreadID(sessionID)
        }
        guard let sessionID else {
            throw OpenCodeBackendError.invalidResponse("OpenCode 会话 ID 为空")
        }

        let eventBytes = try await openEventStream(
            baseURL: server.baseURL,
            workingDirectory: context.workingDirectory,
            cancellation: cancellation
        )
        guard !cancellation.isCancelled else { throw OpenCodeBackendError.cancelled }
        let eventStreamState = OpenCodeEventStreamState()
        let eventTask = Task { [weak self] in
            guard let self else { throw OpenCodeBackendError.shuttingDown }
            try await consumeEvents(
                bytes: eventBytes,
                baseURL: server.baseURL,
                workingDirectory: context.workingDirectory,
                sessionID: sessionID,
                context: context,
                cancellation: cancellation,
                eventStreamState: eventStreamState
            )
        }
        cancellation.onCancel = { [weak self] in
            eventTask.cancel()
            guard let self else { return }
            Task {
                _ = try? await self.requestJSON(
                    baseURL: server.baseURL,
                    path: self.directoryPath(
                        "/session/\(sessionID)/abort",
                        directory: context.workingDirectory
                    ),
                    method: "POST",
                    body: nil,
                    cancellation: CancellationToken()
                )
            }
        }
        defer { cancellation.onCancel = nil }
        do {
            let modelSelection = parseModelSelection(context.modelID)
            var promptBody: [String: JSONValue] = [
                "agent": .string(context.mode == .plan ? "plan" : "build"),
                "parts": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(context.prompt),
                    ]),
                ]),
            ]
            if let modelSelection {
                promptBody["model"] = .object([
                    "providerID": .string(modelSelection.providerID),
                    "modelID": .string(modelSelection.modelID),
                ])
            }
            if let reasoningEffort = context.reasoningEffort {
                promptBody["variant"] = .string(reasoningEffort.rawValue)
            }
            eventStreamState.markPromptSubmitted()
            _ = try await requestJSON(
                baseURL: server.baseURL,
                path: directoryPath(
                    "/session/\(sessionID)/prompt_async",
                    directory: context.workingDirectory
                ),
                method: "POST",
                body: .object(promptBody),
                cancellation: cancellation
            )
            try await eventTask.value
            if cancellation.isCancelled {
                throw OpenCodeBackendError.cancelled
            }
            return sessionID
        } catch {
            eventTask.cancel()
            _ = await eventTask.result
            throw error
        }
    }

    func shutdown() {
        let (server, task) = withStateLock {
            isShuttingDown = true
            let server = sharedServer
            sharedServer = nil
            let task = startTask
            startTask = nil
            return (server, task)
        }
        task?.cancel()
        if let server {
            stop(server)
        }
        session.finishTasksAndInvalidate()
    }

    private func acquireServer(
        cancellation: CancellationToken? = nil
    ) async throws -> RunningOpenCodeServer {
        switch beginLaunch() {
        case .shuttingDown:
            throw OpenCodeBackendError.shuttingDown
        case let .ready(server):
            return server
        case let .launching(task):
            let server = try await waitForLaunch(task, cancellation: cancellation)
            guard !withStateLock({ isShuttingDown }) else {
                stop(server)
                throw OpenCodeBackendError.shuttingDown
            }
            return server
        }
    }

    private enum LaunchState {
        case ready(RunningOpenCodeServer)
        case launching(Task<RunningOpenCodeServer, Error>)
        case shuttingDown
    }

    /// Deciding whether to reuse, join or start the launch has to be atomic: two
    /// callers racing here would each end up with a server and leak one.
    private func beginLaunch() -> LaunchState {
        withStateLock {
            if isShuttingDown {
                return .shuttingDown
            }
            if let sharedServer, sharedServer.process.process.isRunning {
                return .ready(sharedServer)
            }
            sharedServer = nil
            if let startTask {
                return .launching(startTask)
            }
            let task = Task { [weak self] in
                guard let self else { throw OpenCodeBackendError.shuttingDown }
                return try await self.launchServer()
            }
            startTask = task
            return .launching(task)
        }
    }

    /// The launch is shared, so a cancelled caller stops waiting instead of
    /// cancelling it for every other run.
    private func waitForLaunch(
        _ task: Task<RunningOpenCodeServer, Error>,
        cancellation: CancellationToken?
    ) async throws -> RunningOpenCodeServer {
        while withStateLock({ startTask != nil }) {
            if let cancellation, cancellation.isCancelled {
                throw OpenCodeBackendError.cancelled
            }
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                throw OpenCodeBackendError.cancelled
            }
        }
        guard !withStateLock({ isShuttingDown }) else {
            throw OpenCodeBackendError.shuttingDown
        }
        return try await task.value
    }

    private func launchServer() async throws -> RunningOpenCodeServer {
        defer {
            withStateLock { startTask = nil }
        }
        // The server is shared across all sessions and projects; requests scope
        // themselves with the ?directory= query parameter instead.
        let port = try findFreePort()
        let process = ManagedProcess(
            executableURL: executableURL,
            arguments: ["serve", "--hostname", "127.0.0.1", "--port", String(port)],
            workingDirectory: nil,
            environment: await providerEnvironment(for: executableURL),
            captureStandardOutput: false,
            captureStandardError: false
        )
        try process.launch()
        let server = RunningOpenCodeServer(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            process: process
        )
        do {
            // The launch is shared: it must not be cancelled by a single
            // caller's cancellation token.
            try await waitForServerReady(server: server)
        } catch {
            stop(server)
            throw error
        }
        // Publishing has to be atomic with the shutdown check: a server stored
        // after shutdown() cleared the state would never be stopped.
        let published = withStateLock { () -> Bool in
            guard !isShuttingDown else { return false }
            sharedServer = server
            return true
        }
        guard published else {
            stop(server)
            throw OpenCodeBackendError.shuttingDown
        }
        return server
    }

    private func waitForServerReady(server: RunningOpenCodeServer) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !server.process.process.isRunning {
                throw OpenCodeBackendError.requestFailed("OpenCode 服务已退出")
            }
            do {
                let (_, response) = try await request(
                    baseURL: server.baseURL,
                    path: "/global/health",
                    method: "GET",
                    body: nil,
                    cancellation: CancellationToken()
                )
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    return
                }
            } catch {
                // Retry until the deadline.
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw OpenCodeBackendError.startupTimeout
    }

    private func openEventStream(
        baseURL: URL,
        workingDirectory: String,
        cancellation: CancellationToken
    ) async throws -> URLSession.AsyncBytes {
        guard !cancellation.isCancelled else { throw OpenCodeBackendError.cancelled }
        let requestURL = directoryURL(
            baseURL: baseURL,
            path: "/event",
            directory: workingDirectory
        )
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 24 * 60 * 60
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw OpenCodeBackendError.requestFailed("OpenCode 事件流请求失败")
        }
        return bytes
    }

    private func consumeEvents(
        bytes: URLSession.AsyncBytes,
        baseURL: URL,
        workingDirectory: String,
        sessionID: String,
        context: BackendRunContext,
        cancellation: CancellationToken,
        eventStreamState: OpenCodeEventStreamState
    ) async throws {
        var dataLines: [String] = []
        var lineBuffer = Data()
        for try await byte in bytes {
            if cancellation.isCancelled {
                throw OpenCodeBackendError.cancelled
            }
            if byte == 0x0A {
                let line = String(decoding: lineBuffer, as: UTF8.self)
                lineBuffer.removeAll(keepingCapacity: true)
                if line.isEmpty {
                    let event = parseSSEEvent(dataLines.joined(separator: "\n"))
                    dataLines.removeAll(keepingCapacity: true)
                    if let event {
                        let completed = try await handleEvent(
                            event,
                            baseURL: baseURL,
                            workingDirectory: workingDirectory,
                            sessionID: sessionID,
                            context: context,
                            cancellation: cancellation,
                            eventStreamState: eventStreamState
                        )
                        if completed {
                            return
                        }
                    }
                } else if line.hasPrefix("data:") {
                    dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                }
            } else if byte != 0x0D {
                lineBuffer.append(byte)
            }
        }
        if !lineBuffer.isEmpty {
            let line = String(decoding: lineBuffer, as: UTF8.self)
            if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        if !dataLines.isEmpty,
           let event = parseSSEEvent(dataLines.joined(separator: "\n"))
        {
            _ = try await handleEvent(
                event,
                baseURL: baseURL,
                workingDirectory: workingDirectory,
                sessionID: sessionID,
                context: context,
                cancellation: cancellation,
                eventStreamState: eventStreamState
            )
        }
        if !cancellation.isCancelled {
            throw OpenCodeBackendError.requestFailed("OpenCode 事件流意外结束")
        }
    }

    private func handleEvent(
        _ event: [String: JSONValue],
        baseURL: URL,
        workingDirectory: String,
        sessionID: String,
        context: BackendRunContext,
        cancellation: CancellationToken,
        eventStreamState: OpenCodeEventStreamState
    ) async throws -> Bool {
        let payload = jsonObject(event["payload"]) ?? event
        guard
            let type = jsonString(payload["type"]),
            let properties = jsonObject(payload["properties"])
        else { return false }
        // The server scopes /event by directory, so only sessions in this
        // directory share the stream, and every event handled below carries
        // sessionID at the top level. session.error may omit it: an unattributed
        // error belongs to the whole directory, not to some other run.
        if let eventSessionID = jsonString(properties["sessionID"]), eventSessionID != sessionID {
            return false
        }

        switch type {
        case "message.updated":
            let info = jsonObject(properties["info"])
            if jsonString(info?["role"]) == "assistant",
               let error = info?["error"], error != .null
            {
                throw OpenCodeBackendError.backend(formatError(error))
            }
            if jsonString(info?["role"]) == "user", let messageID = jsonString(info?["id"]) {
                eventStreamState.userMessageIDs.insert(messageID)
            }
        case "message.part.delta":
            emitPartDelta(
                properties,
                context: context,
                eventStreamState: eventStreamState
            )
        case "message.part.updated":
            emitPartUpdate(
                properties,
                context: context,
                eventStreamState: eventStreamState
            )
        case "session.next.text.delta":
            let partID = jsonString(properties["textID"])
            if let partID {
                eventStreamState.registerPartKind(.text, partID: partID)
            }
            if eventStreamState.acceptsStreamDelta(
                messageID: jsonString(properties["assistantMessageID"]),
                partID: partID,
                kind: .text,
                source: .sessionNextDelta
            ) {
                if let partID {
                    eventStreamState.markPartAsStreamed(partID)
                }
                if let delta = jsonString(properties["delta"]) {
                    context.emit(.text(text: delta, itemID: partID))
                }
            }
        case "session.next.text.ended":
            let partID = jsonString(properties["textID"])
            if let partID, !eventStreamState.isPartStreamed(partID),
               let text = jsonString(properties["text"])
            {
                context.emit(.item(.text(id: partID, text: text, state: .completed)))
            }
        case "session.next.reasoning.delta":
            let partID = jsonString(properties["reasoningID"])
            if let partID {
                eventStreamState.registerPartKind(.reasoning, partID: partID)
            }
            if eventStreamState.acceptsStreamDelta(
                messageID: jsonString(properties["assistantMessageID"]),
                partID: partID,
                kind: .reasoning,
                source: .sessionNextDelta
            ) {
                if let partID {
                    eventStreamState.markPartAsStreamed(partID)
                }
                if let delta = jsonString(properties["delta"]) {
                    context.emit(.reasoning(text: delta, itemID: partID))
                }
            }
        case "session.next.reasoning.ended":
            let partID = jsonString(properties["reasoningID"])
            if let partID, !eventStreamState.isPartStreamed(partID),
               let text = jsonString(properties["text"])
            {
                context.emit(.item(.reasoning(id: partID, text: text, state: .completed)))
            }
        case "session.next.tool.called":
            emitToolStarted(properties, context: context)
        case "session.next.tool.progress":
            emitToolProgress(properties, context: context)
        case "session.next.tool.success":
            emitToolFinished(properties, failed: false, context: context)
        case "session.next.tool.failed":
            emitToolFinished(properties, failed: true, context: context)
        case "session.next.shell.started":
            context.emit(.tool(
                id: jsonString(properties["callID"]) ?? UUID().uuidString,
                title: jsonString(properties["command"]) ?? "命令执行",
                state: .started,
                input: properties["command"].map { .object(["command": $0]) },
                output: nil,
                error: nil
            ))
        case "session.next.shell.ended":
            context.emit(.tool(
                id: jsonString(properties["callID"]) ?? UUID().uuidString,
                title: "命令执行",
                state: .completed,
                input: nil,
                output: formatJSONValue(properties["output"]),
                error: nil
            ))
        case "permission.asked":
            try await handlePermission(
                properties,
                baseURL: baseURL,
                workingDirectory: workingDirectory,
                sessionID: sessionID,
                versionTwo: false,
                context: context,
                cancellation: cancellation
            )
        case "permission.v2.asked":
            try await handlePermission(
                properties,
                baseURL: baseURL,
                workingDirectory: workingDirectory,
                sessionID: sessionID,
                versionTwo: true,
                context: context,
                cancellation: cancellation
            )
        case "question.asked", "question.v2.asked":
            guard let requestID = jsonString(properties["id"]) else { return false }
            let questions = jsonArray(properties["questions"]).enumerated().compactMap { index, value -> UserInputQuestion? in
                guard let question = jsonObject(value), let title = jsonString(question["question"]) else { return nil }
                return UserInputQuestion(
                    id: String(index),
                    title: title,
                    options: jsonArray(question["options"]).compactMap { value in
                        guard let option = jsonObject(value), let label = jsonString(option["label"]) else { return nil }
                        return .init(label: label, description: jsonString(option["description"]) ?? "")
                    },
                    allowsMultiple: question["multiple"] == .boolean(true),
                    allowsCustom: question["custom"] != .boolean(false),
                    isSecret: false
                )
            }
            guard !questions.isEmpty, questions.count == jsonArray(properties["questions"]).count else {
                throw OpenCodeBackendError.invalidResponse("OpenCode 返回了无效的问题")
            }
            let answers = await context.requestUserInput(questions)
            guard !cancellation.isCancelled else { return false }
            let action = answers == nil ? "reject" : "reply"
            let path = type == "question.v2.asked"
                ? "/api/session/\(sessionID)/question/\(requestID)/\(action)"
                : directoryPath("/question/\(requestID)/\(action)", directory: workingDirectory)
            _ = try await requestJSON(
                baseURL: baseURL,
                path: path,
                method: "POST",
                body: answers.map { .object(["answers": .array($0.map { .array($0.map { .string($0) }) })]) },
                cancellation: cancellation
            )
        case "session.error":
            throw OpenCodeBackendError.backend(formatError(properties["error"]))
        case "session.idle":
            return eventStreamState.promptWasSubmitted
        case "session.status":
            let status = jsonObject(properties["status"])
            if jsonString(status?["type"]) == "idle" || jsonString(properties["status"]) == "idle" {
                return eventStreamState.promptWasSubmitted
            }
        default:
            break
        }
        return false
    }

    private func emitPartDelta(
        _ properties: [String: JSONValue],
        context: BackendRunContext,
        eventStreamState: OpenCodeEventStreamState
    ) {
        guard
            let delta = jsonString(properties["delta"]),
            let partID = jsonString(properties["partID"])
        else { return }
        let field = jsonString(properties["field"])
        let messageID = jsonString(properties["messageID"])
        guard !eventStreamState.userMessageIDs.contains(messageID ?? "") else { return }
        guard field == "text" || field == "reasoning" else { return }

        if let kind = eventStreamState.partKind(for: partID) {
            emitPartDelta(
                delta,
                partID: partID,
                kind: kind,
                context: context,
                eventStreamState: eventStreamState
            )
        } else if field == "reasoning" {
            eventStreamState.registerPartKind(.reasoning, partID: partID)
            emitPartDelta(
                delta,
                partID: partID,
                kind: .reasoning,
                context: context,
                eventStreamState: eventStreamState
            )
        } else {
            eventStreamState.bufferPartDelta(delta, partID: partID)
        }
    }

    private func emitPartDelta(
        _ delta: String,
        partID: String,
        kind: OpenCodePartKind,
        context: BackendRunContext,
        eventStreamState: OpenCodeEventStreamState
    ) {
        guard eventStreamState.acceptsStreamDelta(
            messageID: nil,
            partID: partID,
            kind: kind,
            source: .messagePartDelta
        ) else { return }
        eventStreamState.markPartAsStreamed(partID)
        switch kind {
        case .text:
            context.emit(.text(text: delta, itemID: partID))
        case .reasoning:
            context.emit(.reasoning(text: delta, itemID: partID))
        }
    }

    private func emitPartSnapshot(
        _ text: String,
        partID: String,
        kind: OpenCodePartKind,
        state: MessageItemState,
        context: BackendRunContext,
        eventStreamState: OpenCodeEventStreamState
    ) {
        let bufferedDeltas = eventStreamState.takeBufferedPartDeltas(partID)
        if !bufferedDeltas.isEmpty {
            for bufferedDelta in bufferedDeltas {
                emitPartDelta(
                    bufferedDelta,
                    partID: partID,
                    kind: kind,
                    context: context,
                    eventStreamState: eventStreamState
                )
            }
            return
        }

        guard eventStreamState.acceptsPartSnapshot(
            partID: partID,
            kind: kind,
            hasContent: !text.isEmpty
        ) else { return }
        guard !text.isEmpty else { return }
        switch kind {
        case .text:
            context.emit(.item(.text(id: partID, text: text, state: state)))
        case .reasoning:
            context.emit(.item(.reasoning(id: partID, text: text, state: state)))
        }
    }

    private func emitPartUpdate(
        _ properties: [String: JSONValue],
        context: BackendRunContext,
        eventStreamState: OpenCodeEventStreamState
    ) {
        guard let part = jsonObject(properties["part"]),
              let partID = jsonString(part["id"]),
              let type = jsonString(part["type"])
        else { return }
        let messageID = jsonString(part["messageID"])
        guard !eventStreamState.userMessageIDs.contains(messageID ?? "") else { return }
        let state = messageItemState(part)
        switch type {
        case "text":
            eventStreamState.registerPartKind(.text, partID: partID)
            emitPartSnapshot(
                jsonString(part["text"]) ?? "",
                partID: partID,
                kind: .text,
                state: state,
                context: context,
                eventStreamState: eventStreamState
            )
        case "reasoning":
            eventStreamState.registerPartKind(.reasoning, partID: partID)
            emitPartSnapshot(
                jsonString(part["text"]) ?? "",
                partID: partID,
                kind: .reasoning,
                state: state,
                context: context,
                eventStreamState: eventStreamState
            )
        case "tool":
            let toolState = jsonObject(part["state"])
            let status = jsonString(toolState?["status"])
            let toolID = jsonString(part["callID"]) ?? partID
            let title = jsonString(part["tool"]) ?? "工具调用"
            if status == "error" {
                let error = jsonString(toolState?["error"]) ?? "工具调用失败"
                context.emit(.tool(id: toolID, title: title, state: .failed, input: toolState?["input"], output: error, error: error))
            } else if status == "completed" || state == .completed {
                context.emit(.tool(id: toolID, title: title, state: .completed, input: toolState?["input"], output: formatJSONValue(toolState?["output"]), error: nil))
            } else {
                context.emit(.tool(id: toolID, title: title, state: .started, input: toolState?["input"], output: nil, error: nil))
            }
        case "patch":
            let files = jsonStringArray(part["files"])
            if !files.isEmpty {
                context.emit(.item(.fileChange(
                    id: partID,
                    changes: files.map { FileChange(path: $0, kind: .update, diff: nil) },
                    patchOutput: nil,
                    state: state
                )))
            }
        default:
            break
        }
    }

    private func emitToolStarted(_ properties: [String: JSONValue], context: BackendRunContext) {
        guard let id = jsonString(properties["callID"]) else { return }
        context.emit(.tool(
            id: id,
            title: jsonString(properties["tool"]) ?? "工具调用",
            state: .started,
            input: properties["input"],
            output: nil,
            error: nil
        ))
    }

    private func emitToolProgress(
        _ properties: [String: JSONValue],
        context: BackendRunContext
    ) {
        guard let id = jsonString(properties["callID"]) else { return }
        let output = formatJSONValue(properties["structured"] ?? properties["content"])
        context.emit(.tool(
            id: id,
            title: "工具调用",
            state: .started,
            input: nil,
            output: output.isEmpty ? nil : output,
            error: nil
        ))
    }

    private func emitToolFinished(
        _ properties: [String: JSONValue],
        failed: Bool,
        context: BackendRunContext
    ) {
        guard let id = jsonString(properties["callID"]) else { return }
        let outputValue = failed
            ? (properties["error"] ?? properties["result"])
            : (properties["result"] ?? properties["structured"] ?? properties["content"])
        let output = formatJSONValue(outputValue)
        context.emit(.tool(
            id: id,
            title: jsonString(properties["tool"]) ?? "工具调用",
            state: failed ? .failed : .completed,
            input: nil,
            output: output.isEmpty ? nil : output,
            error: failed ? output : nil
        ))
    }

    private func handlePermission(
        _ properties: [String: JSONValue],
        baseURL: URL,
        workingDirectory: String,
        sessionID: String,
        versionTwo: Bool,
        context: BackendRunContext,
        cancellation: CancellationToken
    ) async throws {
        guard
            let requestID = jsonString(properties["id"]),
            let permission = jsonString(properties["permission"] ?? properties["action"])
        else { return }
        let metadata = jsonObject(properties["metadata"])
        let title = jsonString(metadata?["title"]) ?? permission
        let decision = await context.requestApproval(
            permission,
            title,
            [
                "permission": .string(permission),
                "patterns": properties["patterns"] ?? properties["resources"] ?? .null,
                "metadata": properties["metadata"] ?? .null,
                "tool": properties["tool"] ?? properties["source"] ?? .null,
            ]
        )
        if cancellation.isCancelled {
            return
        }
        let replyPath = versionTwo
            ? "/api/session/\(sessionID)/permission/\(requestID)/reply"
            : directoryPath(
                "/permission/\(requestID)/reply",
                directory: workingDirectory
            )
        _ = try await requestJSON(
            baseURL: baseURL,
            path: replyPath,
            method: "POST",
            body: .object([
                "reply": .string(decision == .approved ? "once" : "reject"),
            ]),
            cancellation: cancellation
        )
    }

    private func withStateLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try operation()
    }

    private func requestJSON(
        baseURL: URL,
        path: String,
        method: String,
        body: JSONValue?,
        cancellation: CancellationToken
    ) async throws -> JSONValue? {
        let (data, response) = try await request(
            baseURL: baseURL,
            path: path,
            method: method,
            body: body,
            cancellation: cancellation
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeBackendError.requestFailed("OpenCode 响应无效")
        }
        if httpResponse.statusCode == 204 || data.isEmpty {
            return nil
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func request(
        baseURL: URL,
        path: String,
        method: String,
        body: JSONValue?,
        cancellation: CancellationToken
    ) async throws -> (Data, URLResponse) {
        guard !cancellation.isCancelled else { throw OpenCodeBackendError.cancelled }
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw OpenCodeBackendError.requestFailed("OpenCode URL 无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = path == "/global/health" ? 1 : 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw OpenCodeBackendError.requestFailed("OpenCode 请求失败：\(detail)")
        }
        return (data, response)
    }

    private func stop(_ server: RunningOpenCodeServer) {
        server.process.terminate()
        if server.process.process.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                server.process.forceTerminate()
            }
        }
    }

    private func directoryPath(_ path: String, directory: String) -> String {
        "\(path)?directory=\(percentEncode(directory))"
    }

    private func directoryURL(baseURL: URL, path: String, directory: String) -> URL {
        URL(string: directoryPath(path, directory: directory), relativeTo: baseURL)!.absoluteURL
    }
}

enum OpenCodePartKind: Hashable {
    case text
    case reasoning
}

enum OpenCodeStreamSource: Equatable {
    case messagePartDelta
    case sessionNextDelta
    case partSnapshot
}

private struct OpenCodeStreamKey: Hashable {
    let streamID: String
    let kind: OpenCodePartKind
}

final class OpenCodeEventStreamState {
    var userMessageIDs: Set<String> = []
    private let stateLock = NSLock()
    private var promptSubmitted = false
    private var partKindByID: [String: OpenCodePartKind] = [:]
    private var bufferedDeltasByPartID: [String: [String]] = [:]
    private var streamedPartIDs: Set<String> = []
    private var streamSourceByKey: [OpenCodeStreamKey: OpenCodeStreamSource] = [:]

    func registerPartKind(_ kind: OpenCodePartKind, partID: String) {
        stateLock.lock()
        if partKindByID[partID] == nil {
            partKindByID[partID] = kind
        }
        stateLock.unlock()
    }

    func partKind(for partID: String) -> OpenCodePartKind? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return partKindByID[partID]
    }

    func bufferPartDelta(_ delta: String, partID: String) {
        stateLock.lock()
        bufferedDeltasByPartID[partID, default: []].append(delta)
        stateLock.unlock()
    }

    func takeBufferedPartDeltas(_ partID: String) -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return bufferedDeltasByPartID.removeValue(forKey: partID) ?? []
    }

    func acceptsStreamDelta(
        messageID: String?,
        partID: String?,
        kind: OpenCodePartKind,
        source: OpenCodeStreamSource
    ) -> Bool {
        guard let streamID = partID ?? messageID else { return true }
        let key = OpenCodeStreamKey(streamID: streamID, kind: kind)
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existingSource = streamSourceByKey[key] {
            return existingSource == source
        }
        streamSourceByKey[key] = source
        return true
    }

    func acceptsPartSnapshot(
        partID: String,
        kind: OpenCodePartKind,
        hasContent: Bool
    ) -> Bool {
        let key = OpenCodeStreamKey(streamID: partID, kind: kind)
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existingSource = streamSourceByKey[key] {
            return existingSource == .partSnapshot
        }
        guard hasContent else { return false }
        streamSourceByKey[key] = .partSnapshot
        return true
    }

    func markPartAsStreamed(_ partID: String) {
        stateLock.lock()
        streamedPartIDs.insert(partID)
        stateLock.unlock()
    }

    func isPartStreamed(_ partID: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streamedPartIDs.contains(partID)
    }

    var promptWasSubmitted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return promptSubmitted
    }

    func markPromptSubmitted() {
        stateLock.lock()
        promptSubmitted = true
        stateLock.unlock()
    }
}

private final class RunningOpenCodeServer {
    let baseURL: URL
    let process: ManagedProcess

    init(baseURL: URL, process: ManagedProcess) {
        self.baseURL = baseURL
        self.process = process
    }
}

enum OpenCodeBackendError: LocalizedError {
    case cancelled
    case shuttingDown
    case startupTimeout
    case invalidResponse(String)
    case backend(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "运行已取消"
        case .shuttingDown: "Disco 正在关闭"
        case .startupTimeout: "OpenCode 服务启动超时"
        case let .invalidResponse(message): message
        case let .backend(message): message
        case let .requestFailed(message): message
        }
    }
}

private func findFreePort() throws -> Int {
    let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else { throw OpenCodeBackendError.requestFailed("无法创建本地端口") }
    defer { close(socketDescriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw OpenCodeBackendError.requestFailed("无法绑定本地端口") }
    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(socketDescriptor, $0, &length)
        }
    }
    guard result == 0 else { throw OpenCodeBackendError.requestFailed("无法读取本地端口") }
    return Int(UInt16(bigEndian: boundAddress.sin_port))
}

private func parseSSEEvent(_ data: String) -> [String: JSONValue]? {
    guard
        let jsonData = data.data(using: .utf8),
        let value = try? JSONDecoder().decode(JSONValue.self, from: jsonData)
    else { return nil }
    return jsonObject(value)
}

func parseOpenCodeMessages(_ value: JSONValue?) -> [ConversationMessage] {
    let responseObject = jsonObject(value)
    let messageValues = value?.arrayValue
        ?? jsonArray(responseObject?["data"] ?? responseObject?["messages"])
    return messageValues.compactMap { value in
        guard let message = jsonObject(value) else { return nil }
        let info = jsonObject(message["info"]) ?? message
        guard let role = jsonString(info["role"]).flatMap({ MessageRole(rawValue: $0) }) else {
            return nil
        }
        let messageID = jsonString(info["id"]) ?? UUID().uuidString
        let time = jsonObject(info["time"])
        let createdAt = openCodeTimestamp(time?["created"] ?? info["createdAt"]) ?? .timestamp()
        let fallbackText = jsonString(info["text"]) ?? ""
        var timeline: [MessageItem] = []

        for partValue in jsonArray(message["parts"]) {
            guard let part = jsonObject(partValue),
                  let partID = jsonString(part["id"]),
                  let type = jsonString(part["type"])
            else { continue }
            let state = messageItemState(part)
            switch type {
            case "text":
                let partText = jsonString(part["text"]) ?? ""
                upsertTimelineItem(.text(id: partID, text: partText, state: state), in: &timeline)
            case "reasoning":
                let partText = jsonString(part["text"]) ?? ""
                upsertTimelineItem(.reasoning(id: partID, text: partText, state: state), in: &timeline)
            case "tool":
                let toolState = jsonObject(part["state"])
                let status = jsonString(toolState?["status"])
                let toolStatus: ToolCallStatus = switch status {
                case "completed": .completed
                case "error": .failed
                default: .started
                }
                let error = jsonString(toolState?["error"])
                    ?? jsonObject(toolState?["error"]).flatMap { jsonString($0["message"]) }
                upsertTimelineItem(
                    .toolCall(
                        id: jsonString(part["callID"]) ?? partID,
                        name: jsonString(part["tool"]) ?? "工具调用",
                        input: toolState?["input"],
                        output: formatJSONValue(toolState?["output"]),
                        error: error,
                        state: toolStatus
                    ),
                    in: &timeline
                )
            case "patch":
                let files = jsonStringArray(part["files"]).map {
                    FileChange(path: $0, kind: .update, diff: nil)
                }
                if !files.isEmpty {
                    upsertTimelineItem(
                        .fileChange(
                            id: partID,
                            changes: files,
                            patchOutput: jsonString(part["hash"]),
                            state: state
                        ),
                        in: &timeline
                    )
                }
            default:
                break
            }
        }

        let isPlan = jsonString(info["mode"]) == "plan"
        let aggregatedText = timeline.compactMap { item in
            guard case let .text(_, partText, _) = item, !partText.isEmpty else { return nil }
            return partText
        }.joined()
        let text = isPlan
            ? (lastTextPartText(in: timeline) ?? fallbackText)
            : (aggregatedText.isEmpty ? fallbackText : aggregatedText)
        let reasoning = timeline.compactMap { item in
            guard case let .reasoning(_, partText, _) = item else { return nil }
            return partText
        }.joined()
        let errorValue = info["error"].flatMap { $0 == .null ? nil : $0 }
        return ConversationMessage(
            id: messageID,
            role: role,
            text: text,
            reasoning: reasoning.isEmpty ? nil : reasoning,
            toolCalls: nil,
            items: timeline.isEmpty ? nil : timeline,
            timeline: timeline.isEmpty ? nil : timeline,
            status: errorValue == nil ? nil : .failed,
            error: errorValue.map(formatError),
            createdAt: createdAt,
            isPlan: isPlan
        )
    }
}

private func upsertTimelineItem(_ item: MessageItem, in timeline: inout [MessageItem]) {
    if let index = timeline.firstIndex(where: { $0.id == item.id }) {
        timeline[index] = item
    } else {
        timeline.append(item)
    }
}

private func openCodeTimestamp(_ value: JSONValue?) -> String? {
    if let string = jsonString(value) {
        return string
    }
    guard let number = jsonNumber(value) else { return nil }
    let seconds = number > 10_000_000_000 ? number / 1_000 : number
    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
}

private func parseOpenCodeModels(_ value: JSONValue?) -> [ModelInfo] {
    let response = jsonObject(value)
    let configuredProviders = jsonArray(response?["providers"])
    let providers = configuredProviders.isEmpty
        ? jsonArray(response?["all"])
        : configuredProviders
    var models: [ModelInfo] = []
    for providerValue in providers {
        guard let provider = jsonObject(providerValue), let providerID = jsonString(provider["id"]) else { continue }
        let modelEntries: [(key: String?, value: JSONValue)]
        if let providerModelList = provider["models"]?.arrayValue {
            modelEntries = providerModelList.map { (key: nil, value: $0) }
        } else if let providerModels = jsonObject(provider["models"]) {
            modelEntries = providerModels.map { (key: $0.key, value: $0.value) }
        } else {
            continue
        }
        for (modelKey, modelValue) in modelEntries {
            guard
                let model = openCodeModel(
                    providerID: providerID,
                    modelKey: modelKey,
                    value: modelValue
                ),
                !models.contains(where: { $0.id == model.id })
            else { continue }
            models.append(model)
        }
    }
    return models
}

private func openCodeModel(
    providerID: String,
    modelKey: String?,
    value: JSONValue
) -> ModelInfo? {
    let model = jsonObject(value)
    guard let modelID = jsonString(model?["id"]) ?? modelKey else { return nil }
    let id = "\(providerID)/\(modelID)"
    let variants = jsonObject(model?["variants"])
    var efforts: [ReasoningEffort] = []
    for (variantName, variantValue) in variants ?? [:] {
        let effort = jsonString(jsonObject(variantValue)?["reasoningEffort"]) ?? variantName
        guard let reasoningEffort = ReasoningEffort(rawValue: effort), !efforts.contains(reasoningEffort) else { continue }
        efforts.append(reasoningEffort)
    }
    return ModelInfo(
        id: id,
        name: jsonString(model?["name"]) ?? id,
        reasoningEfforts: efforts.isEmpty ? nil : efforts
    )
}

private func parseModelSelection(_ modelID: String?) -> (providerID: String, modelID: String)? {
    guard let modelID, let separator = modelID.firstIndex(of: "/"), separator > modelID.startIndex else { return nil }
    let providerID = String(modelID[..<separator])
    let selectedModelID = String(modelID[modelID.index(after: separator)...])
    guard !selectedModelID.isEmpty else { return nil }
    return (providerID, selectedModelID)
}

private func messageItemState(_ part: [String: JSONValue]) -> MessageItemState {
    guard let time = jsonObject(part["time"]) else { return .started }
    if time["end"] != nil {
        return .completed
    }
    if time["start"] != nil {
        return .updated
    }
    return .started
}

private func formatError(_ value: JSONValue?) -> String {
    let object = jsonObject(value)
    if let message = jsonString(object?["message"]) {
        return message
    }
    if let dataMessage = jsonString(jsonObject(object?["data"])?["message"]) {
        return dataMessage
    }
    let formattedValue = formatJSONValue(value)
    return formattedValue.isEmpty ? "OpenCode 运行失败" : formattedValue
}

private func percentEncode(_ value: String) -> String {
    var allowedCharacters = CharacterSet.alphanumerics
    allowedCharacters.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
}
