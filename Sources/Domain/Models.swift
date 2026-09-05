import Foundation

// MARK: - Shared domain values

struct AgentID: RawRepresentable, Codable, Identifiable, Hashable, Sendable {
    let rawValue: String

    static let codex = AgentID(uncheckedValue: "codex")
    static let opencode = AgentID(uncheckedValue: "opencode")
    static let builtInAgents: [AgentID] = [.codex, .opencode]

    init?(rawValue: String) {
        guard rawValue == "codex" || rawValue == "opencode"
            || (rawValue.hasPrefix("acp:") && rawValue.count > 4)
        else { return nil }
        self.rawValue = rawValue
    }

    private init(uncheckedValue: String) {
        rawValue = uncheckedValue
    }

    static func acp(id: String) -> AgentID {
        AgentID(uncheckedValue: "acp:" + id)
    }

    var isACP: Bool { rawValue.hasPrefix("acp:") }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let kind = AgentID(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "未知 Agent：\(value)")
        }
        self = kind
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .codex:
            "Codex"
        case .opencode:
            "OpenCode"
        default:
            String(rawValue.dropFirst(4))
        }
    }

    var iconAssetName: String {
        switch self {
        case .codex:
            "CodexIcon"
        case .opencode:
            "OpenCodeIcon"
        default:
            ""
        }
    }

    var cliDescription: String {
        switch self {
        case .codex:
            "OpenAI Codex CLI"
        case .opencode:
            "OpenCode CLI"
        default:
            "ACP Agent"
        }
    }
}

enum RunMode: String, Codable {
    case agent
    case plan
}

enum ApprovalDecision: String, Codable {
    case approved
    case denied
}

enum RunStatus: String, Codable {
    case completed
    case cancelled
    case failed
}

enum ToolCallStatus: String, Codable {
    case started
    case completed
    case failed
}

enum MessageItemState: String, Codable {
    case started
    case updated
    case completed
    case failed
}

enum SandboxMode: String, Codable, CaseIterable, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"
}

enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra
    case persistent
}

let defaultSandboxMode = SandboxMode.workspaceWrite

struct ProjectInfo: Codable, Identifiable, Hashable {
    var id: String {
        projectID
    }

    let projectID: String
    var name: String
    var projectPath: String
    let createdAt: String
    var activatedAt: String?
}

struct SessionInfo: Codable, Identifiable, Hashable {
    var id: String {
        sessionID
    }

    let sessionID: String
    let projectID: String
    var agent: AgentID
    var modelID: String?
    var reasoningEffort: ReasoningEffort?
    var sandboxMode: SandboxMode?
    var agentThreadID: String?
    var title: String
    let createdAt: String
    var activatedAt: String?
}

struct LastAgentSelection: Codable, Hashable {
    var agent: AgentID
    var modelID: String?
    var reasoningEffort: ReasoningEffort?
}

struct ModelInfo: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var reasoningEfforts: [ReasoningEffort]?
}

struct ProviderInfo: Identifiable, Hashable {
    let kind: AgentID
    let available: Bool
    let detail: String
    let version: String?
    let executablePath: String?
    let supportsPlan: Bool
    let isLoadingModels: Bool
    var models: [ModelInfo]
    let modelLoadFailureDescription: String?
    var configuredName: String? = nil

    var displayName: String { configuredName ?? kind.displayName }

    var id: AgentID {
        kind
    }
}

struct FileChange: Codable, Hashable {
    let path: String
    let kind: ChangeKind
    let diff: String?

    enum ChangeKind: String, Codable {
        case add
        case delete
        case update
    }
}

struct TodoEntry: Codable, Hashable {
    let text: String
    let completed: Bool
}

// MARK: - JSON values

enum JSONValue: Codable, Hashable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "不支持的 JSON 值"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .boolean(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }

    func prettyPrinted() -> String {
        guard JSONSerialization.isValidJSONObject(jsonObjectRepresentation) else {
            return stringValue ?? ""
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: jsonObjectRepresentation,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return stringValue ?? ""
        }
        return text
    }

    private var jsonObjectRepresentation: Any {
        switch self {
        case let .object(value):
            value.mapValues(\JSONValue.jsonObjectRepresentation)
        case let .array(value):
            value.map(\JSONValue.jsonObjectRepresentation)
        case let .string(value):
            value
        case let .number(value):
            value
        case let .boolean(value):
            value
        case .null:
            NSNull()
        }
    }
}

// MARK: - Normalized messages

