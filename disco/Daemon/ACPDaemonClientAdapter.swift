import Foundation

/// ConversationStore 依赖的稳定 daemon 边界；隐藏 ACP 传输细节。
@MainActor
protocol DiscoDaemonClient: AnyObject {
    func events() -> AsyncThrowingStream<DaemonEvent, Error>
    func startRun(sessionID: UUID, text: String) async throws -> UUID
    func cancelRun(runID: UUID) async throws
    func approve(approvalID: UUID, decision: String) async throws
    func deleteSession(sessionID: UUID) async throws
    func compactContext(sessionID: UUID) async throws
}

/// 将 ACP session update 转换为公共 `DaemonEvent`。
///
/// 该 mapper 不持有运行状态；run ID、审批路由和终止结果由 adapter 管理。
enum ACPDaemonEventMapper {
    static func sessionUpdateEvents(
        _ update: ACPSessionUpdate,
        runID: UUID,
        shouldEmitRunningState: Bool
    ) -> [DaemonEvent] {
        guard let fields = update.update.objectValue,
              let updateKind = fields["sessionUpdate"]?.stringValue else {
            return []
        }

        var events: [DaemonEvent] = []
        if shouldEmitRunningState,
           let runningEvent = makeEvent(
               "run.state",
               DaemonRunStateData(
                   runId: runID.uuidString,
                   sessionId: update.sessionID,
                   state: "running"
               )
           ) {
            events.append(runningEvent)
        }

        switch updateKind {
        case "agent_message_chunk":
            guard let text = textContent(from: fields["content"]) else { return events }
            if let event = makeEvent(
                "message.delta",
                DaemonMessageDeltaData(
                    runId: runID.uuidString,
                    sessionId: update.sessionID,
                    delta: text
                )
            ) {
                events.append(event)
            }
        case "agent_thought_chunk":
            guard let text = textContent(from: fields["content"]) else { return events }
            if let event = makeEvent(
                "reasoning.delta",
                DaemonReasoningDeltaData(
                    runId: runID.uuidString,
                    sessionId: update.sessionID,
                    delta: text
                )
            ) {
                events.append(event)
            }
        case "tool_call":
            guard let toolCallID = fields["toolCallId"]?.stringValue else { return events }
            let toolName = fields["title"]?.stringValue ?? "ACP tool"
            let arguments = jsonText(fields["rawInput"] ?? .object([:]))
            if let event = makeEvent(
                "tool.started",
                DaemonToolStartedData(
                    runId: runID.uuidString,
                    sessionId: update.sessionID,
                    toolCallId: toolCallID,
                    toolName: toolName,
                    arguments: arguments
                )
            ) {
                events.append(event)
            }
            if let completedEvent = completedToolEvent(
                fields: fields,
                runID: runID,
                sessionID: update.sessionID,
                fallbackToolName: toolName,
                toolCallID: toolCallID
            ) {
                events.append(completedEvent)
            }
        case "tool_call_update":
            guard let toolCallID = fields["toolCallId"]?.stringValue,
                  let completedEvent = completedToolEvent(
                      fields: fields,
                      runID: runID,
                      sessionID: update.sessionID,
                      fallbackToolName: fields["title"]?.stringValue ?? "ACP tool",
                      toolCallID: toolCallID
                  ) else {
                return events
            }
            events.append(completedEvent)
        case "usage_update":
            guard let usageEvent = usageEvent(
                fields: fields,
                runID: runID,
                sessionID: update.sessionID
            ) else {
                return events
            }
            events.append(usageEvent)
        default:
            break
        }
        return events
    }

    private static func usageEvent(
        fields: [String: DaemonJSONValue],
        runID: UUID,
        sessionID: String
    ) -> DaemonEvent? {
        guard let usageMeta = fields["_meta"]?.objectValue?["disco/usage"]?.objectValue,
              let current = tokenUsage(from: usageMeta["current"]),
              let accumulated = tokenUsage(from: usageMeta["accumulated"]) else {
            return nil
        }
        return makeEvent(
            "context.usage",
            DaemonContextUsageData(
                runId: runID.uuidString,
                sessionId: sessionID,
                current: current,
                accumulated: accumulated,
                contextWindow: nil,
                source: "provider"
            )
        )
    }

