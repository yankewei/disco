import Foundation

// MARK: - 子进程抽象

/// 逐行子进程抽象：生产实现包装 `codex app-server`，测试注入脚本化替身。
protocol LineProcess: AnyObject {
    var isRunning: Bool { get }
    func start() throws
    func sendLine(_ line: String) throws
    func receiveLines() -> AsyncThrowingStream<String, Error>
    func terminate()
}

/// 生产实现：stdio JSONL 的 Codex app-server 子进程。
final class SubprocessLineProcess: LineProcess, @unchecked Sendable {
    private let process: Process
    private let stdoutPipe: Pipe
    private let stdinHandle: FileHandle
    private let state = State()

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var buffer = Data()
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        var finished = false

        func append(_ data: Data, isEOF: Bool) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)
            var lines = Self.drainLines(from: &buffer)
            if isEOF && !buffer.isEmpty {
                lines.append(Self.decodeLine(buffer))
                buffer.removeAll()
            }
            return lines
        }

        func registerConsumer(
            _ continuation: AsyncThrowingStream<String, Error>.Continuation
        ) -> (buffered: [String], finished: Bool) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
            return (Self.drainLines(from: &buffer), finished)
        }

        func continuationAndFinish() -> AsyncThrowingStream<String, Error>.Continuation? {
            lock.lock()
            defer { lock.unlock() }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }

        func currentContinuation() -> AsyncThrowingStream<String, Error>.Continuation? {
            lock.lock()
            defer { lock.unlock() }
            return continuation
        }

        private static func drainLines(from buffer: inout Data) -> [String] {
            var lines: [String] = []
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                lines.append(decodeLine(lineData))
            }
            return lines
        }

        private static func decodeLine(_ data: Data) -> String {
            var line = String(decoding: data, as: UTF8.self)
            if line.last == "\r" { line.removeLast() }
            return line
        }
    }

    init(executableURL: URL, arguments: [String] = ["app-server"]) {
        let stdinPipe = Pipe()
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stdinHandle = stdinPipe.fileHandleForWriting
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [state] handle in
            let data = handle.availableData
            let isEOF = data.isEmpty
            let lines = state.append(data, isEOF: isEOF)
            let continuation = state.currentContinuation()
            if isEOF {
                handle.readabilityHandler = nil
                let closingContinuation = state.continuationAndFinish()
                for line in lines { closingContinuation?.yield(line) }
                closingContinuation?.finish()
            } else {
                for line in lines { continuation?.yield(line) }
            }
        }
        try process.run()
    }

    func sendLine(_ line: String) throws {
        guard let data = (line + "\n").data(using: .utf8) else {
            throw CodexAppServerError.invalidLine(line)
        }
        try stdinHandle.write(contentsOf: data)
    }

    func receiveLines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let result = state.registerConsumer(continuation)
            for line in result.buffered { continuation.yield(line) }
            if result.finished { continuation.finish() }
        }
    }

    func terminate() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        state.continuationAndFinish()?.finish()
        if process.isRunning { process.terminate() }
    }
}

// MARK: - turn 领域事件

enum CodexTurnEvent: Sendable, Equatable {
    case started(turnID: String)
    case itemStarted(itemID: String, itemType: String?)
    case agentMessageDelta(String)
    case reasoningSummaryDelta(String)
    case itemCompleted(itemID: String, itemType: String?)
    case completed(CodexTurnStatus)
}

enum CodexTurnStatus: Sendable, Equatable {
    case completed
    case interrupted
    case failed(String)
}

struct CodexModel: Sendable, Equatable {
    let id: String
    let displayName: String

    /// 服务端返回的可选推理档位；为空表示当前版本未提供可调能力。
    let supportedReasoningEfforts: [String]
    let defaultReasoningEffort: String?

    init(
        id: String,
        displayName: String,
        supportedReasoningEfforts: [String] = [],
        defaultReasoningEffort: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

struct CodexAccountStatus: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case chatgpt(email: String?, planType: String?)
        case apiKey
        case other(String)
        case signedOut
    }

    let kind: Kind
    let requiresOpenAI: Bool

    var isSignedIn: Bool {
        switch kind {
        case .signedOut: false
        case .chatgpt, .apiKey, .other: true
        }
    }
}

// MARK: - 错误

