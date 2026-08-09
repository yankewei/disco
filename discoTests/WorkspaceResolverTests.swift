import XCTest
@testable import disco

@MainActor
final class WorkspaceResolverTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("disco-workspace-tests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testResolvesReadableDirectoryWithoutRequiringGit() throws {
        let workspace = temporaryDirectory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let resolver = WorkspaceResolver()

        let resolved = try resolver.resolve(directory: workspace)

        XCTAssertEqual(resolved.context.rootURL, workspace.resolvingSymlinksInPath())
        XCTAssertTrue(resolved.context.additionalReadableRoots.isEmpty)
        XCTAssertEqual(resolved.projectName, workspace.lastPathComponent)
        XCTAssertNotNil(resolved.bookmarkData)
    }

    func testRejectsFileAndRelativeURL() throws {
        let file = temporaryDirectory.appendingPathComponent("file.txt")
        try Data("content".utf8).write(to: file)
        let resolver = WorkspaceResolver()

        XCTAssertThrowsError(try resolver.resolve(directory: file))
        XCTAssertThrowsError(try resolver.resolve(directory: URL(fileURLWithPath: "relative")))
    }

    func testCanonicalizesSymlinkToSameWorkspace() throws {
        let workspace = temporaryDirectory.appendingPathComponent("workspace", isDirectory: true)
        let link = temporaryDirectory.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: workspace)
        let resolver = WorkspaceResolver()

        let resolved = try resolver.resolve(directory: link)

        XCTAssertEqual(resolved.context.rootURL, workspace.resolvingSymlinksInPath())
    }

    func testAvailabilityUsesBookmarkAndRefreshesStaleBookmark() throws {
        let workspace = temporaryDirectory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let resolver = WorkspaceResolver()
        let resolved = try resolver.resolve(directory: workspace)
        let project = ProjectSnapshot(
            id: UUID(),
            name: resolved.projectName,
            workspaceRoot: resolved.context.rootURL,
            bookmarkData: resolved.bookmarkData,
            createdAt: .now,
            lastOpenedAt: .now
        )

        let resolution = resolver.resolve(project: project)

        guard case let .available(context) = resolution.availability else {
            return XCTFail("expected an available project")
        }
        XCTAssertEqual(context.rootURL, workspace.resolvingSymlinksInPath())
        XCTAssertEqual(resolution.canonicalURL, context.rootURL)
        XCTAssertNotNil(resolution.bookmarkData)
    }

    func testBrokenBookmarkFallsBackToStoredPath() throws {
        let workspace = temporaryDirectory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let resolver = WorkspaceResolver()
        let project = ProjectSnapshot(
            id: UUID(),
            name: "Workspace",
            workspaceRoot: workspace,
            bookmarkData: Data("broken bookmark".utf8),
            createdAt: .now,
            lastOpenedAt: .now
        )

        let resolution = resolver.resolve(project: project)

        guard case let .available(context) = resolution.availability else {
            return XCTFail("expected the stored path fallback to be available")
        }
        XCTAssertEqual(context.rootURL, workspace.resolvingSymlinksInPath())
        XCTAssertNotNil(resolution.bookmarkData)
    }

    func testMissingWorkspaceReportsMissingAvailability() throws {
        let missing = temporaryDirectory.appendingPathComponent("missing", isDirectory: true)
        let project = ProjectSnapshot(
            id: UUID(),
            name: "Missing",
            workspaceRoot: missing,
            bookmarkData: nil,
            createdAt: .now,
            lastOpenedAt: .now
        )

        let resolution = WorkspaceResolver().resolve(project: project)

        XCTAssertEqual(resolution.availability, .unavailable(.missing))
    }
}
