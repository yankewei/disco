use std::pin::Pin;
use std::sync::Arc;

use anyhow::{Context, Result, anyhow};
use async_trait::async_trait;
use disco_core::{
    AgentBackend, AgentLoop, BackendCapabilities, BackendRun, BackendRunRequest, BackendSession,
};
use disco_protocol::types::TokenUsage;
use disco_providers::{ChatMessage, ModelProvider, ProviderEvent};
use disco_tools::{CompositeExecutor, ToolDefinition};
use futures_core::Stream;
use rig_core::OneOrMany;
use rig_core::client::CompletionClient;
use rig_core::completion::{CompletionModel, GetTokenUsage};
use rig_core::message::{
    AssistantContent, Message, Reasoning, ReasoningContent, ToolCall as RigToolCall, ToolFunction,
    ToolResult as RigToolResult, ToolResultContent,
};
use rig_core::streaming::{StreamedAssistantContent, ToolCallDeltaContent};
use tokio_stream::StreamExt;

/// Rig 模型后端。
///
/// 当前切片由 Rig 负责 provider 请求与流式事件规范化，Disco 的 AgentLoop 继续负责
/// 审批和工具执行。后续迁移到 `rig-agent` 时，daemon 仍只依赖 AgentBackend。
pub struct RigBackend {
    provider: Arc<dyn ModelProvider>,
    executor: Arc<CompositeExecutor>,
}

impl RigBackend {
    pub fn new(provider: Arc<dyn ModelProvider>, executor: Arc<CompositeExecutor>) -> Self {
        Self { provider, executor }
    }
}

#[async_trait]
impl AgentBackend for RigBackend {
    fn capabilities(&self) -> BackendCapabilities {
        BackendCapabilities {
            has_persistent_sessions: false,
            can_delete_session: true,
        }
    }

    async fn start_run(&self, request: BackendRunRequest) -> Result<BackendRun> {
        let agent = AgentLoop::new(
            self.provider.clone(),
            self.executor.clone(),
            request.approval_manager,
        );
        let events = agent
            .run(
                request.messages,
                request.cancellation,
                request.run_id,
                request.session.id,
                request.workspace_path,
            )
            .await;

        Ok(BackendRun {
            events: Box::pin(events),
            backend_handle: None,
        })
    }

    async fn delete_session(&self, _session: &BackendSession) -> Result<()> {
        // API Key 后端没有远端持久会话，权威会话状态只存在于 Disco 数据库。
        Ok(())
    }
}

/// 构造使用 OpenAI Responses API 的 Rig provider。
pub fn openai_responses_provider(
    base_url: String,
    api_key: String,
    model: String,
) -> Result<Arc<dyn ModelProvider>> {
    let client = rig_core::providers::openai::Client::builder()
        .api_key(&api_key)
        .base_url(&base_url)
        .build()
        .context("无法创建 Rig OpenAI Responses client")?;
    Ok(Arc::new(RigModelProvider::new(
        client.completion_model(model),
        "openai_responses",
    )))
}

/// 构造使用 OpenAI Chat Completions 兼容协议的 Rig provider。
pub fn openai_chat_provider(
    base_url: String,
    api_key: String,
    model: String,
) -> Result<Arc<dyn ModelProvider>> {
    let client = rig_core::providers::openai::Client::builder()
        .api_key(&api_key)
        .base_url(&base_url)
        .build()
        .context("无法创建 Rig OpenAI client")?
        .completions_api();
    Ok(Arc::new(RigModelProvider::new(
        client.completion_model(model),
        "openai_chat_completions",
    )))
}

/// 构造使用 Rig 原生 DeepSeek 适配器的 provider。
pub fn deepseek_provider(
    base_url: String,
    api_key: String,
    model: String,
) -> Result<Arc<dyn ModelProvider>> {
    let client = rig_core::providers::deepseek::Client::builder()
        .api_key(&api_key)
        .base_url(&base_url)
        .build()
        .context("无法创建 Rig DeepSeek client")?;
    Ok(Arc::new(RigModelProvider::new(
        client.completion_model(model),
        "deepseek",
    )))
}

struct RigModelProvider<M> {
    model: M,
    vendor_name: &'static str,
}

impl<M> RigModelProvider<M> {
    fn new(model: M, vendor_name: &'static str) -> Self {
        Self { model, vendor_name }
    }
}