enum CodexAppServerError: LocalizedError, Equatable {
    case processFailedToStart(String)
    case notInitialized
    case alreadyInitialized
    case threadAlreadyStarted
    case noActiveThread
    case turnAlreadyInProgress
    case noActiveTurn
    case stopped
    case processExited
    case requestTimedOut(String)
    case unsupportedServerRequest(String)
    case writeFailed(String)
    case invalidLine(String)
    case invalidResponse(String)
    case rpcError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case let .processFailedToStart(message): "无法启动 codex app-server：\(message)"
        case .notInitialized: "尚未完成 codex app-server 握手（initialize）。"
        case .alreadyInitialized: "codex app-server 已初始化。"
        case .threadAlreadyStarted: "该连接已经加载了这个会话线程。"
        case .noActiveThread: "尚未创建会话线程（thread/start）。"
        case .turnAlreadyInProgress: "该会话线程已有进行中的 turn。"
        case .noActiveTurn: "当前没有进行中的 turn。"
        case .stopped: "codex app-server 已停止。"
        case .processExited: "codex app-server 进程已退出。"
        case let .requestTimedOut(method): "codex app-server 请求超时：\(method)"
        case let .unsupportedServerRequest(method): "disco 暂不支持 codex app-server 服务端请求：\(method)"
        case let .writeFailed(message): "无法向 codex app-server 写入请求：\(message)"
        case let .invalidLine(line): "收到无法解析的服务端行：\(line)"
        case let .invalidResponse(description): "服务端响应格式不符合预期：\(description)"
        case let .rpcError(code, message): "codex app-server 返回错误（\(code)）：\(message)"
        }
    }
}

// MARK: - app-server 传输层

/// Codex app-server 的 stdio JSONL transport。
///
/// 这是一个连接级模块：一条长连接可以加载多个 thread，并按 threadId
/// 路由多个 turn 的事件。它只负责协议、生命周期和流，不负责审批或工具执行。
@MainActor
final class CodexAppServerTransport {
    struct ClientInfo: Sendable, Encodable {
        let name: String
        let title: String
        let version: String
    }

    struct Configuration: Sendable {
        let executableURL: URL
        let arguments: [String]
        let clientInfo: ClientInfo
        let requestTimeout: Duration

        init(
            executableURL: URL,
            arguments: [String],
            clientInfo: ClientInfo,
            requestTimeout: Duration = .seconds(30)
        ) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.clientInfo = clientInfo
            self.requestTimeout = requestTimeout
        }

        static func standard() -> Configuration {
            Configuration(
                executableURL: locateCodex(),
                arguments: ["app-server"],
                clientInfo: ClientInfo(name: "disco", title: "Disco", version: "0.1.0")
            )
        }

