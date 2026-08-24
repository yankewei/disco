import Darwin
import Foundation

/// ACP stdio transport 的错误。
enum ACPDaemonError: Error, LocalizedError, Equatable {
    case notConnected
    case daemonLaunchFailed(String)
    case disconnected
    case requestTimedOut(String)
    case rpcError(code: Int, message: String, detail: String?)
    case invalidResponse(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "ACP daemon 尚未连接。"
        case let .daemonLaunchFailed(message):
            return "无法启动 ACP daemon：\(message)"
        case .disconnected:
            return "ACP daemon 连接已断开。"
        case let .requestTimedOut(method):
            return "ACP 请求超时：\(method)"
        case let .rpcError(code, message, detail):
            return detail.map {
                "ACP RPC 错误（\(code)）：\(message)（\($0)）"
            } ?? "ACP RPC 错误（\(code)）：\(message)"
        case let .invalidResponse(message):
            return "ACP 响应无效：\(message)"
        case let .writeFailed(message):
            return "ACP 写入失败：\(message)"
        }
    }
}

/// JSON-RPC request ID，兼容 ACP 允许的 number/string/null 三种形式。
enum ACPRequestID: Codable, Hashable, Sendable, CustomStringConvertible {
    case number(Int)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ACP request ID 必须是 number、string 或 null。"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var description: String {
        switch self {
        case let .number(value): String(value)
        case let .string(value): value
        case .null: "null"
        }
    }

    var numericValue: Int? {
        guard case let .number(value) = self else { return nil }
        return value
    }
}

/// ACP agent 发给 App 的 session update。
struct ACPSessionUpdate: Sendable {
    let sessionID: String
    let update: DaemonJSONValue
    let eventEpoch: String?
    let eventSequence: UInt64?

    init(
        sessionID: String,
        update: DaemonJSONValue,
        eventEpoch: String? = nil,
        eventSequence: UInt64? = nil
    ) {
        self.sessionID = sessionID
        self.update = update
        self.eventEpoch = eventEpoch
        self.eventSequence = eventSequence
    }
}

/// ACP agent 请求 App 决定工具权限。
struct ACPPermissionRequest: Identifiable, Sendable {
    let requestID: ACPRequestID
    let sessionID: String
    let toolCall: DaemonJSONValue
    let options: [DaemonJSONValue]
    let metadata: DaemonJSONValue?

    var id: String { requestID.description }
}

// MARK: - ACP response DTO

struct ACPInitializeResult: Decodable, Sendable {
    let protocolVersion: Int
    let agentCapabilities: DaemonJSONValue
    let authMethods: [DaemonJSONValue]?
    let agentInfo: ACPImplementation?
}

struct ACPImplementation: Decodable, Sendable {
    let name: String
    let title: String?
    let version: String
}

struct ACPNewSessionResult: Decodable, Sendable {
    let sessionId: String
}

struct ACPLoadSessionResult: Decodable, Sendable {}

struct ACPListSessionsResult: Decodable, Sendable {
    let sessions: [ACPSessionInfo]
    let nextCursor: String?
}

struct ACPStateProject: Decodable, Sendable {
    let id: UUID
    let name: String
    let path: String
    let createdAt: String
}

struct ACPStateSnapshotResult: Decodable, Sendable {
    let revision: UInt64
    let providers: [ACPProviderEntry]
    let projects: [ACPStateProject]
    let sessions: [ACPSessionInfo]
}

struct ACPEventReplayEntry: Decodable, Sendable {
    let sessionId: String
    let epoch: String
    let sequence: UInt64
    let update: DaemonJSONValue
}

struct ACPEventReplayResult: Decodable, Sendable {
    let epoch: String
    let events: [ACPEventReplayEntry]
}

struct ACPSessionMessagesResult: Decodable, Sendable {
    let messages: [ACPSessionMessage]
}

struct ACPCompactionResult: Decodable, Sendable {
    let compaction: ACPCompactionInfo
}

struct ACPCompactionInfo: Decodable, Sendable {
    let id: String
    let status: String
    let beforeTokens: Int64?
    let afterTokens: Int64?
    let errorMessage: String?
}

