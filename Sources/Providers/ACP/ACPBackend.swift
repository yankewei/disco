import Foundation

final class ACPBackend: AgentBackend {
    let supportsPlan = false
    private let executableURL: URL
    private let arguments: [String]
    private let stateLock = NSLock()
    private var sessions: [String: Task<ACPClient, Error>] = [:]
    private var clients: [UUID: ACPClient] = [:]
    private var isShuttingDown = false

    init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func listModels() async -> ModelListResult {
        ModelListResult(models: [], failureDescription: nil)
    }

    func loadMessages(agentThreadID: String, workingDirectory: String) async throws -> [ConversationMessage] {
        let client = try await session(id: agentThreadID, workingDirectory: workingDirectory)
        return client.messages
    }

    func run(context: BackendRunContext) async throws -> String {
        guard !context.cancellation.isCancelled else { throw CancellationError() }
        guard context.mode == .agent, context.modelID == nil, context.reasoningEffort == nil else {
            throw ACPError.unsupportedConfiguration
        }
        let client = try await session(id: context.agentThreadID, workingDirectory: context.workingDirectory, cancellation: context.cancellation)
        context.reportAgentThreadID(client.sessionID)
        guard !context.cancellation.isCancelled else { throw CancellationError() }
        return try await client.prompt(context: context)
    }

    func shutdown() {
        let (clients, tasks) = withStateLock { () -> ([ACPClient], [Task<ACPClient, Error>]) in
            isShuttingDown = true
            let result = (Array(self.clients.values), Array(sessions.values))
            self.clients.removeAll()
            sessions.removeAll()
            return result
        }
        tasks.forEach { $0.cancel() }
        clients.forEach { $0.close() }
    }

    private func session(id: String?, workingDirectory: String, cancellation: CancellationToken? = nil) async throws -> ACPClient {
        let key = id ?? UUID().uuidString
        let task = try withStateLock { () throws -> Task<ACPClient, Error> in
            guard !isShuttingDown else { throw CancellationError() }
            if let closedClient = clients.first(where: { $0.value.sessionID == id && $0.value.isDisconnected }) {
                clients.removeValue(forKey: closedClient.key)
                sessions.removeValue(forKey: key)
            }
            if let existing = sessions[key] { return existing }
            let task = Task { () throws -> ACPClient in
                let environment = await providerEnvironment(for: self.executableURL)
                try Task.checkCancellation()
                let client = ACPClient(
                    executableURL: self.executableURL,
                    arguments: self.arguments,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    sessionID: id
                )
                let clientID = UUID()
                try self.withStateLock {
                    guard !self.isShuttingDown else { throw CancellationError() }
                    self.clients[clientID] = client
                }
                do {
                    try await client.connect()
                    return client
                } catch {
                    client.close()
                    _ = self.withStateLock { self.clients.removeValue(forKey: clientID) }
                    throw error
                }
            }
            sessions[key] = task
            return task
        }
        cancellation?.onCancel = { task.cancel() }
        defer { cancellation?.onCancel = nil }
        do {
            let client = try await task.value
            guard client.workingDirectory == workingDirectory else { throw ACPError.workspaceMismatch }
            withStateLock {
                if id == nil {
                    sessions.removeValue(forKey: key)
                    sessions[client.sessionID] = task
                }
            }
            return client
        } catch {
            _ = withStateLock { sessions.removeValue(forKey: key) }
            throw error
        }
    }

    private func withStateLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try operation()
    }
}

private final class ACPClient: @unchecked Sendable {
    let workingDirectory: String
    private let connection: JSONRPCConnection
    private let stateLock = NSLock()
    private var remoteSessionID: String?
    private var history = ACPConversationHistory()
    private var updates = ACPUpdateTranslator()
    private var runContext: BackendRunContext?
    private var isClosed = false

    var sessionID: String { withStateLock { remoteSessionID ?? "" } }
    var messages: [ConversationMessage] { withStateLock { history.messages } }
    var isDisconnected: Bool { withStateLock { isClosed } }