        private static func locateCodex() -> URL {
            let fallback = URL(fileURLWithPath: "/usr/local/bin/codex")
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            var candidates = path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex")
            }
            let realHome = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
            candidates.append(contentsOf: [
                URL(fileURLWithPath: realHome).appendingPathComponent(".local/bin/codex"),
                URL(fileURLWithPath: realHome).appendingPathComponent(".codex/bin/codex"),
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                fallback,
            ])
            return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) ?? fallback
        }
    }

    private struct ActiveTurn {
        let continuation: AsyncThrowingStream<CodexTurnEvent, Error>.Continuation
        var turnID: String?
        var didEmitStarted = false
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<CodexJSONValue, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private let configuration: Configuration
    private let processFactory: () -> LineProcess
    private var process: LineProcess?
    private var isInitialized = false
    private var isStopping = false
    private var nextRequestID = 0
    private var pending: [Int: PendingRequest] = [:]
    private var readTask: Task<Void, Never>?
    private var activeTurns: [String: ActiveTurn] = [:]
    private var loadedThreadIDs: Set<String> = []
    private var defaultThreadID: String?

    /// 每次成功握手递增。Runtime 用它判断连接重启后是否需要重新 resume thread。
    private(set) var connectionGeneration: UInt64 = 0

    var isReady: Bool { isInitialized }

    init(process: LineProcess? = nil, configuration: Configuration? = nil) {
        let configuration = configuration ?? .standard()
        self.configuration = configuration
        if let process {
            self.process = process
            self.processFactory = { process }
        } else {
            self.processFactory = {
                SubprocessLineProcess(
                    executableURL: configuration.executableURL,
                    arguments: configuration.arguments
                )
            }
        }
    }

    init(
        processFactory: @escaping () -> LineProcess,
        configuration: Configuration? = nil
    ) {
        self.configuration = configuration ?? .standard()
        self.processFactory = processFactory
    }

    // MARK: 生命周期

    func start() async throws {
        guard !isInitialized else { throw CodexAppServerError.alreadyInitialized }
        isStopping = false
        if process?.isRunning != true {
            process = processFactory()
        }
        guard let process else { throw CodexAppServerError.stopped }

        do {
            try process.start()
            startReading(process: process)
            _ = try await request(
                method: "initialize",
                params: CodexInitializeParams(clientInfo: configuration.clientInfo),
                result: CodexInitializeResponse.self
            )
            try sendNotification(method: "initialized", params: CodexEmptyParams())
            isInitialized = true
            connectionGeneration &+= 1
        } catch {
            failConnection(error)
            throw error
        }
    }

    func stop() {
        isStopping = true
        finishActiveTurns(with: CodexAppServerError.stopped)
        finishPending(with: CodexAppServerError.stopped)
        process?.terminate()
        process = nil
        readTask?.cancel()
        readTask = nil
        loadedThreadIDs.removeAll()
        defaultThreadID = nil
        isInitialized = false
    }

    // MARK: 会话方法

    func listModels() async throws -> [CodexModel] {
        let response = try await request(
            method: "model/list",
            params: CodexModelListParams(limit: 100, includeHidden: false),
            result: CodexModelListResponse.self
        )
        return response.data.map {
            CodexModel(
                id: $0.model.isEmpty ? $0.id : $0.model,
                displayName: $0.displayName,
                supportedReasoningEfforts: $0.supportedReasoningEfforts.map(\.value),
                defaultReasoningEffort: $0.defaultReasoningEffort
            )
        }
    }

    func accountStatus() async throws -> CodexAccountStatus {
        let response = try await request(
            method: "account/read",
            params: CodexEmptyParams(),
            result: CodexAccountReadResponse.self
        )
        guard let account = response.account else {
            return CodexAccountStatus(kind: .signedOut, requiresOpenAI: response.requiresOpenaiAuth)
        }
        switch account.type {
        case "chatgpt":
            return CodexAccountStatus(
                kind: .chatgpt(email: account.email, planType: account.planType),
                requiresOpenAI: response.requiresOpenaiAuth
            )
        case "apiKey":
            return CodexAccountStatus(kind: .apiKey, requiresOpenAI: response.requiresOpenaiAuth)
        default:
            return CodexAccountStatus(kind: .other(account.type), requiresOpenAI: response.requiresOpenaiAuth)
        }
    }

    /// 加载一个 thread。一个连接可多次调用；同一连接不会重复加载同一个 id。
    func startThread(model: String, resumeThreadID: String? = nil) async throws -> String {
        guard isInitialized else { throw CodexAppServerError.notInitialized }
        let response: CodexThreadResponse
        if let resumeThreadID {
            response = try await request(
                method: "thread/resume",
                params: CodexThreadResumeParams(threadId: resumeThreadID, model: model),
                result: CodexThreadResponse.self
            )
        } else {
            response = try await request(
                method: "thread/start",
                params: CodexThreadStartParams(model: model),
                result: CodexThreadResponse.self
            )
        }
        let threadID = response.thread.id
        guard !loadedThreadIDs.contains(threadID) else {
            throw CodexAppServerError.threadAlreadyStarted
        }
        loadedThreadIDs.insert(threadID)
        defaultThreadID = defaultThreadID ?? threadID
        return threadID
    }

    func startTurn(
        threadID: String,
        input: String,
        effort: String? = nil
    ) -> AsyncThrowingStream<CodexTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor [weak self] in
                self?.beginTurn(
                    threadID: threadID,
                    input: input,
                    effort: effort,
                    continuation: continuation
                )
            }
        }
    }

    /// 兼容单线程调用方；新代码应显式传 threadID。
    func startTurn(input: String) -> AsyncThrowingStream<CodexTurnEvent, Error> {
        guard isInitialized else {
            return AsyncThrowingStream { $0.finish(throwing: CodexAppServerError.notInitialized) }
        }
        guard let defaultThreadID else {
            return AsyncThrowingStream { $0.finish(throwing: CodexAppServerError.noActiveThread) }
        }
        return startTurn(threadID: defaultThreadID, input: input)
    }

    func interruptTurn(threadID: String) async throws {
        guard let turnID = activeTurns[threadID]?.turnID else {
            throw CodexAppServerError.noActiveTurn
        }
        _ = try await request(
            method: "turn/interrupt",
            params: CodexTurnInterruptParams(threadId: threadID, turnId: turnID),
            result: CodexEmptyResponse.self
        )
    }

    /// 兼容单线程调用方。
    func interruptTurn() async throws {
        guard let threadID = activeTurns.keys.first else { throw CodexAppServerError.noActiveTurn }
        try await interruptTurn(threadID: threadID)
    }

    // MARK: 读循环与路由

    private func beginTurn(
        threadID: String,
        input: String,
        effort: String?,
        continuation: AsyncThrowingStream<CodexTurnEvent, Error>.Continuation
    ) {
        guard isInitialized else {
            continuation.finish(throwing: CodexAppServerError.notInitialized)
            return
        }
        guard loadedThreadIDs.contains(threadID) else {
            continuation.finish(throwing: CodexAppServerError.noActiveThread)
            return
        }
        guard activeTurns[threadID] == nil else {
            continuation.finish(throwing: CodexAppServerError.turnAlreadyInProgress)
            return
        }

        activeTurns[threadID] = ActiveTurn(continuation: continuation)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await self.request(
                    method: "turn/start",
                    params: CodexTurnStartParams(
                        threadId: threadID,
                        input: [CodexTurnInput(type: "text", text: input)],
                        effort: effort
                    ),
                    result: CodexTurnResponse.self
                )
                self.activeTurns[threadID]?.turnID = response.turn.id
            } catch {
                guard let active = self.activeTurns.removeValue(forKey: threadID) else { return }
                active.continuation.finish(throwing: error)
            }
        }
    }

    private func startReading(process: LineProcess) {
        readTask = Task { @MainActor [weak self] in
            do {
                for try await line in process.receiveLines() {
                    self?.handleLine(line)
                }
                guard let self, !self.isStopping else { return }
                self.failConnection(CodexAppServerError.processExited)
            } catch {
                guard let self, !self.isStopping else { return }
                self.failConnection(error)
            }
        }
    }

    private func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(CodexRPCEnvelope.self, from: data) else {
            failConnection(CodexAppServerError.invalidLine(trimmed))
            return
        }

        if let method = envelope.method, let id = envelope.id {
            handleServerRequest(id: id, method: method)
        } else if let id = envelope.id {
            handleResponse(id: id, envelope: envelope)
        } else if let method = envelope.method {
            handleNotification(method: method, params: envelope.params)
        } else {
            failConnection(CodexAppServerError.invalidResponse("JSON-RPC message 缺少 method 或 id。"))
        }
    }

    private func handleServerRequest(id: Int, method: String) {
        // 审批、工具和用户输入都刻意留在边界之外：必须回复错误，不能让
        // app-server 永久等待，也不能假装已经执行了请求。
        do {
            let data = try JSONEncoder().encode(CodexRPCErrorResponse(
                id: id,
                error: .init(code: -32601, message: "disco 暂不支持服务端请求：\(method)")
            ))
            try sendRawLine(String(decoding: data, as: UTF8.self))
        } catch {
            failConnection(CodexAppServerError.unsupportedServerRequest(method))
        }
    }

    private func handleResponse(id: Int, envelope: CodexRPCEnvelope) {
        guard let pendingRequest = pending.removeValue(forKey: id) else { return }
        pendingRequest.timeoutTask?.cancel()
        if let error = envelope.error {
            pendingRequest.continuation.resume(throwing: CodexAppServerError.rpcError(
                code: error.code,
                message: error.message
            ))
        } else {
            pendingRequest.continuation.resume(returning: envelope.result ?? .null)
        }
    }

    private func handleNotification(method: String, params: CodexJSONValue?) {
        switch method {
        case "turn/started":
            guard let notification = decode(params, as: CodexTurnStartedNotification.self) else { return }
            handleTurnStarted(notification)
        case "item/started":
            guard let lifecycle = decode(params, as: CodexItemLifecycleNotification.self),
                  let active = activeTurns[lifecycle.threadId],
                  let itemID = lifecycle.itemID else { return }
            active.continuation.yield(.itemStarted(itemID: itemID, itemType: lifecycle.itemType))
        case "item/agentMessage/delta":
            if let delta = decode(params, as: CodexAgentMessageDeltaNotification.self) {
                activeTurns[delta.threadId]?.continuation.yield(.agentMessageDelta(delta.delta))
            }
        case "item/reasoning/summaryTextDelta":
            if let delta = decode(params, as: CodexReasoningSummaryTextDeltaNotification.self) {
                activeTurns[delta.threadId]?.continuation.yield(.reasoningSummaryDelta(delta.delta))
            }
        case "item/completed":
            guard let lifecycle = decode(params, as: CodexItemLifecycleNotification.self),
                  let active = activeTurns[lifecycle.threadId],
                  let itemID = lifecycle.itemID else { return }
            active.continuation.yield(.itemCompleted(itemID: itemID, itemType: lifecycle.itemType))
        case "turn/completed":
            guard let notification = decode(params, as: CodexTurnCompletedNotification.self) else { return }
            handleTurnCompleted(notification)
        default:
            break
        }
    }

    private func handleTurnStarted(_ notification: CodexTurnStartedNotification) {
        guard var active = activeTurns[notification.threadId], !active.didEmitStarted else { return }
        active.didEmitStarted = true
        active.turnID = notification.turn.id
        activeTurns[notification.threadId] = active
        active.continuation.yield(.started(turnID: notification.turn.id))
    }

    private func handleTurnCompleted(_ notification: CodexTurnCompletedNotification) {
        guard let active = activeTurns.removeValue(forKey: notification.threadId) else { return }
        let status: CodexTurnStatus
        switch notification.turn.status {
        case "interrupted":
            status = .interrupted
        case "failed":
            status = .failed(notification.turn.error?.message ?? "模型响应失败。")
        default:
            status = .completed
        }
        active.continuation.yield(.completed(status))
        active.continuation.finish()
    }

    private func decode<T: Decodable>(_ value: CodexJSONValue?, as type: T.Type) -> T? {
        guard let value else { return nil }
        return try? value.decoded(as: type)
    }

    private func failConnection(_ error: Error) {
        guard !isStopping else { return }
        isStopping = true
        finishActiveTurns(with: error)
        finishPending(with: error)
        process?.terminate()
        process = nil
        readTask?.cancel()
        readTask = nil
        loadedThreadIDs.removeAll()
        defaultThreadID = nil
        isInitialized = false
    }

    private func finishActiveTurns(with error: Error) {
        let turns = activeTurns.values
        activeTurns.removeAll()
        for active in turns { active.continuation.finish(throwing: error) }
    }

    private func finishPending(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    // MARK: JSON-RPC 收发包

    private func request<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params,
        result: Result.Type
    ) async throws -> Result {
        guard isInitialized || method == "initialize" else {
            throw CodexAppServerError.notInitialized
        }
        let id = nextRequestID
        nextRequestID += 1
        let data = try JSONEncoder().encode(CodexRPCRequest(id: id, method: method, params: params))

        let value = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CodexJSONValue, Error>) in
            pending[id] = PendingRequest(continuation: continuation, timeoutTask: nil)
            let timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: self?.configuration.requestTimeout ?? .seconds(30))
                } catch {
                    return
                }
                self?.timeoutRequest(id: id, method: method)
            }
            pending[id]?.timeoutTask = timeoutTask
            do {
                try sendRawLine(String(decoding: data, as: UTF8.self))
            } catch {
                let request = pending.removeValue(forKey: id)
                request?.timeoutTask?.cancel()
                continuation.resume(throwing: CodexAppServerError.writeFailed(error.localizedDescription))
            }
        }
        do {
            return try value.decoded(as: result)
        } catch {
            throw CodexAppServerError.invalidResponse("\(method) 响应无法解码：\(error.localizedDescription)")
        }
    }

    private func timeoutRequest(id: Int, method: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: CodexAppServerError.requestTimedOut(method))
    }

    private func sendNotification<Params: Encodable>(method: String, params: Params) throws {
        let data = try JSONEncoder().encode(CodexRPCNotification(method: method, params: params))
        try sendRawLine(String(decoding: data, as: UTF8.self))
    }

    private func sendRawLine(_ line: String) throws {
        guard let process, process.isRunning else { throw CodexAppServerError.processExited }
        do {
            try process.sendLine(line)
        } catch {
            throw CodexAppServerError.writeFailed(error.localizedDescription)
        }
    }
}

private struct CodexEmptyResponse: Decodable, Sendable {}
