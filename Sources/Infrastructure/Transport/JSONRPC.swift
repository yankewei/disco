import Foundation

struct JSONRPCError: Error, LocalizedError {
    let code: Int
    let message: String

    var errorDescription: String? {
        "JSON-RPC 请求失败（\(code)）：\(message)"
    }
}

enum JSONRPCIdentifier: Hashable {
    case number(Int)
    case string(String)

    init?(value: JSONValue?) {
        guard let value else { return nil }
        switch value {
        case let .number(number):
            self = .number(Int(number))
        case let .string(string):
            self = .string(string)
        default:
            return nil
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case let .number(value):
            .number(Double(value))
        case let .string(value):
            .string(value)
        }
    }
}

struct JSONRPCRequest {
    let id: JSONRPCIdentifier
    let method: String
    let params: JSONValue?
}

final class JSONRPCConnection {
    typealias ServerRequestHandler = (JSONRPCRequest) async throws -> JSONValue
    typealias NotificationHandler = (String, JSONValue?) -> Void

    private let managedProcess: ManagedProcess
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var nextRequestID = 1
    private var pendingRequests: [JSONRPCIdentifier: CheckedContinuation<JSONValue, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var serverRequestHandler: ServerRequestHandler?
    private var notificationHandler: NotificationHandler?
    private var closeHandler: (() -> Void)?
    private var isClosed = false

    init(managedProcess: ManagedProcess) {
        self.managedProcess = managedProcess
    }

    func start(
        serverRequestHandler: @escaping ServerRequestHandler,
        notificationHandler: @escaping NotificationHandler,
        closeHandler: (() -> Void)? = nil
    ) throws {
        guard let output = managedProcess.standardOutput else {
            throw ProcessSupportError.outputClosed
        }
        withStateLock {
            self.serverRequestHandler = serverRequestHandler
            self.notificationHandler = notificationHandler
            self.closeHandler = closeHandler
        }
        try managedProcess.launch()
        let task = Task { [weak self] in
            do {
                for try await line in lineStream(from: output) {
                    guard !line.isEmpty else { continue }
                    self?.handle(line: line)
                }
                self?.close(with: ProcessSupportError.outputClosed)
            } catch {
                self?.close(with: error)
            }
        }
        withStateLock {
            readerTask = task
        }
    }

    func request(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        let identifier = withStateLock { () -> JSONRPCIdentifier in
            let identifier = JSONRPCIdentifier.number(nextRequestID)
            nextRequestID += 1
            return identifier
        }
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await self.performRequest(
                    identifier: identifier,
                    method: method,
                    params: params
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw ProcessSupportError.requestTimedOut(method)
            }
            defer { group.cancelAll() }
            do {
                guard let result = try await group.next() else {
                    throw ProcessSupportError.outputClosed
                }
                return result
            } catch {
                cancelPending(identifier: identifier, error: error)
                if let supportError = error as? ProcessSupportError,
                   case .requestTimedOut = supportError
                {
                    close(with: error)
                }
                throw error
            }
        }
    }

