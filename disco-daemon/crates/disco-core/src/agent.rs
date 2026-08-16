use std::sync::Arc;

use disco_protocol::types::{ApprovalDecision, ApprovalImpact, TokenUsage};
use disco_providers::ModelProvider;
use disco_providers::openai_responses::{ChatMessage, ProviderEvent, ToolCallInfo};
use disco_tools::{CompositeExecutor, ToolCall, ToolContext, ToolExecutor};
use tokio_stream::StreamExt;
use tokio_stream::wrappers::ReceiverStream;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};
use uuid::Uuid;

use crate::approval::{ApprovalManager, ApprovalRequest, PreparedApproval, tool_approval_request};

const MAX_MODEL_ROUNDS: usize = 8;
const MAX_TOOL_CALLS: usize = 16;

/// Output events from the agent loop, forwarded to the client via the daemon.
#[derive(Debug, Clone)]
pub enum AgentOutput {
    TextDelta(String),
    ReasoningDelta(String),
    Usage(TokenUsage),
    ToolStarted {
        tool_call_id: String,
        tool_name: String,
        arguments: String,
    },
    ToolCompleted {
        tool_call_id: String,
        tool_name: String,
        output: String,
    },
    ApprovalWaiting {
        approval_id: Uuid,
        kind: String,
        title: String,
        impact: ApprovalImpact,
        fingerprint: String,
        allows_session_approval: bool,
    },
    ApprovalResolved {
        approval_id: Uuid,
        decision: ApprovalDecision,
    },
    Completed,
    Failed(String),
    Cancelled,
}

impl AgentOutput {
    /// 将领域审批请求转换为等待用户响应的事件。
    pub fn approval_waiting(request: &ApprovalRequest) -> Self {
        Self::ApprovalWaiting {
            approval_id: request.id,
            kind: request.kind.clone(),
            title: request.title.clone(),
            impact: request.impact.clone(),
            fingerprint: request.fingerprint.clone(),
            allows_session_approval: request.allows_session_approval,
        }
    }
}

/// Agent loop with tool execution and approval flow.
pub struct AgentLoop {
    provider: Arc<dyn ModelProvider>,
    executor: Arc<CompositeExecutor>,
    approval_manager: Arc<ApprovalManager>,
}

impl AgentLoop {
    pub fn new(
        provider: Arc<dyn ModelProvider>,
        executor: Arc<CompositeExecutor>,
        approval_manager: Arc<ApprovalManager>,
    ) -> Self {
        Self {
            provider,
            executor,
            approval_manager,
        }
    }

