import Foundation

/// ConversationStore 依赖的稳定 daemon 边界；隐藏 ACP 传输细节。
@MainActor
protocol DiscoDaemonClient: AnyObject {
    func events() -> AsyncThrowingStream<DaemonEvent, Error>
    func startRun(sessionID: UUID, text: String) async throws -> UUID
    func cancelRun(runID: UUID) async throws
    func approve(approvalID: UUID, decision: String) async throws
    func closeSession(sessionID: UUID) async throws
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
                    kind: fields["kind"]?.stringValue,
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
        case "compaction_update":
            guard let compactionID = fields["compactionId"]?.stringValue,
                  let status = fields["status"]?.stringValue,
                  let event = makeEvent(
                      "context.compaction",
                      DaemonContextCompactionData(
                          runId: runID.uuidString,
                          sessionId: update.sessionID,
                          id: compactionID,
                          runtimeKind: fields["runtimeKind"]?.stringValue ?? "generic",
                          trigger: fields["trigger"]?.stringValue ?? "automatic",
                          status: status == "in_progress" ? "running" : status,
                          startedAt: fields["startedAt"]?.stringValue,
                          completedAt: fields["completedAt"]?.stringValue,
                          beforeTokens: fields["beforeTokens"]?.numberValue.map(Int.init),
                          afterTokens: fields["afterTokens"]?.numberValue.map(Int.init),
                          summary: fields["summary"]?.stringValue,
                          errorMessage: fields["errorMessage"]?.stringValue
                      )
                  ) else {
                return events
            }
            events.append(event)
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
        let usageMeta = fields["_meta"]?.objectValue?["disco/usage"]?.objectValue
        let current = usageMeta
            .flatMap { tokenUsage(from: $0["current"]) }
            ?? tokenUsage(fromStandardUsed: fields["used"])
        guard let current else {
            return nil
        }
        let contextTokens = fields["used"]?.numberValue
            .map(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? current.total
        let accumulated = usageMeta.flatMap { tokenUsage(from: $0["accumulated"]) }
        let contextWindow = fields["size"]?.numberValue
            .map(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
        let source = usageMeta?["source"]?.stringValue ?? "provider"
        return makeEvent(
            "context.usage",
            DaemonContextUsageData(
                runId: runID.uuidString,
                sessionId: sessionID,
                contextTokens: contextTokens,
                current: current,
                accumulated: accumulated,
                contextWindow: contextWindow,
                source: source
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

    private static func tokenUsage(fromStandardUsed value: DaemonJSONValue?) -> DaemonTokenUsage? {
        guard let used = value?.numberValue else { return nil }
        let tokens = Int(used)
        return DaemonTokenUsage(
            input: tokens,
            output: 0,
            total: tokens,
            cachedInput: nil,
            reasoningOutput: nil
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
            ?? UUID()

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
                summary: nil,
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
                kind: fields["kind"]?.stringValue,
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
    private var eventCursors: [String: (epoch: String, sequence: UInt64)] = [:]
    private var pendingSequencedUpdates: [String: [ACPSessionUpdate]] = [:]
    private var replayTasks: [String: Task<Void, Never>] = [:]

    init(client: ACPDaemonClient) {
        self.client = client
    }

    deinit {
        updateTask?.cancel()
        permissionTask?.cancel()
        for task in promptTasks.values {
            task.cancel()
        }
        for task in replayTasks.values {
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

    func closeSession(sessionID: UUID) async throws {
        try await client.closeSession(sessionID: sessionID.uuidString)
    }

    func deleteSession(sessionID: UUID) async throws {
        try await client.deleteSession(sessionID: sessionID.uuidString)
        eventCursors[sessionID.uuidString] = nil
        pendingSequencedUpdates[sessionID.uuidString] = nil
        replayTasks.removeValue(forKey: sessionID.uuidString)?.cancel()
    }

    func compactContext(sessionID: UUID) async throws {
        _ = try await client.compactSession(sessionID: sessionID.uuidString)
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
        if let eventEpoch = update.eventEpoch, let eventSequence = update.eventSequence {
            guard acceptSequencedUpdate(update, epoch: eventEpoch, sequence: eventSequence) else {
                return
            }
        }
        let updateKind = update.update.objectValue?["sessionUpdate"]?.stringValue
        let isCompactionUpdate = updateKind == "compaction_update"
        guard isCompactionUpdate || runIDBySessionID[update.sessionID] != nil else { return }
        // 手动压缩不属于 session/prompt run；用短生命周期的合成 ID 让事件仍能进入
        // 公共 DaemonEvent 流，ConversationStore 会按 session 处理压缩状态。
        let runID = runIDBySessionID[update.sessionID] ?? UUID()
        let shouldEmitRunningState = !isCompactionUpdate
            && runningStateSentForSession.insert(update.sessionID).inserted
        for event in ACPDaemonEventMapper.sessionUpdateEvents(
            update,
            runID: runID,
            shouldEmitRunningState: isCompactionUpdate ? false : shouldEmitRunningState
        ) {
            emit(event)
        }
    }

    private func acceptSequencedUpdate(
        _ update: ACPSessionUpdate,
        epoch: String,
        sequence: UInt64
    ) -> Bool {
        guard let cursor = eventCursors[update.sessionID] else {
            eventCursors[update.sessionID] = (epoch, sequence)
            return true
        }
        guard cursor.epoch == epoch else {
            // daemon 重启后 epoch 改变；新 epoch 从 1 重新计数，快照负责恢复权威状态。
            eventCursors[update.sessionID] = (epoch, sequence)
            pendingSequencedUpdates[update.sessionID] = nil
            return true
        }
        if sequence <= cursor.sequence {
            return false
        }
        if sequence > cursor.sequence + 1 {
            pendingSequencedUpdates[update.sessionID, default: []].append(update)
            startReplay(sessionID: update.sessionID, epoch: epoch, afterSequence: cursor.sequence)
            return false
        }
        eventCursors[update.sessionID] = (epoch, sequence)
        return true
    }

    private func startReplay(sessionID: String, epoch: String, afterSequence: UInt64) {
        guard replayTasks[sessionID] == nil else { return }
        replayTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { replayTasks[sessionID] = nil }
            do {
                let result = try await client.replayEvents(
                    sessionID: sessionID,
                    epoch: epoch,
                    afterSequence: afterSequence
                )
                if let first = result.events.first,
                   let cursor = eventCursors[sessionID],
                   first.sequence > cursor.sequence + 1
                {
                    // journal 窗口已滚动，无法补齐更早事件；从最早可用事件继续，
                    // 权威消息状态由 snapshot/持久化历史兜底。
                    eventCursors[sessionID] = (result.epoch, first.sequence - 1)
                }
                for replayed in result.events {
                    handleSessionUpdate(ACPSessionUpdate(
                        sessionID: replayed.sessionId,
                        update: replayed.update,
                        eventEpoch: replayed.epoch,
                        eventSequence: replayed.sequence
                    ))
                }
            } catch {
                // replay 失败时，后续 live event 仍会触发下一次 gap 检测；不伪造事件。
                return
            }
            let pending = pendingSequencedUpdates.removeValue(forKey: sessionID) ?? []
            for pendingUpdate in pending.sorted(by: {
                ($0.eventSequence ?? 0) < ($1.eventSequence ?? 0)
            }) {
                handleSessionUpdate(pendingUpdate)
            }
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
