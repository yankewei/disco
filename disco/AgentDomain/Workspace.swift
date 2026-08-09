import Foundation

/// 当前 Project 可供 Runtime 使用的工作区上下文。
struct WorkspaceContext: Sendable, Equatable {
    let rootURL: URL
    let additionalReadableRoots: [URL]
}

/// Project 的持久化身份；workspaceRoot 是最近一次成功解析的规范路径。
struct ProjectSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var workspaceRoot: URL
    var bookmarkData: Data?
    let createdAt: Date
    var lastOpenedAt: Date
}

enum ProjectAvailability: Sendable, Equatable {
    case available(WorkspaceContext)
    case unavailable(WorkspaceUnavailableReason)
}

enum WorkspaceUnavailableReason: Sendable, Equatable {
    case missing
    case unreadable
}

enum WorkspaceResolverError: Error, LocalizedError, Sendable, Equatable {
    case notFileURL
    case notAbsolute
    case missing
    case notDirectory
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notFileURL:
            return "项目路径必须是本地目录。"
        case .notAbsolute:
            return "项目路径必须是绝对路径。"
        case .missing:
            return "项目目录不存在。"
        case .notDirectory:
            return "所选路径不是目录。"
        case .unreadable:
            return "项目目录不可读。"
        }
    }
}

/// 目录规范化、bookmark 创建和 Project 恢复的唯一边界。
struct WorkspaceResolver {
    struct ResolvedWorkspace: Sendable, Equatable {
        let context: WorkspaceContext
        let projectName: String
        let bookmarkData: Data?
    }

    struct ProjectResolution: Sendable, Equatable {
        let availability: ProjectAvailability
        let canonicalURL: URL?
        let bookmarkData: Data?
    }

    /// 校验目录、解析符号链接，并尽力创建普通 bookmark。
    func resolve(directory url: URL) throws -> ResolvedWorkspace {
        let canonicalURL = try canonicalDirectoryURL(url)
        return ResolvedWorkspace(
            context: WorkspaceContext(
                rootURL: canonicalURL,
                additionalReadableRoots: []
            ),
            projectName: projectName(for: canonicalURL),
            bookmarkData: makeBookmark(for: canonicalURL)
        )
    }

    /// 恢复 Project。bookmark 无效时回退到持久化的规范路径。
    func resolve(project: ProjectSnapshot) -> ProjectResolution {
        if let bookmarkData = project.bookmarkData,
           let bookmarkedURL = resolveBookmark(bookmarkData),
           let canonicalURL = try? canonicalDirectoryURL(bookmarkedURL) {
            return availableResolution(for: canonicalURL, originalBookmark: bookmarkData)
        }

        do {
            let canonicalURL = try canonicalDirectoryURL(project.workspaceRoot)
            return availableResolution(for: canonicalURL, originalBookmark: project.bookmarkData)
        } catch let error as WorkspaceResolverError {
            return ProjectResolution(
                availability: .unavailable(error == .missing ? .missing : .unreadable),
                canonicalURL: nil,
                bookmarkData: nil
            )
        } catch {
            return ProjectResolution(
                availability: .unavailable(.unreadable),
                canonicalURL: nil,
                bookmarkData: nil
            )
        }
    }

    private func availableResolution(
        for canonicalURL: URL,
        originalBookmark: Data?
    ) -> ProjectResolution {
        ProjectResolution(
            availability: .available(WorkspaceContext(
                rootURL: canonicalURL,
                additionalReadableRoots: []
            )),
            canonicalURL: canonicalURL,
            bookmarkData: makeBookmark(for: canonicalURL) ?? originalBookmark
        )
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func canonicalDirectoryURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw WorkspaceResolverError.notFileURL }
        guard url.path.hasPrefix("/") else { throw WorkspaceResolverError.notAbsolute }

        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalURL.path, isDirectory: &isDirectory) else {
            throw WorkspaceResolverError.missing
        }
        guard isDirectory.boolValue else { throw WorkspaceResolverError.notDirectory }

        let resourceValues = try? canonicalURL.resourceValues(forKeys: [.isReadableKey])
        guard resourceValues?.isReadable == true else {
            throw WorkspaceResolverError.unreadable
        }
        return canonicalURL
    }

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func projectName(for url: URL) -> String {
        let resourceValues = try? url.resourceValues(forKeys: [.localizedNameKey])
        let localizedName = resourceValues?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let localizedName, !localizedName.isEmpty else {
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }
        return localizedName
    }
}