    private static func tokenUsage(from value: DaemonJSONValue?) -> DaemonTokenUsage? {
        guard let fields = value?.objectValue,
              let input = fields["input"]?.numberValue,
              let output = fields["output"]?.numberValue,
              let total = fields["total"]?.numberValue else {
            return nil
        }
        return DaemonTokenUsage(
            input: Int(input),
            output: Int(output),
            total: Int(total),
            cachedInput: fields["cached_input"]?.numberValue.map(Int.init),
            reasoningOutput: fields["reasoning_output"]?.numberValue.map(Int.init)
        )
    }

    static func approvalEvent(
        _ request: ACPPermissionRequest,
        runID: UUID
    ) -> (approvalID: UUID, event: DaemonEvent)? {
        let toolCallFields = request.toolCall.objectValue ?? [:]
        let approvalID = request.metadata
            .flatMap { $0.objectValue?["disco/approvalId"]?.stringValue }
            .flatMap(UUID.init(uuidString:))
            ?? toolCallFields["toolCallId"]?.stringValue.flatMap(UUID.init(uuidString:))
        guard let approvalID else { return nil }

        let metadata = request.metadata?.objectValue
        let scope = metadata?["disco/approvalScope"]?.stringValue
        let fingerprint = metadata?["disco/approvalFingerprint"]?.stringValue ?? approvalID.uuidString
        let title = toolCallFields["title"]?.stringValue ?? "ACP agent 请求执行操作"
        let rawInput = toolCallFields["rawInput"]
        let approvalInput = rawInput.flatMap { try? $0.decoded(as: ACPApprovalInput.self) }
        let kind = normalizedApprovalKind(approvalInput?.kind)
        let impact = approvalInput?.impact ?? fallbackApprovalImpact()

        guard let event = makeEvent(
            "approval.requested",
            DaemonApprovalRequestedData(
                runId: runID.uuidString,
                sessionId: request.sessionID,
                approvalId: approvalID.uuidString,
                kind: kind,
                title: title,
                reason: nil,
                impact: impact,
                fingerprint: fingerprint,
                allowsSessionApproval: scope == "session"
            )
        ) else {
            return nil
        }
        return (approvalID, event)
    }

    static func terminalEvent(
        stopReason: String,
        runID: UUID,
        sessionID: String
    ) -> DaemonEvent {
        switch stopReason {
        case "cancelled":
            return makeEvent(
                "run.cancelled",
                DaemonRunCancelledData(
                    runId: runID.uuidString,
                    sessionId: sessionID
                )
            ) ?? DaemonEvent(eventName: "run.cancelled", data: .object([:]))
        case "end_turn", "max_tokens", "max_turn_requests":
            return makeEvent(
                "run.completed",
                DaemonRunCompletedData(
                    runId: runID.uuidString,
                    sessionId: sessionID
                )
            ) ?? DaemonEvent(eventName: "run.completed", data: .object([:]))
        default:
            return makeEvent(
                "run.failed",
                DaemonRunFailedData(
                    runId: runID.uuidString,
                    sessionId: sessionID,
                    error: DaemonRunError(
                        code: .generic,
                        message: "ACP run 以非正常原因结束：\(stopReason)",
                        recoverySuggestion: nil,
                        retryable: false
                    )
                )
            ) ?? DaemonEvent(eventName: "run.failed", data: .object([:]))
        }
    }

    static func failedEvent(
        error: Error,
        runID: UUID,
        sessionID: String
    ) -> DaemonEvent {
        makeEvent(
            "run.failed",
            DaemonRunFailedData(
                runId: runID.uuidString,
                sessionId: sessionID,
                error: DaemonRunError(
                    code: .generic,
                    message: error.localizedDescription,
                    recoverySuggestion: nil,
                    retryable: false
                )
            )
        ) ?? DaemonEvent(eventName: "run.failed", data: .object([:]))
    }

    static func compactionEvent(
        sessionID: UUID,
        id: String,
        status: String,
        beforeTokens: Int?,
        afterTokens: Int?,
        errorMessage: String?,
        startedAt: String,
        completedAt: String
    ) -> DaemonEvent {
        makeEvent(
            "context.compaction",
            DaemonContextCompactionData(
                runId: UUID().uuidString,
                sessionId: sessionID.uuidString,
                id: id,
                runtimeKind: "generic",
                trigger: "manual",
                status: status,
                startedAt: startedAt,
                completedAt: completedAt,
                beforeTokens: beforeTokens,
                afterTokens: afterTokens,
                errorMessage: errorMessage
            )
        ) ?? DaemonEvent(eventName: "context.compaction", data: .object([:]))
    }

