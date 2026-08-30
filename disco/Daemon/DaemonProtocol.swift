import Foundation

// MARK: - Daemon 协议共享 DTO

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

    var numberValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .boolean(value) = self else { return nil }
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
    /// 当前上下文窗口占用；与 current 的单次请求明细分开。
    let contextTokens: Int
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
    let summary: String?
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

/// `run.failed` 中的错误码。
enum DaemonRunErrorCode: String, Codable, Sendable, Equatable {
    case generic
    case noTextOutput = "no_text_output"
    case contextOverflow = "context_overflow"
    case contextCompactionFailed = "context_compaction_failed"
}

/// Agent 通过 daemon 协商出的会话协作模式。
enum ConversationCollaborationMode: String, Codable, Sendable, CaseIterable, Hashable {
    case `default`
    case plan

    var title: String {
        switch self {
        case .default: "Agent"
        case .plan: "Plan"
        }
    }
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

// MARK: - 工具执行事件

/// `tool.started` 事件数据：工具即将开始执行。
struct DaemonToolStartedData: Codable, Sendable {
    let runId: String
    let sessionId: String
    let toolCallId: String
    let toolName: String
    let kind: String?
    let arguments: String  // JSON 字符串
}

/// `tool.completed` 事件数据：工具执行完成。
struct DaemonToolCompletedData: Codable, Sendable {
    let runId: String
    let sessionId: String
    let toolCallId: String
    let toolName: String
    let kind: String?
    let output: String
}

// MARK: - 审批事件

/// `approval.requested` 事件数据：Agent 需要用户确认后才能执行工具。
struct DaemonApprovalRequestedData: Codable, Sendable, Identifiable {
    let runId: String
    let sessionId: String
    let approvalId: String
    let kind: String  // "command", "file_change", "network", "permission"
    let title: String
    let reason: String?
    let impact: DaemonApprovalImpact
    let fingerprint: String
    let allowsSessionApproval: Bool

    var id: String { approvalId }
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
    case notConnected
    case invalidResponse(String)
    case rpcError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "尚未连接到守护进程。"
        case let .invalidResponse(description):
            return "守护进程响应格式不符合预期：\(description)"
        case let .rpcError(code, message):
            return "守护进程返回错误（\(code)）：\(message)"
        }
    }
}