struct ACPSessionMessage: Decodable, Sendable {
    let id: String
    let role: String
    let text: String
    let reasoning: String?
    let toolCalls: [ACPSessionToolCall]?
    let toolCallId: String?
    let toolName: String?
    let createdAt: String
}

struct ACPSessionToolCall: Decodable, Sendable {
    let id: String
    let name: String
    let arguments: String
    let status: String
    let output: String?
}

struct ACPSessionInfo: Decodable, Sendable {
    let sessionId: String
    let cwd: String
    let title: String?
    let updatedAt: String?
    let meta: DaemonJSONValue?

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case cwd
        case title
        case updatedAt
        case meta = "_meta"
    }

    var providerID: String? {
        meta?.objectValue?["disco/providerId"]?.stringValue
    }

    var projectID: UUID? {
        guard let value = meta?.objectValue?["disco/projectId"]?.stringValue else { return nil }
        return UUID(uuidString: value)
    }

    var runtimeKind: SessionRuntimeKind? {
        if let value = meta?.objectValue?["disco/runtimeKind"]?.stringValue {
            return SessionRuntimeKind(rawValue: value)
        }
        return SessionRuntimeKind.from(providerID: providerID)
    }

    var compactionMode: String? {
        meta?.objectValue?["disco/compactionMode"]?.stringValue
    }
}

struct ACPDeleteSessionResult: Decodable, Sendable {}
struct ACPCloseSessionResult: Decodable, Sendable {}

struct ACPPromptResult: Decodable, Sendable {
    let stopReason: String
}

struct ACPProviderConfigureResult: Decodable, Sendable {
    let providerId: String
    let vendor: String
}

struct ACPProviderEntry: Decodable, Sendable {
    let providerId: String
    let vendor: String
    let baseUrl: String
    let model: String
    let thinkingEnabled: Bool
}

struct ACPProviderListResult: Decodable, Sendable {
    let providers: [ACPProviderEntry]
}

struct ACPProviderModelsResult: Decodable, Sendable {
    let models: [ACPModelCatalogEntry]
}

struct ACPModelCatalogEntry: Decodable, Sendable {
    let id: String
    let displayName: String?
    let contextWindow: Int64?
    let supportedReasoningEfforts: [String]?
    let defaultReasoningEffort: String?
}

// MARK: - ACP request DTO

private struct ACPClientInfo: Encodable, Sendable {
    let name: String
    let version: String
}

private struct ACPCompactionCapabilities: Encodable, Sendable {}

private struct ACPSessionClientCapabilities: Encodable, Sendable {
    let compaction: ACPCompactionCapabilities
}

private struct ACPClientCapabilities: Encodable, Sendable {
    let session: ACPSessionClientCapabilities
}

private struct ACPInitializeParams: Encodable, Sendable {
    let protocolVersion: Int
    let clientCapabilities: ACPClientCapabilities
    let clientInfo: ACPClientInfo
}

private struct ACPNewSessionParams: Encodable, Sendable {
    let cwd: String
    let additionalDirectories: [String]
    let mcpServers: [DaemonJSONValue]
    let meta: [String: DaemonJSONValue]?

    enum CodingKeys: String, CodingKey {
        case cwd
        case additionalDirectories
        case mcpServers
        case meta = "_meta"
    }
}

private struct ACPLoadSessionParams: Encodable, Sendable {
    let sessionId: String
    let cwd: String
    let additionalDirectories: [String]
    let mcpServers: [DaemonJSONValue]
}

private struct ACPListSessionsParams: Encodable, Sendable {
    let cwd: String?
    let cursor: String?
}

private struct ACPEventReplayParams: Encodable, Sendable {
    let sessionId: String
    let epoch: String?
    let afterSequence: UInt64
}

private struct ACPSessionIDParams: Encodable, Sendable {
    let sessionId: String
}

private struct ACPTextContent: Encodable, Sendable {
    let type = "text"
    let text: String
}

