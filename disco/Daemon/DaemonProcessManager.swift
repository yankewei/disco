import Darwin
import Foundation

// MARK: - 守护进程进程管理

/// 管理 disco-daemon 二进制的查找与旧实例清理。
///
/// 职责：
/// - 查找守护进程可执行文件（App 以 `disco-daemon --stdio` 子进程方式启动它）
/// - 清理旧版 socket daemon（旧 App 版本遗留，与当前 daemon 共享 SQLite 数据库）
@MainActor
final class DaemonProcessManager {
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

    /// 停掉占用旧版 Unix 域套接字的遗留 daemon。
    ///
    /// 旧 App 版本以 `--socket` 方式启动 daemon；新版本只用 stdio，
    /// 但升级后旧进程可能仍在运行并与新 daemon 共享 SQLite 数据库。
    func stopDaemon() {
        let socketPath = Self.legacySocketPath()
        let holders = Self.socketHolderPIDs(
            lsofOutput: runCommand("/usr/sbin/lsof", ["-U", "-Fn"]),
            socketPath: socketPath
        )
        stopProcesses(holders)

        // 清理套接字文件
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - 内部实现

    /// 旧版守护进程套接字路径。
    private static func legacySocketPath() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let discoDir = appSupport.appendingPathComponent("disco")
        try? FileManager.default.createDirectory(
            at: discoDir,
            withIntermediateDirectories: true
        )
        return discoDir.appendingPathComponent("disco.sock").path
    }

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
}
