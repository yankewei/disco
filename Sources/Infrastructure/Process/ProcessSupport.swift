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
        let readerTask = Task {
            do {
                for try await line in fileHandle.bytes.lines {
                    continuation.yield(line)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            readerTask.cancel()
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