enum MessageItem: Codable, Identifiable, Hashable {
    case text(id: String, text: String, state: MessageItemState)
    case reasoning(id: String, text: String, state: MessageItemState)
    case toolCall(
        id: String,
        name: String,
        input: JSONValue?,
        output: String?,
        error: String?,
        state: ToolCallStatus
    )
    case commandExecution(
        id: String,
        command: String,
        output: String,
        processID: String?,
        exitCode: Int?,
        durationMs: Int?,
        terminalInput: String?,
        state: MessageItemState
    )
    case fileChange(
        id: String,
        changes: [FileChange],
        patchOutput: String?,
        state: MessageItemState
    )
    case mcpToolCall(
        id: String,
        server: String,
        tool: String,
        arguments: JSONValue,
        result: JSONValue?,
        error: String?,
        progress: [String]?,
        state: MessageItemState
    )
    case webSearch(id: String, query: String, state: MessageItemState)
    case todoList(id: String, items: [TodoEntry], state: MessageItemState)
    case notice(id: String, message: String, state: MessageItemState)
    case error(id: String, message: String, state: MessageItemState)
    // Kept for decoding messages persisted by older versions. New protocol events are not emitted as chat items.
    case codexEvent(
        id: String,
        eventType: String,
        payload: [String: JSONValue],
        state: MessageItemState
    )

