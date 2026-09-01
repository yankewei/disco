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
            applicationSupportURL
                .appendingPathComponent("ai.disco.desktop", isDirectory: true)
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
        directories.append(contentsOf: [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".npm-global/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ])
        var visited: Set<String> = []
        for directory in directories where visited.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command)
            if isExecutable(candidate, fileManager: fileManager) {
                return candidate
            }
        }
        return nil
    }

    private static func isExecutable(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }
}

func providerEnvironment(for executableURL: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    var pathEntries = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    let additionalDirectories = [
        executableURL.deletingLastPathComponent().path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin").path,
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]
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