    init(executableURL: URL, arguments: [String], environment: [String: String], workingDirectory: String, sessionID: String?) {
        self.workingDirectory = workingDirectory
        remoteSessionID = sessionID
        connection = JSONRPCConnection(managedProcess: ManagedProcess(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            captureStandardError: false
        ))
    }

    func connect() async throws {
        try connection.start(
            serverRequestHandler: { [weak self] request in
                guard let self else { throw CancellationError() }
                return try await self.handle(request: request)
            },
            notificationHandler: { [weak self] method, params in
                self?.receive(method: method, params: params)
            },
            closeHandler: { [weak self] in
                self?.withStateLock { self?.isClosed = true }
            }
        )
        let initialization = try await connection.request(method: "initialize", params: .object([
            "protocolVersion": .number(1),
            "clientCapabilities": .object([:]),
            "clientInfo": .object(["name": .string("disco"), "title": .string("Disco"), "version": .string("1.0")]),
        ]))
        guard initialization.objectValue?["protocolVersion"] == .number(1) else {
            throw ACPError.incompatibleVersion
        }
        var params: [String: JSONValue] = ["cwd": .string(workingDirectory), "mcpServers": .array([])]
        if let id = withStateLock({ remoteSessionID }) {
            guard initialization.objectValue?["agentCapabilities"]?.objectValue?["loadSession"] == .boolean(true) else {
                throw ACPError.historyUnsupported
            }
            params["sessionId"] = .string(id)
            _ = try await connection.request(method: "session/load", params: .object(params))
        } else {
            let response = try await connection.request(method: "session/new", params: .object(params))
            guard let id = response.objectValue?["sessionId"]?.stringValue, !id.isEmpty else {
                throw ACPError.invalidResponse("session/new 缺少会话 ID")
            }
            withStateLock { remoteSessionID = id }
        }
    }

