import Darwin
import Foundation

final class ManagedProcess {
    let process: Process
    let standardInput: FileHandle?
    let standardOutput: FileHandle?

    init(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        captureStandardOutput: Bool = true,
        captureStandardError: Bool = true
    ) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory.map(URL.init(fileURLWithPath:))
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = captureStandardOutput ? Pipe() : nil
        let errorPipe = captureStandardError ? Pipe() : nil
        process.standardInput = inputPipe
        process.standardOutput = outputPipe ?? FileHandle.nullDevice
        process.standardError = errorPipe ?? FileHandle.nullDevice

        self.process = process
        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputPipe?.fileHandleForReading
    }

    func launch() throws {
        do {
            try process.run()
        } catch {
            throw ProcessSupportError.launchFailed(error.localizedDescription)
        }
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