    var id: String {
        switch self {
        case let .text(id, _, _), let .reasoning(id, _, _), let .webSearch(id, _, _),
             let .todoList(id, _, _), let .notice(id, _, _), let .error(id, _, _):
            id
        case let .toolCall(id, _, _, _, _, _), let .commandExecution(id, _, _, _, _, _, _, _),
             let .fileChange(id, _, _, _), let .mcpToolCall(id, _, _, _, _, _, _, _),
             let .codexEvent(id, _, _, _):
            id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case text
        case state
        case name
        case input
        case output
        case error
        case command
        case processID = "processId"
        case exitCode
        case durationMs
        case terminalInput
        case changes
        case patchOutput
        case server
        case tool
        case arguments
        case result
        case progress
        case query
        case items
        case message
        case eventType
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let id = try container.decode(String.self, forKey: .id)
        switch type {
        case "text":
            self = try .text(
                id: id,
                text: container.decode(String.self, forKey: .text),
                state: container.decode(MessageItemState.self, forKey: .state)
            )
        case "reasoning":
            self = try .reasoning(
                id: id,
                text: container.decode(String.self, forKey: .text),
                state: container.decode(MessageItemState.self, forKey: .state)
            )
        case "tool_call":
            self = try .toolCall(
                id: id,
                name: container.decode(String.self, forKey: .name),
                input: container.decodeIfPresent(JSONValue.self, forKey: .input),
                output: container.decodeIfPresent(String.self, forKey: .output),
                error: container.decodeIfPresent(String.self, forKey: .error),
                state: container.decode(ToolCallStatus.self, forKey: .state)
            )
        case "command_execution":
            self = try .commandExecution(
                id: id,
                command: container.decode(String.self, forKey: .command),
                output: container.decode(String.self, forKey: .output),
                processID: container.decodeIfPresent(String.self, forKey: .processID),
                exitCode: container.decodeIfPresent(Int.self, forKey: .exitCode),
                durationMs: container.decodeIfPresent(Int.self, forKey: .durationMs),
                terminalInput: container.decodeIfPresent(String.self, forKey: .terminalInput),
                state: container.decode(MessageItemState.self, forKey: .state)
            )
        case "file_change":
            self = try .fileChange(
                id: id,
                changes: container.decode([FileChange].self, forKey: .changes),
                patchOutput: container.decodeIfPresent(String.self, forKey: .patchOutput),
                state: container.decode(MessageItemState.self, forKey: .state)
            )
        case "mcp_tool_call":
            self = try .mcpToolCall(
                id: id,
                server: container.decode(String.self, forKey: .server),
                tool: container.decode(String.self, forKey: .tool),
                arguments: container.decode(JSONValue.self, forKey: .arguments),
                result: container.decodeIfPresent(JSONValue.self, forKey: .result),
                error: container.decodeIfPresent(String.self, forKey: .error),
                progress: container.decodeIfPresent([String].self, forKey: .progress),
                state: container.decode(MessageItemState.self, forKey: .state)
            )
        case "web_search":
            self = try .webSearch(
                id: id,
                query: container.decode(String.self, forKey: .query),
                state: container.decode(MessageItemState.self, forKey: .state)
            )
        case "todo_list":
            self = try .todoList(
                id: id,
                items: container.decode([TodoEntry].self, forKey: .items),
                state: container.decode(MessageItemState.self, forKey: .state)
            )
        case "notice":
            self = try .notice(
                id: id,
                message: container.decode(String.self, forKey: .message),
                state: container.decode(MessageItemState.self, forKey: .state)
            )
        case "error":
            self = try .error(
                id: id,
                message: container.decode(String.self, forKey: .message),
                state: container.decode(MessageItemState.self, forKey: .state)
            )
        case "codex_event":
            self = try .codexEvent(
                id: id,
                eventType: container.decode(String.self, forKey: .eventType),
                payload: container.decode([String: JSONValue].self, forKey: .payload),
                state: container.decode(MessageItemState.self, forKey: .state)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "未知消息项类型：\(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        switch self {
        case let .text(_, text, state):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(state, forKey: .state)
        case let .reasoning(_, text, state):
            try container.encode("reasoning", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(state, forKey: .state)
        case let .toolCall(_, name, input, output, error, state):
            try container.encode("tool_call", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(input, forKey: .input)
            try container.encodeIfPresent(output, forKey: .output)
            try container.encodeIfPresent(error, forKey: .error)
            try container.encode(state, forKey: .state)
        case let .commandExecution(_, command, output, processID, exitCode, durationMs, terminalInput, state):
            try container.encode("command_execution", forKey: .type)
            try container.encode(command, forKey: .command)
            try container.encode(output, forKey: .output)
            try container.encodeIfPresent(processID, forKey: .processID)
            try container.encodeIfPresent(exitCode, forKey: .exitCode)
            try container.encodeIfPresent(durationMs, forKey: .durationMs)
            try container.encodeIfPresent(terminalInput, forKey: .terminalInput)
            try container.encode(state, forKey: .state)
        case let .fileChange(_, changes, patchOutput, state):
            try container.encode("file_change", forKey: .type)
            try container.encode(changes, forKey: .changes)
            try container.encodeIfPresent(patchOutput, forKey: .patchOutput)
            try container.encode(state, forKey: .state)
        case let .mcpToolCall(_, server, tool, arguments, result, error, progress, state):
            try container.encode("mcp_tool_call", forKey: .type)
            try container.encode(server, forKey: .server)
            try container.encode(tool, forKey: .tool)
            try container.encode(arguments, forKey: .arguments)
            try container.encodeIfPresent(result, forKey: .result)
            try container.encodeIfPresent(error, forKey: .error)
            try container.encodeIfPresent(progress, forKey: .progress)
            try container.encode(state, forKey: .state)
        case let .webSearch(_, query, state):
            try container.encode("web_search", forKey: .type)
            try container.encode(query, forKey: .query)
            try container.encode(state, forKey: .state)
        case let .todoList(_, items, state):
            try container.encode("todo_list", forKey: .type)
            try container.encode(items, forKey: .items)
            try container.encode(state, forKey: .state)
        case let .notice(_, message, state):
            try container.encode("notice", forKey: .type)
            try container.encode(message, forKey: .message)
            try container.encode(state, forKey: .state)
        case let .error(_, message, state):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
            try container.encode(state, forKey: .state)
        case let .codexEvent(_, eventType, payload, state):
            try container.encode("codex_event", forKey: .type)
            try container.encode(eventType, forKey: .eventType)
            try container.encode(payload, forKey: .payload)
            try container.encode(state, forKey: .state)
        }
    }
}

struct ToolCall: Codable, Hashable {
    let id: String
    var name: String
    var status: ToolCallStatus
    var input: JSONValue?
    var output: String?
    var error: String?
}

struct ConversationMessage: Codable, Identifiable, Hashable {
    let id: String
    let role: MessageRole
    var text: String
    var reasoning: String?
    var toolCalls: [ToolCall]?
    var items: [MessageItem]?
    var timeline: [MessageItem]?
    var status: RunStatus?
    var error: String?
    let createdAt: String
    /// 该消息是 Plan 模式的产物（OpenCode 的 `info.mode == "plan"` 或本机记录的计划模式运行），
    /// 用于在界面中渲染为独立的计划卡片。
    var isPlan: Bool
}

extension ConversationMessage {
    private enum CodingKeys: String, CodingKey {
        case id, role, text, reasoning, toolCalls, items, timeline, status, error, createdAt, isPlan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(MessageRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        items = try container.decodeIfPresent([MessageItem].self, forKey: .items)
        timeline = try container.decodeIfPresent([MessageItem].self, forKey: .timeline)
        status = try container.decodeIfPresent(RunStatus.self, forKey: .status)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        isPlan = try container.decodeIfPresent(Bool.self, forKey: .isPlan) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(items, forKey: .items)
        try container.encodeIfPresent(timeline, forKey: .timeline)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isPlan, forKey: .isPlan)
    }
}

enum MessageRole: String, Codable {
    case user
    case assistant
}

/// Plan 模式的产物取消息中最后一段非空 text part 作为计划正文：
/// plan agent 的中间分析也是 text part，只有结尾的 text 才是完整计划。
func lastTextPartText(in timeline: [MessageItem]) -> String? {
    for item in timeline.reversed() {
        if case let .text(_, text, _) = item, !text.isEmpty {
            return text
        }
    }
    return nil
}

extension String {
    static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
