use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::types::*;

// MARK: - Client → Daemon Request

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub id: i64,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientInfo {
    pub name: String,
    pub version: String,
}

// --- initialize ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InitializeParams {
    pub client_info: ClientInfo,
    pub protocol_version: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InitializeResult {
    pub daemon_version: String,
    pub protocol_version: String,
}

// --- shutdown ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShutdownParams {}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShutdownResult {}

// --- provider/configure ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderConfigureParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_id: Option<ProviderId>,
    pub vendor: Vendor,
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    #[serde(default)]
    pub thinking_enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderConfigureResult {
    pub provider_id: ProviderId,
    pub vendor: Vendor,
}

// --- provider/list ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderListParams {}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderListResult {
    pub providers: Vec<ProviderEntry>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderEntry {
    pub provider_id: ProviderId,
    pub vendor: Vendor,
    pub base_url: String,
    pub model: String,
    pub thinking_enabled: bool,
}

// --- provider/models ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderModelsParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_id: Option<ProviderId>,
    pub vendor: Vendor,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderModelsResult {
    pub models: Vec<ModelCatalogEntry>,
}

// --- codex/account ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CodexAccountParams {}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CodexAccountResult {
    pub requires_openai_auth: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account: Option<CodexAccount>,
}

// --- codex/models ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CodexModelsParams {}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CodexModelsResult {
    pub models: Vec<ModelCatalogEntry>,
}

// --- session/projects ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionProjectsParams {}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionProjectsResult {
    pub projects: Vec<Project>,
}

// --- session/project/create ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionProjectCreateParams {
    pub name: String,
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionProjectCreateResult {
    pub project: Project,
}

// --- session/list ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionListParams {
    pub project_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionListResult {
    pub sessions: Vec<Session>,
}

// --- session/create ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionCreateParams {
    pub project_id: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_id: Option<ProviderId>,
    pub vendor: Vendor,
    pub model: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionCreateResult {
    pub session: Session,
}

// --- session/delete ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionDeleteParams {
    pub session_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionDeleteResult {}

// --- run/start ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunStartParams {
    pub session_id: Uuid,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunStartResult {
    pub run_id: Uuid,
}

// --- run/cancel ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunCancelParams {
    pub run_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunCancelResult {}

// --- run/approve ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunApproveParams {
    pub approval_id: Uuid,
    pub decision: ApprovalDecision,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunApproveResult {}

// --- run/answer ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunAnswerParams {
    pub request_id: Uuid,
    pub answers: Vec<UserInputAnswer>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunAnswerResult {}

// --- run/compact ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunCompactParams {
    pub session_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunCompactResult {
    pub compaction: CompactionInfo,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompactionInfo {
    pub id: String,
    pub status: CompactionStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub before_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub after_tokens: Option<i64>,
}

// MARK: - Response

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Response {
    pub id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
}

impl RpcError {
    pub fn method_not_found(method: &str) -> Self {
        Self {
            code: -32601,
            message: format!("Method not found: {method}"),
        }
    }

    pub fn invalid_params(message: &str) -> Self {
        Self {
            code: -32602,
            message: message.to_string(),
        }
    }

    pub fn internal(message: &str) -> Self {
        Self {
            code: -32603,
            message: message.to_string(),
        }
    }

    pub fn timeout(method: &str) -> Self {
        Self {
            code: -32000,
            message: format!("Request timed out: {method}"),
        }
    }
}

// MARK: - Daemon → Client Event

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Event {
    pub event: String,
    pub data: serde_json::Value,
}

// --- message.delta ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MessageDeltaData {
    pub run_id: Uuid,
    pub session_id: Uuid,
    pub delta: String,
}

// --- reasoning.delta ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReasoningDeltaData {
    pub run_id: Uuid,
    pub session_id: Uuid,
    pub delta: String,
}

// --- tool.started ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolStartedData {
    pub run_id: Uuid,
    pub session_id: Uuid,
    pub tool_call_id: String,
    pub tool_name: String,
    pub arguments: String,
}