private struct ACPPromptParams: Encodable, Sendable {
    let sessionId: String
    let prompt: [ACPTextContent]
}

private struct ACPCancelParams: Encodable, Sendable {
    let sessionId: String
}

private struct ACPProviderConfigureParams: Encodable, Sendable {
    let providerId: String?
    let vendor: String
    let baseUrl: String
    let apiKey: String
    let model: String
    let thinkingEnabled: Bool
    let reasoningEffort: String?
}

private struct ACPProviderModelsParams: Encodable, Sendable {
    let providerId: String?
    let vendor: String
    let baseUrl: String?
    let apiKey: String?
}

/// `session/request_permission` 响应的 outcome 字段：服务端按 ACP schema
/// 解析为 internally tagged enum，必须是嵌套结构
/// （`{"outcome": {"outcome": "selected", "optionId": ...}}`），
/// 扁平写法会让服务端解析失败并按拒绝处理。
private struct ACPPermissionResponse: Encodable, Sendable {
    let outcome: ACPPermissionOutcome
}

private struct ACPPermissionOutcome: Encodable, Sendable {
    let outcome: String
    let optionId: String?
}

private struct ACPWireRequest<Params: Encodable>: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

private struct ACPWireNotification<Params: Encodable>: Encodable, Sendable {
    let jsonrpc = "2.0"
    let method: String
    let params: Params
}

private struct ACPWireResponse: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: ACPRequestID
    let result: DaemonJSONValue?
    let error: ACPWireError?
}

private struct ACPWireError: Codable, Sendable {
    let code: Int
    let message: String
    let data: DaemonJSONValue?
}

private struct ACPIncomingEnvelope: Decodable, Sendable {
    let id: ACPRequestID?
    let method: String?
    let params: DaemonJSONValue?
    let result: DaemonJSONValue?
    let error: ACPWireError?
}

private struct ACPPermissionRequestParams: Decodable, Sendable {
    let sessionId: String
    let toolCall: DaemonJSONValue
    let options: [DaemonJSONValue]
    let meta: DaemonJSONValue?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case toolCall
        case options
        case meta = "_meta"
    }
}

/// 通过 stdin/stdout 与 `disco-daemon --stdio` 通信的 ACP v1 client，
/// daemon 唯一 transport。
@MainActor
final class ACPDaemonClient {
    enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private(set) var state: State = .disconnected

    private var process: Process?
    private var inputFileHandle: FileHandle?
    private var outputFileHandle: FileHandle?
    private var inputFD: Int32 = -1
    private var outputFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    private var readBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<ACPWireResponse, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private let defaultRequestTimeout: Duration = .seconds(30)

    private var writeQueue: [Data] = []
    private var isWriting = false

    private var sessionUpdateStream: AsyncThrowingStream<ACPSessionUpdate, Error>?
    private var sessionUpdateContinuation: AsyncThrowingStream<ACPSessionUpdate, Error>.Continuation?
    private var permissionStream: AsyncThrowingStream<ACPPermissionRequest, Error>?
    private var permissionContinuation: AsyncThrowingStream<ACPPermissionRequest, Error>.Continuation?

    deinit {
        readSource?.cancel()
        inputFileHandle?.closeFile()
        outputFileHandle?.closeFile()
    }

    // MARK: - Connection

    func connect(
        binaryPath: String,
        environmentOverrides: [String: String] = [:]
    ) async throws {
        switch state {
        case .disconnected, .failed:
            break
        case .connecting, .connected:
            return
        }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            state = .failed("找不到可执行的 disco-daemon：\(binaryPath)")
            throw ACPDaemonError.daemonLaunchFailed("文件不存在或不可执行。")
        }

