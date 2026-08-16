import XCTest
@testable import disco

// MARK: - DaemonProcessManager 解析逻辑

/// 覆盖 daemon 进程身份校验用到的命令输出解析：
/// `lsof -U -Fn` 的套接字占用者、`lsof -p <pid> -a -d txt -Fn` 的可执行路径、
/// `ps -o lstart=` 的进程启动时间。真实进程探测不放进单测。
@MainActor
final class DaemonProcessManagerTests: XCTestCase {
    func testSocketHolderPIDsParsesFieldOutputAndFiltersBySocketPath() {
        let output = """
        p11117
        f6u
        n->0xabc
        p95477
        f12
        n/Users/yankewei/Library/Application Support/disco/disco.sock
        f14
        n/Users/yankewei/Library/Application Support/disco/disco.sock
        """
        let pids = DaemonProcessManager.socketHolderPIDs(
            lsofOutput: output,
            socketPath: "/Users/yankewei/Library/Application Support/disco/disco.sock"
        )
        XCTAssertEqual(pids, [95477])
    }

    func testSocketHolderPIDsReturnsEmptyWhenSocketNotPresent() {
        let output = "p11117\nf6u\nn->0xabc\n"
        XCTAssertTrue(
            DaemonProcessManager.socketHolderPIDs(
                lsofOutput: output,
                socketPath: "/nonexistent/disco.sock"
            ).isEmpty
        )
        XCTAssertTrue(
            DaemonProcessManager.socketHolderPIDs(
                lsofOutput: nil,
                socketPath: "/nonexistent/disco.sock"
            ).isEmpty
        )
    }

    func testDaemonExecutablePathParsesTextMapping() {
        let output = """
        p95477
        ftxt
        n/Applications/disco.app/Contents/Resources/disco-daemon
        ftxt
        n/usr/lib/dyld
        """
        XCTAssertEqual(
            DaemonProcessManager.daemonExecutablePath(lsofOutput: output),
            "/Applications/disco.app/Contents/Resources/disco-daemon"
        )
    }

    func testDaemonExecutablePathReturnsNilWhenMappingMissing() {
        XCTAssertNil(
            DaemonProcessManager.daemonExecutablePath(
                lsofOutput: "p95477\nftxt\nn/usr/lib/dyld\n"
            )
        )
        XCTAssertNil(DaemonProcessManager.daemonExecutablePath(lsofOutput: nil))
    }

    func testProcessStartTimeParsesLCAllCLstart() throws {
        let date = try XCTUnwrap(
            DaemonProcessManager.processStartTime(psOutput: "Sun Aug 16 22:39:23 2026")
        )
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 16)
        XCTAssertEqual(components.hour, 22)
        XCTAssertEqual(components.minute, 39)
        XCTAssertEqual(components.second, 23)
    }

    func testProcessStartTimeReturnsNilForEmptyOrInvalidOutput() {
        XCTAssertNil(DaemonProcessManager.processStartTime(psOutput: ""))
        XCTAssertNil(DaemonProcessManager.processStartTime(psOutput: "not a date"))
        XCTAssertNil(DaemonProcessManager.processStartTime(psOutput: nil))
    }
}
