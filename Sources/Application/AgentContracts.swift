import Foundation

enum BackendEvent {
    case text(text: String, itemID: String?)
    case reasoning(text: String, itemID: String?)
    case item(MessageItem)
    case tool(
        id: String,
        title: String,
        state: ToolCallStatus,
        input: JSONValue?,
        output: String?,
        error: String?
    )
}

enum AgentEvent {
    case runStarted(sessionID: String, runID: String)
    case sessionAgentThreadIDUpdated(sessionID: String, agentThreadID: String)
    case text(sessionID: String, runID: String, text: String, itemID: String?)
    case reasoning(sessionID: String, runID: String, text: String, itemID: String?)
    case item(sessionID: String, runID: String, item: MessageItem)
    case tool(
        sessionID: String,
        runID: String,
        id: String,
        title: String,
        state: ToolCallStatus,
        input: JSONValue?,
        output: String?,
        error: String?
    )
    case userInputRequested(UserInputRequest)
    case userInputResolved(id: String)
    case approvalRequested(
        sessionID: String,
        runID: String,
        approvalID: String,
        toolName: String,
        title: String?,
        input: [String: JSONValue]
    )
    case approvalResolved(sessionID: String, runID: String, approvalID: String)
    case runFinished(
        sessionID: String,
        runID: String,
        status: RunStatus,
        sessionTitle: String?,
        error: String?
    )
}

final class CancellationToken {
    private let stateLock = NSLock()
    private var cancelled = false
    private var cancellationHandler: (() -> Void)?

    var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    var onCancel: (() -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return cancellationHandler
        }
        set {
            stateLock.lock()
            cancellationHandler = newValue
            let shouldInvoke = cancelled && newValue != nil
            stateLock.unlock()
            if shouldInvoke {
                newValue?()
            }
        }
    }

    func cancel() {
        stateLock.lock()
        guard !cancelled else {
            stateLock.unlock()
            return
        }
        cancelled = true
        let handler = cancellationHandler
        stateLock.unlock()
        handler?()
    }
}

struct BackendRunContext {
    let agentThreadID: String?
    let modelID: String?
    let reasoningEffort: ReasoningEffort?
    let sandboxMode: SandboxMode?
    let workingDirectory: String
    let prompt: String
    let mode: RunMode
    let emit: (BackendEvent) -> Void
    let cancellation: CancellationToken
    let reportAgentThreadID: (String) -> Void
    let requestUserInput: ([UserInputQuestion]) async -> [[String]]?
    let requestApproval: (
        _ toolName: String,
        _ title: String?,
        _ input: [String: JSONValue]
    ) async -> ApprovalDecision
}

struct ModelListResult {
    let models: [ModelInfo]
    let failureDescription: String?
}

protocol AgentBackend: AnyObject {
    var supportsPlan: Bool { get }
    func listModels() async -> ModelListResult
    func loadMessages(agentThreadID: String, workingDirectory: String) async throws -> [ConversationMessage]
    func run(context: BackendRunContext) async throws -> String
    func shutdown()
}

struct UserInputQuestion: Identifiable {
    let id: String
    let title: String
    let options: [Option]
    let allowsMultiple: Bool
    let allowsCustom: Bool
    let isSecret: Bool

    struct Option {
        let label: String
        let description: String
    }
}

struct UserInputRequest: Identifiable {
    let id: String
    let sessionID: String
    let runID: String
    let questions: [UserInputQuestion]
}