    pub async fn run(
        &self,
        messages: Vec<ChatMessage>,
        cancel: CancellationToken,
        run_id: Uuid,
        _session_id: Uuid,
        workspace_path: Option<String>,
    ) -> ReceiverStream<AgentOutput> {
        let (tx, rx) = tokio::sync::mpsc::channel::<AgentOutput>(64);
        let provider = self.provider.clone();
        let executor = self.executor.clone();
        let approval_manager = self.approval_manager.clone();

        tokio::spawn(async move {
            info!("Agent loop starting with {} messages", messages.len());

            let tool_defs = executor.definitions();
            let has_tools = !tool_defs.is_empty();
            let mut conversation = messages;
            let mut model_round = 0;
            let mut total_tool_calls = 0;
            let mut accumulated_usage: Option<TokenUsage> = None;
            let mut full_response = String::new();

            loop {
                if model_round >= MAX_MODEL_ROUNDS {
                    info!("Max model rounds ({MAX_MODEL_ROUNDS}) reached");
                    let _ = tx.send(AgentOutput::Completed).await;
                    return;
                }

                let mut round_text = String::new();
                let mut completed_tool_calls: Vec<(String, String, String)> = Vec::new();

                // Process one model round in a scoped block so the stream
                // (which borrows `conversation`) is dropped before we mutate it.
                {
                    let event_stream = match provider
                        .stream(
                            &conversation,
                            if has_tools { Some(&tool_defs) } else { None },
                        )
                        .await
                    {
                        Ok(stream) => stream,
                        Err(e) => {
                            error!("Failed to start provider stream: {e}");
                            let _ = tx.send(AgentOutput::Failed(e.to_string())).await;
                            return;
                        }
                    };

                    tokio::pin!(event_stream);

                    let mut tool_call_acc: Vec<(String, String, String)> = Vec::new();

                    loop {
                        tokio::select! {
                            _ = cancel.cancelled() => {
                                info!("Agent loop cancelled");
                                let _ = tx.send(AgentOutput::Cancelled).await;
                                return;
                            }
                            event = event_stream.next() => {
                                match event {
                                    Some(Ok(ProviderEvent::TextDelta(delta))) => {
                                        round_text.push_str(&delta);
                                        if tx.send(AgentOutput::TextDelta(delta)).await.is_err() {
                                            return;
                                        }
                                    }
                                    Some(Ok(ProviderEvent::ReasoningDelta(delta))) => {
                                        if tx.send(AgentOutput::ReasoningDelta(delta)).await.is_err() {
                                            return;
                                        }
                                    }
                                    Some(Ok(ProviderEvent::Usage(usage))) => {
                                        accumulated_usage = Some(accumulate_usage(&accumulated_usage, &usage));
                                        if tx.send(AgentOutput::Usage(usage)).await.is_err() {
                                            return;
                                        }
                                    }
                                    Some(Ok(ProviderEvent::ToolCallDelta { call_id, name, arguments_delta })) => {
                                        if let Some(existing) = tool_call_acc.iter_mut().find(|(id, _, _)| id == &call_id) {
                                            if !name.is_empty() && existing.1.is_empty() {
                                                existing.1 = name;
                                            }
                                            existing.2.push_str(&arguments_delta);
                                        } else {
                                            tool_call_acc.push((call_id, name, arguments_delta));
                                        }
                                    }
                                    Some(Ok(ProviderEvent::ToolCallCompleted { call_id, name, arguments })) => {
                                        if let Some(existing) = tool_call_acc.iter_mut().find(|(id, _, _)| id == &call_id) {
                                            if !name.is_empty() {
                                                existing.1 = name.clone();
                                            }
                                            existing.2 = arguments.clone();
                                        }
                                        completed_tool_calls.push((call_id, name, arguments));
                                    }
                                    Some(Ok(ProviderEvent::Completed)) => {
                                        break;
                                    }
                                    Some(Ok(ProviderEvent::Cancelled)) => {
                                        let _ = tx.send(AgentOutput::Cancelled).await;
                                        return;
                                    }
                                    Some(Ok(ProviderEvent::Failed(error))) => {
                                        error!("Agent loop failed: {error}");
                                        let _ = tx.send(AgentOutput::Failed(error)).await;
                                        return;
                                    }
                                    Some(Err(e)) => {
                                        error!("Provider stream error: {e}");
                                        let _ = tx.send(AgentOutput::Failed(e.to_string())).await;
                                        return;
                                    }
                                    None => {
                                        debug!("Provider stream ended without completion event");
                                        break;
                                    }
                                }
                            }
                        }
                    }
                } // stream dropped here, conversation borrow released

                full_response.push_str(&round_text);

                if completed_tool_calls.is_empty() {
                    let _ = tx.send(AgentOutput::Completed).await;
                    return;
                }

                // Add assistant message with tool calls to conversation
                let assistant_tool_calls: Vec<ToolCallInfo> = completed_tool_calls
                    .iter()
                    .map(|(call_id, name, arguments)| ToolCallInfo {
                        call_id: call_id.clone(),
                        name: name.clone(),
                        arguments: arguments.clone(),
                    })
                    .collect();

                conversation.push(ChatMessage {
                    role: "assistant".to_string(),
                    text: round_text,
                    tool_calls: Some(assistant_tool_calls),
                    ..Default::default()
                });

                // Execute tool calls with approval
                let tool_context = ToolContext {
                    run_id,
                    workspace_path: workspace_path.clone(),
                };

                let mut all_declined = true;

                for (call_id, name, arguments) in &completed_tool_calls {
                    total_tool_calls += 1;
                    if total_tool_calls > MAX_TOOL_CALLS {
                        warn!("Max tool calls ({MAX_TOOL_CALLS}) reached");
                        let _ = tx.send(AgentOutput::Completed).await;
                        return;
                    }

                    // Send tool started event
                    let _ = tx
                        .send(AgentOutput::ToolStarted {
                            tool_call_id: call_id.clone(),
                            tool_name: name.clone(),
                            arguments: arguments.clone(),
                        })
                        .await;

                    // 等待审批时仍必须响应取消，不能把取消误判为用户拒绝。
                    let (approval_id, decision) = tokio::select! {
                        biased;
                        _ = cancel.cancelled() => {
                            let _ = tx.send(AgentOutput::Cancelled).await;
                            return;
                        }
                        decision = request_tool_approval(
                            &approval_manager,
                            &tx,
                            run_id,
                            name,
                            arguments,
                        ) => decision,
                    };

                    // Send approval resolved event
                    let _ = tx
                        .send(AgentOutput::ApprovalResolved {
                            approval_id,
                            decision,
                        })
                        .await;

                    let output = if decision == ApprovalDecision::Decline {
                        "Tool execution declined by user".to_string()
                    } else {
                        all_declined = false;
                        let tool_call = ToolCall {
                            call_id: call_id.clone(),
                            name: name.clone(),
                            arguments: arguments.clone(),
                        };
                        let execution = executor.execute(&tool_call, &tool_context);
                        let result = tokio::select! {
                            biased;
                            _ = cancel.cancelled() => {
                                executor.cancel(run_id).await;
                                let _ = tx.send(AgentOutput::Cancelled).await;
                                return;
                            }
                            result = execution => result,
                        };
                        match result {
                            Ok(result) => result.output,
                            Err(e) => format!("Error: {e}"),
                        }
                    };

                    // Send tool completed event
                    let _ = tx
                        .send(AgentOutput::ToolCompleted {
                            tool_call_id: call_id.clone(),
                            tool_name: name.clone(),
                            output: output.clone(),
                        })
                        .await;

                    // Add tool result to conversation
                    conversation.push(ChatMessage {
                        role: "user".to_string(),
                        text: output,
                        tool_call_id: Some(call_id.clone()),
                        tool_name: Some(name.clone()),
                        ..Default::default()
                    });
                }

                if all_declined {
                    let _ = tx.send(AgentOutput::Completed).await;
                    return;
                }

                model_round += 1;
            }
        });

        ReceiverStream::new(rx)
    }
}

