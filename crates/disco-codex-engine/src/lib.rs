//! Local Codex app-server discovery and JSON-RPC transport.

use std::collections::VecDeque;
use std::env;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::{Value, json};
use thiserror::Error;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexInstallation {
    pub path: PathBuf,
    pub version: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexModel {
    pub id: String,
    pub display_name: String,
    pub description: String,
    pub reasoning_efforts: Vec<String>,
    pub default_reasoning_effort: String,
    pub is_default: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexActivity {
    pub id: String,
    pub title: String,
    pub detail: String,
    pub success: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CodexTokenUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub total_tokens: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexTurnResult {
    pub thread_id: String,
    pub text: String,
    pub activities: Vec<CodexActivity>,
    pub usage: CodexTokenUsage,
    pub interrupted: bool,
}

#[derive(Clone)]
pub struct CodexRuntime {
    installation: CodexInstallation,
    process: Arc<Mutex<AppServerProcess>>,
    stdin: Arc<Mutex<BufWriter<ChildStdin>>>,
    active_turn: Arc<Mutex<Option<ActiveTurn>>>,
    interrupt_requested: Arc<AtomicBool>,
    next_request_id: Arc<AtomicU64>,
}

impl CodexRuntime {
    pub fn connect(workspace: &Path) -> Result<Self, CodexError> {
        let installation = discover_codex()?;
        let process = AppServerProcess::spawn(&installation.path, workspace)?;
        let stdin = Arc::clone(&process.stdin);
        let active_turn = Arc::clone(&process.active_turn);
        let interrupt_requested = Arc::clone(&process.interrupt_requested);
        let next_request_id = Arc::clone(&process.next_request_id);
        Ok(Self {
            installation,
            process: Arc::new(Mutex::new(process)),
            stdin,
            active_turn,
            interrupt_requested,
            next_request_id,
        })
    }

    pub const fn installation(&self) -> &CodexInstallation {
        &self.installation
    }

    pub fn list_models(&self) -> Result<Vec<CodexModel>, CodexError> {
        let response = self
            .process
            .lock()
            .map_err(|_| CodexError::LockPoisoned)?
            .request(
                "model/list",
                json!({ "limit": 100, "includeHidden": false }),
            )?;
        parse_models(&response)
    }

    pub fn run_turn(
        &self,
        existing_thread_id: Option<&str>,
        workspace: &Path,
        prompt: &str,
        model: &str,
        reasoning_effort: &str,
    ) -> Result<CodexTurnResult, CodexError> {
        self.process
            .lock()
            .map_err(|_| CodexError::LockPoisoned)?
            .run_turn(
                existing_thread_id,
                workspace,
                prompt,
                model,
                reasoning_effort,
            )
    }

    pub fn prepare_turn(&self) {
        self.interrupt_requested.store(false, Ordering::SeqCst);
    }

    pub fn interrupt_turn(&self) -> Result<(), CodexError> {
        self.interrupt_requested.store(true, Ordering::SeqCst);
        let active_turn = self
            .active_turn
            .lock()
            .map_err(|_| {
                self.interrupt_requested.store(false, Ordering::SeqCst);
                CodexError::LockPoisoned
            })?
            .clone();
        let Some(active_turn) = active_turn else {
            // No turn registered yet: leave the flag set as a pending
            // interrupt. start_turn consumes it with swap(false) right
            // after registering, so the turn is interrupted before any
            // work runs.
            return Ok(());
        };

        let id = self.next_request_id.fetch_add(1, Ordering::SeqCst);
        let sent = write_message(
            &self.stdin,
            &json!({
                "id": id,
                "method": "turn/interrupt",
                "params": {
                    "threadId": active_turn.thread_id,
                    "turnId": active_turn.turn_id
                }
            }),
        );
        // The pending-interrupt contract is fulfilled by this direct send
        // (or failed outright). Never leave a stale flag behind: a later
        // start_turn swap(false) would auto-interrupt a turn the user did
        // not ask to stop.
        self.interrupt_requested.store(false, Ordering::SeqCst);
        sent
    }
}

pub fn discover_codex() -> Result<CodexInstallation, CodexError> {
    for candidate in codex_candidates() {
        if !candidate.is_file() {
            continue;
        }
        let output = Command::new(&candidate).arg("--version").output();
        let Ok(output) = output else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        let version = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        if version.starts_with("codex-cli ") {
            return Ok(CodexInstallation {
                path: candidate,
                version,
            });
        }
    }
    Err(CodexError::NotInstalled)
}

fn codex_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = env::var_os("CODEX_BIN") {
        candidates.push(PathBuf::from(path));
    }
    if let Some(paths) = env::var_os("PATH") {
        candidates.extend(env::split_paths(&paths).map(|path| path.join("codex")));
    }
    if let Some(home) = env::var_os("HOME").map(PathBuf::from) {
        candidates.push(home.join(".local/bin/codex"));
        candidates.push(home.join(".codex/packages/standalone/current/bin/codex"));
    }
    candidates.push(PathBuf::from("/opt/homebrew/bin/codex"));
    candidates.push(PathBuf::from("/usr/local/bin/codex"));
    candidates.dedup();
    candidates
}

struct AppServerProcess {
    child: Child,
    stdin: Arc<Mutex<BufWriter<ChildStdin>>>,
    stdout: BufReader<ChildStdout>,
    queued: VecDeque<Value>,
    active_turn: Arc<Mutex<Option<ActiveTurn>>>,
    interrupt_requested: Arc<AtomicBool>,
    next_request_id: Arc<AtomicU64>,
}

#[derive(Clone)]
struct ActiveTurn {
    thread_id: String,
    turn_id: String,
}

struct ActiveTurnGuard {
    active_turn: Arc<Mutex<Option<ActiveTurn>>>,
    turn_id: String,
}

impl Drop for ActiveTurnGuard {
    fn drop(&mut self) {
        if let Ok(mut active_turn) = self.active_turn.lock()
            && active_turn
                .as_ref()
                .is_some_and(|active| active.turn_id == self.turn_id)
        {
            *active_turn = None;
        }
    }
}

fn write_message(
    stdin: &Arc<Mutex<BufWriter<ChildStdin>>>,
    message: &Value,
) -> Result<(), CodexError> {
    let mut stdin = stdin.lock().map_err(|_| CodexError::LockPoisoned)?;
    serde_json::to_writer(&mut *stdin, message)?;
    stdin.write_all(b"\n")?;
    stdin.flush()?;
    Ok(())
}

impl AppServerProcess {
    fn spawn(codex_path: &Path, workspace: &Path) -> Result<Self, CodexError> {
        let mut child = Command::new(codex_path)
            .args(["app-server", "--listen", "stdio://"])
            .current_dir(workspace)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let stdin = Arc::new(Mutex::new(BufWriter::new(
            child.stdin.take().ok_or(CodexError::MissingPipe("stdin"))?,
        )));
        let stdout = child
            .stdout
            .take()
            .ok_or(CodexError::MissingPipe("stdout"))?;
        if let Some(stderr) = child.stderr.take() {
            thread::spawn(move || {
                for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                    eprintln!("codex app-server: {line}");
                }
            });
        }
        let mut process = Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
            queued: VecDeque::new(),
            active_turn: Arc::new(Mutex::new(None)),
            interrupt_requested: Arc::new(AtomicBool::new(false)),
            next_request_id: Arc::new(AtomicU64::new(1)),
        };
        process.request(
            "initialize",
            json!({
                "clientInfo": {
                    "name": "disco",
                    "title": "Disco",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": { "experimentalApi": false }
            }),
        )?;
        process.notify("initialized", None)?;
        Ok(process)
    }

    fn write_message(&mut self, message: &Value) -> Result<(), CodexError> {
        write_message(&self.stdin, message)
    }

    fn notify(&mut self, method: &str, params: Option<Value>) -> Result<(), CodexError> {
        let mut message = json!({ "method": method });
        if let Some(params) = params {
            message["params"] = params;
        }
        self.write_message(&message)
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value, CodexError> {
        let id = self.next_request_id.fetch_add(1, Ordering::SeqCst);
        self.write_message(&json!({ "id": id, "method": method, "params": params }))?;
        loop {
            let message = self.read_message()?;
            if message.get("id").and_then(Value::as_u64) == Some(id) {
                if let Some(error) = message.get("error") {
                    return Err(CodexError::Server(error.to_string()));
                }
                return message
                    .get("result")
                    .cloned()
                    .ok_or(CodexError::MissingField("result"));
            }
            if message.get("id").is_some() && message.get("method").is_some() {
                self.answer_server_request(&message)?;
            } else {
                self.queued.push_back(message);
            }
        }
    }

    fn read_message(&mut self) -> Result<Value, CodexError> {
        let mut line = String::new();
        loop {
            line.clear();
            if self.stdout.read_line(&mut line)? == 0 {
                let status = self.child.try_wait()?;
                return Err(CodexError::ServerExited(
                    status.map(|status| status.to_string()),
                ));
            }
            if line.trim().is_empty() {
                continue;
            }
            return Ok(serde_json::from_str(line.trim())?);
        }
    }

    fn answer_server_request(&mut self, message: &Value) -> Result<(), CodexError> {
        let Some(id) = message.get("id").cloned() else {
            return Ok(());
        };
        let method = message
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let result = match method {
            "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
                json!({ "decision": "decline" })
            }
            "item/tool/requestUserInput" => json!({ "answers": {} }),
            _ => {
                return self.write_message(&json!({
                    "id": id,
                    "error": { "code": -32601, "message": "Unsupported Disco client request" }
                }));
            }
        };
        self.write_message(&json!({ "id": id, "result": result }))
    }

    fn run_turn(
        &mut self,
        existing_thread_id: Option<&str>,
        workspace: &Path,
        prompt: &str,
        model: &str,
        reasoning_effort: &str,
    ) -> Result<CodexTurnResult, CodexError> {
        let thread_id = if let Some(thread_id) = existing_thread_id {
            thread_id.to_owned()
        } else {
            let response = self.request(
                "thread/start",
                json!({
                    "model": model,
                    "cwd": workspace,
                    "approvalPolicy": "never",
                    "sandbox": "workspace-write",
                    "ephemeral": false
                }),
            )?;
            response
                .pointer("/thread/id")
                .and_then(Value::as_str)
                .ok_or(CodexError::MissingField("thread.id"))?
                .to_owned()
        };

        let response = self.request(
            "turn/start",
            json!({
                "threadId": thread_id,
                "input": [{ "type": "text", "text": prompt }],
                "model": model,
                "effort": reasoning_effort,
                "cwd": workspace
            }),
        )?;
        let turn_id = response
            .pointer("/turn/id")
            .and_then(Value::as_str)
            .ok_or(CodexError::MissingField("turn.id"))?
            .to_owned();
        *self
            .active_turn
            .lock()
            .map_err(|_| CodexError::LockPoisoned)? = Some(ActiveTurn {
            thread_id: thread_id.clone(),
            turn_id: turn_id.clone(),
        });
        let _active_turn_guard = ActiveTurnGuard {
            active_turn: Arc::clone(&self.active_turn),
            turn_id: turn_id.clone(),
        };
        if self.interrupt_requested.swap(false, Ordering::SeqCst) {
            let id = self.next_request_id.fetch_add(1, Ordering::SeqCst);
            self.write_message(&json!({
                "id": id,
                "method": "turn/interrupt",
                "params": { "threadId": thread_id, "turnId": turn_id }
            }))?;
        }

        let mut text = String::new();
        let mut activities = Vec::new();
        let mut usage = CodexTokenUsage::default();
        loop {
            let message = if let Some(message) = self.queued.pop_front() {
                message
            } else {
                self.read_message()?
            };
            if message.get("id").is_some() && message.get("method").is_some() {
                self.answer_server_request(&message)?;
                continue;
            }
            let method = message
                .get("method")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let params = message.get("params").unwrap_or(&Value::Null);
            let matching_turn = params.get("turnId").and_then(Value::as_str) == Some(&turn_id)
                || params.pointer("/turn/id").and_then(Value::as_str) == Some(&turn_id);
            match method {
                "item/agentMessage/delta" if matching_turn => {
                    if let Some(delta) = params.get("delta").and_then(Value::as_str) {
                        text.push_str(delta);
                    }
                }
                "item/completed" if matching_turn => {
                    if let Some(item) = params.get("item") {
                        if text.is_empty()
                            && item.get("type").and_then(Value::as_str) == Some("agentMessage")
                            && let Some(final_text) = item.get("text").and_then(Value::as_str)
                        {
                            text.push_str(final_text);
                        }
                        if let Some(activity) = activity_from_item(item) {
                            activities.push(activity);
                        }
                    }
                }
                "thread/tokenUsage/updated" if matching_turn => {
                    if let Some(last) = params.pointer("/tokenUsage/last") {
                        usage = CodexTokenUsage {
                            input_tokens: last
                                .get("inputTokens")
                                .and_then(Value::as_u64)
                                .unwrap_or(0),
                            output_tokens: last
                                .get("outputTokens")
                                .and_then(Value::as_u64)
                                .unwrap_or(0),
                            total_tokens: last
                                .get("totalTokens")
                                .and_then(Value::as_u64)
                                .unwrap_or(0),
                        };
                    }
                }
                "turn/completed" if matching_turn => {
                    let status = params.pointer("/turn/status").and_then(Value::as_str);
                    if status == Some("failed") {
                        let message = params
                            .pointer("/turn/error/message")
                            .and_then(Value::as_str)
                            .unwrap_or("Codex turn failed");
                        return Err(CodexError::TurnFailed(message.into()));
                    }
                    return Ok(CodexTurnResult {
                        thread_id,
                        text,
                        activities,
                        usage,
                        interrupted: status == Some("interrupted"),
                    });
                }
                _ => {}
            }
        }
    }
}

impl Drop for AppServerProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn parse_models(response: &Value) -> Result<Vec<CodexModel>, CodexError> {
    let models = response
        .get("data")
        .and_then(Value::as_array)
        .ok_or(CodexError::MissingField("data"))?;
    models
        .iter()
        .map(|model| {
            let efforts = model
                .get("supportedReasoningEfforts")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|effort| effort.get("reasoningEffort").and_then(Value::as_str))
                .map(str::to_owned)
                .collect();
            Ok(CodexModel {
                id: required_string(model, "id")?,
                display_name: required_string(model, "displayName")?,
                description: required_string(model, "description")?,
                reasoning_efforts: efforts,
                default_reasoning_effort: required_string(model, "defaultReasoningEffort")?,
                is_default: model
                    .get("isDefault")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            })
        })
        .collect()
}

