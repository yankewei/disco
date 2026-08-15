//! Generic Disco ACP engine, built on the official
//! [`agent-client-protocol`](https://crates.io/crates/agent-client-protocol) SDK.
//!
//! Any agent that speaks the Agent Client Protocol over stdio (OpenCode, Kimi
//! CLI, Pi, ...) runs through this crate: it owns the connection thread, the
//! ACP lifecycle (initialize -> session/new -> session/prompt -> session/cancel),
//! and the projection of typed `session/update` notifications into the shared
//! Disco activity model. Per-agent differences — how the binary is discovered,
//! how it enters ACP mode, how models are listed, and how a model is pinned on a
//! session — are confined to [`AcpSpec`], so wiring a new CLI is a spec, not an
//! engine rewrite.
//!
//! The SDK owns the JSON-RPC connection, typed message parsing, and subprocess
//! lifecycle; protocol versioning stays a connection-level concern negotiated by
//! the SDK (stable v1 today, with v1 fallback once draft v2 lands).

use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::schema::v1::{
    CancelNotification, ContentBlock, ContentChunk, Cost, Implementation, InitializeRequest, Plan,
    RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse, SessionId,
    SessionNotification, SessionUpdate, SetSessionConfigOptionRequest, StopReason, ToolCallContent,
    ToolCallId, ToolCallStatus, UsageUpdate,
};
pub use agent_client_protocol::schema::v1::{
    SessionConfigId, SessionConfigOptionValue, SessionConfigValueId,
};
use agent_client_protocol::util::MatchDispatch;
use agent_client_protocol::{
    AcpAgent, AcpAgentConfig, ActiveSession, Agent, Client, ConnectionTo, SessionMessage,
};
use futures::StreamExt;
use futures::channel::mpsc;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use thiserror::Error;

/// A locally installed ACP agent CLI.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcpInstallation {
    pub path: PathBuf,
    pub version: String,
}

/// A model an agent exposes through its own provider configuration.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcpModel {
    /// Fully qualified id in the agent's own selector form.
    pub id: String,
    /// Display name reported by the agent CLI.
    pub name: String,
}

/// A single activity surfaced from an ACP `session/update` notification.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcpActivity {
    pub id: String,
    pub title: String,
    pub detail: String,
    pub success: bool,
}

/// Aggregated token usage reported through ACP `usage_update` notifications.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AcpTokenUsage {
    pub used: u64,
    pub size: u64,
    pub cost_amount: Option<f64>,
    pub cost_currency: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AcpTurnResult {
    pub session_id: String,
    pub text: String,
    pub activities: Vec<AcpActivity>,
    pub usage: AcpTokenUsage,
    pub interrupted: bool,
}

/// Per-agent wiring for the generic engine. Every field is agent-specific
/// knowledge that ACP itself does not standardize: binary discovery, ACP-mode
/// arguments, model listing, and the session config option that pins a model.
#[derive(Clone)]
pub struct AcpSpec {
    /// Display name used in errors and the client implementation name
    /// (e.g. "OpenCode", "Kimi", "Pi").
    pub name: &'static str,
    /// Arguments that report the CLI version.
    pub version_args: &'static [&'static str],
    /// Binary candidates in priority order, env override first.
    pub binary_candidates: fn() -> Vec<PathBuf>,
    /// Arguments after the binary that start the agent in ACP mode.
    pub acp_args: fn(workspace: &Path) -> Vec<String>,
    /// Lists models via the agent CLI's own model-listing command.
    pub list_models: fn(&AcpInstallation) -> Result<Vec<AcpModel>, AcpError>,
    /// Builds the session config option that pins one model for a turn. ACP
    /// leaves option ids and value forms to each agent; this is where that
    /// convention lives.
    pub model_config: fn(model_id: &str) -> (SessionConfigId, SessionConfigOptionValue),
}