    func prompt(context: BackendRunContext) async throws -> String {
        try withStateLock {
            guard !isClosed else { throw ACPError.connectionClosed }
            guard runContext == nil else { throw ACPError.sessionBusy }
            runContext = context
            updates = ACPUpdateTranslator()
            history.beginTurn(prompt: context.prompt)
        }
        let cancellation = context.cancellation
        context.cancellation.onCancel = { [weak self] in
            guard let self else { return }
            try? self.connection.notify(method: "session/cancel", params: .object(["sessionId": .string(self.sessionID)]))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                if self.withStateLock({ self.runContext?.cancellation === cancellation }) {
                    self.close()
                }
            }
        }
        defer {
            context.cancellation.onCancel = nil
            withStateLock { runContext = nil }
        }
        do {
            guard !context.cancellation.isCancelled else { throw CancellationError() }
            let response = try await connection.request(method: "session/prompt", params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array([.object(["type": .string("text"), "text": .string(context.prompt)])]),
            ]), timeout: 3_600)
            guard let reason = response.objectValue?["stopReason"]?.stringValue else {
                throw ACPError.invalidResponse("session/prompt 缺少结束原因")
            }
            if reason == "cancelled" || context.cancellation.isCancelled { throw CancellationError() }
            let notice: String?
            switch reason {
            case "end_turn": notice = nil
            case "max_tokens": notice = "Agent 已达到本轮输出长度限制。"
            case "max_turn_requests": notice = "Agent 已达到本轮模型请求次数限制。"
            case "refusal": notice = "Agent 拒绝继续此请求。"
            default: throw ACPError.invalidResponse("未知结束原因：\(reason)")
            }
            if let notice {
                let event = BackendEvent.item(.notice(id: UUID().uuidString, message: notice, state: .completed))
                withStateLock { history.append(event, messageID: nil) }
                context.emit(event)
            }
            return withStateLock {
                history.finishTurn(status: .completed)
                return history.messages.last?.text ?? ""
            }
        } catch {
            withStateLock { history.finishTurn(status: context.cancellation.isCancelled || error is CancellationError ? .cancelled : .failed) }
            if context.cancellation.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func close() {
        withStateLock { isClosed = true }
        connection.close()
    }

    private func receive(method: String, params: JSONValue?) {
        guard method == "session/update", let params = params?.objectValue,
              let id = params["sessionId"]?.stringValue,
              let update = params["update"]?.objectValue
        else { return }
        let (event, context) = withStateLock { () -> (BackendEvent?, BackendRunContext?) in
            guard remoteSessionID == nil || remoteSessionID == id else { return (nil, nil) }
            if update["sessionUpdate"]?.stringValue == "user_message_chunk" {
                if runContext == nil, let content = update["content"]?.objectValue,
                   content["type"]?.stringValue == "text", let text = content["text"]?.stringValue {
                    history.appendUser(text, messageID: update["messageId"]?.stringValue)
                }
                return (nil, nil)
            }
            guard let event = updates.event(for: update) else { return (nil, nil) }
            history.append(event, messageID: update["messageId"]?.stringValue)
            return (event, runContext)
        }
        if let event { context?.emit(event) }
    }

    private func handle(request: JSONRPCRequest) async throws -> JSONValue {
        guard request.method == "session/request_permission" else {
            throw JSONRPCError(code: -32601, message: "Disco 未启用该客户端能力：\(request.method)")
        }
        guard let params = request.params?.objectValue,
              params["sessionId"]?.stringValue == sessionID,
              let tool = params["toolCall"]?.objectValue,
              let rawOptions = params["options"]?.arrayValue, !rawOptions.isEmpty
        else { throw JSONRPCError(code: -32602, message: "权限请求参数无效") }
        let options = try rawOptions.map { value -> (id: String, label: String, kind: String) in
            guard let option = value.objectValue,
                  let id = option["optionId"]?.stringValue,
                  let label = option["name"]?.stringValue,
                  let kind = option["kind"]?.stringValue
            else { throw JSONRPCError(code: -32602, message: "权限选项无效") }
            return (id, label, kind)
        }
        let cancelled = JSONValue.object(["outcome": .object(["outcome": .string("cancelled")])])
        guard let context = withStateLock({ runContext }), !context.cancellation.isCancelled else { return cancelled }
        let questionOptions = options.enumerated().map { index, option in
            let description: String = switch option.kind {
            case "allow_once": "仅允许此次操作"
            case "allow_always": "持续允许此类操作"
            case "reject_once": "仅拒绝此次操作"
            case "reject_always": "持续拒绝此类操作"
            default: "由 Agent 定义的权限选项"
            }
            return UserInputQuestion.Option(label: "\(index + 1). \(option.label)", description: description)
        }
        let answers = await context.requestUserInput([UserInputQuestion(
            id: UUID().uuidString,
            title: tool["title"]?.stringValue ?? "Agent 请求操作权限",
            options: questionOptions,
            allowsMultiple: false,
            allowsCustom: false,
            isSecret: false
        )])
        guard !context.cancellation.isCancelled,
              let answer = answers?.first?.first,
              let index = questionOptions.firstIndex(where: { $0.label == answer })
        else { return cancelled }
        return .object(["outcome": .object([
            "outcome": .string("selected"), "optionId": .string(options[index].id),
        ])])
    }

    private func withStateLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try operation()
    }
}

enum ACPError: LocalizedError {
    case incompatibleVersion
    case historyUnsupported
    case connectionClosed
    case sessionBusy
    case workspaceMismatch
    case unsupportedConfiguration
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .incompatibleVersion: "Agent 的 ACP 协议版本不兼容，Disco 当前支持版本 1。"
        case .historyUnsupported: "此 Agent 不支持恢复历史会话，请新建对话。"
        case .connectionClosed: "Agent 连接已断开，请刷新服务商后重试。"
        case .sessionBusy: "此 Agent 会话正在运行，请稍后重试。"
        case .workspaceMismatch: "Agent 会话的工作目录与当前项目不一致。"
        case .unsupportedConfiguration: "ACP 接入当前使用 Agent 默认模型和模式，请新建使用默认配置的对话。"
        case let .invalidResponse(message): "Agent 的 ACP 响应无效：\(message)"
        }
    }
}
