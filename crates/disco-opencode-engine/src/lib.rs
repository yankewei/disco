//! Local OpenCode ACP discovery and client transport, built on the official
//! [`agent-client-protocol`](https://crates.io/crates/agent-client-protocol) SDK.
//!
//! OpenCode exposes two surfaces: a headless HTTP server (`opencode serve`) and the
//! Agent Client Protocol subprocess (`opencode acp`). Per ADR 0002, Disco integrates
//! through ACP: Disco owns durable run events, approvals, and conversation history
//! while the OpenCode agent runs its own sandbox, tool, and approval semantics.
//!
//! This crate spawns `opencode acp` over stdio and speaks the ACP lifecycle
//! (initialize -> session/new -> session/prompt -> session/cancel) through the SDK:
//! the SDK owns the JSON-RPC connection, typed message parsing, and subprocess
//! lifecycle, while this crate projects typed `session/update` notifications into
//! the shared Disco activity model.

use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::schema::v1::{
    CancelNotification, ContentBlock, ContentChunk, Cost, Implementation, InitializeRequest, Plan,
    RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse, SessionId,
    SessionNotification, SessionUpdate, StopReason, ToolCallContent, ToolCallId, ToolCallStatus,
    UsageUpdate,
};
use agent_client_protocol::util::MatchDispatch;
use agent_client_protocol::{
    AcpAgent, AcpAgentConfig, ActiveSession, Agent, Client, ConnectionTo, SessionMessage,
};
use futures::StreamExt;
use futures::channel::mpsc;
use std::collections::HashMap;
use std::env;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use thiserror::Error;

/// The ACP protocol version this client speaks.
pub const ACP_PROTOCOL_VERSION: u64 = 1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OpenCodeInstallation {
    pub path: PathBuf,
    pub version: String,
}

/// A single activity surfaced from an ACP `session/update` notification.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OpenCodeActivity {
    pub id: String,
    pub title: String,
    pub detail: String,
    pub success: bool,
}

/// Aggregated token usage reported through ACP `usage_update` notifications.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct OpenCodeTokenUsage {
    pub used: u64,
    pub size: u64,
    pub cost_amount: Option<f64>,
    pub cost_currency: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OpenCodeTurnResult {
    pub session_id: String,
    pub text: String,
    pub activities: Vec<OpenCodeActivity>,
    pub usage: OpenCodeTokenUsage,
    pub interrupted: bool,
}

/// Commands the connection thread services on behalf of the caller.
enum Command {
    NewSession {
        cwd: PathBuf,
        reply: std::sync::mpsc::Sender<Result<String, OpenCodeError>>,
    },
    RunTurn {
        session_id: String,
        prompt: String,
        reply: std::sync::mpsc::Sender<Result<OpenCodeTurnResult, OpenCodeError>>,
    },
}

#[derive(Clone)]
pub struct OpenCodeRuntime {
    installation: OpenCodeInstallation,
    connection: ConnectionTo<Agent>,
    command_tx: mpsc::UnboundedSender<Command>,
    interrupt_requested: Arc<AtomicBool>,
}

impl OpenCodeRuntime {
    /// Discovers the `opencode` binary, spawns `opencode acp`, and completes the
    /// ACP `initialize` handshake before returning.
    pub fn connect(workspace: &Path) -> Result<Self, OpenCodeError> {
        let installation = discover_opencode()?;
        // `--cwd` mirrors the old `Command::current_dir(workspace)`: the OpenCode
        // agent's own project context starts in the workspace. Session workspace
        // is additionally pinned per-session via `session/new` `cwd`.
        let agent = AcpAgent::new(
            AcpAgentConfig::new(&installation.path)
                .arg("acp")
                .arg("--cwd")
                .arg(workspace.to_string_lossy().into_owned()),
        );
        let (startup_tx, startup_rx) =
            std::sync::mpsc::channel::<Result<ConnectionTo<Agent>, OpenCodeError>>();
        let (command_tx, command_rx) = mpsc::unbounded();
        let interrupt_requested = Arc::new(AtomicBool::new(false));

        thread::spawn(move || {
            let result = futures::executor::block_on(run_connection(agent, command_rx, startup_tx));
            if let Err(error) = result {
                eprintln!("opencode acp connection ended: {error}");
            }
        });

        let connection = startup_rx.recv().map_err(|_| {
            OpenCodeError::Disconnected("opencode acp exited during startup".into())
        })??;

        Ok(Self {
            installation,
            connection,
            command_tx,
            interrupt_requested,
        })
    }

