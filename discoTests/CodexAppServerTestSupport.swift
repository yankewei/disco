import Foundation
@testable import disco

// MARK: - app-server 契约测试共用替身

/// 一条脚本步骤：客户端写入的 JSON 行满足 `match` 后，用请求行本身构造回放行
/// （回放可解析请求的 id 以构造正确关联的响应）。
struct ScriptStep {
    let match: (String) -> Bool
    let reply: (String) -> [String]

    /// 匹配指定 method 的请求行
    static func on(_ methodName: String, reply: @escaping (String) -> [String]) -> ScriptStep {
        ScriptStep(match: { requestLine in lineMethod(of: requestLine) == methodName }, reply: reply)
    }

    /// 匹配指定 method，回放固定行
    static func on(_ methodName: String, reply: [String]) -> ScriptStep {
        .on(methodName) { _ in reply }
    }
}

/// 脚本化子进程替身：记录客户端写入的行，按脚本回放服务端行。
/// 内部状态由锁保护（`@unchecked Sendable` 是本测试替身的跨线程取舍），
/// 回放行在消费者注册前先入缓冲，不依赖时序。
final class ScriptedLineProcess: LineProcess, @unchecked Sendable {
    private let state = State()

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var sentLines: [String] = []
        var pendingReplies: [String] = []
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        var terminated = false
    }

    private let script: [ScriptStep]
    private var scriptStepIndex = 0

    init(script: [ScriptStep]) {
        self.script = script
    }

    var isRunning: Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return !state.terminated
    }

    /// 客户端写入的行（含顺序），供测试断言 wire 内容
    var sentLines: [String] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.sentLines
    }

    func start() throws {}

    func sendLine(_ line: String) throws {
        state.lock.lock()
        state.sentLines.append(line)
        var replies: [String] = []
        // 从指针位置向后找第一个匹配的步骤并消费一次（跳过不匹配的，如
        // initialized 通知；同 method 的多个步骤由后续请求行逐个消费）
        for index in scriptStepIndex..<script.count where script[index].match(line) {
            replies.append(contentsOf: script[index].reply(line))
            scriptStepIndex = index + 1
            break
        }
        if state.terminated {
            state.lock.unlock()
            return
        }
        if let continuation = state.continuation {
            for reply in replies {
                continuation.yield(reply)
            }
        } else {
            state.pendingReplies.append(contentsOf: replies)
        }
        state.lock.unlock()
    }

    func receiveLines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            state.lock.lock()
            let buffered = state.pendingReplies
            state.pendingReplies.removeAll()
            state.continuation = continuation
            let terminated = state.terminated
            state.lock.unlock()
            for reply in buffered {
                continuation.yield(reply)
            }
            if terminated {
                continuation.finish()
            }
        }
    }

    /// 模拟进程退出：结束行流（turn 未完成时应触发传输层的 processExited）
    func terminate() {
        state.lock.lock()
        state.terminated = true
        let continuation = state.continuation
        state.lock.unlock()
        continuation?.finish()
    }
}

// MARK: - wire 工具

func parseLine(_ line: String) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]) ?? [:]
}

func lineMethod(of line: String) -> String? {
    parseLine(line)["method"] as? String
}

func requestID(of line: String) -> Int? {
    parseLine(line)["id"] as? Int
}

func requestParams(of line: String) -> [String: Any] {
    (parseLine(line)["params"] as? [String: Any]) ?? [:]
}

/// 构造 JSON-RPC 成功响应（回显请求 id）
func rpcResult(_ requestLine: String, result: [String: Any]) -> String {
    line(["id": requestID(of: requestLine) ?? -1, "result": result])
}

/// 构造 JSON-RPC 错误响应（回显请求 id）
func rpcError(_ requestLine: String, code: Int, message: String) -> String {
    line(["id": requestID(of: requestLine) ?? -1, "error": ["code": code, "message": message]])
}

/// 构造服务端 request（带 id）。客户端必须回复 JSON-RPC error，不能静默忽略。
func serverRequest(_ id: Int, method: String, params: [String: Any] = [:]) -> String {
    line(["id": id, "method": method, "params": params])
}

/// 构造服务端通知（无 id）
func notification(_ method: String, _ params: [String: Any]) -> String {
    line(["method": method, "params": params])
}

func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

// MARK: - 常用契约脚本片段

/// 标准握手脚本：initialize 成功（供测试起点一致）
func handshakeScript() -> [ScriptStep] {
    [
        .on("initialize") { request in
            [rpcResult(request, result: ["userAgent": "codex-cli/0.144.5"])]
        },
    ]
}

/// 标准 thread/start 脚本：返回固定线程 id
func threadStartScript(threadID: String = "thr_123") -> [ScriptStep] {
    [
        .on("thread/start") { request in
            [rpcResult(request, result: ["thread": ["id": threadID, "status": "idle"]])]
        },
    ]
}

/// 标准 turn/start 脚本：先返回 turn，再依次回放 turn/started、若干 delta、turn/completed
func turnScript(
    threadID: String = "thr_123",
    turnID: String = "turn_456",
    deltas: [String] = ["你好，世界"],
    reasoning: [String] = [],
    finalStatus: String = "completed",
    finalError: String? = nil
) -> [ScriptStep] {
    [
        .on("turn/start") { request in
            var lines: [String] = [
                rpcResult(request, result: ["turn": ["id": turnID, "status": "inProgress", "items": []]]),
                notification("turn/started", ["threadId": threadID, "turn": ["id": turnID, "status": "inProgress", "items": []]]),
            ]
            for (index, delta) in reasoning.enumerated() {
                lines.append(notification("item/reasoning/summaryTextDelta", [
                    "threadId": threadID, "turnId": turnID, "itemId": "item_r\(index)", "summaryIndex": index, "delta": delta,
                ]))
            }
            for (index, delta) in deltas.enumerated() {
                lines.append(notification("item/agentMessage/delta", [
                    "threadId": threadID, "turnId": turnID, "itemId": "item_\(index)", "delta": delta,
                ]))
            }
            var turn: [String: Any] = ["id": turnID, "status": finalStatus, "items": []]
            if let finalError {
                turn["error"] = ["message": finalError]
            }
            lines.append(notification("turn/completed", ["threadId": threadID, "turn": turn]))
            return lines
        },
    ]
}
