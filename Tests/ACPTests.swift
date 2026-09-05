@testable import Disco
import Foundation
import XCTest

final class ACPTests: XCTestCase {
    func testAgentIdentityKeepsLegacyValuesAndSeparatesACPAgents() throws {
        XCTAssertEqual(try JSONEncoder().encode(AgentID.codex), Data("\"codex\"".utf8))
        XCTAssertEqual(try JSONDecoder().decode(AgentID.self, from: Data("\"opencode\"".utf8)), .opencode)
        let kimi = AgentID.acp(id: "kimi")
        let pi = AgentID.acp(id: "pi")
        XCTAssertNotEqual(kimi, pi)
        XCTAssertEqual(AgentID(rawValue: kimi.rawValue), kimi)
        XCTAssertEqual(try JSONDecoder().decode(AgentID.self, from: JSONEncoder().encode(pi)), pi)
        XCTAssertNil(AgentID(rawValue: "acp:"))
    }

    func testToolPartialUpdatesKeepInputTitleAndOutput() {
        var translator = ACPUpdateTranslator()
        _ = translator.event(for: [
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("read"),
            "title": .string("读取文件"), "status": .string("in_progress"),
            "rawInput": .object(["path": .string("test.txt")]),
            "content": .array([.object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string("文件内容")])])]),
        ])
        let event = translator.event(for: [
            "sessionUpdate": .string("tool_call_update"), "toolCallId": .string("read"), "status": .string("failed"),
        ])
        guard case let .tool(_, title, status, input, output, error) = event else { return XCTFail("缺少工具更新") }
        XCTAssertEqual(title, "读取文件")
        XCTAssertEqual(status, .failed)
        XCTAssertEqual(input, .object(["path": .string("test.txt")]))
        XCTAssertEqual(output, "文件内容")
        XCTAssertEqual(error, "文件内容")
    }

    func testPromptStreamsAndRestoresHistoryAcrossConnections() async throws {
        let fixture = try ACPFixture()
        defer { fixture.remove() }
        let backend = fixture.backend()
        let events = ACPEventRecorder()
        let result = try await backend.run(context: fixture.context(prompt: "hello", recorder: events))
        XCTAssertEqual(result, "你好")
        XCTAssertEqual(events.sessionID, "mock-session")
        XCTAssertEqual(events.text, "你好")
        let cached = try await backend.loadMessages(agentThreadID: "mock-session", workingDirectory: fixture.directory.path)
        XCTAssertEqual(cached.map(\.role), [.user, .assistant])
        XCTAssertEqual(cached.last?.text, "你好")
        backend.shutdown()

        let restoredBackend = fixture.backend()
        defer { restoredBackend.shutdown() }
        let restored = try await restoredBackend.loadMessages(agentThreadID: "mock-session", workingDirectory: fixture.directory.path)
        XCTAssertEqual(restored.map(\.text), ["旧问题", "旧回答"])
        let nextEvents = ACPEventRecorder()
        _ = try await restoredBackend.run(context: fixture.context(prompt: "next", sessionID: "mock-session", recorder: nextEvents))
        XCTAssertEqual(nextEvents.text, "你好", "恢复历史不能混入当前流式输出")
    }

    func testPermissionReturnsExactSelectedOptionID() async throws {
        let fixture = try ACPFixture()
        defer { fixture.remove() }
        let backend = fixture.backend()
        defer { backend.shutdown() }
        let recorder = ACPEventRecorder()
        let result = try await backend.run(context: fixture.context(prompt: "permission", recorder: recorder, answer: { questions in
            XCTAssertEqual(questions.first?.options.count, 3)
            XCTAssertEqual(questions.first?.options[1].description, "持续允许此类操作")
            return [[questions[0].options[0].label]]
        }))
        XCTAssertEqual(result, "option-once")
    }

    func testCancellationDuringPermissionRespondsCancelledAndEndsOnce() async throws {
        let fixture = try ACPFixture()
        defer { fixture.remove() }
        let backend = fixture.backend()
        defer { backend.shutdown() }
        let token = CancellationToken()
        do {
            _ = try await backend.run(context: fixture.context(prompt: "permission", token: token, answer: { _ in
                token.cancel()
                return nil
            }))
            XCTFail("应取消运行")
        } catch is CancellationError {
        }
        let history = try await backend.loadMessages(agentThreadID: "mock-session", workingDirectory: fixture.directory.path)
        XCTAssertEqual(history.last?.status, .cancelled)
    }

    func testRejectsUnsupportedRestoreAndVersion() async throws {
        for scenario in ["no-load", "bad-version"] {
            let fixture = try ACPFixture(scenario: scenario)
            defer { fixture.remove() }
            let backend = fixture.backend()
            defer { backend.shutdown() }
            do {
                _ = try await backend.loadMessages(agentThreadID: "old", workingDirectory: fixture.directory.path)
                XCTFail("应拒绝不支持的协议能力")
            } catch let error as ACPError {
                switch (scenario, error) {
                case ("no-load", .historyUnsupported), ("bad-version", .incompatibleVersion): break
                default: XCTFail("错误类型不正确：\(error)")
                }
            }
        }
    }

    func testProcessExitFailsPromptAndNextRunReconnects() async throws {
        let fixture = try ACPFixture()
        defer { fixture.remove() }
        let backend = fixture.backend()
        defer { backend.shutdown() }
        do {
            _ = try await backend.run(context: fixture.context(prompt: "crash"))
            XCTFail("进程退出应结束请求")
        } catch { }
        let result = try await backend.run(context: fixture.context(prompt: "hello", sessionID: "mock-session"))
        XCTAssertEqual(result, "你好")
    }

    func testJSONRPCRequestTimeoutClosesUnresponsiveProcess() async throws {
        let fixture = try ACPFixture()
        defer { fixture.remove() }
        let process = ManagedProcess(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", fixture.script.path], workingDirectory: fixture.directory.path, captureStandardError: false)
        let connection = JSONRPCConnection(managedProcess: process)
        defer { connection.close() }
        try connection.start(serverRequestHandler: { _ in .null }, notificationHandler: { _, _ in })
        do {
            _ = try await connection.request(method: "never", timeout: 0.1)
            XCTFail("请求应超时")
        } catch let error as ProcessSupportError {
            guard case .requestTimedOut("never") = error else { return XCTFail("错误类型不正确") }
        }
    }
}

