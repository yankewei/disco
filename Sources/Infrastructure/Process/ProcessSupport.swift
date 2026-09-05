import Darwin
import Foundation

final class ManagedProcess {
    let process: Process
    let standardInput: FileHandle?
    let standardOutput: FileHandle?
    private let registry: ProviderProcessRegistry

    init(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        captureStandardOutput: Bool = true,
        captureStandardError: Bool = true,
        registry: ProviderProcessRegistry = .shared
    ) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory.map(URL.init(fileURLWithPath:))
        process.environment = environment
        process.terminationHandler = { [weak process] _ in
            guard let process else { return }
            registry.unregister(pid: process.processIdentifier)
        }

        let inputPipe = Pipe()
        let outputPipe = captureStandardOutput ? Pipe() : nil
        let errorPipe = captureStandardError ? Pipe() : nil
        process.standardInput = inputPipe
        process.standardOutput = outputPipe ?? FileHandle.nullDevice
        process.standardError = errorPipe ?? FileHandle.nullDevice

        self.process = process
        self.registry = registry
        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputPipe?.fileHandleForReading
    }

    func launch() throws {
        do {
            try process.run()
        } catch {
            throw ProcessSupportError.launchFailed(error.localizedDescription)
        }
        // A process that already exited is skipped by register; a record racing its
        // termination handler is dropped by the next reap.
        registry.register(
            pid: process.processIdentifier,
            executablePath: process.executableURL?.path ?? ""
        )
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func forceTerminate() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}

func lineStream(from fileHandle: FileHandle) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        // Pipe reads must not block Swift's cooperative executor or Foundation's shared async reader.
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            do {
                while true {
                    let count = Darwin.read(fileHandle.fileDescriptor, &bytes, bytes.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    buffer.append(contentsOf: bytes[..<count])
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[..<newline], as: UTF8.self)
                        buffer.removeSubrange(...newline)
                        if case .terminated = continuation.yield(line) { return }
                    }
                }
                if !buffer.isEmpty {
                    continuation.yield(String(decoding: buffer, as: UTF8.self))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

enum ProcessSupportError: LocalizedError {
    case launchFailed(String)
    case outputClosed
    case requestTimedOut(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            "无法启动 Provider：\(message)"
        case .outputClosed:
            "Provider 输出流已关闭"
        case let .requestTimedOut(method):
            "Provider 请求超时：\(method)"
        case let .invalidOutput(message):
            "Provider 输出无法解析：\(message)"
        }
    }
}

private struct ProviderProcessRecord: Codable {
    let pid: Int32
    let executablePath: String
    let startTime: Double
    let ownerPID: Int32
    let ownerStartTime: Double
}

/// Tracks launched provider processes so that orphans left behind by a crash or
/// force-quit (when graceful shutdown never runs) can be reaped on the next
/// launch. A record is acted on only when the Disco instance that launched it is
/// gone and the pid still reports the recorded start time, which rules out both
/// killing a concurrently running instance and pid reuse.
final class ProviderProcessRegistry {
    static let shared = ProviderProcessRegistry(storageURL: defaultStorageURL)

    private static let recordLimit = 32
    private static let owner: (pid: Int32, startTime: Double) = {
        let pid = ProcessInfo.processInfo.processIdentifier
        return (pid, ProcessIdentity.startTime(of: pid) ?? 0)
    }()

    private static let defaultStorageURL: URL? = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first?
        .appendingPathComponent("Disco", isDirectory: true)
        .appendingPathComponent("provider-processes.json")

    private let storageURL: URL?
    private let lock = NSLock()

    init(storageURL: URL?) {
        self.storageURL = storageURL
    }

    func register(
        pid: Int32,
        executablePath: String,
        ownerPID: Int32 = ProviderProcessRegistry.owner.pid,
        ownerStartTime: Double = ProviderProcessRegistry.owner.startTime
    ) {
        guard !executablePath.isEmpty, let startTime = ProcessIdentity.startTime(of: pid) else {
            return
        }
        modifyRecords { records in
            records.removeAll { $0.pid == pid }
            records.append(ProviderProcessRecord(
                pid: pid,
                executablePath: executablePath,
                startTime: startTime,
                ownerPID: ownerPID,
                ownerStartTime: ownerStartTime
            ))
            if records.count > Self.recordLimit {
                records.removeFirst(records.count - Self.recordLimit)
            }
        }
    }

    func unregister(pid: Int32) {
        modifyRecords { records in
            records.removeAll { $0.pid == pid }
        }
    }

    /// Terminates this executable's processes whose owner instance never ran
    /// graceful shutdown, and drops records that no longer describe a live
    /// process. Processes owned by a running instance are left alone.
    func reapOrphanedProcesses(executablePath: String) {
        let orphans: [ProviderProcessRecord] = lock.withLock {
            var orphans: [ProviderProcessRecord] = []
            let records = readRecords()
            let survivors = records.filter { record in
                guard Self.isAlive(record) else { return false }
                guard record.executablePath == executablePath, !Self.isOwnerAlive(record) else {
                    return true
                }
                orphans.append(record)
                return false
            }
            if survivors.count != records.count {
                writeRecords(survivors)
            }
            return orphans
        }
        guard !orphans.isEmpty else { return }
        for orphan in orphans {
            kill(orphan.pid, SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            for orphan in orphans where ProviderProcessRegistry.isAlive(orphan) {
                kill(orphan.pid, SIGKILL)
            }
        }
    }

    private static func isAlive(_ record: ProviderProcessRecord) -> Bool {
        ProcessIdentity.startTime(of: record.pid) == record.startTime
    }

    private static func isOwnerAlive(_ record: ProviderProcessRecord) -> Bool {
        record.ownerPID == owner.pid
            || ProcessIdentity.startTime(of: record.ownerPID) == record.ownerStartTime
    }

    private func modifyRecords(_ mutation: (inout [ProviderProcessRecord]) -> Void) {
        lock.withLock {
            var records = readRecords()
            mutation(&records)
            writeRecords(records)
        }
    }

    private func readRecords() -> [ProviderProcessRecord] {
        guard
            let storageURL,
            let data = try? Data(contentsOf: storageURL),
            let records = try? JSONDecoder().decode([ProviderProcessRecord].self, from: data)
        else { return [] }
        return records
    }

    private func writeRecords(_ records: [ProviderProcessRecord]) {
        guard let storageURL else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}

enum ProcessIdentity {
    static func startTime(of pid: pid_t) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // An exited pid reports success with an empty result.
        guard
            sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
            size == MemoryLayout<kinfo_proc>.stride
        else { return nil }
        let startTime = info.kp_proc.p_starttime
        return TimeInterval(startTime.tv_sec) + TimeInterval(startTime.tv_usec) / 1_000_000
    }
}