    private func performRequest(
        identifier: JSONRPCIdentifier,
        method: String,
        params: JSONValue?
    ) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            let accepted = withStateLock {
                guard !isClosed else { return false }
                pendingRequests[identifier] = continuation
                return true
            }
            guard accepted else {
                continuation.resume(throwing: ProcessSupportError.outputClosed)
                return
            }
            do {
                try write(
                    object: [
                        "jsonrpc": .string("2.0"),
                        "id": identifier.jsonValue,
                        "method": .string(method),
                        "params": params ?? .object([:]),
                    ]
                )
            } catch {
                let pendingRequest = withStateLock {
                    pendingRequests.removeValue(forKey: identifier)
                }
                pendingRequest?.resume(throwing: error)
            }
        }
    }

    private func cancelPending(identifier: JSONRPCIdentifier, error: Error) {
        let pendingRequest = withStateLock {
            pendingRequests.removeValue(forKey: identifier)
        }
        pendingRequest?.resume(throwing: error)
    }

    func notify(method: String, params: JSONValue = .object([:])) throws {
        let isClosed = withStateLock { self.isClosed }
        guard !isClosed else {
            throw ProcessSupportError.outputClosed
        }
        try write(
            object: [
                "jsonrpc": .string("2.0"),
                "method": .string(method),
                "params": params,
            ]
        )
    }

    func close(with error: Error = ProcessSupportError.outputClosed) {
        let (task, continuations, closeHandler): (
            Task<Void, Never>?,
            [CheckedContinuation<JSONValue, Error>],
            (() -> Void)?
        ) = withStateLock {
            guard !isClosed else { return (nil, [], nil) }
            isClosed = true
            let task = readerTask
            readerTask = nil
            let continuations = Array(pendingRequests.values)
            pendingRequests.removeAll()
            let closeHandler = self.closeHandler
            self.closeHandler = nil
            return (task, continuations, closeHandler)
        }
        task?.cancel()
        managedProcess.terminate()
        if managedProcess.process.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [managedProcess = self.managedProcess] in
                managedProcess.forceTerminate()
            }
        }
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
        closeHandler?()
    }

    private func handle(line: String) {
        guard
            let data = line.data(using: .utf8),
            let value = try? jsonDecoder.decode(JSONValue.self, from: data),
            let object = value.objectValue
        else {
            close(with: ProcessSupportError.invalidOutput(line))
            return
        }

        if let method = object["method"]?.stringValue,
           let requestID = JSONRPCIdentifier(value: object["id"])
        {
            let request = JSONRPCRequest(
                id: requestID,
                method: method,
                params: object["params"]
            )
            let requestHandler = withStateLock { serverRequestHandler }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await requestHandler?(request) ?? .object([:])
                    try write(
                        object: [
                            "jsonrpc": .string("2.0"),
                            "id": requestID.jsonValue,
                            "result": result,
                        ]
                    )
                } catch {
                    try? write(
                        object: [
                            "jsonrpc": .string("2.0"),
                            "id": requestID.jsonValue,
                            "error": .object([
                                "code": .number(-32000),
                                "message": .string(error.localizedDescription),
                            ]),
                        ]
                    )
                }
            }
            return
        }

        if let method = object["method"]?.stringValue {
            let handler = withStateLock { notificationHandler }
            handler?(method, object["params"])
            return
        }

        guard let responseID = JSONRPCIdentifier(value: object["id"]) else {
            return
        }
        let continuation = withStateLock {
            pendingRequests.removeValue(forKey: responseID)
        }
        guard let continuation else {
            return
        }
        if let errorObject = object["error"]?.objectValue {
            let code = errorObject["code"].flatMap { value -> Int? in
                guard case let .number(number) = value else { return nil }
                return Int(number)
            } ?? -32000
            let message = errorObject["message"]?.stringValue ?? "未知错误"
            continuation.resume(throwing: JSONRPCError(code: code, message: message))
            return
        }
        continuation.resume(returning: object["result"] ?? .null)
    }

    private func write(object: [String: JSONValue]) throws {
        guard let input = managedProcess.standardInput else {
            throw ProcessSupportError.outputClosed
        }
        let data = try jsonEncoder.encode(JSONValue.object(object))
        var line = data
        line.append(0x0A)
        writeLock.lock()
        defer { writeLock.unlock() }
        try input.write(contentsOf: line)
    }

    private func withStateLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try operation()
    }
}

final class CodexAppServer {
    private let executableURL: URL
    private let stateLock = NSLock()
    private var connection: JSONRPCConnection?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func start(
        environment: [String: String],
        serverRequestHandler: @escaping JSONRPCConnection.ServerRequestHandler,
        notificationHandler: @escaping JSONRPCConnection.NotificationHandler,
        closeHandler: (() -> Void)? = nil
    ) throws {
        var codexEnvironment = environment
        codexEnvironment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] =
            codexEnvironment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] ?? "codex_cli_rs"
        let process = ManagedProcess(
            executableURL: executableURL,
            arguments: ["app-server", "--listen", "stdio://"],
            workingDirectory: nil,
            environment: codexEnvironment,
            captureStandardError: false
        )
        let connection = JSONRPCConnection(managedProcess: process)
        try connection.start(
            serverRequestHandler: serverRequestHandler,
            notificationHandler: notificationHandler,
            closeHandler: closeHandler
        )
        stateLock.lock()
        self.connection = connection
        stateLock.unlock()
    }

    func request(method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        let connection = withStateLock { self.connection }
        guard let connection else { throw ProcessSupportError.outputClosed }
        return try await connection.request(method: method, params: .object(params))
    }

    func notify(method: String, params: [String: JSONValue] = [:]) throws {
        let connection = withStateLock { self.connection }
        guard let connection else { throw ProcessSupportError.outputClosed }
        try connection.notify(method: method, params: .object(params))
    }

    func close() {
        let connection = withStateLock { () -> JSONRPCConnection? in
            let connection = self.connection
            self.connection = nil
            return connection
        }
        connection?.close()
    }

    private func withStateLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try operation()
    }
}