fn activity_from_item(item: &Value) -> Option<CodexActivity> {
    let kind = item.get("type")?.as_str()?;
    let id = item.get("id")?.as_str()?.to_owned();
    match kind {
        "commandExecution" => Some(CodexActivity {
            id,
            title: "Ran command".into(),
            detail: item.get("command")?.as_str()?.to_owned(),
            success: item.get("status").and_then(Value::as_str) == Some("completed"),
        }),
        "fileChange" => {
            let paths = item
                .get("changes")?
                .as_array()?
                .iter()
                .filter_map(|change| change.get("path").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join(", ");
            Some(CodexActivity {
                id,
                title: "Updated files".into(),
                detail: paths,
                success: item.get("status").and_then(Value::as_str) == Some("completed"),
            })
        }
        "plan" => Some(CodexActivity {
            id,
            title: "Plan".into(),
            detail: item.get("text")?.as_str()?.to_owned(),
            success: true,
        }),
        "mcpToolCall" => Some(CodexActivity {
            id,
            title: format!(
                "Used {}",
                item.get("tool").and_then(Value::as_str).unwrap_or("tool")
            ),
            detail: item
                .get("server")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            success: item.get("status").and_then(Value::as_str) == Some("completed"),
        }),
        "webSearch" => Some(CodexActivity {
            id,
            title: "Searched the web".into(),
            detail: item.get("query")?.as_str()?.to_owned(),
            success: true,
        }),
        "subAgentActivity" | "collabAgentToolCall" => Some(CodexActivity {
            id,
            title: "Delegated task".into(),
            detail: item
                .get("agentPath")
                .or_else(|| item.get("tool"))
                .and_then(Value::as_str)
                .unwrap_or("Codex sub-agent")
                .to_owned(),
            success: true,
        }),
        _ => None,
    }
}

fn required_string(value: &Value, field: &'static str) -> Result<String, CodexError> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or(CodexError::MissingField(field))
}

#[derive(Debug, Error)]
pub enum CodexError {
    #[error("Codex CLI is not installed")]
    NotInstalled,
    #[error("codex app-server did not expose its {0} pipe")]
    MissingPipe(&'static str),
    #[error("codex app-server response is missing {0}")]
    MissingField(&'static str),
    #[error("codex app-server returned an error: {0}")]
    Server(String),
    #[error("codex app-server exited: {0:?}")]
    ServerExited(Option<String>),
    #[error("Codex turn failed: {0}")]
    TurnFailed(String),
    #[error("Codex runtime lock was poisoned")]
    LockPoisoned,
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[cfg(test)]
mod tests {
    use super::{ActiveTurn, ActiveTurnGuard, activity_from_item, parse_models};
    use serde_json::json;
    use std::sync::{Arc, Mutex};

    #[test]
    fn model_catalog_comes_from_app_server_fields() {
        let models = parse_models(&json!({
            "data": [{
                "id": "gpt-codex",
                "displayName": "GPT Codex",
                "description": "Coding model",
                "supportedReasoningEfforts": [
                    { "reasoningEffort": "low" },
                    { "reasoningEffort": "high" }
                ],
                "defaultReasoningEffort": "low",
                "isDefault": true
            }]
        }))
        .expect("catalog should parse");

        assert_eq!(models[0].id, "gpt-codex");
        assert_eq!(models[0].reasoning_efforts, ["low", "high"]);
        assert!(models[0].is_default);
    }

    #[test]
    fn completed_file_changes_become_real_activity() {
        let activity = activity_from_item(&json!({
            "id": "patch-1",
            "type": "fileChange",
            "status": "completed",
            "changes": [
                { "path": "src/lib.rs" },
                { "path": "src/main.rs" }
            ]
        }))
        .expect("activity should parse");

        assert_eq!(activity.title, "Updated files");
        assert_eq!(activity.detail, "src/lib.rs, src/main.rs");
        assert!(activity.success);
    }

    #[test]
    fn active_turn_guard_clears_matching_turn() {
        let active_turn: Arc<Mutex<Option<ActiveTurn>>> = Arc::new(Mutex::new(Some(ActiveTurn {
            thread_id: "thread-1".into(),
            turn_id: "turn-1".into(),
        })));
        let guard = ActiveTurnGuard {
            active_turn: Arc::clone(&active_turn),
            turn_id: "turn-1".into(),
        };
        drop(guard);
        assert!(
            active_turn
                .lock()
                .expect("test lock should not be poisoned")
                .is_none()
        );
    }

    #[test]
    fn active_turn_guard_preserves_newer_turn() {
        let active_turn: Arc<Mutex<Option<ActiveTurn>>> = Arc::new(Mutex::new(Some(ActiveTurn {
            thread_id: "thread-2".into(),
            turn_id: "turn-2".into(),
        })));
        let guard = ActiveTurnGuard {
            active_turn: Arc::clone(&active_turn),
            turn_id: "turn-1".into(),
        };
        drop(guard);
        let current = active_turn
            .lock()
            .expect("test lock should not be poisoned");
        assert_eq!(
            current.as_ref().expect("newer turn should remain").turn_id,
            "turn-2"
        );
    }
}