/// Discovers the agent binary and reports its version.
pub fn discover(spec: &AcpSpec) -> Result<AcpInstallation, AcpError> {
    for candidate in (spec.binary_candidates)() {
        if !candidate.is_file() {
            continue;
        }
        let output = std::process::Command::new(&candidate)
            .args(spec.version_args)
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
        return Ok(AcpInstallation {
            path: candidate,
            version,
        });
    }
    Err(AcpError::NotInstalled { agent: spec.name })
}

/// Commands the connection thread services on behalf of the caller.
enum Command {
    NewSession {
        cwd: PathBuf,
        reply: std::sync::mpsc::Sender<Result<String, AcpError>>,
    },
    RunTurn {
        session_id: String,
        prompt: String,
        model: String,
        reply: std::sync::mpsc::Sender<Result<AcpTurnResult, AcpError>>,
    },
}

#[derive(Clone)]
pub struct AcpRuntime {
    installation: AcpInstallation,
    connection: ConnectionTo<Agent>,
    command_tx: mpsc::UnboundedSender<Command>,
    interrupt_requested: Arc<AtomicBool>,
}

impl AcpRuntime {
    /// Discovers the agent binary, spawns it in ACP mode, and completes the
    /// ACP `initialize` handshake before returning.
    pub fn connect(spec: AcpSpec, workspace: &Path) -> Result<Self, AcpError> {
        let installation = discover(&spec)?;
        let mut config = AcpAgentConfig::new(&installation.path);
        for arg in (spec.acp_args)(workspace) {
            config = config.arg(arg);
        }
        let agent = AcpAgent::new(config);
        let (startup_tx, startup_rx) =
            std::sync::mpsc::channel::<Result<ConnectionTo<Agent>, AcpError>>();
        let (command_tx, command_rx) = mpsc::unbounded();
        let interrupt_requested = Arc::new(AtomicBool::new(false));
        let agent_name = spec.name;

        thread::spawn(move || {
            let result =
                futures::executor::block_on(run_connection(agent, spec, command_rx, startup_tx));
            if let Err(error) = result {
                eprintln!("{agent_name} acp connection ended: {error}");
            }
        });

        let connection = startup_rx.recv().map_err(|_| {
            AcpError::Disconnected(format!("{agent_name} acp exited during startup"))
        })??;

        Ok(Self {
            installation,
            connection,
            command_tx,
            interrupt_requested,
        })
    }

    pub const fn installation(&self) -> &AcpInstallation {
        &self.installation
    }

    /// Starts a new ACP session in `workspace` and returns the session id.
    pub fn new_session(&self, workspace: &Path) -> Result<String, AcpError> {
        let (reply_tx, reply_rx) = std::sync::mpsc::channel();
        self.command_tx
            .unbounded_send(Command::NewSession {
                cwd: workspace.to_path_buf(),
                reply: reply_tx,
            })
            .map_err(|_| AcpError::Disconnected("connection thread ended".into()))?;
        reply_rx
            .recv()
            .map_err(|_| AcpError::Disconnected("connection thread ended".into()))?
    }

    /// Runs one prompt turn against an existing ACP session. The spec's model
    /// config option is set on the session first so the turn runs with the
    /// selected model.
    pub fn run_turn(
        &self,
        session_id: &str,
        prompt: &str,
        model: &str,
    ) -> Result<AcpTurnResult, AcpError> {
        let (reply_tx, reply_rx) = std::sync::mpsc::channel();
        self.command_tx
            .unbounded_send(Command::RunTurn {
                session_id: session_id.to_owned(),
                prompt: prompt.to_owned(),
                model: model.to_owned(),
                reply: reply_tx,
            })
            .map_err(|_| AcpError::Disconnected("connection thread ended".into()))?;
        reply_rx
            .recv()
            .map_err(|_| AcpError::Disconnected("connection thread ended".into()))?
    }

    /// Clears any pending interrupt flag before starting a turn.
    pub fn prepare_turn(&self) {
        self.interrupt_requested.store(false, Ordering::SeqCst);
    }

