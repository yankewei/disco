import Foundation

/// Generic Runtime 跨越工具执行 seam 时携带的锁定上下文（计划 G2/G3）。
/// Workspace 在 Runtime 创建时固定，Executor 不从模型 arguments 中接受授权根目录。
struct ToolExecutionContext: Sendable, Equatable {
    let runID: RunID
    let workspace: WorkspaceContext?
}

/// 交给 ToolExecutor 的单个完整调用。Runtime 在跨越 seam 前已经校验：
/// 工具已广告、arguments 是 JSON object、当前响应只有一个客户端工具调用。
struct ToolExecutionRequest: Sendable, Equatable {
    let call: ModelToolCall
    let context: ToolExecutionContext
}

/// 工具的有限结构化结果。`output` 必须已经过 Executor 的大小限制和脱敏；
/// Runtime 只负责编码并回传模型，不解析其业务内容。
struct ToolExecutionResult: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable, Equatable {
        case success
        case failure
        case declined
        case cancelled
        case timedOut = "timed_out"
    }

    let status: Status
    let output: String
    let isTruncated: Bool

    init(status: Status, output: String, isTruncated: Bool = false) {
        self.status = status
        self.output = output
        self.isTruncated = isTruncated
    }
}

/// Generic Runtime 与实际工具实现之间唯一的执行 seam。
/// G2 使用脚本化内存 Adapter；G3 再接独立只读 Tool Host。
protocol ToolExecutor: Sendable {
    var toolDefinitions: [ModelToolDefinition] { get }

    func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult
    func cancel(runID: RunID) async
}

extension ToolExecutor {
    func cancel(runID: RunID) async {}
}
