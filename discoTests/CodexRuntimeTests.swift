import Foundation
import XCTest
@testable import disco

// MARK: - CodexRuntime 测试

/// `CodexRuntime`（计划 §6.2 Codex Runtime Adapter）的单元测试：
/// 复用 `CodexAppServerTestSupport.swift` 的脚本化替身，验证
/// `CodexTurnEvent` → `AgentEvent` 的映射与"一次运行恰好一个终止事件"不变量。
@MainActor
final class CodexRuntimeTests: XCTestCase {
    private func makeRuntime(
        process: ScriptedLineProcess,
        model: String = "gpt-5.6",
        reasoningEffort: String? = nil,
        resumeThreadID: String? = nil
    ) -> CodexRuntime {
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        return CodexRuntime(
            transport: transport,
            configuration: CodexRuntime.Configuration(
                model: model,
                reasoningEffort: reasoningEffort,
                resumeThreadID: resumeThreadID
            )
        )
    }

    /// happy path：文本/推理 delta 映射为 messageDelta/reasoningDelta，turn 结束 → runCompleted。
    /// 同时校验 wire：握手、thread/start（带模型）、turn/start（只带新增用户输入）。
    func testRunStreamsTextAndReasoningThenCompletes() async throws {
        let process = ScriptedLineProcess(script:
            handshakeScript() + threadStartScript() + turnScript(
                deltas: ["你好，", "世界"],
                reasoning: ["让我想想"]
            )
        )
        let runtime = makeRuntime(process: process, reasoningEffort: "high")
        let runID = RunID()
        let request = AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "介绍一下你自己")]
        )

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: request) {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .runStateChanged(runID, .running),
            .reasoningDelta("让我想想"),
            .messageDelta("你好，"),
            .messageDelta("世界"),
            .runCompleted(runID),
        ])

        let sent = process.sentLines
        XCTAssertEqual(lineMethod(of: sent[0]), "initialize")
        XCTAssertEqual(requestID(of: sent[0]), 0)
        XCTAssertEqual(lineMethod(of: sent[1]), "initialized")
        XCTAssertEqual(lineMethod(of: sent[2]), "thread/start")
        XCTAssertEqual(requestID(of: sent[2]), 1)
        XCTAssertEqual(requestParams(of: sent[2])["model"] as? String, "gpt-5.6")
        XCTAssertEqual(lineMethod(of: sent[3]), "turn/start")
        XCTAssertEqual(requestID(of: sent[3]), 2)
        let input = requestParams(of: sent[3])["input"] as? [[String: Any]]
        XCTAssertEqual(input?.first?["text"] as? String, "介绍一下你自己")
        XCTAssertEqual(requestParams(of: sent[3])["effort"] as? String, "high")
    }

    /// turn 失败：服务端消息翻译为 runFailed
    func testFailedTurnMapsToRunFailedWithServerMessage() async throws {
        let process = ScriptedLineProcess(script:
            handshakeScript() + threadStartScript() + turnScript(
                deltas: ["部分回答"],
                finalStatus: "failed",
                finalError: "订阅额度已用尽。"
            )
        )
        let runtime = makeRuntime(process: process)
        let runID = RunID()
        let request = AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "hi")]
        )

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: request) {
            events.append(event)
        }
        XCTAssertEqual(events.last, .runFailed(runID, AgentFailure(message: "订阅额度已用尽。")))
        // 已输出的文本保留，失败仅替换终止事件
        XCTAssertTrue(events.contains(.messageDelta("部分回答")))
    }

    /// 取消：cancel 发送 turn/interrupt，服务端以 interrupted 结束 → runCancelled
    /// 脚本注意：turn 必须保持进行中（不预先回放 turn/completed），
    /// 否则服务端 turn 已结束时 interruptTurn 会因无活动 turn 而不发请求。
    func testCancelInterruptsTurnAndMapsToRunCancelled() async throws {
        let process = ScriptedLineProcess(script:
            handshakeScript() + threadStartScript() + [
                .on("turn/start") { request in
                    [
                        rpcResult(request, result: ["turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                        notification("turn/started", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                        notification("item/agentMessage/delta", ["threadId": "thr_123", "turnId": "turn_456", "itemId": "item_1", "delta": "正在思考"]),
                    ]
                },
                .on("turn/interrupt") { request in
                    [
                        rpcResult(request, result: [:]),
                        notification("turn/completed", [
                            "threadId": "thr_123",
                            "turn": ["id": "turn_456", "status": "interrupted", "items": []],
                        ]),
                    ]
                },
            ]
        )
        let runtime = makeRuntime(process: process)
        let runID = RunID()
        let request = AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "hi")]
        )

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: request) {
            events.append(event)
            if case .messageDelta = event {
                await runtime.cancel(runID: runID)
            }
        }
        XCTAssertEqual(events.last, .runCancelled(runID))

        let interrupt = process.sentLines.last!
        XCTAssertEqual(lineMethod(of: interrupt), "turn/interrupt")
        XCTAssertEqual(requestParams(of: interrupt)["threadId"] as? String, "thr_123")
        XCTAssertEqual(requestParams(of: interrupt)["turnId"] as? String, "turn_456")
    }

    /// turn 完成但没有文本：按 Generic 一致语义失败（noTextFailure）
    func testTurnWithoutTextFailsWithNoTextFailure() async throws {
        let process = ScriptedLineProcess(script:
            handshakeScript() + threadStartScript() + turnScript(deltas: [])
        )
        let runtime = makeRuntime(process: process)
        let runID = RunID()
        let request = AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "hi")]
        )

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: request) {
            events.append(event)
        }
        XCTAssertEqual(events, [
            .runStateChanged(runID, .running),
            .runFailed(runID, AgentFailure(message: "助手没有返回文本内容。")),
        ])
    }

    /// 进程中途退出：传输层错误翻译为 runFailed。
    /// 脚本不预发 turn/completed，保证终止发生在 turn 进行中。
    func testProcessExitMidRunMapsToRunFailed() async throws {
        let process = ScriptedLineProcess(script:
            handshakeScript() + threadStartScript() + [
                .on("turn/start") { request in
                    [
                        rpcResult(request, result: ["turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                        notification("turn/started", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                        notification("item/agentMessage/delta", ["threadId": "thr_123", "turnId": "turn_456", "itemId": "item_1", "delta": "半截"]),
                    ]
                },
            ]
        )
        let runtime = makeRuntime(process: process)
        let runID = RunID()
        let request = AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "hi")]
        )

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: request) {
            events.append(event)
            if case .messageDelta = event {
                process.terminate() // 模拟子进程崩溃
            }
        }
        // runtime 按设计不向调用方抛错：传输层错误翻译为 runFailed 终止事件
        XCTAssertEqual(events.last, .runFailed(
            runID,
            AgentFailure(message: CodexAppServerError.processExited.localizedDescription)
        ))
        XCTAssertTrue(events.contains(.messageDelta("半截")))
    }

    /// 第二次运行复用同一 thread：thread/start 只发一次，turn/start 每次发送
    func testSecondRunReusesThread() async throws {
        let process = ScriptedLineProcess(script:
            handshakeScript() + threadStartScript()
            + turnScript(deltas: ["第一轮"])
            + turnScript(deltas: ["第二轮"])
        )
        let runtime = makeRuntime(process: process)
        let firstRunID = RunID()
        let secondRunID = RunID()

        var firstEvents: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: firstRunID,
            messages: [ChatMessage(role: .user, text: "第一个问题")]
        )) {
            firstEvents.append(event)
        }

        var secondEvents: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: secondRunID,
            messages: [ChatMessage(role: .user, text: "第二个问题")]
        )) {
            secondEvents.append(event)
        }

        XCTAssertEqual(firstEvents, [
            .runStateChanged(firstRunID, .running),
            .messageDelta("第一轮"),
            .runCompleted(firstRunID),
        ])
        XCTAssertEqual(secondEvents, [
            .runStateChanged(secondRunID, .running),
            .messageDelta("第二轮"),
            .runCompleted(secondRunID),
        ])

        let threadStarts = process.sentLines.filter { lineMethod(of: $0) == "thread/start" }
        let turnStarts = process.sentLines.filter { lineMethod(of: $0) == "turn/start" }
        XCTAssertEqual(threadStarts.count, 1)
        XCTAssertEqual(turnStarts.count, 2)
        let secondTurnInput = requestParams(of: turnStarts[1])["input"] as? [[String: Any]]
        XCTAssertEqual(secondTurnInput?.first?["text"] as? String, "第二个问题")
        XCTAssertNil(requestParams(of: turnStarts[1])["effort"])
    }

    /// 续接已持久化的线程：wire 走 thread/resume（而非 thread/start），
    /// 且 onThreadReady 回调携带续接的线程 id（供上层写回会话并持久化）
    func testResumePersistedThreadAndReportsThreadID() async throws {
        var reportedThreadID: String?
        let process = ScriptedLineProcess(script:
            handshakeScript()
            + [
                .on("thread/resume") { request in
                    [rpcResult(request, result: ["thread": ["id": "thr_999", "status": "idle"]])]
                },
            ]
            + turnScript(threadID: "thr_999", deltas: ["续接成功"])
        )
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        let runtime = CodexRuntime(
            transport: transport,
            configuration: CodexRuntime.Configuration(
                model: "gpt-5.6",
                resumeThreadID: "thr_999"
            ),
            onThreadReady: { threadID in
                reportedThreadID = threadID
            }
        )
        let runID = RunID()
        var events: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "继续")]
        )) {
            events.append(event)
        }

        XCTAssertEqual(events.last, .runCompleted(runID))
        XCTAssertEqual(reportedThreadID, "thr_999")
        // wire：续接走 thread/resume 而非 thread/start
        XCTAssertEqual(lineMethod(of: process.sentLines[2]), "thread/resume")
        XCTAssertEqual(requestParams(of: process.sentLines[2])["threadId"] as? String, "thr_999")
        XCTAssertEqual(
            process.sentLines.filter { lineMethod(of: $0) == "thread/start" }.count,
            0
        )
    }

}
