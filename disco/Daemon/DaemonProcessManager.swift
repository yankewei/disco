import Foundation

// MARK: - 守护进程进程管理

/// 管理 disco-daemon 二进制文件的生命周期。
///
/// 职责：
/// - 查找守护进程可执行文件
/// - 启动守护进程子进程
/// - 等待套接字就绪
/// - 停止守护进程
///
/// Phase 1 中守护进程可能不存在（尚未编译），此时优雅降级：
/// 记录警告日志，AppState 继续使用直连模式。
@MainActor
final class DaemonProcessManager {
    /// 守护进程子进程。
    private var process: Process?
    /// 守护进程是否由当前应用启动（影响是否有权停止它）。
    private var launchedByUs = false

    /// 守护进程套接字路径。
    func daemonSocketPath() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let discoDir = appSupport.appendingPathComponent("disco")
        // 确保目录存在
        try? FileManager.default.createDirectory(
            at: discoDir,
            withIntermediateDirectories: true
        )
        return discoDir.appendingPathComponent("disco.sock").path
    }

    /// 查找守护进程可执行文件。
    ///
    /// 搜索顺序：
    /// 1. 应用包 Resources/ 目录（生产环境）
    /// 2. 与可执行文件同目录（开发环境：cargo build 输出）
    /// 3. 已知的构建路径
    /// 4. PATH 环境变量
    func daemonBinaryPath() -> String? {
        let candidates = buildCandidatePaths()
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 确保守护进程正在运行。
    ///
    /// 如果守护进程已经在运行（套接字存在且可连接），直接返回。
    /// 否则查找并启动守护进程二进制文件。
    func ensureDaemonRunning() async throws {
        // 检查套接字是否已经存在且可连接
        let socketPath = daemonSocketPath()
        if canConnectToSocket(at: socketPath) {
            // 守护进程已在运行（可能由其他实例启动）
            launchedByUs = false
            return
        }

        // 查找守护进程二进制
        guard let binaryPath = daemonBinaryPath() else {
            throw DaemonError.daemonNotFound
        }

        // 启动守护进程
        try launchDaemon(binaryPath: binaryPath, socketPath: socketPath)
        launchedByUs = true

        // 等待套接字就绪
        try await waitForSocket(at: socketPath, timeout: .seconds(10))
    }

    /// 停止守护进程。
    func stopDaemon() {
        guard launchedByUs, let process, process.isRunning else {
            // 不是我们启动的，或者已经停止
            return
        }

        // 尝试优雅关闭（通过套接字发送 shutdown 请求）
        // Phase 1 简化：直接终止进程
        process.terminate()
        process.waitUntilExit()
        self.process = nil
        launchedByUs = false

        // 清理套接字文件
        let socketPath = daemonSocketPath()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// 守护进程是否正在运行（由我们启动）。
    ///
    /// 未接线：当前没有调用方（Phase 1 预留）。
    var isRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: - 内部实现

    /// 构建候选可执行文件路径列表。
    private func buildCandidatePaths() -> [String] {
        var candidates: [String] = []

        // 1. 应用包 Resources/ 目录
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("disco-daemon").path)
            // macOS 应用包结构：Contents/Resources/
            candidates.append(
                resourceURL.appendingPathComponent("bin/disco-daemon").path
            )
        }

        // 2. 与可执行文件同目录（开发环境）
        let executablePath = CommandLine.arguments[0]
        let executableDir = (executablePath as NSString).deletingLastPathComponent
        candidates.append((executableDir as NSString).appendingPathComponent("disco-daemon"))

        // 3. 常见的安装路径
        candidates.append(contentsOf: [
            "/usr/local/bin/disco-daemon",
            "/opt/homebrew/bin/disco-daemon",
        ])

        // 4. PATH 环境变量
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                candidates.append(
                    (String(dir) as NSString).appendingPathComponent("disco-daemon")
                )
            }
        }

        return candidates
    }

    /// 启动守护进程子进程。
    private func launchDaemon(binaryPath: String, socketPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "--socket", socketPath,
        ]

        // 守护进程的标准输出/错误重定向到 /dev/null
        // （Phase 1：后续可改为日志文件）
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // 设置环境变量
        var env = ProcessInfo.processInfo.environment
        env["DISCO_DAEMON_MODE"] = "daemon"
        process.environment = env

        do {
            try process.run()
        } catch {
            throw DaemonError.daemonLaunchFailed(error.localizedDescription)
        }

        self.process = process
    }

    /// 等待套接字文件出现并可连接。
    private func waitForSocket(at path: String, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let pollInterval: Duration = .milliseconds(100)

        while ContinuousClock.now < deadline {
            if canConnectToSocket(at: path) {
                return
            }
            // 检查进程是否还在运行
            if launchedByUs, let process, !process.isRunning {
                throw DaemonError.daemonLaunchFailed(
                    "守护进程在套接字就绪前退出。"
                )
            }
            try await Task.sleep(for: pollInterval)
        }

        throw DaemonError.daemonLaunchFailed(
            "等待守护进程套接字超时。"
        )
    }

    /// 尝试连接到套接字以检查守护进程是否就绪。
    private func canConnectToSocket(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            return false
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let sunPathPointer = withUnsafeMutablePointer(to: &addr.sun_path) { $0 }
        pathBytes.withUnsafeBufferPointer { buf in
            let dest = UnsafeMutableRawPointer(sunPathPointer)
            dest.copyMemory(
                from: buf.baseAddress!,
                byteCount: min(buf.count, MemoryLayout.size(ofValue: addr.sun_path))
            )
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        return result == 0
    }
}
