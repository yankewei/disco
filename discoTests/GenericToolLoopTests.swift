import Foundation
import XCTest
@testable import disco

@MainActor
final class GenericToolLoopTests: XCTestCase {
    func testAdvertisedToolResultIsReturnedToModelBeforeRunCompletes() async throws {
        let providerScript = SingleToolProviderScript()
        let executorRecorder = ToolExecutorRecorder()
        let workspace = WorkspaceContext(
            rootURL: URL(fileURLWithPath: "/tmp/disco-workspace"),
            additionalReadableRoots: []
        )
        let runtime = GenericAgentRuntime(
            provider: SingleToolProvider(script: providerScript),
            configuration: .init(
                model: "test-model",
                reasoningEnabled: false,
                workspace: workspace
            ),
            toolExecutor: ScriptedToolExecutor(
                recorder: executorRecorder,
                result: ToolExecutionResult(status: .success, output: "README contents")
            )
        )
        let runID = RunID()

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "读取 README")]
        )) {
            events.append(event)
        }

        XCTAssertTrue(events.contains(.messageDelta("文件内容已经读取。")))
        XCTAssertEqual(events.compactMap { event -> AgentRunState? in
            guard case let .runStateChanged(_, state) = event else { return nil }
            return state
        }, [.running, .waitingForTool, .running])
        XCTAssertEqual(events.filter(\.isTerminal), [.runCompleted(runID)])

        let executedRequests = await executorRecorder.requests
        XCTAssertEqual(executedRequests, [ToolExecutionRequest(
            call: ModelToolCall(
                callID: "call_read",
                name: "filesystem.read",
                arguments: #"{"path":"README.md"}"#
            ),
            context: ToolExecutionContext(runID: runID, workspace: workspace)
        )])

        let modelRequests = await providerScript.requests
        XCTAssertEqual(modelRequests.count, 2)
        XCTAssertEqual(modelRequests[0].functionTools.map(\.name), ["filesystem.read"])
        XCTAssertEqual(modelRequests[1].toolFollowUp?.results, [ModelToolResult(
            callID: "call_read",
            output: #"{"is_truncated":false,"output":"README contents","status":"success"}"#
        )])
    }

    func testModelRoundLimitStopsARepeatedToolLoop() async throws {
        let providerScript = RepeatingToolProviderScript()
        let executorRecorder = ToolExecutorRecorder()
        let runtime = GenericAgentRuntime(
            provider: RepeatingToolProvider(script: providerScript),
            configuration: .init(
                model: "test-model",
                reasoningEnabled: false,
                maximumModelRounds: 2
            ),
            toolExecutor: ScriptedToolExecutor(
                recorder: executorRecorder,
                result: ToolExecutionResult(status: .success, output: "README contents")
            )
        )
        let runID = RunID()

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "持续读取 README")]
        )) {
            events.append(event)
        }

        let requestCount = await providerScript.requestCount
        let executionCount = await executorRecorder.requests.count
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(executionCount, 2)
        XCTAssertEqual(events.filter(\.isTerminal), [
            .runFailed(runID, AgentFailure(
                message: "模型工具循环超过最大模型轮次（2），运行已停止。"
            )),
        ])
    }

    func testStructuredFailureAndTruncationAreReturnedToModel() async throws {
        let providerScript = SingleToolProviderScript()
        let runtime = GenericAgentRuntime(
            provider: SingleToolProvider(script: providerScript),
            configuration: .init(model: "test-model", reasoningEnabled: false),
            toolExecutor: ScriptedToolExecutor(
                recorder: ToolExecutorRecorder(),
                result: ToolExecutionResult(
                    status: .failure,
                    output: "文件不存在",
                    isTruncated: true
                )
            )
        )

        for try await _ in runtime.start(request: AgentRunRequest(
            runID: RunID(),
            messages: [ChatMessage(role: .user, text: "读取缺失文件")]
        )) {}

        let modelRequests = await providerScript.requests
        XCTAssertEqual(modelRequests.count, 2)
        XCTAssertEqual(modelRequests[1].toolFollowUp?.results, [ModelToolResult(
            callID: "call_read",
            output: #"{"is_truncated":true,"output":"文件不存在","status":"failure"}"#
        )])
    }

    func testToolCallLimitStopsBeforeExecutingTheExtraCall() async throws {
        let providerScript = RepeatingToolProviderScript()
        let executorRecorder = ToolExecutorRecorder()
        let runtime = GenericAgentRuntime(
            provider: RepeatingToolProvider(script: providerScript),
            configuration: .init(
                model: "test-model",
                reasoningEnabled: false,
                maximumToolCalls: 1
            ),
            toolExecutor: ScriptedToolExecutor(
                recorder: executorRecorder,
                result: ToolExecutionResult(status: .success, output: "README contents")
            )
        )
        let runID = RunID()

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "持续读取 README")]
        )) {
            events.append(event)
        }

        let requestCount = await providerScript.requestCount
        let executionCount = await executorRecorder.requests.count
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(events.filter(\.isTerminal), [
            .runFailed(runID, AgentFailure(
                message: "模型工具循环超过最大工具调用次数（1），运行已停止。"
            )),
        ])
    }

    func testInvalidArgumentsFailBeforeToolExecution() async throws {
        let executorRecorder = ToolExecutorRecorder()
        let runtime = GenericAgentRuntime(
            provider: FixedToolProvider(calls: [ModelToolCall(
                callID: "call_invalid",
                name: "filesystem.read",
                arguments: "[]"
            )]),
            configuration: .init(model: "test-model", reasoningEnabled: false),
            toolExecutor: ScriptedToolExecutor(
                recorder: executorRecorder,
                result: ToolExecutionResult(status: .success, output: "must not execute")
            )
        )
        let runID = RunID()

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "读取文件")]
        )) {
            events.append(event)
        }

        let executedRequests = await executorRecorder.requests
        XCTAssertTrue(executedRequests.isEmpty)
        XCTAssertEqual(events.filter(\.isTerminal), [
            .runFailed(runID, AgentFailure(
                message: "模型返回的工具参数不是有效的 JSON object。"
            )),
        ])
    }

    func testUnknownAndParallelToolCallsFailBeforeToolExecution() async throws {
        let unknownRecorder = ToolExecutorRecorder()
        let unknownRunID = RunID()
        let unknownRuntime = GenericAgentRuntime(
            provider: FixedToolProvider(calls: [ModelToolCall(
                callID: "call_unknown",
                name: "filesystem.delete",
                arguments: #"{"path":"README.md"}"#
            )]),
            configuration: .init(model: "test-model", reasoningEnabled: false),
            toolExecutor: ScriptedToolExecutor(
                recorder: unknownRecorder,
                result: ToolExecutionResult(status: .success, output: "must not execute")
            )
        )

        var unknownEvents: [AgentEvent] = []
        for try await event in unknownRuntime.start(request: AgentRunRequest(
            runID: unknownRunID,
            messages: [ChatMessage(role: .user, text: "删除文件")]
        )) {
            unknownEvents.append(event)
        }

        let parallelRecorder = ToolExecutorRecorder()
        let parallelRunID = RunID()
        let parallelRuntime = GenericAgentRuntime(
            provider: FixedToolProvider(calls: [
                ModelToolCall(
                    callID: "call_one",
                    name: "filesystem.read",
                    arguments: #"{"path":"README.md"}"#
                ),
                ModelToolCall(
                    callID: "call_two",
                    name: "filesystem.read",
                    arguments: #"{"path":"AGENTS.md"}"#
                ),
            ]),
            configuration: .init(model: "test-model", reasoningEnabled: false),
            toolExecutor: ScriptedToolExecutor(
                recorder: parallelRecorder,
                result: ToolExecutionResult(status: .success, output: "must not execute")
            )
        )

        var parallelEvents: [AgentEvent] = []
        for try await event in parallelRuntime.start(request: AgentRunRequest(
            runID: parallelRunID,
            messages: [ChatMessage(role: .user, text: "读取两个文件")]
        )) {
            parallelEvents.append(event)
        }

        let unknownExecutions = await unknownRecorder.requests
        let parallelExecutions = await parallelRecorder.requests
        XCTAssertTrue(unknownExecutions.isEmpty)
        XCTAssertTrue(parallelExecutions.isEmpty)
        XCTAssertEqual(unknownEvents.filter(\.isTerminal), [
            .runFailed(unknownRunID, AgentFailure(
                message: "模型调用了未广告的本地工具：filesystem.delete"
            )),
        ])
        XCTAssertEqual(parallelEvents.filter(\.isTerminal), [
            .runFailed(parallelRunID, AgentFailure(
                message: "当前工具循环一次只支持一个客户端工具调用。"
            )),
        ])
    }

    func testCancellingWhileToolRunsCancelsExecutorAndEmitsOneTerminalEvent() async throws {
        let executor = BlockingToolExecutor()
        let runID = RunID()
        let runtime = GenericAgentRuntime(
            provider: FixedToolProvider(calls: [ModelToolCall(
                callID: "call_blocking",
                name: "filesystem.read",
                arguments: #"{"path":"README.md"}"#
            )]),
            configuration: .init(model: "test-model", reasoningEnabled: false),
            toolExecutor: executor
        )

        let eventTask = Task { @MainActor () throws -> [AgentEvent] in
            var events: [AgentEvent] = []
            for try await event in runtime.start(request: AgentRunRequest(
                runID: runID,
                messages: [ChatMessage(role: .user, text: "读取文件")]
            )) {
                events.append(event)
            }
            return events
        }

        await executor.waitUntilStarted()
        await runtime.cancel(runID: runID)
        let events = try await eventTask.value

        let cancelledRunIDs = await executor.cancelledRunIDs
        XCTAssertEqual(cancelledRunIDs, [runID])
        XCTAssertTrue(events.contains(.runStateChanged(runID, .waitingForTool)))
        XCTAssertEqual(events.filter(\.isTerminal), [.runCancelled(runID)])
    }
}

