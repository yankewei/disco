import Foundation

// MARK: - Daemon 协议 DTO（对应 Rust disco-protocol crate）

/// 动态 JSON 值，用于协议中不确定 schema 的字段。
/// 复用 CodexJSONValue 的模式，不依赖第三方库。
enum DaemonJSONValue: Codable, Sendable, Equatable {
    case object([String: DaemonJSONValue])
    case array([DaemonJSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                self = .null
                return
            }
            if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
                return
            }
            if let value = try? container.decode(Double.self) {
                self = .number(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
        }

        if var container = try? decoder.unkeyedContainer() {
            var values: [DaemonJSONValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(DaemonJSONValue.self))
            }
            self = .array(values)
            return
        }

        let container = try decoder.container(keyedBy: DaemonDynamicCodingKey.self)
        var values: [String: DaemonJSONValue] = [:]
        for key in container.allKeys {
            values[key.stringValue] = try container.decode(DaemonJSONValue.self, forKey: key)
        }
        self = .object(values)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .object(values):
            var container = encoder.container(keyedBy: DaemonDynamicCodingKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: DaemonDynamicCodingKey(stringValue: key))
            }
        case let .array(values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .boolean(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    /// 将动态 JSON 解码为具体类型。
    /// 注意：此方法使用无 key 策略的 encoder/decoder，因为 DaemonJSONValue
    /// 的 object key 已在外层解码时由 .convertFromSnakeCase 转换过。
    func decoded<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    var objectValue: [String: DaemonJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}

private struct DaemonDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

// MARK: - RPC 信封

/// 请求信封（客户端 → 守护进程）。
/// 对应 Rust `Request { id, method, params }`。
struct DaemonRPCRequest<Params: Encodable>: Encodable, Sendable {
    let id: Int
    let method: String
    let params: Params?
}

/// 响应信封（守护进程 → 客户端）。
/// 对应 Rust `Response { id, result?, error? }`。
struct DaemonRPCResponse: Decodable, Sendable {
    let id: Int
    let result: DaemonJSONValue?
    let error: DaemonRPCError?
}

/// 事件信封（守护进程 → 客户端）。
/// 对应 Rust `Event { event, data }`。
struct DaemonEventEnvelope: Decodable, Sendable {
    let event: String
    let data: DaemonJSONValue
}

/// 服务端错误载荷。
struct DaemonRPCError: Codable, Sendable, Equatable {
    let code: Int
    let message: String
}

// MARK: - 初始化

struct DaemonClientInfo: Encodable, Sendable {
    let name: String
    let version: String
}

struct DaemonInitializeParams: Encodable, Sendable {
    let clientInfo: DaemonClientInfo
    let protocolVersion: String
}

struct DaemonInitializeResult: Decodable, Sendable {
    let daemonVersion: String?
    let protocolVersion: String?
}

// MARK: - 运行（Phase 1 最小集）

struct DaemonRunStartParams: Encodable, Sendable {
    let sessionId: String
    let text: String
}

struct DaemonRunStartResult: Decodable, Sendable {
    let runId: String
}

struct DaemonRunCancelParams: Encodable, Sendable {
    let runId: String
}

struct DaemonRunCancelResult: Decodable, Sendable {}

// MARK: - 服务商配置（Phase 2）

/// 配置一个服务商（API Key、Base URL、模型等）。
struct DaemonProviderConfigureParams: Codable, Sendable {
    let providerId: String
    let vendor: String
    let baseUrl: String
    let apiKey: String
    let model: String
    let thinkingEnabled: Bool
}

/// 守护进程返回的服务商条目（不含 API Key 明文）。
struct DaemonProviderEntry: Codable, Sendable {
    let providerId: String
    let vendor: String
    let baseUrl: String
    let model: String
    let thinkingEnabled: Bool
}

/// `provider/list` 返回结果。
struct DaemonProviderListResult: Codable, Sendable {
    let providers: [DaemonProviderEntry]
}

// MARK: - 会话管理

struct DaemonSessionCreateParams: Codable, Sendable {
    let sessionId: String
    let projectId: String
    let providerId: String
    let vendor: String
    let model: String
}

struct DaemonSession: Codable, Sendable {
    let id: String
    let projectId: String
    let providerId: String
    let vendor: String
    let model: String
    let createdAt: String
    let updatedAt: String
    let title: String?
}

struct DaemonSessionCreateResult: Codable, Sendable {
    let session: DaemonSession
}

/// `session/list` 返回结果。
struct DaemonSessionListParams: Codable, Sendable {
    let projectId: String
}

struct DaemonSessionListResult: Codable, Sendable {
    let sessions: [DaemonSession]
}

/// `session/messages` 返回的会话消息（daemon 权威历史）。
struct DaemonSessionMessage: Codable, Sendable {
    let id: String
    let role: String
    let text: String
    let createdAt: String
}

/// `session/messages` 参数与结果。
struct DaemonSessionMessagesParams: Codable, Sendable {
    let sessionId: String
}

struct DaemonSessionMessagesResult: Codable, Sendable {
    let messages: [DaemonSessionMessage]
}

/// `session/delete` 参数。
struct DaemonSessionDeleteParams: Codable, Sendable {
    let sessionId: String
}

// MARK: - 项目管理

struct DaemonProjectCreateParams: Codable, Sendable {
    let projectId: String
    let name: String
    let path: String
}

struct DaemonProject: Codable, Sendable {
    let id: String
    let name: String
    let path: String
    let createdAt: String
}

struct DaemonProjectCreateResult: Codable, Sendable {
    let project: DaemonProject
}

/// `project/list` 返回结果。
struct DaemonProjectListResult: Codable, Sendable {
    let projects: [DaemonProject]
}

// MARK: - 事件数据类型

/// `message.delta` 事件数据：文本内容增量。
struct DaemonMessageDeltaData: Codable, Sendable {
    let runId: String
    let sessionId: String
    let delta: String
}

/// `reasoning.delta` 事件数据：推理内容增量。
struct DaemonReasoningDeltaData: Codable, Sendable {
    let runId: String
    let sessionId: String
    let delta: String
}

/// `context.usage` 事件数据：token 使用量更新。
struct DaemonContextUsageData: Codable, Sendable {
    let runId: String
    let sessionId: String
    let current: DaemonTokenUsage
    let accumulated: DaemonTokenUsage?
    let contextWindow: Int?
    let source: String
}

/// token 使用量明细。
struct DaemonTokenUsage: Codable, Sendable {
    let input: Int
    let output: Int
    let total: Int
    let cachedInput: Int?
    let reasoningOutput: Int?
}

/// `context.compaction` 事件数据：上下文压缩状态。
struct DaemonContextCompactionData: Codable, Sendable {
    let runId: String
    let sessionId: String
    let id: String
    let runtimeKind: String
    let trigger: String
    let status: String
    let startedAt: String?
    let completedAt: String?
    let beforeTokens: Int?
    let afterTokens: Int?
    let errorMessage: String?
}

/// `run.state` 事件数据：运行状态变更。
struct DaemonRunStateData: Codable, Sendable {
    let runId: String
    let sessionId: String
    let state: String
}

// MARK: - 终止事件

/// `run.completed` 事件数据。
struct DaemonRunCompletedData: Codable, Sendable {
    let runId: String
    let sessionId: String
}

/// `run.failed` 事件数据。
struct DaemonRunFailedData: Codable, Sendable {
    let runId: String
    let sessionId: String
    let error: DaemonRunError
}

/// `run.failed` 中的错误码，对应 Rust `ErrorCode` 枚举。
enum DaemonRunErrorCode: String, Codable, Sendable, Equatable {
    case generic
    case noTextOutput = "no_text_output"
    case contextOverflow = "context_overflow"
    case contextCompactionFailed = "context_compaction_failed"
}

/// `run.failed` 中的错误对象。
struct DaemonRunError: Codable, Sendable {
    let code: DaemonRunErrorCode
    let message: String
    let recoverySuggestion: String?
    let retryable: Bool
}

/// `run.cancelled` 事件数据。
struct DaemonRunCancelledData: Codable, Sendable {
    let runId: String
    let sessionId: String
}

// MARK: - 上下文压缩（Phase 2）

/// `run/compact` 参数。
struct DaemonRunCompactParams: Codable, Sendable {
    let sessionId: String
}

// MARK: - 工具执行事件

/// `tool.started` 事件数据：工具即将开始执行。
struct DaemonToolStartedData: Codable, Sendable {
    let runId: String
    let sessionId: String
    let toolCallId: String
    let toolName: String
    let arguments: String  // JSON 字符串
}

/// `tool.completed` 事件数据：工具执行完成。
struct DaemonToolCompletedData: Codable, Sendable {
    let runId: String
    let sessionId: String
    let toolCallId: String
    let toolName: String
    let output: String
}

// MARK: - 审批事件

/// `approval.requested` 事件数据：Agent 需要用户确认后才能执行工具。
struct DaemonApprovalRequestedData: Codable, Sendable {
    let runId: String
    let sessionId: String
    let approvalId: String
    let kind: String  // "command", "file_change", "network", "permission"
    let title: String
    let reason: String?
    let impact: DaemonApprovalImpact
    let fingerprint: String
    let allowsSessionApproval: Bool
}

/// 审批请求的影响范围详情。
struct DaemonApprovalImpact: Codable, Sendable {
    let type: String  // "command", "file_change", "network", "permission"
    // 命令相关
    let executable: String?
    let arguments: [String]?
    let cwd: String?
    // 文件变更相关
    let paths: [String]?
    let summary: String?
    let diff: String?
    // 网络相关
    let host: String?
    let scheme: String?
    let port: Int?
    // 权限相关
    let scope: String?
    let description: String?
}

/// `approval.resolved` 事件数据：审批已处理。
struct DaemonApprovalResolvedData: Codable, Sendable {
    let runId: String
    let sessionId: String
    let approvalId: String
    let decision: String
}

// MARK: - 审批请求

/// `run/approve` 参数：响应用户审批决定。
struct DaemonRunApproveParams: Codable, Sendable {
    let approvalId: String
    let decision: String  // "approve_once", "approve_for_session", "decline"
}

struct DaemonRunApproveResult: Decodable, Sendable {}

// MARK: - 关闭

struct DaemonShutdownParams: Encodable, Sendable {}

struct DaemonShutdownResult: Decodable, Sendable {}

// MARK: - 守护进程事件

/// 守护进程推送的事件（通知），按 `eventName` 区分类型。
/// 这是 Swift 侧的内部表示，`eventName` 对应协议中的 `event` 字段。
struct DaemonEvent: Sendable, Equatable {
    let eventName: String
    let data: DaemonJSONValue

    /// 解析为具体类型。
    func decoded<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try data.decoded(as: type)
    }

    var sessionID: UUID? {
        guard let fields = data.objectValue,
              let value = (fields["sessionId"] ?? fields["session_id"])?.stringValue else {
            return nil
        }
        return UUID(uuidString: value)
    }

    var runID: UUID? {
        guard let fields = data.objectValue,
              let value = (fields["runId"] ?? fields["run_id"])?.stringValue else {
            return nil
        }
        return UUID(uuidString: value)
    }
}

// MARK: - 错误

enum DaemonError: LocalizedError, Equatable, Sendable {
    case socketCreationFailed
    case connectionFailed(String)
    case notConnected
    case disconnected
    case requestFailed(String)
    case rpcError(code: Int, message: String)
    case invalidResponse(String)
    case requestTimedOut(String)
    case daemonNotFound
    case daemonLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            return "无法创建 Unix 域套接字。"
        case let .connectionFailed(message):
            return "无法连接到守护进程：\(message)"
        case .notConnected:
            return "尚未连接到守护进程。"
        case .disconnected:
            return "守护进程连接已断开。"
        case let .requestFailed(message):
            return "守护进程请求失败：\(message)"
        case let .rpcError(code, message):
            return "守护进程返回错误（\(code)）：\(message)"
        case let .invalidResponse(description):
            return "守护进程响应格式不符合预期：\(description)"
        case let .requestTimedOut(method):
            return "守护进程请求超时：\(method)"
        case .daemonNotFound:
            return "找不到 disco-daemon 可执行文件。"
        case let .daemonLaunchFailed(message):
            return "无法启动守护进程：\(message)"
        }
    }
}
