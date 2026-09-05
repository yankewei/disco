import Foundation

struct AppEnvironment {
    let databaseURL: URL

    static func live() throws -> AppEnvironment {
        try AppEnvironment(databaseURL: DatabaseLocator.resolveURL())
    }
}

enum DatabaseLocator {
    static func resolveURL(fileManager: FileManager = .default) throws -> URL {
        guard
            let applicationSupportURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw AppEnvironmentError.applicationSupportUnavailable
        }

        let nativeDirectory = applicationSupportURL.appendingPathComponent(
            "Disco",
            isDirectory: true
        )
        let nativeURL = nativeDirectory.appendingPathComponent("disco.sqlite")
        try fileManager.createDirectory(
            at: nativeDirectory,
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: nativeURL.path) {
            return nativeURL
        }

        let legacyURLs = [
            applicationSupportURL
                .appendingPathComponent("disco-electron", isDirectory: true)
                .appendingPathComponent("disco.sqlite"),
        ]
        for legacyURL in legacyURLs where fileManager.fileExists(atPath: legacyURL.path) {
            try copyDatabase(from: legacyURL, to: nativeURL, fileManager: fileManager)
            return nativeURL
        }
        return nativeURL
    }

    private static func copyDatabase(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        for suffix in ["-wal", "-shm"] {
            let sourceSidecar = URL(fileURLWithPath: sourceURL.path + suffix)
            let destinationSidecar = URL(fileURLWithPath: destinationURL.path + suffix)
            if fileManager.fileExists(atPath: sourceSidecar.path) {
                try fileManager.copyItem(at: sourceSidecar, to: destinationSidecar)
            }
        }
    }
}

enum ExecutableLocator {
    private static let loginShellLock = NSLock()
    private static var didResolveLoginShellEnvironment = false
    private static var cachedLoginShellEnvironment: [String: String]?

    static func locate(
        _ command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if command.hasPrefix("/") {
            return isExecutable(URL(fileURLWithPath: command), fileManager: fileManager)
                ? URL(fileURLWithPath: command)
                : nil
        }

        var directories = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        directories.append(contentsOf: standardSearchDirectories())
        var visited: Set<String> = []
        for directory in directories where visited.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command)
            if isExecutable(candidate, fileManager: fileManager) {
                return candidate
            }
        }
        return nil
    }

    static func environmentIncludingLoginShell(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard let shellEnvironment = loginShellEnvironment(environment: environment) else {
            return environment
        }

        var mergedEnvironment = environment
        mergedEnvironment.merge(shellEnvironment) { _, shellValue in shellValue }
        if let shellPath = shellEnvironment["PATH"], let inheritedPath = environment["PATH"] {
            mergedEnvironment["PATH"] = [shellPath, inheritedPath]
                .joined(separator: ":")
        }
        return mergedEnvironment
    }

    static func standardSearchDirectories() -> [String] {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        return [
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent(".opencode/bin").path,
            homeDirectory.appendingPathComponent(".npm-global/bin").path,
            homeDirectory.appendingPathComponent(".bun/bin").path,
            homeDirectory.appendingPathComponent(".cargo/bin").path,
            homeDirectory.appendingPathComponent(".local/share/mise/shims").path,
            homeDirectory.appendingPathComponent(".volta/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }

    private static func loginShellEnvironment(
        environment: [String: String]
    ) -> [String: String]? {
        loginShellLock.lock()
        if didResolveLoginShellEnvironment {
            let cachedEnvironment = cachedLoginShellEnvironment
            loginShellLock.unlock()
            return cachedEnvironment
        }
        loginShellLock.unlock()

        let resolvedEnvironment = resolveLoginShellEnvironment(environment: environment)

        loginShellLock.lock()
        if !didResolveLoginShellEnvironment {
            cachedLoginShellEnvironment = resolvedEnvironment
            didResolveLoginShellEnvironment = true
        }
        let cachedEnvironment = cachedLoginShellEnvironment
        loginShellLock.unlock()
        return cachedEnvironment
    }

    private static func resolveLoginShellEnvironment(
        environment: [String: String]
    ) -> [String: String]? {
        var shells: [String] = []
        if let configuredShell = environment["SHELL"], !configuredShell.isEmpty {
            shells.append(configuredShell)
        }
        shells.append(contentsOf: ["/bin/zsh", "/bin/bash", "/bin/sh"])

        var visited: Set<String> = []
        for shell in shells where visited.insert(shell).inserted {
            let shellURL = URL(fileURLWithPath: shell)
            guard FileManager.default.isExecutableFile(atPath: shellURL.path) else {
                continue
            }
            if let resolvedEnvironment = captureShellEnvironment(
                shellURL: shellURL,
                environment: environment,
                arguments: ["-i", "-l", "-c"],
                timeout: 3
            ) ?? captureShellEnvironment(
                shellURL: shellURL,
                environment: environment,
                arguments: ["-l", "-c"],
                timeout: 5
            ) {
                return resolvedEnvironment
            }
        }
        return nil
    }

    private static func captureShellEnvironment(
        shellURL: URL,
        environment: [String: String],
        arguments: [String],
        timeout: TimeInterval
    ) -> [String: String]? {
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("disco-shell-environment-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: captureURL) }

        let process = Process()
        var shellEnvironment = environment
        shellEnvironment["DISCO_SHELL_ENV_CAPTURE_FILE"] = captureURL.path
        process.executableURL = shellURL
        process.arguments = arguments + [
            "/usr/bin/env -0 > \"$DISCO_SHELL_ENV_CAPTURE_FILE\"",
        ]
        process.environment = shellEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let waiter = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            waiter.signal()
        }
        defer { process.terminationHandler = nil }
        do {
            try process.run()
        } catch {
            return nil
        }

        guard waiter.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning {
                process.terminate()
            }
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: captureURL)
        else {
            return nil
        }
        return parseShellEnvironment(data)
    }

    private static func parseShellEnvironment(_ data: Data) -> [String: String] {
        var environment: [String: String] = [:]
        for record in data.split(separator: 0) {
            guard let separator = record.firstIndex(of: 61), separator > record.startIndex else {
                continue
            }
            let key = String(decoding: record[..<separator], as: UTF8.self)
            let value = String(decoding: record[record.index(after: separator)...], as: UTF8.self)
            environment[key] = value
        }
        return environment
    }

    private static func isExecutable(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }
}

enum ExecutableMetadataLocator {
    static func version(for executableURL: URL) -> String? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let waiter = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            waiter.signal()
        }
        defer { process.terminationHandler = nil }
        do {
            try process.run()
        } catch {
            return nil
        }

        guard waiter.wait(timeout: .now() + 5) == .success else {
            if process.isRunning {
                process.terminate()
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        return text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func providerEnvironment(for executableURL: URL) async -> [String: String] {
    var environment = await Task.detached(priority: .utility) {
        ExecutableLocator.environmentIncludingLoginShell()
    }.value
    var pathEntries = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    let additionalDirectories = [executableURL.deletingLastPathComponent().path]
        + ExecutableLocator.standardSearchDirectories()
    for directory in additionalDirectories where !pathEntries.contains(directory) {
        pathEntries.append(directory)
    }
    environment["PATH"] = pathEntries.joined(separator: ":")
    return environment
}

enum AppEnvironmentError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "无法找到 macOS 应用支持目录"
        }
    }
}