async fn request_tool_approval(
    manager: &ApprovalManager,
    tx: &tokio::sync::mpsc::Sender<AgentOutput>,
    run_id: Uuid,
    tool_name: &str,
    arguments: &str,
) -> (Uuid, ApprovalDecision) {
    let request = tool_approval_request(run_id, tool_name, arguments);
    let decision = match manager.prepare_approval(&request).await {
        PreparedApproval::SessionApproved => ApprovalDecision::ApproveOnce,
        PreparedApproval::Pending(pending) => {
            let _ = tx.send(AgentOutput::approval_waiting(&request)).await;
            pending.wait().await
        }
    };
    (request.id, decision)
}

fn accumulate_usage(prev: &Option<TokenUsage>, current: &TokenUsage) -> TokenUsage {
    match prev {
        Some(p) => TokenUsage {
            input: p.input + current.input,
            output: p.output + current.output,
            total: p.total + current.total,
            cached_input: match (p.cached_input, current.cached_input) {
                (Some(a), Some(b)) => Some(a + b),
                (Some(a), None) => Some(a),
                (None, Some(b)) => Some(b),
                (None, None) => None,
            },
            reasoning_output: match (p.reasoning_output, current.reasoning_output) {
                (Some(a), Some(b)) => Some(a + b),
                (Some(a), None) => Some(a),
                (None, Some(b)) => Some(b),
                (None, None) => None,
            },
        },
        None => current.clone(),
    }
}

#[cfg(test)]
mod tests {
    use std::pin::Pin;

    use disco_tools::ToolDefinition;
    use futures_core::Stream;

    use super::*;

    struct ToolCallingProvider;

    #[async_trait::async_trait]
    impl ModelProvider for ToolCallingProvider {
        fn vendor_name(&self) -> &'static str {
            "test"
        }