#[async_trait]
impl<M> ModelProvider for RigModelProvider<M>
where
    M: CompletionModel + Send + Sync + 'static,
    M::StreamingResponse: 'static,
{
    fn vendor_name(&self) -> &'static str {
        self.vendor_name
    }

    async fn stream<'a>(
        &'a self,
        messages: &'a [ChatMessage],
        tools: Option<&'a [ToolDefinition]>,
    ) -> Result<Pin<Box<dyn Stream<Item = Result<ProviderEvent>> + Send + 'a>>> {
        let mut rig_messages = messages
            .iter()
            .map(to_rig_message)
            .collect::<Result<Vec<_>>>()?;
        let prompt = rig_messages
            .pop()
            .ok_or_else(|| anyhow!("模型请求至少需要一条消息"))?;
        let rig_tools = tools
            .unwrap_or_default()
            .iter()
            .map(|tool| rig_core::completion::ToolDefinition {
                name: tool.name.clone(),
                description: tool.description.clone(),
                parameters: tool.input_schema.clone(),
            })
            .collect();
        let mut rig_stream = self
            .model
            .completion_request(prompt)
            .messages(rig_messages)
            .tools(rig_tools)
            .stream()
            .await
            .context("Rig 模型流启动失败")?;

        Ok(Box::pin(async_stream::try_stream! {
            while let Some(item) = rig_stream.next().await {
                match item.context("Rig 模型流读取失败")? {
                    StreamedAssistantContent::Text(text) => {
                        yield ProviderEvent::TextDelta(text.text);
                    }
                    StreamedAssistantContent::Reasoning(reasoning) => {
                        let text = reasoning_text(&reasoning);
                        if !text.is_empty() {
                            yield ProviderEvent::ReasoningDelta(text);
                        }
                    }
                    StreamedAssistantContent::ReasoningDelta { reasoning, .. } => {
                        yield ProviderEvent::ReasoningDelta(reasoning);
                    }
                    StreamedAssistantContent::ToolCallDelta { id, content, .. } => {
                        let (name, arguments_delta) = match content {
                            ToolCallDeltaContent::Name(name) => (name, String::new()),
                            ToolCallDeltaContent::Delta(delta) => (String::new(), delta),
                        };
                        yield ProviderEvent::ToolCallDelta {
                            call_id: id,
                            name,
                            arguments_delta,
                        };
                    }
                    StreamedAssistantContent::ToolCall { tool_call, .. } => {
                        let call_id = tool_call.call_id.unwrap_or(tool_call.id);
                        yield ProviderEvent::ToolCallCompleted {
                            call_id,
                            name: tool_call.function.name,
                            arguments: serde_json::to_string(&tool_call.function.arguments)
                                .context("无法序列化 Rig 工具参数")?,
                        };
                    }
                    StreamedAssistantContent::Final(raw_response) => {
                        let usage = raw_response.token_usage();
                        if usage.has_values() {
                            yield ProviderEvent::Usage(TokenUsage {
                                input: usage.input_tokens.try_into().unwrap_or(i64::MAX),
                                output: usage.output_tokens.try_into().unwrap_or(i64::MAX),
                                total: usage.total_tokens.try_into().unwrap_or(i64::MAX),
                                cached_input: Some(
                                    usage.cached_input_tokens.try_into().unwrap_or(i64::MAX),
                                ),
                                reasoning_output: Some(
                                    usage.reasoning_tokens.try_into().unwrap_or(i64::MAX),
                                ),
                            });
                        }
                    }
                    StreamedAssistantContent::Unknown(_) => {}
                }
            }
            yield ProviderEvent::Completed;
        }))
    }
}

fn to_rig_message(message: &ChatMessage) -> Result<Message> {
    match message.role.as_str() {
        "system" => Ok(Message::system(message.text.clone())),
        "user" if message.tool_call_id.is_some() => {
            let call_id = message.tool_call_id.clone().expect("guarded by is_some");
            Ok(Message::from(RigToolResult {
                id: call_id.clone(),
                call_id: Some(call_id),
                content: OneOrMany::one(ToolResultContent::text(message.text.clone())),
            }))
        }
        "user" => Ok(Message::user(message.text.clone())),
        "assistant" => {
            let mut content = Vec::new();
            if let Some(reasoning) = &message.reasoning_content {
                content.push(AssistantContent::Reasoning(Reasoning::new(reasoning)));
            }
            if !message.text.is_empty() {
                content.push(AssistantContent::text(message.text.clone()));
            }
            for tool_call in message.tool_calls.iter().flatten() {
                let arguments = serde_json::from_str(&tool_call.arguments)
                    .with_context(|| format!("工具 {} 的历史参数不是有效 JSON", tool_call.name))?;
                content.push(AssistantContent::ToolCall(
                    RigToolCall::new(
                        tool_call.call_id.clone(),
                        ToolFunction {
                            name: tool_call.name.clone(),
                            arguments,
                        },
                    )
                    .with_call_id(tool_call.call_id.clone()),
                ));
            }
            let content = OneOrMany::from_iter_optional(content)
                .unwrap_or_else(|| OneOrMany::one(AssistantContent::text("")));
            Ok(Message::Assistant { id: None, content })
        }
        role => Err(anyhow!("Rig 不支持消息角色: {role}")),
    }
}

