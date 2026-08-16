import Darwin
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
    /// 优先复用仍在运行且二进制未过期的 daemon（同一路径且未被重新编译替换）；
    /// 否则停掉旧进程，用当前包里的二进制重新启动。
    func ensureDaemonRunning() async throws {
        let socketPath = daemonSocketPath()
        if canConnectToSocket(at: socketPath) {
            let holders = Self.socketHolderPIDs(
                lsofOutput: runCommand("/usr/sbin/lsof", ["-U", "-Fn"]),
                socketPath: socketPath
            )
            if holders.isEmpty || holders.contains(where: isCurrentDaemon) {
                // 找不到占用者（lsof 不可用）或仍是当前 daemon：直接复用
                launchedByUs = false
                return
            }
            stopProcesses(holders)
        }

        guard let binaryPath = daemonBinaryPath() else {
            throw DaemonError.daemonNotFound
        }

        try launchDaemon(binaryPath: binaryPath, socketPath: socketPath)
        launchedByUs = true

        try await waitForSocket(at: socketPath, timeout: .seconds(10))
    }

    /// 停止守护进程。
    ///
    /// 停掉占用本应用套接字的 daemon（无论是否由本实例启动），
    /// 确保 App 退出后不留孤儿进程。
    func stopDaemon() {
        let socketPath = daemonSocketPath()
        let holders = Self.socketHolderPIDs(
            lsofOutput: runCommand("/usr/sbin/lsof", ["-U", "-Fn"]),
            socketPath: socketPath
        )
        stopProcesses(holders)

        // 兼容：本实例启动的已知子进程
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
        launchedByUs = false

        // 清理套接字文件
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

    /// 占用给定套接字的进程是否还是当前二进制。
    ///
    /// 满足两个条件才算“当前”：可执行文件路径等于本包路径，且二进制没有被替换
    /// （进程启动时间不早于二进制修改时间）。
    private func isCurrentDaemon(pid: pid_t) -> Bool {
        guard let binaryPath = daemonBinaryPath(),
              let executablePath = Self.daemonExecutablePath(
                  lsofOutput: runCommand(
                      "/usr/sbin/lsof",
                      ["-p", String(pid), "-a", "-d", "txt", "-Fn"]
                  )
              ),
              executablePath == binaryPath,
              let startTime = Self.processStartTime(
                  psOutput: runCommand(
                      "/bin/ps",
                      ["-p", String(pid), "-o", "lstart="],
                      environment: ["LC_ALL": "C"]
                  )
              ),
              let binaryMtime = fileModificationTime(at: binaryPath) else {
            return false
        }
        return binaryMtime <= startTime
    }

    private func fileModificationTime(at path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    /// 发送 SIGTERM 停止指定进程，2 秒内未退出则升级为 SIGKILL。
    private func stopProcesses(_ pids: [pid_t]) {
        for pid in pids {
            Darwin.kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if pids.allSatisfy({ Darwin.kill($0, 0) != 0 }) {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        for pid in pids where Darwin.kill(pid, 0) == 0 {
            Darwin.kill(pid, SIGKILL)
        }
    }

    /// 同步执行一条外部命令并返回标准输出；失败返回 nil。
    private func runCommand(
        _ executablePath: String,
        _ arguments: [String],
        environment: [String: String] = [:]
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// 从 `lsof -U -Fn` 输出解析占用指定套接字的进程 PID。
    static func socketHolderPIDs(lsofOutput: String?, socketPath: String) -> [pid_t] {
        guard let lsofOutput else { return [] }
        var pids: [pid_t] = []
        var currentPID: pid_t?
        for line in lsofOutput.split(separator: "\n") {
            if line.hasPrefix("p"), let pid = pid_t(line.dropFirst()) {
                currentPID = pid
            } else if line.hasPrefix("n"), let pid = currentPID,
                      String(line.dropFirst()) == socketPath {
                if !pids.contains(pid) {
                    pids.append(pid)
                }
            }
        }
        return pids
    }

    /// 从 `lsof -p <pid> -a -d txt -Fn` 输出解析 daemon 可执行文件路径。
    static func daemonExecutablePath(lsofOutput: String?) -> String? {
        guard let lsofOutput else { return nil }
        for line in lsofOutput.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            if path.contains("disco-daemon") {
                return path
            }
        }
        return nil
    }

    /// 从 `ps -p <pid> -o lstart=` 输出解析进程启动时间（LC_ALL=C 格式）。
    static func processStartTime(psOutput: String?) -> Date? {
        guard let psOutput else { return nil }
        let text = psOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: text)
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
