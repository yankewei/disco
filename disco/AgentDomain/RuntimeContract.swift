import Foundation

/// 一次运行的唯一标识（计划 §8 `cancel(run_id: RunID)`）。
typealias RunID = UUID

/// 一次运行请求（计划 §8 AgentRunRequest）。
/// MVP 只携带消息；系统指令 / 项目上下文在后续迭代加入。
struct AgentRunRequest: Sendable {
    let runID: RunID
    let messages: [ChatMessage]
    /// 续接的 codex thread id（订阅服务商用；API Key 运行时忽略）。
    /// 有值时 thread/resume 而非新建线程，保证重启后上下文不丢失。
    var resumeThreadID: String? = nil
}

/// 统一 Agent 事件（计划 §8 AgentEvent）。
/// Runtime 保证：一次运行恰好发射一个终止事件
/// （runCompleted / runFailed / runCancelled），随后流结束。
enum AgentEvent: Sendable, Equatable {
    case messageDelta(String)
    case reasoningDelta(String)
    case runCompleted(RunID)
    case runFailed(RunID, AgentFailure)
    case runCancelled(RunID)
}

/// 失败信息：Runtime 在边界处把 provider 错误翻译成可展示的 AgentFailure
/// （计划 §8 AgentFailure），UI 层不接触 provider 具体错误类型。
struct AgentFailure: Sendable, Equatable {
    let message: String
}

extension AgentFailure {
    static let noTextOutput = AgentFailure(
        message: "模型没有返回文本内容。请确认所选模型支持 Responses API。"
    )
}

/// 推理循环的所有者（ADR-001：Provider 与 Runtime 是两个正交维度）。
/// Runtime 负责：按会话配置组装 ModelRequest、消费 ModelEvent、
/// 控制取消、把 provider 错误翻译为 AgentFailure、发射统一 Agent 事件。
protocol AgentRuntime: Sendable {
    func start(request: AgentRunRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(runID: RunID) async

    /// 释放运行时持有的资源（如 codex 子进程）。
    /// 会话删除或配置变更替换运行时前调用，避免遗留孤儿进程。
    func shutdown() async
}