private extension AgentEvent {
    var isTerminal: Bool {
        switch self {
        case .runCompleted, .runFailed, .runCancelled: true
        default: false
        }
    }
}

private actor ToolExecutorRecorder {
    private(set) var requests: [ToolExecutionRequest] = []

    func record(_ request: ToolExecutionRequest) {
        requests.append(request)
    }
}

private struct ScriptedToolExecutor: ToolExecutor {
    let recorder: ToolExecutorRecorder
    let result: ToolExecutionResult

    let toolDefinitions = [ModelToolDefinition(
        name: "filesystem.read",
        description: "Read one text file from the workspace.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("path")]),
            "additionalProperties": .boolean(false),
        ])
    )]

    func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
        await recorder.record(request)
        return result
    }
}

private actor SingleToolProviderScript {
    private(set) var requests: [ModelRequest] = []

    func events(for request: ModelRequest) -> [ModelEvent] {
        requests.append(request)
        if request.toolFollowUp == nil {
            return [
                .toolCallCompleted(ModelToolCall(
                    callID: "call_read",
                    name: "filesystem.read",
                    arguments: #"{"path":"README.md"}"#
                )),
                .completed(ModelCompletion(continuation: ModelContinuation(
                    format: "test",
                    payload: Data(#"{"output":[]}"#.utf8)
                ))),
            ]
        }
        return [
            .textDelta("文件内容已经读取。"),
            .completed(ModelCompletion(continuation: nil)),
        ]
    }
}

private struct SingleToolProvider: ModelProvider {
    let script: SingleToolProviderScript
    let descriptor = ProviderDescriptor(id: "single-tool", displayName: "Single Tool")

    func modelCatalog() async throws -> [ModelCatalogEntry] {
        [ModelCatalogEntry(id: "test-model", supportsToolCalling: true)]
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await script.events(for: request) {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

private actor RepeatingToolProviderScript {
    private(set) var requestCount = 0

    func nextEvents() -> [ModelEvent] {
        requestCount += 1
        let callID = "call_read_\(requestCount)"
        return [
            .toolCallCompleted(ModelToolCall(
                callID: callID,
                name: "filesystem.read",
                arguments: #"{"path":"README.md"}"#
            )),
            .completed(ModelCompletion(continuation: ModelContinuation(
                format: "test",
                payload: Data(#"{"output":[]}"#.utf8)
            ))),
        ]
    }
}

private struct RepeatingToolProvider: ModelProvider {
    let script: RepeatingToolProviderScript
    let descriptor = ProviderDescriptor(id: "repeating-tool", displayName: "Repeating Tool")

    func modelCatalog() async throws -> [ModelCatalogEntry] {
        [ModelCatalogEntry(id: "test-model", supportsToolCalling: true)]
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await script.nextEvents() {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

private struct FixedToolProvider: ModelProvider {
    let calls: [ModelToolCall]
    let descriptor = ProviderDescriptor(id: "fixed-tool", displayName: "Fixed Tool")

    func modelCatalog() async throws -> [ModelCatalogEntry] {
        [ModelCatalogEntry(id: "test-model", supportsToolCalling: true)]
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            for call in calls {
                continuation.yield(.toolCallCompleted(call))
            }
            continuation.yield(.completed(ModelCompletion(continuation: ModelContinuation(
                format: "test",
                payload: Data(#"{"output":[]}"#.utf8)
            ))))
            continuation.finish()
        }
    }
}

private actor BlockingToolExecutor: ToolExecutor {
    nonisolated let toolDefinitions = [ModelToolDefinition(
        name: "filesystem.read",
        description: "Read one text file from the workspace.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("path")]),
            "additionalProperties": .boolean(false),
        ])
    )]

    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelledRunIDs: [RunID] = []

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(60))
        return ToolExecutionResult(status: .success, output: "must be cancelled")
    }

    func cancel(runID: RunID) {
        cancelledRunIDs.append(runID)
    }
}