    pub const fn installation(&self) -> &OpenCodeInstallation {
        &self.installation
    }

    /// Starts a new ACP session in `workspace` and returns the session id.
    pub fn new_session(&self, workspace: &Path) -> Result<String, OpenCodeError> {
        let (reply_tx, reply_rx) = std::sync::mpsc::channel();
        self.command_tx
            .unbounded_send(Command::NewSession {
                cwd: workspace.to_path_buf(),
                reply: reply_tx,
            })
            .map_err(|_| OpenCodeError::Disconnected("connection thread ended".into()))?;
        reply_rx
            .recv()
            .map_err(|_| OpenCodeError::Disconnected("connection thread ended".into()))?
    }

    /// Runs one prompt turn against an existing ACP session.
    pub fn run_turn(
        &self,
        session_id: &str,
        prompt: &str,
    ) -> Result<OpenCodeTurnResult, OpenCodeError> {
        let (reply_tx, reply_rx) = std::sync::mpsc::channel();
        self.command_tx
            .unbounded_send(Command::RunTurn {
                session_id: session_id.to_owned(),
                prompt: prompt.to_owned(),
                reply: reply_tx,
            })
            .map_err(|_| OpenCodeError::Disconnected("connection thread ended".into()))?;
        reply_rx
            .recv()
            .map_err(|_| OpenCodeError::Disconnected("connection thread ended".into()))?
    }

    /// Clears any pending interrupt flag before starting a turn.
    pub fn prepare_turn(&self) {
        self.interrupt_requested.store(false, Ordering::SeqCst);
    }

    /// Requests cancellation of a running prompt turn. ACP agents abort the current
    /// work and settle the in-flight `session/prompt` request.
    pub fn cancel_turn(&self, session_id: &str) -> Result<(), OpenCodeError> {
        self.interrupt_requested.store(true, Ordering::SeqCst);
        let result = self
            .connection
            .send_notification(CancelNotification::new(SessionId::new(session_id)))
            .map_err(OpenCodeError::from);
        self.interrupt_requested.store(false, Ordering::SeqCst);
        result
    }
}

pub fn discover_opencode() -> Result<OpenCodeInstallation, OpenCodeError> {
    for candidate in opencode_candidates() {
        if !candidate.is_file() {
            continue;
        }
        let output = std::process::Command::new(&candidate)
            .arg("--version")
            .output();
        let Ok(output) = output else { continue };
        if !output.status.success() {
            continue;
        }
        let version = [&output.stdout, &output.stderr]
            .into_iter()
            .find_map(|bytes| {
                let version = String::from_utf8_lossy(bytes).trim().to_owned();
                (!version.is_empty()).then_some(version)
            })
            .unwrap_or_else(|| "unknown".to_owned());
        return Ok(OpenCodeInstallation {
            path: candidate,
            version,
        });
    }
    Err(OpenCodeError::NotInstalled)
}

fn opencode_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = env::var_os("OPENCODE_BIN") {
        candidates.push(PathBuf::from(path));
    }
    if let Some(paths) = env::var_os("PATH") {
        candidates.extend(env::split_paths(&paths).map(|path| path.join("opencode")));
    }
    if let Some(home) = env::var_os("HOME").map(PathBuf::from) {
        candidates.push(home.join(".local/bin/opencode"));
        candidates.push(home.join(".opencode/bin/opencode"));
    }
    candidates.push(PathBuf::from("/opt/homebrew/bin/opencode"));
    candidates.push(PathBuf::from("/usr/local/bin/opencode"));
    candidates.dedup();
    candidates
}

