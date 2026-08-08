import Foundation

protocol APIKeyStoring {
    func load() throws -> String?
    func save(_ apiKey: String) throws
    func delete() throws
    /// 返回绑定到指定 account 的存储实例（用于按服务商隔离）。
    /// 测试替身（如 InMemoryAuthStore）可直接返回自身。
    func forAccount(_ account: String) -> APIKeyStoring
}

/// API Key 明文存储在 Application Support 目录
/// （~/Library/Application Support/disco/config/auth.json，0600 权限、原子写入）。
///
/// 与 gh / aws 等 CLI 的做法一致：文件可读、可备份、可迁移；
/// 代价是没有系统级加密，同一用户下的其他进程可读取。
/// account 作为 JSON 键，按服务商隔离。
///
/// 历史位置（首次读取时自动迁移，不阻塞使用）：
/// - 旧版沙盒容器：~/Library/Containers/<bundle-id>/Data/Library/Application Support/disco/config/auth.json
/// - 更早版本：~/Library/Containers/<bundle-id>/Data/.disco/config/auth.json
struct AuthFileStore: APIKeyStoring {
    private let account: String
    private let fileURL: URL

    init(account: String = "api-key", fileURL: URL? = nil) {
        self.account = account
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    /// 默认存储位置：真实 Application Support 下的 disco/config/auth.json
    private static func defaultFileURL() -> URL {
        // Apple 推荐：数据放在 Application Support 目录
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("disco", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("auth.json")
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

    /// 旧版本把 auth.json 写在家目录（沙盒内即容器根）的 ~/.disco/config 下
    private var legacyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".disco", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    /// 早期版本处于沙盒容器内的 Application Support 位置（本应用曾启用 App Sandbox）
    private var containerFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.yankewei.disco")
            .appendingPathComponent("Data/Library/Application Support")
            .appendingPathComponent("disco", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    /// 更早版本：容器根 ~/.disco/config（沙盒内 homeDirectoryForCurrentUser 即容器 Data 目录）
    private var containerRootLegacyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.yankewei.disco")
            .appendingPathComponent("Data/.disco/config/auth.json")
    }

    /// 实际使用的文件：优先新位置（真实 Application Support）；
    /// 缺失时依次尝试容器位置与更早位置并迁移过去。
    /// 迁移失败则回退读原位置，不阻塞已有 Key。
    ///
    /// 注意：迁移只对**默认位置**生效（`usesDefaultLocation`）。
    /// 测试注入自定义 fileURL 时直接使用该路径，绝不触碰真实用户文件。
    private func resolvedFileURL() -> URL {
        guard usesDefaultLocation else { return fileURL }
        let candidates = [
            legacyFileURL,
            containerRootLegacyFileURL,
            containerFileURL,
        ]
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return fileURL }
        for source in candidates where FileManager.default.fileExists(atPath: source.path) {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: source, to: fileURL)
            } catch {
                // 迁移失败（如权限问题）：继续读原位置，不阻塞使用
            }
            return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : source
        }
        return fileURL
    }

    /// 是否使用默认存储位置：迁移逻辑只对默认位置生效，
    /// 防止测试注入的自定义 fileURL 意外迁移真实用户数据
    private var usesDefaultLocation: Bool {
        fileURL == Self.defaultFileURL()
    }

    private func readAll() throws -> [String: String] {
        let url = resolvedFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try decodeFile(at: url)
    }

    private func decodeFile(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
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
            "无法读取 API Key 文件（Application Support/disco/config/auth.json）：文件损坏或格式不正确。"
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
