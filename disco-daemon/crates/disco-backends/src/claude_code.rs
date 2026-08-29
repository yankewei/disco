//! Claude Code 的长期 stream-json 会话 adapter。
//!
//! 一个 Disco 会话对应一个持久的 `claude` 子进程。stdout 的 Claude 私有 JSON
//! 在本模块内被转换为 `AgentOutput`，不会泄漏到 daemon facade。

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context, Result, bail};
use async_trait::async_trait;
use disco_core::{
    AgentBackend, AgentOutput, ApprovalManager, BackendCapabilities, BackendRun, BackendRunRequest,
    BackendSession, CompactionMode, PreparedApproval, tool_approval_request,
};
use disco_protocol::types::ApprovalDecision;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{Mutex, mpsc};
use tokio_stream::wrappers::ReceiverStream;
use uuid::Uuid;

const PROCESS_CHANNEL_CAPACITY: usize = 128;

#[derive(Clone)]
pub struct ClaudeCodeAdapter {
    executable: String,
    reasoning_effort: Option<String>,
    sessions: Arc<Mutex<HashMap<Uuid, Arc<ClaudeSession>>>>,
}

struct ClaudeSession {
    session_id: String,
    outgoing_commands: mpsc::Sender<ClaudeCommand>,
    incoming_events: Mutex<mpsc::Receiver<ClaudeEvent>>,
    process_terminated: Arc<AtomicBool>,
}

enum ClaudeCommand {
    WriteFrame(Value),
    Shutdown,
}

enum ClaudeEvent {
    StreamFrame(Value),
    TransportFailed(String),
    ProcessExited(String),
}

impl ClaudeCodeAdapter {
    /// Claude Code 默认通过 PATH 发现；测试或受管部署可用 CLAUDE_PATH 覆盖。
    pub fn find_executable() -> String {
        std::env::var("CLAUDE_PATH").unwrap_or_else(|_| "claude".to_string())
    }

    /// 只验证 CLI 是否可启动，不触发模型请求或读取登录凭据。
    pub async fn validate_installation(executable: &str) -> Result<()> {
        let output = Command::new(executable)
            .arg("--version")
            .output()
            .await
            .with_context(|| format!("无法启动 Claude Code：{executable}"))?;
        if !output.status.success() {
            bail!("Claude Code 版本检查失败：{}", output.status);
        }
        Ok(())
    }

