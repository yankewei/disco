import Foundation

protocol APIKeyStoring {
    func load() throws -> String?
    func save(_ apiKey: String) throws
    func delete() throws
    /// 返回绑定到指定 account 的存储实例（用于按服务商隔离）。
    /// 测试替身（如 InMemoryAuthStore）可直接返回自身。
    func forAccount(_ account: String) -> APIKeyStoring
}

/// API Key 明文存储在 ~/.disco/config/auth.json（0600 权限、原子写入）。
///
/// 与 gh / aws 等 CLI 的做法一致：文件可读、可备份、可迁移；
/// 代价是没有系统级加密，同一用户下的其他进程可读取。
/// account 作为 JSON 键，按服务商隔离。
struct AuthFileStore: APIKeyStoring {
    private let account: String
    private let fileURL: URL

    init(account: String = "api-key", fileURL: URL? = nil) {
        self.account = account
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.fileURL = home
                .appendingPathComponent(".disco", isDirectory: true)
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("auth.json")
        }
    }

    func forAccount(_ account: String) -> APIKeyStoring {
        AuthFileStore(account: account, fileURL: fileURL)
    }

    func load() throws -> String? {
        try readAll()[account]
    }

    func save(_ apiKey: String) throws {
        var keys = try readAll()
        keys[account] = apiKey
        try writeAll(keys)
    }

    func delete() throws {
        var keys = try readAll()
        keys.removeValue(forKey: account)
        try writeAll(keys)
    }

    // MARK: - 文件读写

    private func readAll() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw AuthFileError.invalidFile
        }
    }

    private func writeAll(_ keys: [String: String]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(keys)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

enum AuthFileError: LocalizedError {
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            "无法读取 ~/.disco/config/auth.json：文件损坏或格式不正确。"
        }
    }
}

final class InMemoryAuthStore: APIKeyStoring {
    private var apiKey: String?

    func load() throws -> String? {
        apiKey
    }

    func save(_ apiKey: String) throws {
        self.apiKey = apiKey
    }

    func delete() throws {
        apiKey = nil
    }

    func forAccount(_ account: String) -> APIKeyStoring {
        self
    }
}