        state = .connecting
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--stdio"]
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            throw ACPDaemonError.daemonLaunchFailed(error.localizedDescription)
        }

        self.process = process
        inputFileHandle = inputPipe.fileHandleForWriting
        outputFileHandle = outputPipe.fileHandleForReading
        inputFD = inputPipe.fileHandleForWriting.fileDescriptor
        outputFD = outputPipe.fileHandleForReading.fileDescriptor
        state = .connected
        setupStreams()
        startReading()
    }

    func disconnect() {
        guard state != .disconnected else { return }
        finishConnection(with: ACPDaemonError.disconnected, terminateProcess: true)
    }

    // MARK: - Streams

    func sessionUpdates() -> AsyncThrowingStream<ACPSessionUpdate, Error> {
        sessionUpdateStream ?? AsyncThrowingStream { $0.finish() }
    }

    func permissionRequests() -> AsyncThrowingStream<ACPPermissionRequest, Error> {
        permissionStream ?? AsyncThrowingStream { $0.finish() }
    }

    // MARK: - Standard ACP methods

    func initialize() async throws -> ACPInitializeResult {
        try await request(
            "initialize",
            params: ACPInitializeParams(
                protocolVersion: 1,
                clientCapabilities: ACPClientCapabilities(
                    session: ACPSessionClientCapabilities(
                        compaction: ACPCompactionCapabilities()
                    )
                ),
                clientInfo: ACPClientInfo(name: "disco", version: "0.1.0")
            ),
            as: ACPInitializeResult.self
        )
    }

    func newSession(
        cwd: String,
        providerID: String? = nil,
        sessionID: String? = nil
    ) async throws -> ACPNewSessionResult {
        var meta: [String: DaemonJSONValue] = [:]
        if let providerID {
            meta["disco/providerId"] = .string(providerID)
        }
        if let sessionID {
            meta["disco/sessionId"] = .string(sessionID)
        }
        return try await request(
            "session/new",
            params: ACPNewSessionParams(
                cwd: cwd,
                additionalDirectories: [],
                mcpServers: [],
                meta: meta.isEmpty ? nil : meta
            ),
            as: ACPNewSessionResult.self
        )
    }

    func loadSession(sessionID: String, cwd: String) async throws -> ACPLoadSessionResult {
        try await request(
            "session/load",
            params: ACPLoadSessionParams(
                sessionId: sessionID,
                cwd: cwd,
                additionalDirectories: [],
                mcpServers: []
            ),
            as: ACPLoadSessionResult.self
        )
    }

    func listMessages(sessionID: String) async throws -> [ACPSessionMessage] {
        let result = try await request(
            "_disco/session/messages",
            params: ACPSessionIDParams(sessionId: sessionID),
            as: ACPSessionMessagesResult.self
        )
        return result.messages
    }

    func compactSession(sessionID: String) async throws -> ACPCompactionResult {
        try await request(
            "_disco/session/compact",
            params: ACPSessionIDParams(sessionId: sessionID),
            as: ACPCompactionResult.self
        )
    }

    func listSessions(cwd: String? = nil) async throws -> ACPListSessionsResult {
        try await request(
            "session/list",
            params: ACPListSessionsParams(cwd: cwd, cursor: nil),
            as: ACPListSessionsResult.self
        )
    }

    func stateSnapshot() async throws -> ACPStateSnapshotResult {
        try await request(
            "_disco/state/snapshot",
            params: ACPEmptyParams(),
            as: ACPStateSnapshotResult.self
        )
    }

    func replayEvents(
        sessionID: String,
        epoch: String?,
        afterSequence: UInt64
    ) async throws -> ACPEventReplayResult {
        try await request(
            "_disco/event/replay",
            params: ACPEventReplayParams(
                sessionId: sessionID,
                epoch: epoch,
                afterSequence: afterSequence
            ),
            as: ACPEventReplayResult.self
        )
    }

    func deleteSession(sessionID: String) async throws {
        _ = try await request(
            "session/delete",
            params: ACPSessionIDParams(sessionId: sessionID),
            as: ACPDeleteSessionResult.self
        )
    }

    func closeSession(sessionID: String) async throws {
        _ = try await request(
            "session/close",
            params: ACPSessionIDParams(sessionId: sessionID),
            as: ACPCloseSessionResult.self
        )
    }

    func prompt(sessionID: String, text: String) async throws -> ACPPromptResult {
        try await request(
            "session/prompt",
            params: ACPPromptParams(
                sessionId: sessionID,
                prompt: [ACPTextContent(text: text)]
            ),
            as: ACPPromptResult.self
        )
    }

    func cancel(sessionID: String) throws {
        try sendNotification(
            method: "session/cancel",
            params: ACPCancelParams(sessionId: sessionID)
        )
    }

    // MARK: - Disco extensions

    func configureProvider(
        providerID: String?,
        vendor: String,
        baseURL: String,
        apiKey: String,
        model: String,
        thinkingEnabled: Bool,
        reasoningEffort: String? = nil
    ) async throws -> ACPProviderConfigureResult {
        try await request(
            "_disco/provider/configure",
            params: ACPProviderConfigureParams(
                providerId: providerID,
                vendor: vendor,
                baseUrl: baseURL,
                apiKey: apiKey,
                model: model,
                thinkingEnabled: thinkingEnabled,
                reasoningEffort: reasoningEffort
            ),
            as: ACPProviderConfigureResult.self
        )
    }

    func listProviders() async throws -> [ACPProviderEntry] {
        let result = try await request(
            "_disco/provider/list",
            params: ACPEmptyParams(),
            as: ACPProviderListResult.self
        )
        return result.providers
    }

    func listProviderModels(
        providerID: String?,
        vendor: String,
        baseURL: String? = nil,
        apiKey: String? = nil
    ) async throws -> [ACPModelCatalogEntry] {
        let result = try await request(
            "_disco/provider/models",
            params: ACPProviderModelsParams(
                providerId: providerID,
                vendor: vendor,
                baseUrl: baseURL,
                apiKey: apiKey
            ),
            as: ACPProviderModelsResult.self
        )
        return result.models
    }

    // MARK: - Permission response

    func respondToPermission(requestID: ACPRequestID, optionID: String?) throws {
        let response = ACPPermissionResponse(outcome: ACPPermissionOutcome(
            outcome: optionID == nil ? "cancelled" : "selected",
            optionId: optionID
        ))
        let result = try encodeJSONValue(response)
        try sendResponse(
            id: requestID,
            result: result,
            error: nil
        )
    }

    // MARK: - Request/response internals

    private func request<T: Decodable, Params: Encodable>(
        _ method: String,
        params: Params,
        as type: T.Type
    ) async throws -> T {
        guard state == .connected, inputFD >= 0 else {
            throw ACPDaemonError.notConnected
        }
        let requestID = nextRequestID
        nextRequestID += 1
        let payload: Data
        do {
            payload = try JSONEncoder().encode(
                ACPWireRequest(id: requestID, method: method, params: params)
            ) + Data([0x0A])
        } catch {
            throw ACPDaemonError.invalidResponse("无法编码请求：\(error.localizedDescription)")
        }

        let response = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ACPWireResponse, Error>) in
            pendingRequests[requestID] = continuation
            if let timeout = timeoutDuration(for: method) {
                timeoutTasks[requestID] = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.timeoutRequest(id: requestID, method: method)
                }
            }
            enqueueWrite(payload)
        }

        if let error = response.error {
            throw ACPDaemonError.rpcError(
                code: error.code,
                message: error.message,
                detail: error.data?.stringValue
            )
        }
        guard let result = response.result else {
            throw ACPDaemonError.invalidResponse("\(method) 响应缺少 result。")
        }
        do {
            return try result.decoded(as: type)
        } catch {
            throw ACPDaemonError.invalidResponse(
                "\(method) 响应无法解码为 \(type)：\(error.localizedDescription)"
            )
        }
    }

    private func sendNotification<Params: Encodable>(
        method: String,
        params: Params
    ) throws {
        guard state == .connected, inputFD >= 0 else {
            throw ACPDaemonError.notConnected
        }
        do {
            let data = try JSONEncoder().encode(
                ACPWireNotification(method: method, params: params)
            ) + Data([0x0A])
            enqueueWrite(data)
        } catch {
            throw ACPDaemonError.writeFailed(error.localizedDescription)
        }
    }

    private func sendResponse(
        id: ACPRequestID,
        result: DaemonJSONValue?,
        error: ACPWireError?
    ) throws {
        guard state == .connected, inputFD >= 0 else {
            throw ACPDaemonError.notConnected
        }
        do {
            let data = try JSONEncoder().encode(
                ACPWireResponse(id: id, result: result, error: error)
            ) + Data([0x0A])
            enqueueWrite(data)
        } catch {
            throw ACPDaemonError.writeFailed(error.localizedDescription)
        }
    }

    private func encodeJSONValue<T: Encodable>(_ value: T) throws -> DaemonJSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(DaemonJSONValue.self, from: data)
    }

    // MARK: - Read loop

    private func setupStreams() {
        var updateContinuation: AsyncThrowingStream<ACPSessionUpdate, Error>.Continuation!
        sessionUpdateStream = AsyncThrowingStream { continuation in
            updateContinuation = continuation
        }
        sessionUpdateContinuation = updateContinuation

        var permissionContinuation: AsyncThrowingStream<ACPPermissionRequest, Error>.Continuation!
        permissionStream = AsyncThrowingStream { continuation in
            permissionContinuation = continuation
        }
        self.permissionContinuation = permissionContinuation
    }

    private func startReading() {
        guard outputFD >= 0 else { return }
        let fileDescriptor = outputFD
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            let estimatedBytes = source.data
            if estimatedBytes == 0 {
                source.cancel()
                Task { @MainActor [weak self] in
                    self?.handleProcessExit()
                }
                return
            }
            var buffer = [UInt8](repeating: 0, count: Int(estimatedBytes))
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else { return -1 }
                return Darwin.read(fileDescriptor, baseAddress, pointer.count)
            }
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                Task { @MainActor [weak self] in
                    self?.appendReadData(data)
                }
            } else if bytesRead == 0 {
                source.cancel()
                Task { @MainActor [weak self] in
                    self?.handleProcessExit()
                }
            }
        }
        source.setCancelHandler {}
        source.resume()
        readSource = source
    }

    private func appendReadData(_ data: Data) {
        guard state != .disconnected else { return }
        readBuffer.append(data)
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            let trimmed = lineData.trimmingTrailingCR()
            guard !trimmed.isEmpty else { continue }
            handleLine(trimmed)
        }
    }

    private func handleLine(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(ACPIncomingEnvelope.self, from: data) else {
            return
        }

        if let method = envelope.method {
            handleIncomingMethod(
                method: method,
                id: envelope.id,
                params: envelope.params
            )
            return
        }
        guard let requestID = envelope.id?.numericValue else { return }
        guard let continuation = pendingRequests.removeValue(forKey: requestID) else { return }
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation.resume(returning: ACPWireResponse(
            id: .number(requestID),
            result: envelope.result,
            error: envelope.error
        ))
    }

    private func handleIncomingMethod(
        method: String,
        id: ACPRequestID?,
        params: DaemonJSONValue?
    ) {
        switch method {
        case "session/update":
            guard let params,
                  let object = params.objectValue,
                  let sessionID = object["sessionId"]?.stringValue,
                  let update = object["update"] else {
                if let id { sendInvalidIncomingRequestResponse(id: id) }
                return
            }
            sessionUpdateContinuation?.yield(ACPSessionUpdate(
                sessionID: sessionID,
                update: update,
                eventEpoch: object["_meta"]?.objectValue?["disco/eventEpoch"]?.stringValue,
                eventSequence: object["_meta"]?.objectValue?["disco/eventSequence"]?.numberValue
                    .flatMap { UInt64($0) }
            ))
        case "_disco/session/compaction":
            guard let params,
                  let object = params.objectValue,
                  let sessionID = object["sessionId"]?.stringValue,
                  let update = object["update"] else {
                return
            }
            sessionUpdateContinuation?.yield(ACPSessionUpdate(
                sessionID: sessionID,
                update: update,
                eventEpoch: object["_meta"]?.objectValue?["disco/eventEpoch"]?.stringValue,
                eventSequence: object["_meta"]?.objectValue?["disco/eventSequence"]?.numberValue
                    .flatMap { UInt64($0) }
            ))
        case "session/request_permission":
            guard let id, let params else { return }
            do {
                let permission = try params.decoded(as: ACPPermissionRequestParams.self)
                permissionContinuation?.yield(
                    ACPPermissionRequest(
                        requestID: id,
                        sessionID: permission.sessionId,
                        toolCall: permission.toolCall,
                        options: permission.options,
                        metadata: permission.meta
                    )
                )
            } catch {
                sendInvalidIncomingRequestResponse(id: id)
            }
        default:
            if let id {
                sendInvalidIncomingRequestResponse(id: id)
            }
        }
    }

    private func sendInvalidIncomingRequestResponse(id: ACPRequestID) {
        try? sendResponse(
            id: id,
            result: nil,
            error: ACPWireError(
                code: -32601,
                message: "Disco ACP client 不支持该 server request。",
                data: nil
            )
        )
    }

    private func handleProcessExit() {
        guard state != .disconnected else { return }
        finishConnection(with: ACPDaemonError.disconnected, terminateProcess: false)
    }

    // MARK: - Write queue

    private func enqueueWrite(_ data: Data) {
        writeQueue.append(data)
        processWriteQueue()
    }

    private func processWriteQueue() {
        guard !isWriting, !writeQueue.isEmpty, inputFD >= 0 else { return }
        isWriting = true
        let fileDescriptor = inputFD
        let data = writeQueue.removeFirst()

        Task.detached { [weak self] in
            var remaining = data
            while !remaining.isEmpty {
                let written = remaining.withUnsafeBytes { pointer -> Int in
                    guard let baseAddress = pointer.baseAddress else { return -1 }
                    return Darwin.write(fileDescriptor, baseAddress, remaining.count)
                }
                if written > 0 {
                    remaining = remaining.dropFirst(written)
                } else {
                    await self?.handleWriteError()
                    return
                }
            }
            await self?.writeCompleted()
        }
    }

    private func writeCompleted() {
        isWriting = false
        processWriteQueue()
    }

    private func handleWriteError() {
        isWriting = false
        writeQueue.removeAll()
        finishConnection(with: ACPDaemonError.writeFailed("无法向 ACP daemon 写入数据。"), terminateProcess: true)
    }

    // MARK: - Cleanup / timeout

    private func finishConnection(with error: Error, terminateProcess: Bool) {
        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for continuation in pending {
            continuation.resume(throwing: error)
        }
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()

        readSource?.cancel()
        readSource = nil
        sessionUpdateContinuation?.finish(throwing: error)
        permissionContinuation?.finish(throwing: error)
        sessionUpdateContinuation = nil
        permissionContinuation = nil
        sessionUpdateStream = nil
        permissionStream = nil

        writeQueue.removeAll()
        isWriting = false
        inputFileHandle?.closeFile()
        inputFileHandle = nil
        inputFD = -1
        outputFileHandle?.closeFile()
        outputFileHandle = nil
        outputFD = -1
        if terminateProcess, let process, process.isRunning {
            process.terminate()
        }
        self.process = nil
        readBuffer.removeAll()
        if let daemonError = error as? ACPDaemonError, daemonError == .disconnected {
            state = .disconnected
        } else {
            state = .failed(error.localizedDescription)
        }
    }

    private func timeoutRequest(id: Int, method: String) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)
        continuation.resume(throwing: ACPDaemonError.requestTimedOut(method))
    }

    /// `session/prompt` 会在整个模型运行期间保持 pending，终止由 ACP prompt response、
    /// session/cancel 或 daemon 断开负责；普通控制请求仍使用有限超时避免永久等待。
    private func timeoutDuration(for method: String) -> Duration? {
        guard method != "session/prompt" else { return nil }
        return defaultRequestTimeout
    }
}

private struct ACPEmptyParams: Encodable, Sendable {}

private extension Data {
    func trimmingTrailingCR() -> Data {
        guard last == 0x0D else { return self }
        return dropLast()
    }
}

extension ACPDaemonClient: @unchecked Sendable {}