    private static func completedToolEvent(
        fields: [String: DaemonJSONValue],
        runID: UUID,
        sessionID: String,
        fallbackToolName: String,
        toolCallID: String
    ) -> DaemonEvent? {
        let status = fields["status"]?.stringValue
        guard status == "completed" || status == "failed" else { return nil }
        return makeEvent(
            "tool.completed",
            DaemonToolCompletedData(
                runId: runID.uuidString,
                sessionId: sessionID,
                toolCallId: toolCallID,
                toolName: fields["title"]?.stringValue ?? fallbackToolName,
                output: jsonText(fields["rawOutput"] ?? .string(""))
            )
        )
    }

    private static func textContent(from value: DaemonJSONValue?) -> String? {
        value?.objectValue?["text"]?.stringValue
    }

    private static func jsonText(_ value: DaemonJSONValue) -> String {
        switch value {
        case let .string(text): return text
        default:
            guard let data = try? JSONEncoder().encode(value) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private static func normalizedApprovalKind(_ kind: String?) -> String {
        switch kind?.lowercased() {
        case "command": return "command"
        case "filechange", "file_change": return "file_change"
        case "network": return "network"
        default: return "permission"
        }
    }

    private static func fallbackApprovalImpact() -> DaemonApprovalImpact {
        DaemonApprovalImpact(
            type: "permission",
            executable: nil,
            arguments: nil,
            cwd: nil,
            paths: nil,
            summary: nil,
            diff: nil,
            host: nil,
            scheme: nil,
            port: nil,
            scope: "acp",
            description: "ACP agent 请求执行一项需要确认的操作。"
        )
    }

    private static func makeEvent<T: Encodable>(_ name: String, _ data: T) -> DaemonEvent? {
        guard let encoded = try? JSONEncoder().encode(data),
              let value = try? JSONDecoder().decode(DaemonJSONValue.self, from: encoded) else {
            return nil
        }
        return DaemonEvent(eventName: name, data: value)
    }
}

private struct ACPApprovalInput: Decodable, Sendable {
    let kind: String?
    let impact: DaemonApprovalImpact?
}

private struct ACPApprovalRoute: Sendable {
    let runID: UUID
    let requestID: ACPRequestID
}

/// 将 ACP client 适配到 `DiscoDaemonClient` 接口。
///
/// ConversationStore 只理解 `DiscoDaemonClient` 一套运行控制语义，
/// ACP 的 session update / permission request 在这一层翻译成 daemon 事件。
@MainActor
final class ACPDaemonClientAdapter: DiscoDaemonClient {
    private let client: ACPDaemonClient
    private var eventStream: AsyncThrowingStream<DaemonEvent, Error>?
    private var eventContinuation: AsyncThrowingStream<DaemonEvent, Error>.Continuation?
    private var updateTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?

    private var runIDBySessionID: [String: UUID] = [:]
    private var sessionIDByRunID: [UUID: String] = [:]
    private var runningStateSentForSession: Set<String> = []
    private var promptTasks: [UUID: Task<Void, Never>] = [:]
    private var approvalRoutes: [UUID: ACPApprovalRoute] = [:]

    init(client: ACPDaemonClient) {
        self.client = client
    }

    deinit {
        updateTask?.cancel()
        permissionTask?.cancel()
        for task in promptTasks.values {
            task.cancel()
        }
    }

    func events() -> AsyncThrowingStream<DaemonEvent, Error> {
        if let eventStream { return eventStream }
        var capturedContinuation: AsyncThrowingStream<DaemonEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<DaemonEvent, Error> { continuation in
            capturedContinuation = continuation
        }
        eventStream = stream
        eventContinuation = capturedContinuation
        startEventRouting()
        return stream
    }

    func startRun(sessionID: UUID, text: String) async throws -> UUID {
        let sessionKey = sessionID.uuidString
        guard runIDBySessionID[sessionKey] == nil else {
            throw DaemonError.rpcError(code: -32602, message: "会话已有活动 ACP run。")
        }
        let runID = UUID()
        runIDBySessionID[sessionKey] = runID
        sessionIDByRunID[runID] = sessionKey
        runningStateSentForSession.remove(sessionKey)
        emit(
            ACPDaemonEventMapper.makeRunStateEvent(
                runID: runID,
                sessionID: sessionKey,
                state: "connecting"
            )
        )

        let promptTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await client.prompt(sessionID: sessionKey, text: text)
                emit(ACPDaemonEventMapper.terminalEvent(
                    stopReason: result.stopReason,
                    runID: runID,
                    sessionID: sessionKey
                ))
            } catch {
                emit(ACPDaemonEventMapper.failedEvent(
                    error: error,
                    runID: runID,
                    sessionID: sessionKey
                ))
            }
            finishRun(runID: runID, sessionID: sessionKey)
        }
        promptTasks[runID] = promptTask
        return runID
    }

