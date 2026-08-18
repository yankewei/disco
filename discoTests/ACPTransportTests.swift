import Foundation
import XCTest
@testable import disco

final class ACPTransportTests: XCTestCase {
    @MainActor
    func testACPDaemonClientUsesStdioProviderExtension() async throws {
        let daemonPath = repositoryRoot
            .appendingPathComponent("disco-daemon")
            .appendingPathComponent("target")
            .appendingPathComponent("debug")
            .appendingPathComponent("disco-daemon")
        guard FileManager.default.isExecutableFile(atPath: daemonPath.path) else {
            throw XCTSkip("未找到 Rust daemon，请先执行 cargo build -p disco-daemon。")
        }

        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("disco-acp-client-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let client = ACPDaemonClient()
        try await client.connect(
            binaryPath: daemonPath.path,
            environmentOverrides: ["HOME": homeURL.path]
        )
        defer { client.disconnect() }

        let initializeResult = try await client.initialize()
        XCTAssertEqual(initializeResult.protocolVersion, 1)

        let configured = try await client.configureProvider(
            providerID: nil,
            vendor: "deepseek",
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "sk-test",
            model: "deepseek-chat",
            thinkingEnabled: false
        )
        XCTAssertEqual(configured.providerId, "deepseek_api")

        let providers = try await client.listProviders()
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].vendor, "deepseek")

        let models = try await client.listProviderModels(
            providerID: "deepseek_api",
            vendor: "deepseek"
        )
        XCTAssertFalse(models.isEmpty)

        let sessionID = UUID()
        let createdSession = try await client.newSession(
            cwd: homeURL.path,
            providerID: "deepseek_api",
            sessionID: sessionID.uuidString
        )
        XCTAssertEqual(UUID(uuidString: createdSession.sessionId), sessionID)

        let messages = try await client.listMessages(sessionID: sessionID.uuidString)
        XCTAssertTrue(messages.isEmpty)

        // 空会话压缩应返回明确错误,不触发真实模型请求。
        do {
            _ = try await client.compactSession(sessionID: sessionID.uuidString)
            XCTFail("压缩空会话应返回错误")
        } catch {
            // 期望 rpcError
        }

        let sessions = try await client.listSessions(cwd: homeURL.path)
        XCTAssertTrue(sessions.sessions.contains {
            UUID(uuidString: $0.sessionId) == sessionID
        })
        _ = try await client.loadSession(sessionID: sessionID.uuidString, cwd: homeURL.path)
        try await client.deleteSession(sessionID: sessionID.uuidString)
    }

    func testACPEventMapperTranslatesMessageAndPermission() throws {
        let sessionID = UUID().uuidString
        let runID = UUID()
        let update = ACPSessionUpdate(
            sessionID: sessionID,
            update: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("你好")
                ])
            ])
        )

        let events = ACPDaemonEventMapper.sessionUpdateEvents(
            update,
            runID: runID,
            shouldEmitRunningState: true
        )
        XCTAssertEqual(events.map(\.eventName), ["run.state", "message.delta"])
        XCTAssertEqual(
            try events[1].decoded(as: DaemonMessageDeltaData.self).delta,
            "你好"
        )

        let approvalID = UUID()
        let permission = ACPPermissionRequest(
            requestID: .number(7),
            sessionID: sessionID,
            toolCall: .object([
                "toolCallId": .string(approvalID.uuidString),
                "title": .string("执行命令"),
                "rawInput": .object([
                    "kind": .string("command"),
                    "impact": .object([
                        "type": .string("permission"),
                        "scope": .string("shell"),
                        "description": .string("执行命令")
                    ])
                ])
            ]),
            options: [],
            metadata: .object([
                "disco/approvalId": .string(approvalID.uuidString),
                "disco/approvalScope": .string("session"),
                "disco/approvalFingerprint": .string("fingerprint")
            ])
        )
        let mappedApproval = try XCTUnwrap(
            ACPDaemonEventMapper.approvalEvent(permission, runID: runID)
        )
        let approvalData = try mappedApproval.event.decoded(
            as: DaemonApprovalRequestedData.self
        )
        XCTAssertEqual(approvalData.approvalId, approvalID.uuidString)
        XCTAssertTrue(approvalData.allowsSessionApproval)
        XCTAssertEqual(approvalData.kind, "command")

        let usageUpdate = ACPSessionUpdate(
            sessionID: sessionID,
            update: .object([
                "sessionUpdate": .string("usage_update"),
                "used": .number(150),
                "size": .number(0),
                "_meta": .object([
                    "disco/usage": .object([
                        "current": .object([
                            "input": .number(100),
                            "output": .number(50),
                            "total": .number(150),
                            "cached_input": .number(20),
                            "reasoning_output": .number(10)
                        ]),
                        "accumulated": .object([
                            "input": .number(100),
                            "output": .number(50),
                            "total": .number(150),
                            "cached_input": .number(20),
                            "reasoning_output": .number(10)
                        ])
                    ])
                ])
            ])
        )
        let usageEvents = ACPDaemonEventMapper.sessionUpdateEvents(
            usageUpdate,
            runID: runID,
            shouldEmitRunningState: false
        )
        XCTAssertEqual(usageEvents.map(\.eventName), ["context.usage"])
        let usageData = try usageEvents[0].decoded(as: DaemonContextUsageData.self)
        XCTAssertEqual(usageData.current.input, 100)
        XCTAssertEqual(usageData.current.total, 150)
        XCTAssertEqual(usageData.source, "provider")
    }

    func testDaemonRespondsToACPInitializeOverStdio() throws {
        let daemonURL = repositoryRoot
            .appendingPathComponent("disco-daemon")
            .appendingPathComponent("target")
            .appendingPathComponent("debug")
            .appendingPathComponent("disco-daemon")
        guard FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
            throw XCTSkip("未找到 Rust daemon，请先执行 cargo build -p disco-daemon。")
        }

        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("disco-acp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let process = Process()
        process.executableURL = daemonURL
        process.arguments = ["--stdio"]
        process.environment = ["HOME": homeURL.path]

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let initialize = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"disco-tests","version":"0.1.0"}}}
        """
        let providerList = """
        {"jsonrpc":"2.0","id":2,"method":"_disco/provider/list","params":{}}
        """
        input.fileHandleForWriting.write(Data((initialize + "\n" + providerList).utf8))
        input.fileHandleForWriting.closeFile()

        let responses = try (0..<2).map { _ in
            let responseData = try readLine(from: output.fileHandleForReading)
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            )
        }
        let response = try XCTUnwrap(responses.first { ($0["id"] as? Int) == 1 })
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? Int, 1)
        XCTAssertEqual(
            (result["agentInfo"] as? [String: Any])?["name"] as? String,
            "disco-daemon"
        )

        let providerResponse = try XCTUnwrap(responses.first { ($0["id"] as? Int) == 2 })
        guard let providerResult = providerResponse["result"] as? [String: Any] else {
            XCTFail("ACP provider response 缺少 result：\(providerResponse)")
            return
        }
        XCTAssertNotNil(providerResult["providers"] as? [[String: Any]])

        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(error.fileHandleForReading.availableData.isEmpty)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readLine(from handle: FileHandle) throws -> Data {
        var line = Data()
        while true {
            let chunk = try handle.read(upToCount: 1) ?? Data()
            if chunk.isEmpty {
                break
            }
            line.append(chunk)
            if chunk == Data([0x0A]) {
                break
            }
        }
        guard !line.isEmpty else {
            throw NSError(
                domain: "ACPTransportTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ACP daemon 未返回 initialize 响应。"]
            )
        }
        return line
    }
}
