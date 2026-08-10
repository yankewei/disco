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

    func testExpectedNonSuccessToolResultsAreReturnedToModel() async throws {
        let cases: [(ToolExecutionResult.Status, String)] = [
            (.failure, "failure"),
            (.declined, "declined"),
            (.cancelled, "cancelled"),
            (.timedOut, "timed_out"),
        ]

        for (status, encodedStatus) in cases {
            let providerScript = SingleToolProviderScript()
            let runtime = GenericAgentRuntime(
                provider: SingleToolProvider(script: providerScript),
                configuration: .init(model: "test-model", reasoningEnabled: false),
                toolExecutor: ScriptedToolExecutor(
                    recorder: ToolExecutorRecorder(),
                    result: ToolExecutionResult(status: status, output: "工具没有完成")
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

            let modelRequests = await providerScript.requests
            XCTAssertEqual(modelRequests.count, 2, "status: \(encodedStatus)")
            XCTAssertEqual(modelRequests[1].toolFollowUp?.results, [ModelToolResult(
                callID: "call_read",
                output: "{\"is_truncated\":false,\"output\":\"工具没有完成\",\"status\":\"\(encodedStatus)\"}"
            )], "status: \(encodedStatus)")
            XCTAssertEqual(events.filter(\.isTerminal), [.runCompleted(runID)])
        }
    }

    func testExecutorCancellationWithoutRunCancellationFailsTheRun() async throws {
        let runID = RunID()
        let runtime = GenericAgentRuntime(
            provider: FixedToolProvider(calls: [ModelToolCall(
                callID: "call_cancelled",
                name: "filesystem.read",
                arguments: #"{"path":"README.md"}"#
            )]),
            configuration: .init(model: "test-model", reasoningEnabled: false),
            toolExecutor: ThrowingToolExecutor(error: CancellationError())
        )

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "读取文件")]
        )) {
            events.append(event)
        }

        XCTAssertEqual(events.filter(\.isTerminal), [
            .runFailed(runID, AgentFailure(
                message: "工具执行被意外取消，运行已停止。"
            )),
        ])
    }

    func testExecutorInfrastructureFailureEmitsOneRunFailedWithoutFollowUp() async throws {
        let providerScript = SingleToolProviderScript()
        let executorRecorder = ToolExecutorRecorder()
        let runID = RunID()
        let runtime = GenericAgentRuntime(
            provider: SingleToolProvider(script: providerScript),
            configuration: .init(model: "test-model", reasoningEnabled: false),
            toolExecutor: ThrowingToolExecutor(
                error: TestExecutorFailure.disconnected,
                recorder: executorRecorder
            )
        )

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "读取文件")]
        )) {
            events.append(event)
        }

        let modelRequests = await providerScript.requests
        let executionCount = await executorRecorder.requests.count
        XCTAssertEqual(modelRequests.count, 1)
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(events.filter(\.isTerminal), [
            .runFailed(runID, AgentFailure(message: "Tool Host 连接已中断。")),
        ])
    }

    func testDuplicateCallIDIsNotExecutedTwice() async throws {
        let providerScript = DuplicateToolProviderScript()
        let executorRecorder = ToolExecutorRecorder()
        let runID = RunID()
        let runtime = GenericAgentRuntime(
            provider: DuplicateToolProvider(script: providerScript),
            configuration: .init(model: "test-model", reasoningEnabled: false),
            toolExecutor: ScriptedToolExecutor(
                recorder: executorRecorder,
                result: ToolExecutionResult(status: .success, output: "README contents")
            )
        )

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "读取 README")]
        )) {
            events.append(event)
        }

        let requestCount = await providerScript.requestCount
        let executionCount = await executorRecorder.requests.count
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(events.filter(\.isTerminal), [
            .runFailed(runID, AgentFailure(
                message: "模型重复提交了已经处理的工具调用：call_read"
            )),
        ])
    }

    func testContextOverflowAfterToolExecutionFailsWithoutReplayingTool() async throws {
        let providerScript = TwoRoundProviderScript()
        let executorRecorder = ToolExecutorRecorder()
        let runID = RunID()
        let runtime = GenericAgentRuntime(
            provider: FollowUpOverflowProvider(script: providerScript),
            configuration: .init(model: "test-model", reasoningEnabled: false),
            toolExecutor: ScriptedToolExecutor(
                recorder: executorRecorder,
                result: ToolExecutionResult(status: .success, output: "README contents")
            )
        )

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "读取 README")]
        )) {
            events.append(event)
        }

        let requestCount = await providerScript.requestCount
        let executionCount = await executorRecorder.requests.count
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(events.filter(\.isTerminal), [
            .runFailed(runID, AgentFailure(
                code: .contextOverflow,
                message: "工具已经执行，但后续请求超出上下文窗口。为避免重复执行工具，运行已停止。",
                recoverySuggestion: "请缩短上下文或新建会话；重试前请先确认工具产生的结果。",
                isRetryable: false
            )),
        ])
    }

    func testFollowUpDisconnectKeepsPartialTextAndDoesNotReplayTool() async throws {
        let providerScript = TwoRoundProviderScript()
        let executorRecorder = ToolExecutorRecorder()
        let runID = RunID()
        let runtime = GenericAgentRuntime(
            provider: FollowUpDisconnectProvider(script: providerScript),
            configuration: .init(model: "test-model", reasoningEnabled: false),
            toolExecutor: ScriptedToolExecutor(
                recorder: executorRecorder,
                result: ToolExecutionResult(status: .success, output: "README contents")
            )
        )

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "读取 README")]
        )) {
            events.append(event)
        }

        let requestCount = await providerScript.requestCount
        let executionCount = await executorRecorder.requests.count
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(executionCount, 1)
        XCTAssertTrue(events.contains(.messageDelta("已经读取，正在整理")))
        XCTAssertEqual(events.filter(\.isTerminal), [
            .runFailed(runID, AgentFailure(message: "测试模型连接中断")),
        ])
    }

    func testModelStreamFailureBeforeAnyVisibleEventFailsWithoutRetrying() async throws {
        let providerScript = FailingModelProviderScript()
        let runID = RunID()
        let runtime = GenericAgentRuntime(
            provider: FailingModelProvider(script: providerScript, events: []),
            configuration: .init(model: "test-model", reasoningEnabled: false)
        )

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "你好")]
        )) {
            events.append(event)
        }

        let requestCount = await providerScript.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(events.filter(\.isTerminal), [
            .runFailed(runID, AgentFailure(message: "测试模型连接中断")),
        ])
    }

    func testModelStreamFailureAfterVisibleEventsKeepsDeltasWithoutRetrying() async throws {
        let providerScript = FailingModelProviderScript()
        let runID = RunID()
        let runtime = GenericAgentRuntime(
            provider: FailingModelProvider(
                script: providerScript,
                events: [.reasoningDelta("先检查"), .textDelta("部分回答")]
            ),
            configuration: .init(model: "test-model", reasoningEnabled: false)
        )

        var events: [AgentEvent] = []
        for try await event in runtime.start(request: AgentRunRequest(
            runID: runID,
            messages: [ChatMessage(role: .user, text: "你好")]
        )) {
            events.append(event)
        }

        let requestCount = await providerScript.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(events.contains(.reasoningDelta("先检查")))
        XCTAssertTrue(events.contains(.messageDelta("部分回答")))
        XCTAssertEqual(events.filter(\.isTerminal), [
            .runFailed(runID, AgentFailure(message: "测试模型连接中断")),
        ])
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
                result: ToolExecutionResult(status: .declined, output: "用户拒绝")
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

    func testToolCallWithoutContinuationFailsBeforeToolExecution() async throws {
        let executorRecorder = ToolExecutorRecorder()
        let runID = RunID()
        let runtime = GenericAgentRuntime(
            provider: FixedToolProvider(
                calls: [ModelToolCall(
                    callID: "call_without_continuation",
                    name: "filesystem.read",
                    arguments: #"{"path":"README.md"}"#
                )],
                completionContinuation: nil
            ),
            configuration: .init(model: "test-model", reasoningEnabled: false),
            toolExecutor: ScriptedToolExecutor(
                recorder: executorRecorder,
                result: ToolExecutionResult(status: .success, output: "must not execute")
            )
        )

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
                message: "模型没有返回可续接的完整工具调用。"
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

    func testRunCancellationWinsWhenExecutorReturnsCancelledResult() async throws {
        let providerScript = SingleToolProviderScript()
        let executor = CancellationReturningToolExecutor()
        let runID = RunID()
        let runtime = GenericAgentRuntime(
            provider: SingleToolProvider(script: providerScript),
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

        let modelRequests = await providerScript.requests
        let cancelledRunIDs = await executor.cancelledRunIDs
        XCTAssertEqual(modelRequests.count, 1)
        XCTAssertEqual(cancelledRunIDs, [runID])
        XCTAssertEqual(events.filter(\.isTerminal), [.runCancelled(runID)])
    }

    func testRunCancellationWinsWhenExecutorReportsInfrastructureFailure() async throws {
        let providerScript = SingleToolProviderScript()
        let executor = CancellationFailingToolExecutor()
        let runID = RunID()
        let runtime = GenericAgentRuntime(
            provider: SingleToolProvider(script: providerScript),
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

        let modelRequests = await providerScript.requests
        XCTAssertEqual(modelRequests.count, 1)
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

private struct ThrowingToolExecutor: ToolExecutor {
    let error: any Error & Sendable
    var recorder: ToolExecutorRecorder? = nil

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
        await recorder?.record(request)
        throw error
    }
}

private enum TestExecutorFailure: Error, LocalizedError, Sendable {
    case disconnected

    var errorDescription: String? {
        "Tool Host 连接已中断。"
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

private actor DuplicateToolProviderScript {
    private(set) var requestCount = 0

    func nextEvents() -> [ModelEvent] {
        requestCount += 1
        if requestCount <= 2 {
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
            .textDelta("读取完成。"),
            .completed(ModelCompletion(continuation: nil)),
        ]
    }
}

private struct DuplicateToolProvider: ModelProvider {
    let script: DuplicateToolProviderScript
    let descriptor = ProviderDescriptor(id: "duplicate-tool", displayName: "Duplicate Tool")

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

private actor TwoRoundProviderScript {
    private(set) var requestCount = 0

    func beginRequest() -> Int {
        requestCount += 1
        return requestCount
    }
}

private struct FollowUpOverflowProvider: ModelProvider {
    let script: TwoRoundProviderScript
    let descriptor = ProviderDescriptor(id: "follow-up-overflow", displayName: "Follow-up Overflow")

    func modelCatalog() async throws -> [ModelCatalogEntry] {
        [ModelCatalogEntry(id: "test-model", supportsToolCalling: true)]
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if await script.beginRequest() == 1 {
                    continuation.yield(.toolCallCompleted(ModelToolCall(
                        callID: "call_read",
                        name: "filesystem.read",
                        arguments: #"{"path":"README.md"}"#
                    )))
                    continuation.yield(.completed(ModelCompletion(continuation: ModelContinuation(
                        format: "test",
                        payload: Data(#"{"output":[]}"#.utf8)
                    ))))
                    continuation.finish()
                } else {
                    continuation.finish(throwing: TestModelFailure.contextOverflow)
                }
            }
        }
    }
}

private struct FollowUpDisconnectProvider: ModelProvider {
    let script: TwoRoundProviderScript
    let descriptor = ProviderDescriptor(id: "follow-up-disconnect", displayName: "Follow-up Disconnect")

    func modelCatalog() async throws -> [ModelCatalogEntry] {
        [ModelCatalogEntry(id: "test-model", supportsToolCalling: true)]
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if await script.beginRequest() == 1 {
                    continuation.yield(.toolCallCompleted(ModelToolCall(
                        callID: "call_read",
                        name: "filesystem.read",
                        arguments: #"{"path":"README.md"}"#
                    )))
                    continuation.yield(.completed(ModelCompletion(continuation: ModelContinuation(
                        format: "test",
                        payload: Data(#"{"output":[]}"#.utf8)
                    ))))
                    continuation.finish()
                } else {
                    continuation.yield(.textDelta("已经读取，正在整理"))
                    continuation.finish(throwing: TestModelFailure.disconnected)
                }
            }
        }
    }
}

private enum TestModelFailure: Error, LocalizedError, ModelFailureClassifying, Sendable {
    case contextOverflow
    case disconnected

    var failureKind: ModelFailureKind {
        switch self {
        case .contextOverflow: .contextOverflow
        case .disconnected: .other
        }
    }

    var errorDescription: String? {
        switch self {
        case .contextOverflow: "测试模型上下文溢出"
        case .disconnected: "测试模型连接中断"
        }
    }
}

private actor FailingModelProviderScript {
    private(set) var requestCount = 0

    func beginRequest() {
        requestCount += 1
    }
}

private struct FailingModelProvider: ModelProvider {
    let script: FailingModelProviderScript
    let events: [ModelEvent]
    let descriptor = ProviderDescriptor(id: "failing-model", displayName: "Failing Model")

    func modelCatalog() async throws -> [ModelCatalogEntry] {
        [ModelCatalogEntry(id: "test-model")]
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await script.beginRequest()
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish(throwing: TestModelFailure.disconnected)
            }
        }
    }
}

private struct FixedToolProvider: ModelProvider {
    let calls: [ModelToolCall]
    var completionContinuation: ModelContinuation? = ModelContinuation(
        format: "test",
        payload: Data(#"{"output":[]}"#.utf8)
    )
    let descriptor = ProviderDescriptor(id: "fixed-tool", displayName: "Fixed Tool")

    func modelCatalog() async throws -> [ModelCatalogEntry] {
        [ModelCatalogEntry(id: "test-model", supportsToolCalling: true)]
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            for call in calls {
                continuation.yield(.toolCallCompleted(call))
            }
            continuation.yield(.completed(ModelCompletion(
                continuation: completionContinuation
            )))
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

private actor CancellationReturningToolExecutor: ToolExecutor {
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
    private var executionContinuation: CheckedContinuation<ToolExecutionResult, Never>?
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
        return await withCheckedContinuation { continuation in
            executionContinuation = continuation
        }
    }

    func cancel(runID: RunID) {
        cancelledRunIDs.append(runID)
        executionContinuation?.resume(returning: ToolExecutionResult(
            status: .cancelled,
            output: "工具已取消"
        ))
        executionContinuation = nil
    }
}

private actor CancellationFailingToolExecutor: ToolExecutor {
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
    private var executionContinuation: CheckedContinuation<ToolExecutionResult, Error>?

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
        return try await withCheckedThrowingContinuation { continuation in
            executionContinuation = continuation
        }
    }

    func cancel(runID: RunID) {
        executionContinuation?.resume(throwing: TestExecutorFailure.disconnected)
        executionContinuation = nil
    }
}