fn reasoning_text(reasoning: &Reasoning) -> String {
    reasoning
        .content
        .iter()
        .filter_map(|content| match content {
            ReasoningContent::Text { text, .. } | ReasoningContent::Summary(text) => {
                Some(text.as_str())
            }
            _ => None,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use disco_core::{AgentOutput, ApprovalManager};
    use disco_providers::openai_responses::ToolCallInfo;
    use rig_core::completion::Usage;
    use rig_core::test_utils::{MockCompletionModel, MockStreamEvent};
    use tokio::sync::Mutex;
    use tokio_stream::StreamExt;
    use tokio_util::sync::CancellationToken;
    use uuid::Uuid;

    use super::*;

    #[test]
    fn maps_tool_call_history_with_provider_correlation_id() {
        let assistant = to_rig_message(&ChatMessage {
            role: "assistant".to_string(),
            text: "执行检查".to_string(),
            tool_calls: Some(vec![ToolCallInfo {
                call_id: "call-1".to_string(),
                name: "shell".to_string(),
                arguments: r#"{"command":"pwd"}"#.to_string(),
            }]),
            ..Default::default()
        })
        .unwrap();
        let Message::Assistant { content, .. } = assistant else {
            panic!("expected assistant message");
        };
        assert!(content.iter().any(|item| matches!(
            item,
            AssistantContent::ToolCall(tool_call)
                if tool_call.call_id.as_deref() == Some("call-1")
                    && tool_call.function.name == "shell"
        )));

        let tool_result = to_rig_message(&ChatMessage {
            role: "user".to_string(),
            text: "/workspace".to_string(),
            tool_call_id: Some("call-1".to_string()),
            tool_name: Some("shell".to_string()),
            ..Default::default()
        })
        .unwrap();
        let Message::User { content } = tool_result else {
            panic!("expected user tool result");
        };
        assert!(matches!(
            content.first_ref(),
            rig_core::message::UserContent::ToolResult(result)
                if result.call_id.as_deref() == Some("call-1")
        ));
    }

    #[tokio::test]
    async fn rig_provider_maps_stream_and_preserves_request_contract() {
        let usage = Usage {
            input_tokens: 12,
            output_tokens: 5,
            total_tokens: 17,
            ..Usage::new()
        };
        let model = MockCompletionModel::from_stream_turns([[
            MockStreamEvent::text("你好"),
            MockStreamEvent::reasoning_delta(None::<String>, "分析"),
            MockStreamEvent::tool_call("call-1", "shell", serde_json::json!({"command": "pwd"})),
            MockStreamEvent::final_response(usage),
        ]]);
        let provider = RigModelProvider::new(model.clone(), "test");
        let messages = [ChatMessage {
            role: "user".to_string(),
            text: "检查目录".to_string(),
            ..Default::default()
        }];
        let tools = [ToolDefinition {
            name: "shell".to_string(),
            description: "执行命令".to_string(),
            input_schema: serde_json::json!({
                "type": "object",
                "properties": {"command": {"type": "string"}}
            }),
        }];

        let events = provider
            .stream(&messages, Some(&tools))
            .await
            .unwrap()
            .collect::<Vec<_>>()
            .await;

        assert!(matches!(&events[0], Ok(ProviderEvent::TextDelta(text)) if text == "你好"));
        assert!(matches!(&events[1], Ok(ProviderEvent::ReasoningDelta(text)) if text == "分析"));
        assert!(matches!(
            &events[2],
            Ok(ProviderEvent::ToolCallCompleted { call_id, name, arguments })
                if call_id == "call-1" && name == "shell" && arguments == r#"{"command":"pwd"}"#
        ));
        assert!(matches!(
            &events[3],
            Ok(ProviderEvent::Usage(usage))
                if usage.input == 12 && usage.output == 5 && usage.total == 17
        ));
        assert!(matches!(&events[4], Ok(ProviderEvent::Completed)));

        let requests = model.requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].tools.len(), 1);
        assert_eq!(requests[0].tools[0].name, "shell");
        assert!(matches!(
            requests[0].chat_history.last_ref(),
            Message::User { .. }
        ));
    }

    #[tokio::test]
    async fn rig_backend_exposes_the_common_run_contract() {
        let model = MockCompletionModel::from_stream_turns([[
            MockStreamEvent::text("完成"),
            MockStreamEvent::final_response_with_default_usage(),
        ]]);
        let provider: Arc<dyn ModelProvider> = Arc::new(RigModelProvider::new(model, "test"));
        let backend = RigBackend::new(provider, Arc::new(CompositeExecutor::new()));
        let request = BackendRunRequest {
            run_id: Uuid::new_v4(),
            session: BackendSession {
                id: Uuid::new_v4(),
                model: "test-model".to_string(),
                backend_handle: None,
            },
            messages: vec![ChatMessage {
                role: "user".to_string(),
                text: "测试".to_string(),
                ..Default::default()
            }],
            workspace_path: None,
            cancellation: CancellationToken::new(),
            approval_manager: Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new())))),
        };

        let run = backend.start_run(request).await.unwrap();
        assert_eq!(run.backend_handle, None);
        let events = run.events.collect::<Vec<_>>().await;
        assert!(matches!(&events[0], AgentOutput::TextDelta(text) if text == "完成"));
        assert!(matches!(&events[1], AgentOutput::Completed));
    }
}
