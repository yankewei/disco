import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// ConversationStore 依赖的稳定 daemon 边界；隐藏迁移期 DAP 传输细节。
@MainActor
protocol DiscoDaemonClient: AnyObject {
    func events() -> AsyncThrowingStream<DaemonEvent, Error>
    func startRun(sessionID: UUID, text: String) async throws -> UUID
    func cancelRun(runID: UUID) async throws
    func approve(approvalID: UUID, decision: String) async throws
    func deleteSession(sessionID: UUID) async throws
}

// MARK: - 守护进程客户端

/// 通过 Unix 域套接字与 Rust 守护进程通信的客户端。
///
/// Phase 1 职责：
/// - 连接到守护进程的 Unix 域套接字
/// - 发送 JSON-RPC 请求并等待响应
/// - 接收守护进程推送的事件通知
/// - 守护进程不存在时优雅降级（不阻塞 UI）
@MainActor
final class DaemonClient {
    /// 连接状态。
    enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.connecting, .connecting),
                 (.connected, .connected):
                return true
            case let (.failed(a), .failed(b)):
                return a == b
            default:
                return false
            }
        }
    }

    private(set) var state: State = .disconnected

    /// 事件流：守护进程主动推送的通知。
    private var eventContinuation: AsyncThrowingStream<DaemonEvent, Error>.Continuation?
    private var eventStream: AsyncThrowingStream<DaemonEvent, Error>?

    /// 待响应请求：requestID → continuation。
    private var pendingRequests: [Int: CheckedContinuation<DaemonRPCResponse, Error>] = [:]
    /// 超时任务：requestID → timeout task。
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var nextRequestId = 0

    /// 套接字文件描述符。
    private var socketFd: Int32 = -1
    /// 读取缓冲区。
    private var readBuffer = Data()
    /// 后台读取任务。
    private var readTask: Task<Void, Never>?
    /// 写入队列串行化 socket 写入。
    private var writeTask: Task<Void, Never>?
    private var writeQueue: [Data] = []
    private var isWriting = false

    /// 请求超时（秒）。
    private let requestTimeout: Duration = .seconds(30)

    /// JSON 编码器：camelCase → snake_case。
    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    /// JSON 解码器：snake_case → camelCase。
    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    deinit {
        if socketFd >= 0 {
            Darwin.close(socketFd)
        }
    }

    // MARK: - 连接管理

    /// 连接到守护进程的 Unix 域套接字。
    func connect(socketPath: String) async throws {
        // 仅允许从 disconnected 或 failed 状态发起连接
        switch state {
        case .disconnected, .failed:
            break
        case .connecting, .connected:
            return
        }
        state = .connecting

        // 检查套接字文件是否存在
        guard FileManager.default.fileExists(atPath: socketPath) else {
            state = .failed("套接字文件不存在：\(socketPath)")
            throw DaemonError.connectionFailed("套接字文件不存在：\(socketPath)")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            state = .failed("无法创建套接字")
            throw DaemonError.socketCreationFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let sunPathPointer = withUnsafeMutablePointer(to: &addr.sun_path) { $0 }
        pathBytes.withUnsafeBufferPointer { buf in
            let dest = UnsafeMutableRawPointer(sunPathPointer)
            dest.copyMemory(from: buf.baseAddress!, byteCount: min(buf.count, MemoryLayout.size(ofValue: addr.sun_path)))
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            Darwin.close(fd)
            let errnoValue = errno
            let message = "errno=\(errnoValue)"
            state = .failed(message)
            throw DaemonError.connectionFailed(message)
        }

        socketFd = fd
        state = .connected
        setupEventStream()
        startReading()
    }

    /// 创建新的事件流。
    ///
    /// AsyncThrowingStream 的 continuation 一旦 finish 就不能复用，
    /// 因此每次成功连接都重建一个流，断线重连后事件推送不会丢失。
    private func setupEventStream() {
        var capturedContinuation: AsyncThrowingStream<DaemonEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<DaemonEvent, Error> { continuation in
            capturedContinuation = continuation
        }
        eventStream = stream
        eventContinuation = capturedContinuation
    }

    /// 断开连接并清理资源。
    func disconnect() {
        // 取消所有待处理请求
        let pending = pendingRequests
        pendingRequests.removeAll()
        let timeouts = timeoutTasks
        timeoutTasks.removeAll()
        for task in timeouts.values { task.cancel() }
        for continuation in pending.values {
            continuation.resume(throwing: DaemonError.disconnected)
        }

        // 关闭套接字
        if socketFd >= 0 {
            Darwin.close(socketFd)
            socketFd = -1
        }

        // 取消读取任务
        readTask?.cancel()
        readTask = nil
        writeTask?.cancel()
        writeTask = nil
        writeQueue.removeAll()
        isWriting = false

        // 结束事件流（不可复用；重连时会重建）
        eventContinuation?.finish()
        eventContinuation = nil
        eventStream = nil

        state = .disconnected
    }

    // MARK: - 请求-响应

    /// 发送请求并等待响应。
    func request<T: Decodable>(
        _ method: String,
        params: (some Encodable)? = nil,
        as type: T.Type
    ) async throws -> T {
        guard socketFd >= 0 else {
            throw DaemonError.notConnected
        }

        let id = nextRequestId
        nextRequestId += 1

        // 编码请求（camelCase → snake_case）
        let rpcRequest = DaemonRPCRequest(id: id, method: method, params: params)
        let requestData: Data
        do {
            requestData = try Self.jsonEncoder.encode(rpcRequest)
        } catch {
            throw DaemonError.requestFailed("无法编码请求：\(error.localizedDescription)")
        }

        // 等待响应
        let response = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            // 设置超时
            let timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: self?.requestTimeout ?? .seconds(30))
                } catch {
                    return
                }
                self?.timeoutRequest(id: id, method: method)
            }
            timeoutTasks[id] = timeoutTask

            // 发送数据
            enqueueWrite(data: requestData + Data([0x0A]))
        }

        // 解析响应
        if let error = response.error {
            throw DaemonError.rpcError(code: error.code, message: error.message)
        }

        guard let result = response.result else {
            throw DaemonError.invalidResponse("\(method) 响应缺少 result 字段。")
        }

        do {
            return try result.decoded(as: type)
        } catch {
            throw DaemonError.invalidResponse(
                "\(method) 响应无法解码为 \(type)：\(error.localizedDescription)"
            )
        }
    }

    // MARK: - 事件流

    /// 获取守护进程推送的事件流。
    ///
    /// 每次成功连接都会重建事件流；未连接或已断开时返回一个立即结束的空流。
    func events() -> AsyncThrowingStream<DaemonEvent, Error> {
        eventStream ?? AsyncThrowingStream { $0.finish() }
    }

    // MARK: - 便捷方法

    /// 执行初始化握手。
    func initialize() async throws -> DaemonInitializeResult {
        try await request(
            "initialize",
            params: DaemonInitializeParams(
                clientInfo: DaemonClientInfo(name: "disco", version: "0.1.0"),
                protocolVersion: "v1"
            ),
            as: DaemonInitializeResult.self
        )
    }

    /// 启动一次运行。
    func startRun(sessionID: UUID, text: String) async throws -> UUID {
        let result = try await request(
            "run/start",
            params: DaemonRunStartParams(
                sessionId: sessionID.uuidString,
                text: text
            ),
            as: DaemonRunStartResult.self
        )
        guard let runID = UUID(uuidString: result.runId) else {
            throw DaemonError.invalidResponse("run/start 返回了无效的 runID。")
        }
        return runID
    }

    /// 取消一次运行。
    func cancelRun(runID: UUID) async throws {
        _ = try await request(
            "run/cancel",
            params: DaemonRunCancelParams(runId: runID.uuidString),
            as: DaemonRunCancelResult.self
        )
    }

    /// 请求守护进程关闭。
    ///
    /// 未接线：当前应用退出时未调用（Phase 2 预留）。
    func shutdown() async throws {
        _ = try await request(
            "shutdown",
            params: DaemonShutdownParams(),
            as: DaemonShutdownResult.self
        )
    }

    // MARK: - 服务商管理

    /// 配置一个服务商（API Key、Base URL、模型等）。
    func configureProvider(
        providerID: String,
        vendor: String,
        baseURL: String,
        apiKey: String,
        model: String,
        thinkingEnabled: Bool
    ) async throws {
        _ = try await request(
            "provider/configure",
            params: DaemonProviderConfigureParams(
                providerId: providerID,
                vendor: vendor,
                baseUrl: baseURL,
                apiKey: apiKey,
                model: model,
                thinkingEnabled: thinkingEnabled
            ),
            as: DaemonJSONValue.self
        )
    }

    /// 获取已配置的服务商列表。
    ///
    /// 未接线：尚无 UI 调用（Phase 2 预留）。
    func listProviders() async throws -> [DaemonProviderEntry] {
        let result = try await request(
            "provider/list",
            params: nil as DaemonJSONValue?,
            as: DaemonProviderListResult.self
        )
        return result.providers
    }

    // MARK: - 会话管理

    /// 在守护进程中创建一个会话。
    func createSession(
        sessionID: UUID,
        projectID: UUID,
        providerID: String,
        vendor: String,
        model: String
    ) async throws -> DaemonSession {
        let result = try await request(
            "session/create",
            params: DaemonSessionCreateParams(
                sessionId: sessionID.uuidString,
                projectId: projectID.uuidString,
                providerId: providerID,
                vendor: vendor,
                model: model
            ),
            as: DaemonSessionCreateResult.self
        )
        return result.session
    }

    /// 获取指定项目下的会话列表。
    func listSessions(projectID: UUID) async throws -> [DaemonSession] {
        let result = try await request(
            "session/list",
            params: DaemonSessionListParams(projectId: projectID.uuidString),
            as: DaemonSessionListResult.self
        )
        return result.sessions
    }

    /// 读取 daemon 中会话的权威消息历史（恢复用）。
    func listMessages(sessionID: UUID) async throws -> [DaemonSessionMessage] {
        let result = try await request(
            "session/messages",
            params: DaemonSessionMessagesParams(sessionId: sessionID.uuidString),
            as: DaemonSessionMessagesResult.self
        )
        return result.messages
    }

    /// 删除一个会话。
    func deleteSession(sessionID: UUID) async throws {
        _ = try await request(
            "session/delete",
            params: DaemonSessionDeleteParams(sessionId: sessionID.uuidString),
            as: DaemonJSONValue.self
        )
    }

    // MARK: - 项目管理

    /// 在守护进程中创建一个项目。
    func createProject(projectID: UUID, name: String, path: String) async throws -> DaemonProject {
        let result = try await request(
            "session/project/create",
            params: DaemonProjectCreateParams(
                projectId: projectID.uuidString,
                name: name,
                path: path
            ),
            as: DaemonProjectCreateResult.self
        )
        return result.project
    }

    /// 获取守护进程中所有项目。
    ///
    /// 未接线：尚无 UI 调用（Phase 2 预留）。
    func listProjects() async throws -> [DaemonProject] {
        let result = try await request(
            "session/projects",
            params: nil as DaemonJSONValue?,
            as: DaemonProjectListResult.self
        )
        return result.projects
    }

    // MARK: - 上下文压缩（Phase 2）

    /// 请求守护进程对指定会话执行上下文压缩。
    ///
    /// 未接线：压缩仍由客户端本地 runtime 执行（Phase 2 预留）。
    func compactContext(sessionID: UUID) async throws {
        _ = try await request(
            "run/compact",
            params: DaemonRunCompactParams(sessionId: sessionID.uuidString),
            as: DaemonJSONValue.self
        )
    }

    // MARK: - 审批响应

    /// 响应用户审批请求。
    func approve(approvalID: UUID, decision: String) async throws {
        _ = try await request(
            "run/approve",
            params: DaemonRunApproveParams(
                approvalId: approvalID.uuidString,
                decision: decision
            ),
            as: DaemonRunApproveResult.self
        )
    }

    // MARK: - 内部：读取循环

    /// 启动后台读取循环。
    private func startReading() {
        readTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let fd = self.socketFd
            guard fd >= 0 else { return }

            // 使用 DispatchSource 异步读取套接字数据。
            let readSource = DispatchSource.makeReadSource(
                fileDescriptor: fd,
                queue: DispatchQueue.global(qos: .userInitiated)
            )

            let stream = AsyncStream<Data>.makeStream()

            readSource.setEventHandler {
                let estimated = readSource.data
                if estimated == 0 {
                    // EOF：守护进程关闭了连接
                    stream.continuation.finish()
                    return
                }
                var buffer = [UInt8](repeating: 0, count: Int(estimated))
                let bytesRead = buffer.withUnsafeMutableBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return Darwin.read(fd, base, ptr.count)
                }
                if bytesRead > 0 {
                    let data = Data(buffer[0..<bytesRead])
                    stream.continuation.yield(data)
                } else if bytesRead == 0 {
                    stream.continuation.finish()
                }
            }

            readSource.setCancelHandler {
                stream.continuation.finish()
            }

            readSource.resume()

            // 消费数据流
            for await data in stream.stream {
                self.readBuffer.append(data)
                self.drainLines()
            }

            // 读取结束：守护进程断开
            readSource.cancel()
            guard self.state != .disconnected else { return }
            self.handleDisconnection()
        }
    }

    /// 从读取缓冲区中提取完整的行（以 \n 分隔）并路由。
    private func drainLines() {
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            let trimmed = lineData.trimmingTrailingCR()
            guard !trimmed.isEmpty else { continue }
            handleLine(trimmed)
        }
    }

    /// 路由一行 JSON 数据。
    private func handleLine(_ data: Data) {
        // 尝试解码为响应（有 id 字段）
        if let response = try? Self.jsonDecoder.decode(DaemonRPCResponse.self, from: data) {
            handleResponse(response)
            return
        }

        // 尝试解码为事件（有 event 字段，对应 Rust 的 Event 格式）
        if let envelope = try? Self.jsonDecoder.decode(DaemonEventEnvelope.self, from: data) {
            handleEvent(envelope)
            return
        }

        // 无法解析的行：记录但不中断连接
        // （守护进程可能发送非 JSON 的日志行）
    }

    /// 路由响应到对应的待处理请求。
    private func handleResponse(_ response: DaemonRPCResponse) {
        guard let pending = pendingRequests.removeValue(forKey: response.id) else {
            return
        }
        timeoutTasks.removeValue(forKey: response.id)?.cancel()
        pending.resume(returning: response)
    }

    /// 将事件信封转换为 DaemonEvent 并推送到事件流。
    private func handleEvent(_ envelope: DaemonEventEnvelope) {
        let event = DaemonEvent(eventName: envelope.event, data: envelope.data)
        eventContinuation?.yield(event)
    }

    /// 连接断开处理。
    private func handleDisconnection() {
        // 取消所有待处理请求
        let pending = pendingRequests
        pendingRequests.removeAll()
        let timeouts = timeoutTasks
        timeoutTasks.removeAll()
        for task in timeouts.values { task.cancel() }
        for continuation in pending.values {
            continuation.resume(throwing: DaemonError.disconnected)
        }

        if socketFd >= 0 {
            Darwin.close(socketFd)
            socketFd = -1
        }

        eventContinuation?.finish()
        eventContinuation = nil
        eventStream = nil

        state = .disconnected
    }

    // MARK: - 内部：写入

    /// 将数据加入写入队列。
    private func enqueueWrite(data: Data) {
        writeQueue.append(data)
        processWriteQueue()
    }

    /// 处理写入队列。
    private func processWriteQueue() {
        guard !isWriting, !writeQueue.isEmpty, socketFd >= 0 else { return }
        isWriting = true

        let fd = socketFd
        let data = writeQueue.removeFirst()

        // 在后台队列执行写入，避免阻塞 MainActor
        Task.detached { [weak self] in
            var remaining = data
            while !remaining.isEmpty {
                let written = remaining.withUnsafeBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return Darwin.write(fd, base, remaining.count)
                }
                if written > 0 {
                    remaining = remaining.dropFirst(written)
                } else if written < 0 {
                    // 写入失败
                    await self?.handleWriteError()
                    return
                } else {
                    // 写入 0 字节，重试
                    break
                }
            }
            await self?.writeCompleted()
        }
    }

    /// 写入完成回调。
    private func writeCompleted() {
        isWriting = false
        processWriteQueue()
    }

    /// 写入错误处理。
    private func handleWriteError() {
        isWriting = false
        writeQueue.removeAll()
        handleDisconnection()
    }

    // MARK: - 内部：超时

    private func timeoutRequest(id: Int, method: String) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)
        pending.resume(throwing: DaemonError.requestTimedOut(method))
    }
}

extension DaemonClient: DiscoDaemonClient {}

// MARK: - Data 扩展

private extension Data {
    /// 移除末尾的 \r（如果有）。
    func trimmingTrailingCR() -> Data {
        guard last == 0x0D else { return self }
        return dropLast()
    }
}

// MARK: - Sendable 安全

// DaemonClient 标记为 @MainActor，所有状态访问都在 MainActor 上。
extension DaemonClient: @unchecked Sendable {}