    pub fn new(executable: String, reasoning_effort: Option<String>) -> Self {
        Self {
            executable,
            reasoning_effort,
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    async fn session_for(
        &self,
        session: &BackendSession,
        workspace_path: Option<&str>,
    ) -> Result<Arc<ClaudeSession>> {
        let mut sessions = self.sessions.lock().await;
        if let Some(existing) = sessions.get(&session.id)
            && !existing.process_terminated.load(Ordering::Acquire)
        {
            return Ok(existing.clone());
        }

        let session_id = session
            .backend_handle
            .clone()
            .unwrap_or_else(|| session.id.to_string());
        let created = Arc::new(spawn_session(
            &self.executable,
            &session_id,
            session.backend_handle.is_some(),
            &session.model,
            self.reasoning_effort.as_deref(),
            workspace_path,
        )?);
        sessions.insert(session.id, created.clone());
        Ok(created)
    }
}

#[async_trait]
impl AgentBackend for ClaudeCodeAdapter {
    fn capabilities(&self) -> BackendCapabilities {
        BackendCapabilities {
            has_persistent_sessions: true,
            can_delete_session: false,
            compaction: CompactionMode::Native,
        }
    }

    async fn load_session(
        &self,
        session: &BackendSession,
        workspace_path: Option<String>,
    ) -> Result<()> {
        if session.backend_handle.is_some() {
            self.session_for(session, workspace_path.as_deref()).await?;
        }
        Ok(())
    }

    async fn start_run(&self, request: BackendRunRequest) -> Result<BackendRun> {
        let session = self
            .session_for(&request.session, request.workspace_path.as_deref())
            .await?;
        let prompt = request
            .messages
            .last()
            .filter(|message| message.role == "user")
            .map(|message| message.text.clone())
            .ok_or_else(|| anyhow::anyhow!("Claude Code 运行缺少用户消息"))?;
        session
            .outgoing_commands
            .send(ClaudeCommand::WriteFrame(user_message(&prompt)))
            .await
            .map_err(|_| anyhow::anyhow!("Claude Code 会话已经结束"))?;

        let (event_tx, event_rx) = mpsc::channel(PROCESS_CHANNEL_CAPACITY);
        let cancellation = request.cancellation.clone();
        let approval_manager = request.approval_manager.clone();
        let run_id = request.run_id;
        let session_for_run = session.clone();
        tokio::spawn(async move {
            let mut events = session_for_run.incoming_events.lock().await;
            loop {
                tokio::select! {
                    _ = cancellation.cancelled() => {
                        approval_manager.cancel_all().await;
                        let _ = session_for_run.outgoing_commands.send(ClaudeCommand::WriteFrame(interrupt_request())).await;
                        let _ = event_tx.send(AgentOutput::Cancelled).await;
                        return;
                    }
                    event = events.recv() => match event {
                        Some(ClaudeEvent::StreamFrame(message)) => {
                            if forward_claude_message(
                                message,
                                run_id,
                                &approval_manager,
                                &cancellation,
                                &session_for_run.outgoing_commands,
                                &event_tx,
                            ).await {
                                return;
                            }
                        }
                        Some(ClaudeEvent::TransportFailed(error)) | Some(ClaudeEvent::ProcessExited(error)) => {
                            approval_manager.cancel_all().await;
                            let _ = event_tx.send(AgentOutput::Failed(error)).await;
                            return;
                        }
                        None => {
                            approval_manager.cancel_all().await;
                            let _ = event_tx.send(AgentOutput::Failed("Claude Code 事件流意外结束".into())).await;
                            return;
                        }
                    }
                }
            }
        });

        Ok(BackendRun {
            events: Box::pin(ReceiverStream::new(event_rx)),
            backend_handle: Some(session.session_id.clone()),
        })
    }

    async fn delete_session(
        &self,
        session: &BackendSession,
        _workspace_path: Option<String>,
    ) -> Result<()> {
        if let Some(process) = self.sessions.lock().await.remove(&session.id) {
            let _ = process
                .outgoing_commands
                .send(ClaudeCommand::Shutdown)
                .await;
        }
        Ok(())
    }
}

fn spawn_session(
    executable: &str,
    session_id: &str,
    resume: bool,
    model: &str,
    effort: Option<&str>,
    workspace_path: Option<&str>,
) -> Result<ClaudeSession> {
    let mut command = Command::new(executable);
    command.args([
        "-p",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--replay-user-messages",
        "--permission-prompt-tool",
        "stdio",
        "--permission-mode",
        "default",
        "--model",
        model,
    ]);
    if let Some(effort) = effort {
        command.args(["--effort", effort]);
    }
    if resume {
        command.args(["--resume", session_id]);
    } else {
        command.args(["--session-id", session_id]);
    }
    if let Some(workspace_path) = workspace_path {
        command.current_dir(workspace_path);
    }
    command.kill_on_drop(true);
    command.stdin(std::process::Stdio::piped());
    command.stdout(std::process::Stdio::piped());
    command.stderr(std::process::Stdio::piped());
    let mut child = command
        .spawn()
        .with_context(|| format!("无法启动 Claude Code：{executable}"))?;
    let stdin = child.stdin.take().context("Claude Code stdin 不可用")?;
    let stdout = child.stdout.take().context("Claude Code stdout 不可用")?;
    let stderr = child.stderr.take().context("Claude Code stderr 不可用")?;

    let (command_tx, mut command_rx) = mpsc::channel(PROCESS_CHANNEL_CAPACITY);
    let (event_tx, event_rx) = mpsc::channel(PROCESS_CHANNEL_CAPACITY);
    let is_terminated = Arc::new(AtomicBool::new(false));
    let writer_terminated = is_terminated.clone();
    let writer_events = event_tx.clone();
    tokio::spawn(async move {
        let mut stdin = stdin;
        while let Some(command) = command_rx.recv().await {
            match command {
                ClaudeCommand::WriteFrame(value) => {
                    let serialized = match serde_json::to_string(&value) {
                        Ok(serialized) => serialized,
                        Err(error) => {
                            writer_terminated.store(true, Ordering::Release);
                            let _ = writer_events
                                .send(ClaudeEvent::TransportFailed(error.to_string()))
                                .await;
                            return;
                        }
                    };
                    if stdin.write_all(serialized.as_bytes()).await.is_err()
                        || stdin.write_all(b"\n").await.is_err()
                        || stdin.flush().await.is_err()
                    {
                        writer_terminated.store(true, Ordering::Release);
                        let _ = writer_events
                            .send(ClaudeEvent::TransportFailed(
                                "无法写入 Claude Code stdin".into(),
                            ))
                            .await;
                        return;
                    }
                }
                ClaudeCommand::Shutdown => return,
            }
        }
    });
    let reader_events = event_tx.clone();
    let reader_terminated = is_terminated.clone();
    tokio::spawn(async move {
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.trim().is_empty() {
                continue;
            }
            match serde_json::from_str(&line) {
                Ok(message) => {
                    if reader_events
                        .send(ClaudeEvent::StreamFrame(message))
                        .await
                        .is_err()
                    {
                        return;
                    }
                }
                Err(error) => tracing::warn!(%error, "忽略无法解析的 Claude Code 输出行"),
            }
        }
        reader_terminated.store(true, Ordering::Release);
    });
    tokio::spawn(async move {
        let mut lines = BufReader::new(stderr).lines();
        let mut last_line = None;
        while let Ok(Some(line)) = lines.next_line().await {
            if !line.trim().is_empty() {
                last_line = Some(line);
            }
        }
        if let Some(line) = last_line {
            tracing::warn!(%line, "Claude Code stderr");
        }
    });
    let exit_terminated = is_terminated.clone();
    tokio::spawn(async move {
        report_exit(child, event_tx, exit_terminated).await;
    });

    Ok(ClaudeSession {
        session_id: session_id.to_owned(),
        outgoing_commands: command_tx,
        incoming_events: Mutex::new(event_rx),
        process_terminated: is_terminated,
    })
}

async fn report_exit(
    mut child: Child,
    events: mpsc::Sender<ClaudeEvent>,
    is_terminated: Arc<AtomicBool>,
) {
    is_terminated.store(true, Ordering::Release);
    match child.wait().await {
        Ok(status) if !status.success() => {
            let _ = events
                .send(ClaudeEvent::ProcessExited(format!(
                    "Claude Code 进程异常退出：{status}"
                )))
                .await;
        }
        Ok(_) => {
            let _ = events
                .send(ClaudeEvent::ProcessExited("Claude Code 进程已退出".into()))
                .await;
        }
        Err(error) => {
            let _ = events
                .send(ClaudeEvent::ProcessExited(format!(
                    "无法等待 Claude Code 进程：{error}"
                )))
                .await;
        }
    }
}

fn user_message(text: &str) -> Value {
    json!({"type":"user", "message":{"role":"user", "content":[{"type":"text", "text":text}]}, "parent_tool_use_id":null})
}

fn interrupt_request() -> Value {
    json!({"type":"control_request", "request_id":format!("disco-{}", Uuid::new_v4()), "request":{"subtype":"interrupt"}})
}

async fn forward_claude_message(
    message: Value,
    run_id: Uuid,
    approval_manager: &Arc<ApprovalManager>,
    cancellation: &tokio_util::sync::CancellationToken,
    commands: &mpsc::Sender<ClaudeCommand>,
    event_tx: &mpsc::Sender<AgentOutput>,
) -> bool {
    match message.get("type").and_then(Value::as_str) {
        Some("stream_event") => {
            let delta = message.pointer("/event/delta").unwrap_or(&Value::Null);
            let output = match delta.get("type").and_then(Value::as_str) {
                Some("text_delta") => delta
                    .get("text")
                    .and_then(Value::as_str)
                    .map(|value| AgentOutput::TextDelta(value.to_owned())),
                Some("thinking_delta") => delta
                    .get("thinking")
                    .and_then(Value::as_str)
                    .map(|value| AgentOutput::ReasoningDelta(value.to_owned())),
                _ => None,
            };
            if let Some(output) = output {
                return event_tx.send(output).await.is_err();
            }
        }
        Some("assistant") => {
            let Some(content) = message
                .pointer("/message/content")
                .and_then(Value::as_array)
            else {
                return false;
            };
            for block in content {
                if block.get("type").and_then(Value::as_str) == Some("tool_use") {
                    let id = block
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned();
                    let name = block
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("tool")
                        .to_owned();
                    let arguments = block
                        .get("input")
                        .cloned()
                        .unwrap_or(Value::Null)
                        .to_string();
                    if event_tx
                        .send(AgentOutput::ToolStarted {
                            tool_call_id: id,
                            tool_name: name,
                            arguments,
                        })
                        .await
                        .is_err()
                    {
                        return true;
                    }
                }
            }
        }
        Some("user") => {
            let Some(content) = message
                .pointer("/message/content")
                .and_then(Value::as_array)
            else {
                return false;
            };
            for block in content {
                if block.get("type").and_then(Value::as_str) == Some("tool_result") {
                    let id = block
                        .get("tool_use_id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned();
                    let output = block
                        .get("content")
                        .map(Value::to_string)
                        .unwrap_or_default();
                    if event_tx
                        .send(AgentOutput::ToolCompleted {
                            tool_call_id: id,
                            tool_name: "Claude Code 工具".into(),
                            output,
                        })
                        .await
                        .is_err()
                    {
                        return true;
                    }
                }
            }
        }
        Some("control_request")
            if message.pointer("/request/subtype").and_then(Value::as_str)
                == Some("can_use_tool") =>
        {
            request_tool_approval(
                message,
                run_id,
                approval_manager,
                cancellation,
                commands,
                event_tx,
            )
            .await;
        }
        Some("result") => {
            let output = if message.get("is_error").and_then(Value::as_bool) == Some(true) {
                AgentOutput::Failed(
                    message
                        .get("result")
                        .and_then(Value::as_str)
                        .unwrap_or("Claude Code 运行失败")
                        .to_owned(),
                )
            } else {
                AgentOutput::Completed
            };
            let _ = event_tx.send(output).await;
            return true;
        }
        _ => {}
    }
    false
}

async fn request_tool_approval(
    message: Value,
    run_id: Uuid,
    approval_manager: &Arc<ApprovalManager>,
    cancellation: &tokio_util::sync::CancellationToken,
    commands: &mpsc::Sender<ClaudeCommand>,
    event_tx: &mpsc::Sender<AgentOutput>,
) {
    let Some(request_id) = message.get("request_id").and_then(Value::as_str) else {
        return;
    };
    let request = message.get("request").unwrap_or(&Value::Null);
    let tool_name = request
        .get("tool_name")
        .and_then(Value::as_str)
        .unwrap_or("Claude Code 工具");
    let arguments = request
        .get("input")
        .cloned()
        .unwrap_or(Value::Null)
        .to_string();
    let mut approval = tool_approval_request(run_id, tool_name, &arguments);
    approval.title = request
        .get("display_name")
        .and_then(Value::as_str)
        .unwrap_or(tool_name)
        .to_owned();
    approval.reason = request
        .get("description")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let decision = match approval_manager.prepare_approval(&approval).await {
        PreparedApproval::SessionApproved => ApprovalDecision::ApproveOnce,
        PreparedApproval::Pending(pending) => {
            if event_tx
                .send(AgentOutput::approval_waiting(&approval))
                .await
                .is_err()
            {
                ApprovalDecision::Decline
            } else {
                tokio::select! { _ = cancellation.cancelled() => ApprovalDecision::Decline, decision = pending.wait() => decision }
            }
        }
    };
    let _ = event_tx
        .send(AgentOutput::ApprovalResolved {
            approval_id: approval.id,
            decision,
        })
        .await;
    let response = if decision == ApprovalDecision::Decline {
        json!({"behavior":"deny", "message":"用户拒绝了本次工具调用。"})
    } else {
        json!({"behavior":"allow"})
    };
    let _ = commands.send(ClaudeCommand::WriteFrame(json!({"type":"control_response", "response":{"subtype":"success", "request_id":request_id, "response":response}}))).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approval_manager() -> Arc<ApprovalManager> {
        Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new()))))
    }

    #[test]
    fn user_messages_follow_claude_stream_json_shape() {
        let payload = user_message("你好");
        assert_eq!(payload["type"], "user");
        assert_eq!(payload["message"]["content"][0]["text"], "你好");
    }

    #[test]
    fn interrupt_requests_are_control_requests() {
        let request = interrupt_request();
        assert_eq!(request["type"], "control_request");
        assert_eq!(request["request"]["subtype"], "interrupt");
    }

    #[tokio::test]
    async fn stream_frames_map_text_and_terminal_events() {
        let (commands, _command_rx) = mpsc::channel(1);
        let (outputs, mut output_rx) = mpsc::channel(4);
        let cancellation = tokio_util::sync::CancellationToken::new();
        let terminated = forward_claude_message(
            json!({"type":"stream_event", "event":{"delta":{"type":"text_delta", "text":"你好"}}}),
            Uuid::new_v4(),
            &approval_manager(),
            &cancellation,
            &commands,
            &outputs,
        )
        .await;
        assert!(!terminated);
        assert!(
            matches!(output_rx.recv().await, Some(AgentOutput::TextDelta(text)) if text == "你好")
        );

        let terminated = forward_claude_message(
            json!({"type":"result", "is_error":false}),
            Uuid::new_v4(),
            &approval_manager(),
            &cancellation,
            &commands,
            &outputs,
        )
        .await;
        assert!(terminated);
        assert!(matches!(
            output_rx.recv().await,
            Some(AgentOutput::Completed)
        ));
    }
}