    /// Requests cancellation of a running prompt turn. ACP agents abort the current
    /// work and settle the in-flight `session/prompt` request.
    pub fn cancel_turn(&self, session_id: &str) -> Result<(), AcpError> {
        self.interrupt_requested.store(true, Ordering::SeqCst);
        let result = self
            .connection
            .send_notification(CancelNotification::new(SessionId::new(session_id)))
            .map_err(AcpError::from);
        self.interrupt_requested.store(false, Ordering::SeqCst);
        result
    }
}

/// Drives the ACP connection on its own thread until the command channel closes.
///
/// The SDK runs the connection, dispatch loop, and `main_fn` on the single
/// executor this future drives; requests sent from `main_fn` resolve because the
/// dispatch loop is polled alongside it. When the command channel closes (runtime
/// dropped), `main_fn` returns, the connection shuts down, and the SDK terminates
/// the agent process group.
async fn run_connection(
    agent: AcpAgent,
    spec: AcpSpec,
    command_rx: mpsc::UnboundedReceiver<Command>,
    startup_tx: std::sync::mpsc::Sender<Result<ConnectionTo<Agent>, AcpError>>,
) -> Result<(), AcpError> {
    let agent_name = spec.name;
    let client_name = format!("disco-{}", agent_name.to_lowercase());
    let result: Result<(), agent_client_protocol::Error> = Client
        .builder()
        .name(client_name)
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
            command_loop(connection, spec, command_rx).await
        })
        .await;

    match result {
        Ok(()) => Ok(()),
        Err(error) => {
            let message = error.to_string();
            let _ = startup_tx.send(Err(AcpError::Disconnected(format!(
                "{agent_name} acp connection failed: {message}"
            ))));
            Err(AcpError::Sdk(error))
        }
    }
}

async fn command_loop(
    connection: ConnectionTo<Agent>,
    spec: AcpSpec,
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
                model,
                reply,
            } => {
                let result = run_turn(
                    &connection,
                    &spec,
                    &mut sessions,
                    &session_id,
                    &prompt,
                    &model,
                )
                .await;
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
) -> Result<String, AcpError> {
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
    connection: &ConnectionTo<Agent>,
    spec: &AcpSpec,
    sessions: &mut HashMap<SessionId, ActiveSession<'static, Agent>>,
    session_id: &str,
    prompt: &str,
    model: &str,
) -> Result<AcpTurnResult, AcpError> {
    let session = sessions
        .get_mut(&SessionId::new(session_id))
        .ok_or_else(|| AcpError::UnknownSession(session_id.to_owned()))?;
    let (config_id, config_value) = (spec.model_config)(model);
    connection
        .send_request(SetSessionConfigOptionRequest::new(
            SessionId::new(session_id),
            config_id,
            config_value,
        ))
        .block_task()
        .await?;
    session.send_prompt(prompt)?;

    let mut text = String::new();
    let mut activities = Vec::new();
    let mut usage = AcpTokenUsage::default();

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

    Ok(AcpTurnResult {
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
    activities: &mut Vec<AcpActivity>,
    usage: &mut AcpTokenUsage,
) {
    match update {
        SessionUpdate::AgentMessageChunk(ContentChunk {
            content: ContentBlock::Text(chunk),
            ..
        }) => text.push_str(&chunk.text),
        SessionUpdate::Plan(Plan { entries, .. }) => {
            activities.push(AcpActivity {
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
    activities: &mut Vec<AcpActivity>,
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
        activities.push(AcpActivity {
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
pub enum AcpError {
    #[error("{agent} CLI is not installed")]
    NotInstalled { agent: &'static str },
    #[error("acp session {0} does not exist")]
    UnknownSession(String),
    #[error("acp connection closed: {0}")]
    Disconnected(String),
    #[error("acp failed: {0}")]
    Sdk(#[from] agent_client_protocol::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("could not list models: {0}")]
    ModelListing(String),
}

#[cfg(test)]
mod tests {
    use super::{AcpActivity, AcpTokenUsage, apply_update, tool_call_text};
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

    fn projection() -> (String, Vec<AcpActivity>, AcpTokenUsage) {
        (String::new(), Vec::new(), AcpTokenUsage::default())
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
        assert!(activities[0].success);
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