// --- tool.completed ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCompletedData {
    pub run_id: Uuid,
    pub session_id: Uuid,
    pub tool_call_id: String,
    pub tool_name: String,
    pub output: String,
}

// --- approval.requested ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApprovalRequestedData {
    pub run_id: Uuid,
    pub session_id: Uuid,
    pub approval_id: Uuid,
    pub kind: ApprovalKind,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub impact: ApprovalImpact,
    pub fingerprint: String,
    pub allows_session_approval: bool,
}

// --- approval.resolved ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApprovalResolvedData {
    pub run_id: Uuid,
    pub approval_id: Uuid,
    pub decision: ApprovalDecision,
}

// --- user_input.requested ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UserInputRequestedData {
    pub run_id: Uuid,
    pub session_id: Uuid,
    pub request_id: Uuid,
    pub questions: Vec<UserInputQuestion>,
}

// --- context.usage ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContextUsageData {
    pub run_id: Uuid,
    pub session_id: Uuid,
    pub current: TokenUsage,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accumulated: Option<TokenUsage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_window: Option<i64>,
    pub source: UsageSource,
}

// --- context.compaction ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContextCompactionData {
    pub run_id: Uuid,
    pub session_id: Uuid,
    pub id: String,
    pub runtime_kind: RuntimeKind,
    pub trigger: CompactionTrigger,
    pub status: CompactionStatus,
    pub started_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub before_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub after_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
}

// --- run.state ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunStateData {
    pub run_id: Uuid,
    pub session_id: Uuid,
    pub state: RunState,
}

// --- run.completed ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunCompletedData {
    pub run_id: Uuid,
    pub session_id: Uuid,
}

// --- run.failed ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunFailedData {
    pub run_id: Uuid,
    pub session_id: Uuid,
    pub error: RunError,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunError {
    pub code: ErrorCode,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovery_suggestion: Option<String>,
    #[serde(default)]
    pub retryable: bool,
}

// --- run.cancelled ---

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunCancelledData {
    pub run_id: Uuid,
    pub session_id: Uuid,
}

// MARK: - Event constructors

impl Event {
    pub fn message_delta(data: MessageDeltaData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "message.delta".into(),
            data: serde_json::to_value(data)?,
        })
    }

    pub fn reasoning_delta(data: ReasoningDeltaData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "reasoning.delta".into(),
            data: serde_json::to_value(data)?,
        })
    }

    pub fn tool_started(data: ToolStartedData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "tool.started".into(),
            data: serde_json::to_value(data)?,
        })
    }

    pub fn tool_completed(data: ToolCompletedData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "tool.completed".into(),
            data: serde_json::to_value(data)?,
        })
    }

    pub fn approval_requested(data: ApprovalRequestedData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "approval.requested".into(),
            data: serde_json::to_value(data)?,
        })
    }

    pub fn approval_resolved(data: ApprovalResolvedData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "approval.resolved".into(),
            data: serde_json::to_value(data)?,
        })
    }

    pub fn user_input_requested(data: UserInputRequestedData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "user_input.requested".into(),
            data: serde_json::to_value(data)?,
        })
    }

    pub fn context_usage(data: ContextUsageData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "context.usage".into(),
            data: serde_json::to_value(data)?,
        })
    }

    pub fn context_compaction(data: ContextCompactionData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "context.compaction".into(),
            data: serde_json::to_value(data)?,
        })
    }

    pub fn run_state(data: RunStateData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "run.state".into(),
            data: serde_json::to_value(data)?,
        })
    }

    pub fn run_completed(data: RunCompletedData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "run.completed".into(),
            data: serde_json::to_value(data)?,
        })
    }

    pub fn run_failed(data: RunFailedData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "run.failed".into(),
            data: serde_json::to_value(data)?,
        })
    }

    pub fn run_cancelled(data: RunCancelledData) -> serde_json::Result<Self> {
        Ok(Self {
            event: "run.cancelled".into(),
            data: serde_json::to_value(data)?,
        })
    }
}

// MARK: - JSONL helpers