        async fn stream<'a>(
            &'a self,
            _messages: &'a [ChatMessage],
            _tools: Option<&'a [ToolDefinition]>,
        ) -> anyhow::Result<Pin<Box<dyn Stream<Item = anyhow::Result<ProviderEvent>> + Send + 'a>>>
        {
            Ok(Box::pin(tokio_stream::iter(vec![
                Ok(ProviderEvent::ToolCallCompleted {
                    call_id: "call-1".to_string(),
                    name: "shell".to_string(),
                    arguments: r#"{"command":"sleep 30"}"#.to_string(),
                }),
                Ok(ProviderEvent::Completed),
            ])))
        }
    }

    #[test]
    fn agent_output_variants() {
        let _ = AgentOutput::TextDelta("hello".to_string());
        let _ = AgentOutput::ReasoningDelta("thinking".to_string());
        let _ = AgentOutput::Usage(TokenUsage {
            input: 100,
            output: 50,
            total: 150,
            cached_input: None,
            reasoning_output: None,
        });
        let _ = AgentOutput::ToolStarted {
            tool_call_id: "tc1".to_string(),
            tool_name: "shell".to_string(),
            arguments: "{}".to_string(),
        };
        let _ = AgentOutput::ToolCompleted {
            tool_call_id: "tc1".to_string(),
            tool_name: "shell".to_string(),
            output: "ok".to_string(),
        };
        let _ = AgentOutput::ApprovalWaiting {
            approval_id: Uuid::new_v4(),
            kind: "command".to_string(),
            title: "Run".to_string(),
            impact: ApprovalImpact::Permission {
                scope: "shell".to_string(),
                description: "test".to_string(),
            },
            fingerprint: "fp".to_string(),
            allows_session_approval: true,
        };
        let _ = AgentOutput::ApprovalResolved {
            approval_id: Uuid::new_v4(),
            decision: ApprovalDecision::ApproveOnce,
        };
        let _ = AgentOutput::Completed;
        let _ = AgentOutput::Failed("error".to_string());
        let _ = AgentOutput::Cancelled;
    }

    #[test]
    fn accumulate_usage_works() {
        let u1 = TokenUsage {
            input: 100,
            output: 50,
            total: 150,
            cached_input: Some(30),
            reasoning_output: Some(20),
        };
        let u2 = TokenUsage {
            input: 200,
            output: 100,
            total: 300,
            cached_input: Some(40),
            reasoning_output: Some(10),
        };

        let acc = accumulate_usage(&None, &u1);
        assert_eq!(acc.input, 100);

        let acc = accumulate_usage(&Some(u1), &u2);
        assert_eq!(acc.input, 300);
        assert_eq!(acc.output, 150);
        assert_eq!(acc.total, 450);
        assert_eq!(acc.cached_input, Some(70));
        assert_eq!(acc.reasoning_output, Some(30));
    }

    #[test]
    fn max_constants() {
        assert_eq!(MAX_MODEL_ROUNDS, 8);
        assert_eq!(MAX_TOOL_CALLS, 16);
    }

    #[tokio::test]
    async fn cancelling_while_waiting_for_approval_emits_cancelled() {
        let cancellation = CancellationToken::new();
        let approval_manager = Arc::new(ApprovalManager::new(Arc::new(tokio::sync::Mutex::new(
            Vec::new(),
        ))));
        let agent = AgentLoop::new(
            Arc::new(ToolCallingProvider),
            Arc::new(CompositeExecutor::new()),
            approval_manager,
        );
        let mut output = agent
            .run(
                vec![ChatMessage {
                    role: "user".to_string(),
                    text: "test".to_string(),
                    ..Default::default()
                }],
                cancellation.clone(),
                Uuid::new_v4(),
                Uuid::new_v4(),
                None,
            )
            .await;

        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while let Some(event) = output.next().await {
                match event {
                    AgentOutput::ApprovalWaiting { .. } => cancellation.cancel(),
                    AgentOutput::Cancelled => return,
                    AgentOutput::Completed => panic!("取消不应该被当成正常完成"),
                    _ => {}
                }
            }
            panic!("运行结束前未发送 cancelled 事件");
        })
        .await
        .expect("等待 cancelled 事件超时");
    }
}
