import Foundation
import XCTest
@testable import disco

// MARK: - 契约测试框架

/// `CodexAppServerTransport` 的契约测试：
/// 用脚本化进程替身回放服务端行，锁定客户端与 `codex app-server` 的 wire 协议。
///
/// 契约来源：`codex app-server generate-json-schema`（本机 codex 0.144.5 生成）。
/// codex 升级后先重新生成 schema 并运行本套件，再根据差异调整字段。
/// 网络/协议细节变化会在这些测试中显式失败，而不是在真实对话中悄悄断掉。
/// 脚本替身与 wire 工具见 `CodexAppServerTestSupport.swift`。

// MARK: - 测试

@MainActor
final class CodexAppServerTransportTests: XCTestCase {
    private let threadID = "thr_123"
    private let turnID = "turn_456"

    /// 握手 + 一次完整 turn 的 happy path：校验 wire 顺序、id 编号与事件映射。
    func testHandshakeThenTurnHappyPath() async throws {
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in
                [rpcResult(request, result: ["userAgent": "codex-cli/0.144.5"])]
            },
            .on("thread/start") { request in
                [rpcResult(request, result: ["thread": ["id": "thr_123", "status": "idle"]])]
            },
            .on("turn/start") { request in
                [
                    rpcResult(request, result: ["turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                    notification("turn/started", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                    notification("item/agentMessage/delta", ["threadId": "thr_123", "turnId": "turn_456", "itemId": "item_1", "delta": "你好，"]),
                    notification("item/reasoning/summaryTextDelta", ["threadId": "thr_123", "turnId": "turn_456", "itemId": "item_2", "summaryIndex": 0, "delta": "让我想想"]),
                    notification("item/agentMessage/delta", ["threadId": "thr_123", "turnId": "turn_456", "itemId": "item_1", "delta": "世界"]),
                    notification("turn/completed", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "completed", "items": []]]),
                ]
            },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }

        try await transport.start()

        // 握手顺序：initialize（id 0）→ initialized 通知（无 id）→ 后续请求
        let handshake = process.sentLines
        XCTAssertEqual(handshake.count, 2)
        XCTAssertEqual(lineMethod(of: handshake[0]), "initialize")
        XCTAssertEqual(requestID(of: handshake[0]), 0)
        XCTAssertEqual(
            requestParams(of: handshake[0])["clientInfo"] as? [String: String],
            ["name": "disco", "title": "Disco", "version": "0.1.0"]
        )
        XCTAssertEqual(lineMethod(of: handshake[1]), "initialized")
        XCTAssertNil(requestID(of: handshake[1]))

        let thread = try await transport.startThread(model: "gpt-5.6", cwd: "/tmp/disco-workspace")
        XCTAssertEqual(thread, threadID)
        let threadStart = process.sentLines[2]
        XCTAssertEqual(requestID(of: threadStart), 1)
        XCTAssertEqual(requestParams(of: threadStart)["model"] as? String, "gpt-5.6")
        XCTAssertEqual(requestParams(of: threadStart)["cwd"] as? String, "/tmp/disco-workspace")

        var events: [CodexTurnEvent] = []
        for try await event in transport.startTurn(threadID: thread, input: "你好", effort: "high") {
            events.append(event)
        }
        XCTAssertEqual(events, [
            .started(turnID: turnID),
            .agentMessageDelta("你好，"),
            .reasoningSummaryDelta("让我想想"),
            .agentMessageDelta("世界"),
            .completed(.completed),
        ])
        let turnStart = process.sentLines[3]
        XCTAssertEqual(requestID(of: turnStart), 2)
        XCTAssertEqual(requestParams(of: turnStart)["threadId"] as? String, threadID)
        let input = requestParams(of: turnStart)["input"] as? [[String: Any]]
        XCTAssertEqual(input?.first?["type"] as? String, "text")
        XCTAssertEqual(input?.first?["text"] as? String, "你好")
        XCTAssertEqual(requestParams(of: turnStart)["effort"] as? String, "high")
    }

    /// 模型目录：model/list 的解析与请求参数
    func testListModelsParsesServerCatalog() async throws {
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in
                [rpcResult(request, result: ["userAgent": "codex-cli/0.144.5"])]
            },
            .on("model/list") { request in
                [
                    rpcResult(request, result: [
                        "data": [
                            [
                                "id": "gpt-5.6",
                                "model": "gpt-5.6",
                                "displayName": "GPT-5.6",
                                "hidden": false,
                                "defaultReasoningEffort": "medium",
                                "supportedReasoningEfforts": [
                                    ["reasoningEffort": "low"],
                                    ["reasoningEffort": "medium"],
                                    ["reasoningEffort": "high"],
                                ],
                            ],
                            ["id": "gpt-4o", "model": "gpt-4o", "displayName": "GPT-4o"],
                        ],
                        "nextCursor": "",
                    ]),
                ]
            },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()

        let models = try await transport.listModels()
        XCTAssertEqual(models, [
            CodexModel(
                id: "gpt-5.6",
                displayName: "GPT-5.6",
                supportedReasoningEfforts: ["low", "medium", "high"],
                defaultReasoningEffort: "medium"
            ),
            CodexModel(id: "gpt-4o", displayName: "GPT-4o"),
        ])
        let modelListParams = requestParams(of: process.sentLines[2])
        XCTAssertEqual(modelListParams["limit"] as? Int, 100)
        XCTAssertEqual(modelListParams["includeHidden"] as? Bool, false)
    }

    /// JSON-RPC error 响应 → rpcError（保留 code 与 message）
    func testRPCErrorResponseThrowsWithCodeAndMessage() async throws {
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in
                [rpcResult(request, result: ["userAgent": "codex-cli/0.144.5"])]
            },
            .on("thread/start") { request in
                [rpcError(request, code: 4100, message: "not allowed")]
            },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()

        do {
            _ = try await transport.startThread(model: "gpt-5.6")
            XCTFail("应当抛出 rpcError")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .rpcError(code: 4100, message: "not allowed"))
        }
    }

    /// turn 失败：turn/completed status == failed 以 .completed(.failed) 结束，不抛错
    func testFailedTurnYieldsFailedStatusWithMessage() async throws {
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in
                [rpcResult(request, result: [:])]
            },
            .on("thread/start") { request in
                [rpcResult(request, result: ["thread": ["id": "thr_123"]])]
            },
            .on("turn/start") { request in
                [
                    rpcResult(request, result: ["turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                    notification("turn/started", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                    notification("turn/completed", ["threadId": "thr_123", "turn": [
                        "id": "turn_456",
                        "status": "failed",
                        "error": ["message": "订阅额度已用尽。"],
                        "items": [],
                    ]]),
                ]
            },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()
        _ = try await transport.startThread(model: "gpt-5.6")

        var events: [CodexTurnEvent] = []
        for try await event in transport.startTurn(input: "hi") {
            events.append(event)
        }
        XCTAssertEqual(events.last, .completed(.failed("订阅额度已用尽。")))
    }

    /// 中断：turn/interrupt 携带 threadId + turnId，turn 以 interrupted 结束
    func testInterruptSendsTurnInterruptAndFinishesInterrupted() async throws {
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in
                [rpcResult(request, result: [:])]
            },
            .on("thread/start") { request in
                [rpcResult(request, result: ["thread": ["id": "thr_123"]])]
            },
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
                    notification("turn/completed", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "interrupted", "items": []]]),
                ]
            },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()
        _ = try await transport.startThread(model: "gpt-5.6")

        var events: [CodexTurnEvent] = []
        for try await event in transport.startTurn(input: "hi") {
            events.append(event)
            if events.count == 2 {
                try await transport.interruptTurn()
            }
        }
        XCTAssertEqual(events.last, .completed(.interrupted))

        let interruptParams = requestParams(of: process.sentLines.last!)
        XCTAssertEqual(interruptParams["threadId"] as? String, threadID)
        XCTAssertEqual(interruptParams["turnId"] as? String, turnID)
    }

    /// 无关通知（model/rerouted、thread/archived、item/fileChange/outputDelta）被忽略
    func testUnrelatedNotificationsAreIgnored() async throws {
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in
                [rpcResult(request, result: [:])]
            },
            .on("thread/start") { request in
                [rpcResult(request, result: ["thread": ["id": "thr_123"]])]
            },
            .on("turn/start") { request in
                [
                    rpcResult(request, result: ["turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                    notification("thread/archived", ["threadId": "thr_123"]),
                    notification("item/fileChange/outputDelta", ["threadId": "thr_123", "turnId": "turn_456", "itemId": "item_9", "output": "---"]),
                    notification("turn/started", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                    notification("model/rerouted", ["threadId": "thr_123", "turnId": "turn_456", "fromModel": "a", "toModel": "b", "reason": "x"]),
                    notification("item/agentMessage/delta", ["threadId": "thr_123", "turnId": "turn_456", "itemId": "item_1", "delta": "只有这个"]),
                    notification("turn/completed", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "completed", "items": []]]),
                ]
            },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()
        _ = try await transport.startThread(model: "gpt-5.6")

        var events: [CodexTurnEvent] = []
        for try await event in transport.startTurn(input: "hi") {
            events.append(event)
        }
        XCTAssertEqual(events, [
            .started(turnID: turnID),
            .agentMessageDelta("只有这个"),
            .completed(.completed),
        ])
    }

    /// 进程中途退出：活动 turn 抛 processExited
    func testProcessExitMidTurnThrows() async throws {
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in
                [rpcResult(request, result: [:])]
            },
            .on("thread/start") { request in
                [rpcResult(request, result: ["thread": ["id": "thr_123"]])]
            },
            .on("turn/start") { request in
                [
                    rpcResult(request, result: ["turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                    notification("turn/started", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                    notification("item/agentMessage/delta", ["threadId": "thr_123", "turnId": "turn_456", "itemId": "item_1", "delta": "半截"]),
                ]
            },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()
        _ = try await transport.startThread(model: "gpt-5.6")

        var received: [CodexTurnEvent] = []
        do {
            for try await event in transport.startTurn(input: "hi") {
                received.append(event)
                if received.count == 2 {
                    process.terminate() // 模拟子进程崩溃/退出
                }
            }
            XCTFail("进程退出应当抛错")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .processExited)
        }
        XCTAssertEqual(received.count, 2)
    }

    /// 握手前调用会话方法 → notInitialized
    func testRequestBeforeHandshakeThrowsNotInitialized() async throws {
        let transport = CodexAppServerTransport(
            process: ScriptedLineProcess(script: []),
            configuration: .standard()
        )
        defer { transport.stop() }
        do {
            _ = try await transport.startThread(model: "gpt-5.6")
            XCTFail("应当抛出 notInitialized")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .notInitialized)
        }

        var turnEvents: [CodexTurnEvent] = []
        do {
            for try await event in transport.startTurn(input: "hi") {
                turnEvents.append(event)
            }
            XCTFail("应当抛出 notInitialized")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .notInitialized)
        }
    }

    /// 重复握手 → alreadyInitialized
    func testSecondStartThrowsAlreadyInitialized() async throws {
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in
                [rpcResult(request, result: [:])]
            },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()
        do {
            try await transport.start()
            XCTFail("应当抛出 alreadyInitialized")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .alreadyInitialized)
        }
    }

    /// 同一时刻只允许一个活动 turn：第二次 startTurn 立即失败且不再发 turn/start
    func testConcurrentTurnStartIsRejected() async throws {
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in
                [rpcResult(request, result: [:])]
            },
            .on("thread/start") { request in
                [rpcResult(request, result: ["thread": ["id": "thr_123"]])]
            },
            .on("turn/start") { request in
                [
                    rpcResult(request, result: ["turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                    notification("turn/started", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                    notification("turn/completed", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "completed", "items": []]]),
                ]
            },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()
        _ = try await transport.startThread(model: "gpt-5.6")

        let first = transport.startTurn(input: "a")
        let second = transport.startTurn(input: "b")

        do {
            for try await _ in second {}
            XCTFail("第二次 startTurn 应当失败")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .turnAlreadyInProgress)
        }

        var events: [CodexTurnEvent] = []
        for try await event in first {
            events.append(event)
        }
        XCTAssertEqual(events, [.started(turnID: turnID), .completed(.completed)])
        // turn/start 只发出一次
        let turnStartCount = process.sentLines
            .filter { lineMethod(of: $0) == "turn/start" }
            .count
        XCTAssertEqual(turnStartCount, 1)
    }

    /// account/read：ChatGPT 订阅登录态（含邮箱与计划）
    func testAccountStatusParsesChatGPTSubscription() async throws {
        let process = ScriptedLineProcess(script:
            handshakeScript() + [
                .on("account/read") { request in
                    [
                        rpcResult(request, result: [
                            "requiresOpenaiAuth": false,
                            "account": [
                                "type": "chatgpt",
                                "email": "me@example.com",
                                "planType": "plus",
                            ],
                        ]),
                    ]
                },
            ]
        )
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()

        let status = try await transport.accountStatus()
        XCTAssertEqual(
            status,
            CodexAccountStatus(kind: .chatgpt(email: "me@example.com", planType: "plus"), requiresOpenAI: false)
        )
        XCTAssertTrue(status.isSignedIn)
        // sentLines: [0]=initialize, [1]=initialized 通知, [2]=account/read
        XCTAssertEqual(lineMethod(of: process.sentLines[2]), "account/read")
        XCTAssertEqual(requestID(of: process.sentLines[2]), 1)
    }

    /// account/read：account 缺失 → 未登录
    func testAccountStatusSignedOutWhenAccountMissing() async throws {
        let process = ScriptedLineProcess(script:
            handshakeScript() + [
                .on("account/read") { request in
                    [
                        rpcResult(request, result: [
                            "requiresOpenaiAuth": true,
                            "account": NSNull(),
                        ]),
                    ]
                },
            ]
        )
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()

        let status = try await transport.accountStatus()
        XCTAssertEqual(
            status,
            CodexAccountStatus(kind: .signedOut, requiresOpenAI: true)
        )
        XCTAssertFalse(status.isSignedIn)
    }

    /// account/read：API Key 模式
    func testAccountStatusApiKeyMode() async throws {
        let process = ScriptedLineProcess(script:
            handshakeScript() + [
                .on("account/read") { request in
                    [
                        rpcResult(request, result: [
                            "requiresOpenaiAuth": false,
                            "account": ["type": "apiKey"],
                        ]),
                    ]
                },
            ]
        )
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()

        let status = try await transport.accountStatus()
        XCTAssertEqual(status, CodexAccountStatus(kind: .apiKey, requiresOpenAI: false))
        XCTAssertTrue(status.isSignedIn)
    }

    /// thread/resume：续接已持久化的会话线程（重启恢复上下文）
    func testStartThreadResumesExistingThread() async throws {
        let process = ScriptedLineProcess(script:
            handshakeScript() + [
                .on("thread/resume") { request in
                    [rpcResult(request, result: ["thread": ["id": "thr_999", "status": "idle"]])]
                },
            ]
        )
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()

        let threadID = try await transport.startThread(
            model: "gpt-5.6",
            resumeThreadID: "thr_999",
            cwd: "/tmp/disco-workspace"
        )
        XCTAssertEqual(threadID, "thr_999")
        // sentLines: [0]=initialize, [1]=initialized 通知, [2]=thread/resume
        XCTAssertEqual(lineMethod(of: process.sentLines[2]), "thread/resume")
        XCTAssertEqual(requestParams(of: process.sentLines[2])["threadId"] as? String, "thr_999")
        XCTAssertEqual(requestParams(of: process.sentLines[2])["cwd"] as? String, "/tmp/disco-workspace")
    }

    /// 一条连接可承载多个 thread；事件按 threadId 路由，互不覆盖。
    func testOneConnectionCanRunMultipleThreads() async throws {
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in [rpcResult(request, result: [:])] },
            .on("thread/start") { request in
                let id = requestID(of: request) == 1 ? "thr_a" : "thr_b"
                return [rpcResult(request, result: ["thread": ["id": id]])]
            },
            .on("thread/start") { request in
                let id = requestID(of: request) == 1 ? "thr_a" : "thr_b"
                return [rpcResult(request, result: ["thread": ["id": id]])]
            },
            .on("turn/start") { request in
                let threadID = requestParams(of: request)["threadId"] as? String ?? ""
                let turnID = threadID == "thr_a" ? "turn_a" : "turn_b"
                return [
                    rpcResult(request, result: ["turn": ["id": turnID, "status": "inProgress", "items": []]]),
                    notification("turn/started", ["threadId": threadID, "turn": ["id": turnID, "status": "inProgress", "items": []]]),
                    notification("item/agentMessage/delta", ["threadId": threadID, "turnId": turnID, "itemId": "item_1", "delta": threadID]),
                    notification("turn/completed", ["threadId": threadID, "turn": ["id": turnID, "status": "completed", "items": []]]),
                ]
            },
            .on("turn/start") { request in
                let threadID = requestParams(of: request)["threadId"] as? String ?? ""
                let turnID = threadID == "thr_a" ? "turn_a" : "turn_b"
                return [
                    rpcResult(request, result: ["turn": ["id": turnID, "status": "inProgress", "items": []]]),
                    notification("turn/started", ["threadId": threadID, "turn": ["id": turnID, "status": "inProgress", "items": []]]),
                    notification("item/agentMessage/delta", ["threadId": threadID, "turnId": turnID, "itemId": "item_1", "delta": threadID]),
                    notification("turn/completed", ["threadId": threadID, "turn": ["id": turnID, "status": "completed", "items": []]]),
                ]
            },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()

        let firstThread = try await transport.startThread(model: "gpt-5.6")
        let secondThread = try await transport.startThread(model: "gpt-5.6")
        XCTAssertEqual(firstThread, "thr_a")
        XCTAssertEqual(secondThread, "thr_b")

        var firstEvents: [CodexTurnEvent] = []
        for try await event in transport.startTurn(threadID: firstThread, input: "a") {
            firstEvents.append(event)
        }
        var secondEvents: [CodexTurnEvent] = []
        for try await event in transport.startTurn(threadID: secondThread, input: "b") {
            secondEvents.append(event)
        }
        XCTAssertEqual(firstEvents, [.started(turnID: "turn_a"), .agentMessageDelta("thr_a"), .completed(.completed)])
        XCTAssertEqual(secondEvents, [.started(turnID: "turn_b"), .agentMessageDelta("thr_b"), .completed(.completed)])
    }

    /// item 生命周期被消费为核心事件，但 item 内容本身仍不执行。
    func testItemLifecycleEventsAreRouted() async throws {
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in [rpcResult(request, result: [:])] },
            .on("thread/start") { request in [rpcResult(request, result: ["thread": ["id": "thr_123"]])] },
            .on("turn/start") { request in
                [
                    rpcResult(request, result: ["turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                    notification("turn/started", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "inProgress", "items": []]]),
                    notification("item/started", ["threadId": "thr_123", "turnId": "turn_456", "startedAtMs": 1, "item": ["id": "item_1", "type": "agentMessage", "text": ""]]),
                    notification("item/completed", ["threadId": "thr_123", "turnId": "turn_456", "completedAtMs": 2, "item": ["id": "item_1", "type": "agentMessage", "text": "done"]]),
                    notification("turn/completed", ["threadId": "thr_123", "turn": ["id": "turn_456", "status": "completed", "items": []]]),
                ]
            },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()
        let threadID = try await transport.startThread(model: "gpt-5.6")

        var events: [CodexTurnEvent] = []
        for try await event in transport.startTurn(threadID: threadID, input: "hi") {
            events.append(event)
        }
        XCTAssertEqual(events, [
            .started(turnID: "turn_456"),
            .itemStarted(itemID: "item_1", itemType: "agentMessage"),
            .itemCompleted(itemID: "item_1", itemType: "agentMessage"),
            .completed(.completed),
        ])
    }

    /// 服务端 request（审批/工具）返回明确的 JSON-RPC method-not-found，避免永久阻塞。
    func testUnsupportedServerRequestGetsExplicitError() async throws {
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in [rpcResult(request, result: [:])] },
            .on("thread/start") { request in
                [
                    serverRequest(99, method: "item/tool/call"),
                    rpcResult(request, result: ["thread": ["id": "thr_123"]]),
                ]
            },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: .standard())
        defer { transport.stop() }
        try await transport.start()
        _ = try await transport.startThread(model: "gpt-5.6")

        let response = process.sentLines.first { requestID(of: $0) == 99 }
        XCTAssertEqual(response.flatMap { parseLine($0)["error"] as? [String: Any] }?["code"] as? Int, -32601)
        XCTAssertEqual(response.flatMap { parseLine($0)["id"] as? Int }, 99)
    }

    /// 服务器不响应时请求必须在有限时间内结束。
    func testRequestTimeoutDoesNotHang() async throws {
        let standard = CodexAppServerTransport.Configuration.standard()
        let configuration = CodexAppServerTransport.Configuration(
            executableURL: standard.executableURL,
            arguments: standard.arguments,
            clientInfo: standard.clientInfo,
            requestTimeout: .milliseconds(10)
        )
        let process = ScriptedLineProcess(script: [
            .on("initialize") { request in [rpcResult(request, result: [:])] },
        ])
        let transport = CodexAppServerTransport(process: process, configuration: configuration)
        defer { transport.stop() }
        try await transport.start()

        do {
            _ = try await transport.startThread(model: "gpt-5.6")
            XCTFail("应当超时")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .requestTimedOut("thread/start"))
        }
    }

    /// 进程退出后，下一次 start 会创建新进程并重新握手；已有 thread 由调用方 resume。
    func testProcessExitCanReconnectAndResumeThread() async throws {
        let first = ScriptedLineProcess(script: [
            .on("initialize") { request in [rpcResult(request, result: [:])] },
            .on("thread/start") { request in [rpcResult(request, result: ["thread": ["id": "thr_123"]])] },
            .on("turn/start") { request in
                [
                    rpcResult(request, result: ["turn": ["id": "turn_1", "status": "inProgress", "items": []]]),
                    notification("turn/started", ["threadId": "thr_123", "turn": ["id": "turn_1", "status": "inProgress", "items": []]]),
                    notification("item/agentMessage/delta", ["threadId": "thr_123", "turnId": "turn_1", "itemId": "item_1", "delta": "半截"]),
                ]
            },
        ])
        let second = ScriptedLineProcess(script: [
            .on("initialize") { request in [rpcResult(request, result: [:])] },
            .on("thread/resume") { request in [rpcResult(request, result: ["thread": ["id": "thr_123"]])] },
            .on("turn/start") { request in
                [
                    rpcResult(request, result: ["turn": ["id": "turn_2", "status": "inProgress", "items": []]]),
                    notification("turn/started", ["threadId": "thr_123", "turn": ["id": "turn_2", "status": "inProgress", "items": []]]),
                    notification("item/agentMessage/delta", ["threadId": "thr_123", "turnId": "turn_2", "itemId": "item_1", "delta": "恢复"]),
                    notification("turn/completed", ["threadId": "thr_123", "turn": ["id": "turn_2", "status": "completed", "items": []]]),
                ]
            },
        ])
        var processes: [ScriptedLineProcess] = [first, second]
        let transport = CodexAppServerTransport(
            processFactory: { processes.removeFirst() },
            configuration: .standard()
        )
        defer { transport.stop() }
        try await transport.start()
        let threadID = try await transport.startThread(model: "gpt-5.6")

        do {
            for try await event in transport.startTurn(threadID: threadID, input: "hi") {
                if case .agentMessageDelta = event { first.terminate() }
            }
            XCTFail("进程退出应当结束当前 turn")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .processExited)
        }

        try await transport.start()
        let resumedThreadID = try await transport.startThread(model: "gpt-5.6", resumeThreadID: threadID)
        XCTAssertEqual(resumedThreadID, threadID)
        var events: [CodexTurnEvent] = []
        for try await event in transport.startTurn(threadID: threadID, input: "继续") {
            events.append(event)
        }
        XCTAssertEqual(events.last, .completed(.completed))
        XCTAssertTrue(second.sentLines.contains { lineMethod(of: $0) == "thread/resume" })
    }
}