private final class ACPEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BackendEvent] = []
    private var remoteID: String?
    var sessionID: String? {
        lock.lock()
        defer { lock.unlock() }
        return remoteID
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { event in
            if case let .text(text, _) = event { return text }
            return nil
        }.joined()
    }
    func record(_ event: BackendEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }
    func bind(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        remoteID = id
    }
}

private struct ACPFixture {
    let directory: URL
    let script: URL
    let scenario: String

    init(scenario: String = "normal") throws {
        self.scenario = scenario
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("disco-acp-test-" + UUID().uuidString)
        script = directory.appendingPathComponent("agent.py")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.source.write(to: script, atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func backend() -> ACPBackend {
        ACPBackend(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path, scenario])
    }

    func context(prompt: String, sessionID: String? = nil, token: CancellationToken = CancellationToken(), recorder: ACPEventRecorder = ACPEventRecorder(), answer: @escaping ([UserInputQuestion]) async -> [[String]]? = { _ in nil }) -> BackendRunContext {
        BackendRunContext(agentThreadID: sessionID, modelID: nil, reasoningEffort: nil, sandboxMode: nil,
                          workingDirectory: directory.path, prompt: prompt, mode: .agent,
                          emit: { recorder.record($0) }, cancellation: token,
                          reportAgentThreadID: { recorder.bind($0) }, requestUserInput: answer,
                          requestApproval: { _, _, _ in .denied })
    }

    static let source = #"""
import json, sys, os
scenario = sys.argv[1] if len(sys.argv) > 1 else "normal"
pending = None
cancelled = False
def send(value):
    print(json.dumps(dict(jsonrpc="2.0", **value)), flush=True)
def result(request, value):
    send({"id": request["id"], "result": value})
def update(kind, text):
    send({"method": "session/update", "params": {"sessionId": "mock-session", "update": {"sessionUpdate": kind, "content": {"type": "text", "text": text}}}})
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        assert request["params"]["clientCapabilities"] == {}
        result(request, {"protocolVersion": 99 if scenario == "bad-version" else 1, "agentCapabilities": {"loadSession": scenario != "no-load"}})
    elif method == "session/new":
        assert os.path.isabs(request["params"]["cwd"])
        result(request, {"sessionId": "mock-session"})
    elif method == "session/load":
        assert scenario != "no-load"
        update("user_message_chunk", "旧问题")
        update("agent_message_chunk", "旧回答")
        result(request, {})
    elif method == "session/prompt":
        prompt = request["params"]["prompt"][0]["text"]
        if prompt == "crash":
            sys.exit(1)
        if prompt == "permission":
            pending = request
            cancelled = False
            send({"id": "permission-1", "method": "session/request_permission", "params": {"sessionId": "mock-session", "toolCall": {"toolCallId": "tool", "title": "执行命令"}, "options": [{"optionId": "option-once", "name": "允许", "kind": "allow_once"}, {"optionId": "option-always", "name": "允许", "kind": "allow_always"}, {"optionId": "option-deny", "name": "拒绝", "kind": "reject_once"}]}})
        else:
            update("agent_thought_chunk", "思考")
            update("agent_message_chunk", "你")
            update("agent_message_chunk", "好")
            result(request, {"stopReason": "end_turn"})
    elif method == "session/cancel":
        cancelled = True
    elif request.get("id") == "permission-1":
        outcome = request["result"]["outcome"]
        if outcome["outcome"] == "cancelled":
            update("agent_message_chunk", "已取消")
            result(pending, {"stopReason": "cancelled"})
        else:
            update("agent_message_chunk", outcome["optionId"])
            result(pending, {"stopReason": "end_turn"})
    elif method == "never":
        pass
    else:
        send({"id": request.get("id"), "error": {"code": -32601, "message": "unsupported"}})
"""#
}