    func cancelRun(runID: UUID) async throws {
        guard let sessionID = sessionIDByRunID[runID] else { return }
        try client.cancel(sessionID: sessionID)
    }

    func approve(approvalID: UUID, decision: String) async throws {
        guard let route = approvalRoutes[approvalID] else {
            throw DaemonError.invalidResponse("找不到 ACP approval \(approvalID)。")
        }
        let optionID: String?
        switch decision {
        case "approve_once": optionID = "approve_once"
        case "approve_for_session": optionID = "approve_for_session"
        case "decline": optionID = "decline"
        default: optionID = nil
        }
        try client.respondToPermission(requestID: route.requestID, optionID: optionID)
        approvalRoutes[approvalID] = nil
    }

    func deleteSession(sessionID: UUID) async throws {
        try await client.deleteSession(sessionID: sessionID.uuidString)
    }

    func compactContext(sessionID: UUID) async throws {
        let result = try await client.compactSession(sessionID: sessionID.uuidString)
        let info = result.compaction
        let startedAt = ISO8601DateFormatter().string(from: Date.now)
        emit(ACPDaemonEventMapper.compactionEvent(
            sessionID: sessionID,
            id: info.id,
            status: info.status == "completed" ? "completed" : "failed",
            beforeTokens: info.beforeTokens.map(Int.init),
            afterTokens: info.afterTokens.map(Int.init),
            errorMessage: info.errorMessage,
            startedAt: startedAt,
            completedAt: startedAt
        ))
    }

    private func startEventRouting() {
        let updates = client.sessionUpdates()
        let permissions = client.permissionRequests()
        updateTask = Task { @MainActor [weak self] in
            do {
                for try await update in updates {
                    guard let self else { return }
                    handleSessionUpdate(update)
                }
            } catch {
                guard let self else { return }
                finishEventStream(with: error)
            }
        }
        permissionTask = Task { @MainActor [weak self] in
            do {
                for try await permission in permissions {
                    guard let self else { return }
                    handlePermissionRequest(permission)
                }
            } catch {
                guard let self else { return }
                finishEventStream(with: error)
            }
        }
    }

    private func handleSessionUpdate(_ update: ACPSessionUpdate) {
        guard let runID = runIDBySessionID[update.sessionID] else { return }
        let shouldEmitRunningState = runningStateSentForSession.insert(update.sessionID).inserted
        for event in ACPDaemonEventMapper.sessionUpdateEvents(
            update,
            runID: runID,
            shouldEmitRunningState: shouldEmitRunningState
        ) {
            emit(event)
        }
    }

    private func handlePermissionRequest(_ request: ACPPermissionRequest) {
        guard let runID = runIDBySessionID[request.sessionID],
              let mapped = ACPDaemonEventMapper.approvalEvent(request, runID: runID) else {
            return
        }
        approvalRoutes[mapped.approvalID] = ACPApprovalRoute(
            runID: runID,
            requestID: request.requestID
        )
        emit(mapped.event)
    }

    private func finishRun(runID: UUID, sessionID: String) {
        promptTasks[runID] = nil
        sessionIDByRunID[runID] = nil
        if runIDBySessionID[sessionID] == runID {
            runIDBySessionID[sessionID] = nil
        }
        runningStateSentForSession.remove(sessionID)
        approvalRoutes = approvalRoutes.filter { $0.value.runID != runID }
    }

    private func emit(_ event: DaemonEvent) {
        eventContinuation?.yield(event)
    }

    private func finishEventStream(with error: Error) {
        eventContinuation?.finish(throwing: error)
        eventContinuation = nil
        eventStream = nil
        updateTask?.cancel()
        permissionTask?.cancel()
    }
}

private extension ACPDaemonEventMapper {
    static func makeRunStateEvent(
        runID: UUID,
        sessionID: String,
        state: String
    ) -> DaemonEvent {
        makeEvent(
            "run.state",
            DaemonRunStateData(
                runId: runID.uuidString,
                sessionId: sessionID,
                state: state
            )
        ) ?? DaemonEvent(eventName: "run.state", data: .object([:]))
    }
}