pub fn encode_jsonl<T: Serialize>(value: &T) -> serde_json::Result<String> {
    let mut line = serde_json::to_string(value)?;
    line.push('\n');
    Ok(line)
}

pub fn decode_request(line: &str) -> serde_json::Result<Request> {
    serde_json::from_str(line.trim())
}

pub fn decode_response(line: &str) -> serde_json::Result<Response> {
    serde_json::from_str(line.trim())
}

pub fn decode_event(line: &str) -> serde_json::Result<Event> {
    serde_json::from_str(line.trim())
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip<T: Serialize + for<'de> Deserialize<'de> + PartialEq + std::fmt::Debug>(
        value: &T,
    ) {
        let json = serde_json::to_string(value).unwrap();
        let decoded: T = serde_json::from_str(&json).unwrap();
        assert_eq!(value, &decoded);
    }

    #[test]
    fn request_initialize_round_trip() {
        let req = Request {
            id: 1,
            method: "initialize".into(),
            params: serde_json::to_value(InitializeParams {
                client_info: ClientInfo {
                    name: "disco".into(),
                    version: "0.1.0".into(),
                },
                protocol_version: "v1".into(),
            })
            .unwrap(),
        };
        round_trip(&req);
    }

    #[test]
    fn response_success_round_trip() {
        let resp = Response {
            id: 1,
            result: Some(
                serde_json::to_value(InitializeResult {
                    daemon_version: "0.1.0".into(),
                    protocol_version: "v1".into(),
                })
                .unwrap(),
            ),
            error: None,
        };
        round_trip(&resp);
    }

    #[test]
    fn response_error_round_trip() {
        let resp = Response {
            id: 1,
            result: None,
            error: Some(RpcError::method_not_found("foo/bar")),
        };
        round_trip(&resp);
    }

    #[test]
    fn event_message_delta_round_trip() {
        let event = Event::message_delta(MessageDeltaData {
            run_id: Uuid::nil(),
            session_id: Uuid::nil(),
            delta: "你好".into(),
        })
        .unwrap();
        round_trip(&event);

        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("\"event\":\"message.delta\""));
        assert!(json.contains("\"delta\":\"你好\""));
    }

    #[test]
    fn event_run_completed_round_trip() {
        let event = Event::run_completed(RunCompletedData {
            run_id: Uuid::nil(),
            session_id: Uuid::nil(),
        })
        .unwrap();
        round_trip(&event);
    }

    #[test]
    fn event_run_failed_round_trip() {
        let event = Event::run_failed(RunFailedData {
            run_id: Uuid::nil(),
            session_id: Uuid::nil(),
            error: RunError {
                code: ErrorCode::ContextOverflow,
                message: "上下文溢出".into(),
                recovery_suggestion: Some("请新建会话".into()),
                retryable: false,
            },
        })
        .unwrap();
        round_trip(&event);
    }

    #[test]
    fn approval_impact_command_round_trip() {
        let impact = ApprovalImpact::Command {
            executable: "rm".into(),
            arguments: vec!["-rf".into(), "build/".into()],
            cwd: "/Users/test".into(),
        };
        round_trip(&impact);

        let json = serde_json::to_string(&impact).unwrap();
        assert!(json.contains("\"type\":\"command\""));
    }

    #[test]
    fn approval_impact_file_change_round_trip() {
        let impact = ApprovalImpact::FileChange {
            paths: vec!["src/main.rs".into()],
            summary: "修改了主文件".into(),
            diff: Some("@@ -1,3 +1,4 @@\n+new line".into()),
        };
        round_trip(&impact);
    }

    #[test]
    fn vendor_serialization() {
        let v = Vendor::Deepseek;
        let json = serde_json::to_string(&v).unwrap();
        assert_eq!(json, "\"deepseek\"");

        let v: Vendor = serde_json::from_str("\"kimi_code\"").unwrap();
        assert_eq!(v, Vendor::KimiCode);
    }

    #[test]
    fn jsonl_encode_decode() {
        let req = Request {
            id: 42,
            method: "run/start".into(),
            params: serde_json::to_value(RunStartParams {
                session_id: Uuid::nil(),
                text: "hello".into(),
            })
            .unwrap(),
        };
        let line = encode_jsonl(&req).unwrap();
        assert!(line.ends_with('\n'));
        let decoded = decode_request(line.trim()).unwrap();
        assert_eq!(req, decoded);
    }

    #[test]
    fn event_tool_started_round_trip() {
        let event = Event::tool_started(ToolStartedData {
            run_id: Uuid::nil(),
            session_id: Uuid::nil(),
            tool_call_id: "tc1".into(),
            tool_name: "shell".into(),
            arguments: r#"{"command":"ls -la"}"#.into(),
        })
        .unwrap();
        round_trip(&event);
    }

    #[test]
    fn context_usage_round_trip() {
        let event = Event::context_usage(ContextUsageData {
            run_id: Uuid::nil(),
            session_id: Uuid::nil(),
            current: TokenUsage {
                input: 1234,
                output: 567,
                total: 1801,
                cached_input: Some(800),
                reasoning_output: None,
            },
            accumulated: Some(TokenUsage {
                input: 5000,
                output: 2000,
                total: 7000,
                cached_input: None,
                reasoning_output: None,
            }),
            context_window: Some(128000),
            source: UsageSource::Provider,
        })
        .unwrap();
        round_trip(&event);
    }

    #[test]
    fn user_input_requested_round_trip() {
        let event = Event::user_input_requested(UserInputRequestedData {
            run_id: Uuid::nil(),
            session_id: Uuid::nil(),
            request_id: Uuid::nil(),
            questions: vec![UserInputQuestion {
                id: "q1".into(),
                header: "框架".into(),
                question: "选哪个？".into(),
                options: vec![
                    UserInputOption {
                        id: "0".into(),
                        label: "React".into(),
                        description: None,
                    },
                    UserInputOption {
                        id: "1".into(),
                        label: "Vue".into(),
                        description: Some("Vue 3".into()),
                    },
                ],
                allows_other: true,
            }],
        })
        .unwrap();
        round_trip(&event);
    }

    #[test]
    fn provider_configure_params_round_trip() {
        let req = Request {
            id: 3,
            method: "provider/configure".into(),
            params: serde_json::to_value(ProviderConfigureParams {
                provider_id: Some(ProviderId::legacy_default_for_vendor(Vendor::Deepseek)),
                vendor: Vendor::Deepseek,
                base_url: "https://api.deepseek.com/v1".into(),
                api_key: "sk-xxx".into(),
                model: "deepseek-chat".into(),
                thinking_enabled: false,
            })
            .unwrap(),
        };
        round_trip(&req);
    }

    #[test]
    fn context_compaction_round_trip() {
        let event = Event::context_compaction(ContextCompactionData {
            run_id: Uuid::nil(),
            session_id: Uuid::nil(),
            id: "c1".into(),
            runtime_kind: RuntimeKind::Generic,
            trigger: CompactionTrigger::Automatic,
            status: CompactionStatus::Completed,
            started_at: "2026-01-01T00:00:00Z".into(),
            completed_at: Some("2026-01-01T00:00:05Z".into()),
            before_tokens: Some(100000),
            after_tokens: Some(30000),
            error_message: None,
        })
        .unwrap();
        round_trip(&event);
    }

    #[test]
    fn optional_fields_omitted_in_json() {
        let usage = TokenUsage {
            input: 100,
            output: 50,
            total: 150,
            cached_input: None,
            reasoning_output: None,
        };
        let json = serde_json::to_string(&usage).unwrap();
        assert!(!json.contains("cached_input"));
        assert!(!json.contains("reasoning_output"));
    }

    #[test]
    fn run_state_variants() {
        for state in [
            RunState::Connecting,
            RunState::Running,
            RunState::WaitingForTool,
            RunState::WaitingForApproval,
            RunState::WaitingForUserInput,
            RunState::Cancelling,
        ] {
            let json = serde_json::to_string(&state).unwrap();
            let decoded: RunState = serde_json::from_str(&json).unwrap();
            assert_eq!(state, decoded);
        }
    }
}