/// Drives the ACP connection on its own thread until the command channel closes.
///
/// The SDK runs the connection, dispatch loop, and `main_fn` on the single
/// executor this future drives; requests sent from `main_fn` resolve because the
/// dispatch loop is polled alongside it. When the command channel closes (runtime
/// dropped), `main_fn` returns, the connection shuts down, and the SDK terminates
/// the `opencode acp` process group.
async fn run_connection(
    agent: AcpAgent,
    command_rx: mpsc::UnboundedReceiver<Command>,
    startup_tx: std::sync::mpsc::Sender<Result<ConnectionTo<Agent>, OpenCodeError>>,
) -> Result<(), OpenCodeError> {
    let result: Result<(), agent_client_protocol::Error> = Client
        .builder()
        .name("disco-opencode")
        .on_receive_request(
            async move |_request: RequestPermissionRequest, responder, _connection| {
                // Permission requests are declined so a turn never blocks on an
                // unobserved approval prompt; Disco's native approvals map separately.
                responder.respond(RequestPermissionResponse::new(
                    RequestPermissionOutcome::Cancelled,
                ))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .connect_with(agent, async |connection| {
            let initialize = InitializeRequest::new(ProtocolVersion::V1)
                .client_info(Implementation::new("disco", env!("CARGO_PKG_VERSION")));
            connection.send_request(initialize).block_task().await?;
            let _ = startup_tx.send(Ok(connection.clone()));
            command_loop(connection, command_rx).await
        })
        .await;

    match result {
        Ok(()) => Ok(()),
        Err(error) => {
            let message = error.to_string();
            let _ = startup_tx.send(Err(OpenCodeError::Disconnected(message)));
            Err(error.into())
        }
    }
}

async fn command_loop(
    connection: ConnectionTo<Agent>,
    mut command_rx: mpsc::UnboundedReceiver<Command>,
) -> Result<(), agent_client_protocol::Error> {
    let mut sessions: HashMap<SessionId, ActiveSession<'static, Agent>> = HashMap::new();
    while let Some(command) = command_rx.next().await {
        match command {
            Command::NewSession { cwd, reply } => {
                let result = new_session(&connection, &mut sessions, &cwd).await;
                let _ = reply.send(result);
            }
            Command::RunTurn {
                session_id,
                prompt,
                reply,
            } => {
                let result = run_turn(&mut sessions, &session_id, &prompt).await;
                let _ = reply.send(result);
            }
        }
    }
    Ok(())
}

async fn new_session(
    connection: &ConnectionTo<Agent>,
    sessions: &mut HashMap<SessionId, ActiveSession<'static, Agent>>,
    cwd: &Path,
) -> Result<String, OpenCodeError> {
    let session = connection
        .build_session(cwd)
        .block_task()
        .start_session()
        .await?;
    let session_id = session.session_id().clone();
    sessions.insert(session_id.clone(), session);
    Ok(session_id.to_string())
}

async fn run_turn(
    sessions: &mut HashMap<SessionId, ActiveSession<'static, Agent>>,
    session_id: &str,
    prompt: &str,
) -> Result<OpenCodeTurnResult, OpenCodeError> {
    let session = sessions
        .get_mut(&SessionId::new(session_id))
        .ok_or_else(|| OpenCodeError::UnknownSession(session_id.to_owned()))?;
    session.send_prompt(prompt)?;

    let mut text = String::new();
    let mut activities = Vec::new();
    let mut usage = OpenCodeTokenUsage::default();

    let interrupted = loop {
        match session.read_update().await? {
            SessionMessage::SessionMessage(dispatch) => {
                MatchDispatch::new(dispatch)
                    .if_notification(async |notification: SessionNotification| {
                        apply_update(notification.update, &mut text, &mut activities, &mut usage);
                        Ok(())
                    })
                    .await
                    .otherwise_ignore()?;
            }
            SessionMessage::StopReason(reason) => break matches!(reason, StopReason::Cancelled),
            // Future SDK message kinds are ignored; the turn ends on StopReason.
            _ => {}
        }
    };

    Ok(OpenCodeTurnResult {
        session_id: session_id.to_owned(),
        text,
        activities,
        usage,
        interrupted,
    })
}

/// Applies one typed ACP `session/update` notification to the running projection.
/// Pure and unit-testable.
fn apply_update(
    update: SessionUpdate,
    text: &mut String,
    activities: &mut Vec<OpenCodeActivity>,
    usage: &mut OpenCodeTokenUsage,
) {
    match update {
        SessionUpdate::AgentMessageChunk(ContentChunk {
            content: ContentBlock::Text(chunk),
            ..
        }) => text.push_str(&chunk.text),
        SessionUpdate::Plan(Plan { entries, .. }) => {
            activities.push(OpenCodeActivity {
                id: format!("plan-{}", activities.len()),
                title: "Execution plan".into(),
                detail: entries
                    .iter()
                    .map(|entry| entry.content.as_str())
                    .collect::<Vec<_>>()
                    .join("\n"),
                success: true,
            });
        }
        SessionUpdate::ToolCall(tool_call) => {
            upsert_tool_activity(
                activities,
                &tool_call.tool_call_id,
                Some(tool_call.title),
                tool_call.status,
                &tool_call.content,
            );
        }
        SessionUpdate::ToolCallUpdate(update) => {
            upsert_tool_activity(
                activities,
                &update.tool_call_id,
                update.fields.title,
                update.fields.status.unwrap_or(ToolCallStatus::Pending),
                update.fields.content.as_deref().unwrap_or_default(),
            );
        }
        SessionUpdate::UsageUpdate(UsageUpdate {
            used, size, cost, ..
        }) => {
            usage.used = used;
            usage.size = size;
            if let Some(Cost {
                amount, currency, ..
            }) = cost
            {
                usage.cost_amount = Some(amount);
                usage.cost_currency = Some(currency);
            }
        }
        _ => {}
    }
}

/// Inserts a tool activity or refreshes the one with the same id, mirroring how
/// a `tool_call` start is later replaced by `tool_call_update`s.
fn upsert_tool_activity(
    activities: &mut Vec<OpenCodeActivity>,
    tool_call_id: &ToolCallId,
    title: Option<String>,
    status: ToolCallStatus,
    content: &[ToolCallContent],
) {
    let id = tool_call_id.to_string();
    let detail = tool_call_text(content);
    let success = status == ToolCallStatus::Completed;
    if let Some(existing) = activities.iter_mut().find(|activity| activity.id == id) {
        existing.detail = detail;
        existing.success = success;
    } else {
        activities.push(OpenCodeActivity {
            id,
            title: title.unwrap_or_else(|| "Tool call".to_owned()),
            detail,
            success,
        });
    }
}

/// Extracts concatenated text content blocks from a tool call update.
fn tool_call_text(content: &[ToolCallContent]) -> String {
    content
        .iter()
        .filter_map(|block| match block {
            ToolCallContent::Content(content) => match &content.content {
                ContentBlock::Text(text) => Some(text.text.clone()),
                _ => None,
            },
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[derive(Debug, Error)]
pub enum OpenCodeError {
    #[error("OpenCode CLI is not installed")]
    NotInstalled,
    #[error("opencode acp session {0} does not exist")]
    UnknownSession(String),
    #[error("opencode acp connection closed: {0}")]
    Disconnected(String),
    #[error("opencode acp failed: {0}")]
    Sdk(#[from] agent_client_protocol::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

#[cfg(test)]
mod tests {
    use super::{OpenCodeTokenUsage, apply_update, tool_call_text};
    use agent_client_protocol::schema::v1::{
        Content, ContentBlock, ContentChunk, Cost, Plan, PlanEntry, PlanEntryPriority,
        PlanEntryStatus, SessionUpdate, TextContent, ToolCall, ToolCallContent, ToolCallStatus,
        ToolCallUpdate, ToolCallUpdateFields, UsageUpdate,
    };

    fn text_chunk(content: &str) -> SessionUpdate {
        SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(TextContent::new(
            content,
        ))))
    }

    fn projection() -> (String, Vec<super::OpenCodeActivity>, OpenCodeTokenUsage) {
        (String::new(), Vec::new(), OpenCodeTokenUsage::default())
    }

    #[test]
    fn agent_message_chunks_accumulate_delta_text() {
        let (mut text, mut activities, mut usage) = projection();
        apply_update(text_chunk("Hello "), &mut text, &mut activities, &mut usage);
        apply_update(text_chunk("world"), &mut text, &mut activities, &mut usage);
        assert_eq!(text, "Hello world");
        assert!(activities.is_empty());
    }

    #[test]
    fn plan_becomes_a_plan_activity() {
        let (mut text, mut activities, mut usage) = projection();
        apply_update(
            SessionUpdate::Plan(Plan::new(vec![
                PlanEntry::new(
                    "Check syntax",
                    PlanEntryPriority::High,
                    PlanEntryStatus::Pending,
                ),
                PlanEntry::new(
                    "Run tests",
                    PlanEntryPriority::Low,
                    PlanEntryStatus::Pending,
                ),
            ])),
            &mut text,
            &mut activities,
            &mut usage,
        );
        assert_eq!(activities.len(), 1);
        assert_eq!(activities[0].title, "Execution plan");
        assert!(activities[0].detail.contains("Run tests"));
    }

    #[test]
    fn tool_call_updates_replace_in_place() {
        let (mut text, mut activities, mut usage) = projection();
        apply_update(
            SessionUpdate::ToolCall(
                ToolCall::new("call-1", "Ran tests").status(ToolCallStatus::InProgress),
            ),
            &mut text,
            &mut activities,
            &mut usage,
        );
        apply_update(
            SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                "call-1",
                ToolCallUpdateFields::new()
                    .status(ToolCallStatus::Completed)
                    .content(vec![ToolCallContent::Content(Content::new(
                        ContentBlock::Text(TextContent::new("3 passed")),
                    ))]),
            )),
            &mut text,
            &mut activities,
            &mut usage,
        );
        assert_eq!(activities.len(), 1);
        assert_eq!(activities[0].id, "call-1");
        assert_eq!(activities[0].title, "Ran tests");
        assert_eq!(activities[0].success, true);
        assert!(activities[0].detail.contains("3 passed"));
    }

    #[test]
    fn usage_update_populates_cumulative_tokens_and_cost() {
        let (mut text, mut activities, mut usage) = projection();
        apply_update(
            SessionUpdate::UsageUpdate(
                UsageUpdate::new(53000, 200000).cost(Cost::new(0.045, "USD")),
            ),
            &mut text,
            &mut activities,
            &mut usage,
        );
        assert_eq!(usage.used, 53000);
        assert_eq!(usage.size, 200000);
        assert_eq!(usage.cost_amount, Some(0.045));
        assert_eq!(usage.cost_currency.as_deref(), Some("USD"));
    }

    #[test]
    fn tool_call_text_reads_nested_text_content() {
        let content = vec![
            ToolCallContent::Content(Content::new(ContentBlock::Text(TextContent::new("a")))),
            ToolCallContent::Content(Content::new(ContentBlock::Text(TextContent::new("b")))),
        ];
        assert_eq!(tool_call_text(&content), "a\nb");
    }
}
