use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use anyhow::{Context, Result, anyhow};
use async_trait::async_trait;
use disco_core::{
    AgentBackend, AgentOutput, ApprovalManager, BackendCapabilities, BackendRun, BackendRunRequest,
    BackendSession, PreparedApproval, tool_approval_request,
};
use disco_protocol::types::{ApprovalDecision, TokenUsage};
use disco_providers::{ChatMessage, ModelProvider, ProviderEvent};
use disco_tools::{CompositeExecutor, ToolCall, ToolContext, ToolDefinition, ToolExecutor};
use futures_core::Stream;
use rig_agent::AgentBuilder;
use rig_agent::agent::{
    AgentHook, MultiTurnStreamItem, StepEventKind, StreamingError, ToolCall as ToolCallEvent,
    ToolCallAction, ToolResultAction, ToolResultEvent,
};
use rig_agent::completion::PromptError;
use rig_agent::tool::{DynamicTool, ToolExecutionError, ToolOutput};
use rig_core::OneOrMany;
use rig_core::client::CompletionClient;
use rig_core::completion::{CompletionModel, GetTokenUsage};
use rig_core::message::{
    AssistantContent, Message, Reasoning, ReasoningContent, ToolCall as RigToolCall, ToolFunction,
    ToolResult as RigToolResult, ToolResultContent,
};
use rig_core::streaming::{StreamedAssistantContent, ToolCallDeltaContent};
use tokio::sync::mpsc;
use tokio_stream::StreamExt;
use tokio_stream::wrappers::ReceiverStream;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

/// 单次运行的模型轮次预算（含首轮）。大项目分析可能持续很多轮，
/// 10000 实际上近似不设限；达到上限仍按预算约束收尾而不是报错。
const MAX_MODEL_ROUNDS: usize = 10_000;
const MAX_TOOL_CALLS: usize = 10_000;

/// 一份 API Key Provider 配置对应的两个运行时接口。
///
/// 两者共享同一个 Rig model：AgentBackend 负责正常运行，ModelProvider 暂时供上下文压缩使用。
pub struct RigRuntime {
    pub backend: Arc<dyn AgentBackend>,
    pub compaction_provider: Arc<dyn ModelProvider>,
}

/// Rig 模型后端。
///
/// Rig 负责模型续轮和工具调度，Disco hook 负责审批、工具安全策略和公共事件。
struct RigBackend<M> {
    model: M,
    executor: Arc<CompositeExecutor>,
    max_model_rounds: usize,
}

impl<M> RigBackend<M> {
    fn new(model: M, executor: Arc<CompositeExecutor>) -> Self {
        Self::with_budget(model, executor, MAX_MODEL_ROUNDS)
    }

    fn with_budget(model: M, executor: Arc<CompositeExecutor>, max_model_rounds: usize) -> Self {
        Self {
            model,
            executor,
            max_model_rounds,
        }
    }
}

#[async_trait]
impl<M> AgentBackend for RigBackend<M>
where
    M: CompletionModel + Send + Sync + 'static,
    M::StreamingResponse: 'static,
{
    fn capabilities(&self) -> BackendCapabilities {
        BackendCapabilities {
            has_persistent_sessions: false,
            can_delete_session: true,
        }
    }

    async fn start_run(&self, request: BackendRunRequest) -> Result<BackendRun> {
        let mut messages = request
            .messages
            .iter()
            .map(to_rig_message)
            .collect::<Result<Vec<_>>>()?;
        let prompt = messages
            .pop()
            .ok_or_else(|| anyhow!("模型请求至少需要一条消息"))?;
        let tools = build_dynamic_tools(
            self.executor.clone(),
            request.run_id,
            request.workspace_path.clone(),
        );
        let (event_tx, event_rx) = mpsc::channel(64);
        let hook = DiscoToolHook {
            run_id: request.run_id,
            approval_manager: request.approval_manager.clone(),
            event_tx: event_tx.clone(),
            cancellation: request.cancellation.clone(),
            tool_call_count: AtomicUsize::new(0),
        };
        let agent = AgentBuilder::new(self.model.clone())
            .dynamic_tools(tools)
            .add_hook(hook)
            .build();
        let executor = self.executor.clone();
        let max_model_rounds = self.max_model_rounds;

        tokio::spawn(async move {
            let mut stream = agent
                .runner(prompt)
                .history(messages)
                .max_turns(max_model_rounds)
                .tool_concurrency(1)
                .stream()
                .await;
            let mut has_text = false;
            loop {
                tokio::select! {
                    biased;
                    _ = request.cancellation.cancelled() => {
                        request.approval_manager.cancel_all().await;
                        executor.cancel(request.run_id).await;
                        let _ = event_tx.send(AgentOutput::Cancelled).await;
                        return;
                    }
                    item = stream.next() => {
                        let output = match item {
                            Some(Ok(MultiTurnStreamItem::StreamAssistantItem(
                                StreamedAssistantContent::Text(text),
                            ))) => {
                                has_text = true;
                                Some(AgentOutput::TextDelta(text.text))
                            }
                            Some(Ok(MultiTurnStreamItem::StreamAssistantItem(
                                StreamedAssistantContent::Reasoning(reasoning),
                            ))) => {
                                let text = reasoning_text(&reasoning);
                                (!text.is_empty()).then_some(AgentOutput::ReasoningDelta(text))
                            }
                            Some(Ok(MultiTurnStreamItem::StreamAssistantItem(
                                StreamedAssistantContent::ReasoningDelta { reasoning, .. },
                            ))) => Some(AgentOutput::ReasoningDelta(reasoning)),
                            Some(Ok(MultiTurnStreamItem::CompletionCall(call)))
                                if call.usage.has_values() => {
                                    Some(AgentOutput::Usage(to_token_usage(call.usage)))
                                }
                            Some(Ok(MultiTurnStreamItem::FinalResponse(_))) => {
                                Some(AgentOutput::Completed)
                            }
                            Some(Ok(_)) => None,
                            Some(Err(_)) if request.cancellation.is_cancelled() => {
                                Some(AgentOutput::Cancelled)
                            }
                            Some(Err(error))
                                if matches!(
                                    &error,
                                    StreamingError::Prompt(prompt)
                                        if matches!(
                                            prompt.as_ref(),
                                            PromptError::MaxTurnsError { .. }
                                        )
                                ) =>
                            {
                                // 达到轮次上限是预算约束而不是故障：正常收尾，
                                // 避免把 MaxTurnsError 原文当作运行失败抛给用户。
                                if has_text {
                                    Some(AgentOutput::Completed)
                                } else {
                                    Some(AgentOutput::Failed(
                                        "已达到最大模型轮次上限，未产生有效回复。".to_string(),
                                    ))
                                }
                            }
                            Some(Err(error)) => Some(AgentOutput::Failed(error.to_string())),
                            None => Some(AgentOutput::Failed(
                                "Rig agent 事件流未产生终止结果".to_string(),
                            )),
                        };

                        if let Some(output) = output {
                            let terminal = matches!(
                                output,
                                AgentOutput::Completed
                                    | AgentOutput::Cancelled
                                    | AgentOutput::Failed(_)
                            );
                            if event_tx.send(output).await.is_err() || terminal {
                                return;
                            }
                        }
                    }
                }
            }
        });

        Ok(BackendRun {
            events: Box::pin(ReceiverStream::new(event_rx)),
            backend_handle: None,
        })
    }

    async fn delete_session(&self, _session: &BackendSession) -> Result<()> {
        // API Key 后端没有远端持久会话，权威会话状态只存在于 Disco 数据库。
        Ok(())
    }
}

/// 构造使用 OpenAI Responses API 的 Rig runtime。
pub fn openai_responses_runtime(
    base_url: String,
    api_key: String,
    model: String,
    executor: Arc<CompositeExecutor>,
) -> Result<RigRuntime> {
    let client = rig_core::providers::openai::Client::builder()
        .api_key(&api_key)
        .base_url(&base_url)
        .build()
        .context("无法创建 Rig OpenAI Responses client")?;
    Ok(build_runtime(
        client.completion_model(model),
        "openai_responses",
        executor,
    ))
}

/// 构造使用 OpenAI Chat Completions 兼容协议的 Rig runtime。
pub fn openai_chat_runtime(
    base_url: String,
    api_key: String,
    model: String,
    executor: Arc<CompositeExecutor>,
) -> Result<RigRuntime> {
    let client = rig_core::providers::openai::Client::builder()
        .api_key(&api_key)
        .base_url(&base_url)
        .build()
        .context("无法创建 Rig OpenAI client")?
        .completions_api();
    Ok(build_runtime(
        client.completion_model(model),
        "openai_chat_completions",
        executor,
    ))
}

/// 构造使用 Rig 原生 DeepSeek 适配器的 runtime。
pub fn deepseek_runtime(
    base_url: String,
    api_key: String,
    model: String,
    executor: Arc<CompositeExecutor>,
) -> Result<RigRuntime> {
    let client = rig_core::providers::deepseek::Client::builder()
        .api_key(&api_key)
        .base_url(&base_url)
        .build()
        .context("无法创建 Rig DeepSeek client")?;
    Ok(build_runtime(
        client.completion_model(model),
        "deepseek",
        executor,
    ))
}

/// 通过 Rig DeepSeek client 实时获取模型列表（`GET /models`）。
pub async fn list_models_deepseek(base_url: &str, api_key: &str) -> Result<Vec<ModelEntry>> {
    use rig_core::client::ModelListingClient;
    let client = rig_core::providers::deepseek::Client::builder()
        .api_key(api_key)
        .base_url(base_url)
        .build()
        .context("无法创建 Rig DeepSeek client")?;
    let models = client
        .list_models()
        .await
        .map_err(|error| anyhow!("DeepSeek 模型列表请求失败：{error}"))?;
    Ok(to_model_entries(models))
}

/// 通过 Rig OpenAI 兼容 client 实时获取模型列表（`GET {base_url}/models`），
/// 适用于 OpenAI 及兼容其接口的第三方服务商。
pub async fn list_models_openai_compat(base_url: &str, api_key: &str) -> Result<Vec<ModelEntry>> {
    use rig_core::client::ModelListingClient;
    let client = rig_core::providers::openai::Client::builder()
        .api_key(api_key)
        .base_url(base_url)
        .build()
        .context("无法创建 Rig OpenAI client")?;
    let models = client
        .list_models()
        .await
        .map_err(|error| anyhow!("OpenAI 兼容模型列表请求失败：{error}"))?;
    Ok(to_model_entries(models))
}

/// 模型条目：ID、显示名以及服务商声明的基础能力。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelEntry {
    pub id: String,
    pub display_name: Option<String>,
    pub model_type: Option<String>,
    pub context_window: Option<i64>,
}

fn to_model_entries(models: rig_core::model::ModelList) -> Vec<ModelEntry> {
    models
        .iter()
        .map(|model| ModelEntry {
            id: model.id.clone(),
            display_name: model.name.clone(),
            model_type: model.r#type.clone(),
            context_window: model.context_length.map(i64::from),
        })
        .collect()
}

fn build_runtime<M>(
    model: M,
    vendor_name: &'static str,
    executor: Arc<CompositeExecutor>,
) -> RigRuntime
where
    M: CompletionModel + Send + Sync + 'static,
    M::StreamingResponse: 'static,
{
    RigRuntime {
        backend: Arc::new(RigBackend::new(model.clone(), executor)),
        compaction_provider: Arc::new(RigModelProvider::new(model, vendor_name)),
    }
}

struct DiscoToolHook {
    run_id: Uuid,
    approval_manager: Arc<ApprovalManager>,
    event_tx: mpsc::Sender<AgentOutput>,
    cancellation: CancellationToken,
    tool_call_count: AtomicUsize,
}

impl AgentHook for DiscoToolHook {
    async fn on_tool_call(
        &self,
        _context: &rig_agent::agent::HookContext,
        event: ToolCallEvent<'_>,
    ) -> ToolCallAction {
        if self.tool_call_count.fetch_add(1, Ordering::Relaxed) >= MAX_TOOL_CALLS {
            return ToolCallAction::stop(format!("工具调用超过上限 {MAX_TOOL_CALLS}"));
        }

        let call_id = event.tool_call_id.unwrap_or(event.internal_call_id);
        if self
            .event_tx
            .send(AgentOutput::ToolStarted {
                tool_call_id: call_id.to_string(),
                tool_name: event.tool_name.to_string(),
                arguments: event.args.to_string(),
            })
            .await
            .is_err()
        {
            return ToolCallAction::stop("Disco 事件通道已关闭");
        }

        let request = tool_approval_request(self.run_id, event.tool_name, event.args);
        let decision = match self.approval_manager.prepare_approval(&request).await {
            PreparedApproval::SessionApproved => ApprovalDecision::ApproveOnce,
            PreparedApproval::Pending(pending) => {
                if self
                    .event_tx
                    .send(AgentOutput::approval_waiting(&request))
                    .await
                    .is_err()
                {
                    return ToolCallAction::stop("Disco 事件通道已关闭");
                }
                tokio::select! {
                    biased;
                    _ = self.cancellation.cancelled() => {
                        return ToolCallAction::stop("运行已取消");
                    }
                    decision = pending.wait() => decision,
                }
            }
        };
        if self
            .event_tx
            .send(AgentOutput::ApprovalResolved {
                approval_id: request.id,
                decision,
            })
            .await
            .is_err()
        {
            return ToolCallAction::stop("Disco 事件通道已关闭");
        }

        match decision {
            ApprovalDecision::Decline => ToolCallAction::skip("Tool execution declined by user"),
            ApprovalDecision::ApproveOnce | ApprovalDecision::ApproveForSession => {
                ToolCallAction::run()
            }
        }
    }

    async fn on_tool_result(
        &self,
        _context: &rig_agent::agent::HookContext,
        event: ToolResultEvent<'_>,
    ) -> ToolResultAction {
        let call_id = event.tool_call_id.unwrap_or(event.internal_call_id);
        let _ = self
            .event_tx
            .send(AgentOutput::ToolCompleted {
                tool_call_id: call_id.to_string(),
                tool_name: event.tool_name.to_string(),
                output: event.presentation.render(),
            })
            .await;
        ToolResultAction::keep()
    }

    fn observes(&self, kind: StepEventKind) -> bool {
        matches!(kind, StepEventKind::ToolCall | StepEventKind::ToolResult)
    }
}

fn build_dynamic_tools(
    executor: Arc<CompositeExecutor>,
    run_id: Uuid,
    workspace_path: Option<String>,
) -> Vec<DynamicTool> {
    executor
        .definitions()
        .into_iter()
        .map(|definition| {
            let executor = executor.clone();
            let tool_name = definition.name.clone();
            let workspace_path = workspace_path.clone();
            DynamicTool::new(
                definition.name,
                definition.description,
                definition.input_schema,
                move |_context, arguments| {
                    let executor = executor.clone();
                    let tool_name = tool_name.clone();
                    let workspace_path = workspace_path.clone();
                    Box::pin(async move {
                        let arguments = serde_json::to_string(&arguments).map_err(|error| {
                            ToolExecutionError::invalid_args(format!("无法序列化工具参数: {error}"))
                        })?;
                        let result = executor
                            .execute(
                                &ToolCall {
                                    call_id: Uuid::new_v4().to_string(),
                                    name: tool_name,
                                    arguments,
                                },
                                &ToolContext {
                                    run_id,
                                    workspace_path,
                                },
                            )
                            .await
                            .map_err(ToolExecutionError::other)?;
                        Ok(ToolOutput::text(result.output))
                    })
                },
            )
        })
        .collect()
}

fn to_token_usage(usage: rig_core::completion::Usage) -> TokenUsage {
    TokenUsage {
        input: usage.input_tokens.try_into().unwrap_or(i64::MAX),
        output: usage.output_tokens.try_into().unwrap_or(i64::MAX),
        total: usage.total_tokens.try_into().unwrap_or(i64::MAX),
        cached_input: Some(usage.cached_input_tokens.try_into().unwrap_or(i64::MAX)),
        reasoning_output: Some(usage.reasoning_tokens.try_into().unwrap_or(i64::MAX)),
    }
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
                            yield ProviderEvent::Usage(to_token_usage(usage));
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
    use disco_tools::ToolResult;
    use rig_core::completion::Usage;
    use rig_core::test_utils::{MockCompletionModel, MockStreamEvent};
    use tokio::sync::Mutex;
    use tokio_stream::StreamExt;
    use tokio_util::sync::CancellationToken;
    use uuid::Uuid;

    use super::*;

    struct RecordingToolExecutor {
        calls: Arc<Mutex<Vec<ToolCall>>>,
    }

    #[async_trait]
    impl ToolExecutor for RecordingToolExecutor {
        fn definitions(&self) -> Vec<ToolDefinition> {
            vec![ToolDefinition {
                name: "echo".to_string(),
                description: "返回输入值".to_string(),
                input_schema: serde_json::json!({
                    "type": "object",
                    "properties": {"value": {"type": "string"}},
                    "required": ["value"]
                }),
            }]
        }

        async fn execute(
            &self,
            call: &ToolCall,
            _context: &ToolContext,
        ) -> Result<ToolResult, String> {
            self.calls.lock().await.push(call.clone());
            Ok(ToolResult {
                call_id: call.call_id.clone(),
                output: "echo:ok".to_string(),
            })
        }

        async fn cancel(&self, _run_id: Uuid) {}
    }

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
        let usage = Usage {
            input_tokens: 8,
            output_tokens: 3,
            total_tokens: 11,
            ..Usage::new()
        };
        let model = MockCompletionModel::from_stream_turns([[
            MockStreamEvent::text("完成"),
            MockStreamEvent::final_response(usage),
        ]]);
        let backend = RigBackend::new(model, Arc::new(CompositeExecutor::new()));
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
        assert!(matches!(
            &events[1],
            AgentOutput::Usage(usage)
                if usage.input == 8 && usage.output == 3 && usage.total == 11
        ));
        assert!(matches!(&events[2], AgentOutput::Completed));
    }

    #[tokio::test]
    async fn rig_backend_runs_approved_tool_and_continues_model_loop() {
        let model = MockCompletionModel::from_stream_turns([
            [
                MockStreamEvent::tool_call(
                    "internal-call-1",
                    "echo",
                    serde_json::json!({"value": "ok"}),
                )
                .with_call_id("provider-call-1"),
                MockStreamEvent::final_response_with_default_usage(),
            ],
            [
                MockStreamEvent::text("工具已执行"),
                MockStreamEvent::final_response_with_default_usage(),
            ],
        ]);
        let calls = Arc::new(Mutex::new(Vec::new()));
        let mut executor = CompositeExecutor::new();
        executor.register(Box::new(RecordingToolExecutor {
            calls: calls.clone(),
        }));
        let approval_manager = Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new()))));
        let backend = RigBackend::new(model.clone(), Arc::new(executor));
        let request = BackendRunRequest {
            run_id: Uuid::new_v4(),
            session: BackendSession {
                id: Uuid::new_v4(),
                model: "test-model".to_string(),
                backend_handle: None,
            },
            messages: vec![ChatMessage {
                role: "user".to_string(),
                text: "调用 echo".to_string(),
                ..Default::default()
            }],
            workspace_path: Some("/workspace".to_string()),
            cancellation: CancellationToken::new(),
            approval_manager: approval_manager.clone(),
        };

        let mut events = backend.start_run(request).await.unwrap().events;
        let mut received = Vec::new();
        while let Some(event) = events.next().await {
            if let AgentOutput::ApprovalWaiting { approval_id, .. } = &event {
                let mut responded = approval_manager
                    .respond(*approval_id, ApprovalDecision::ApproveOnce)
                    .await;
                for _ in 0..100 {
                    if responded {
                        break;
                    }
                    tokio::task::yield_now().await;
                    responded = approval_manager
                        .respond(*approval_id, ApprovalDecision::ApproveOnce)
                        .await;
                }
                assert!(responded, "审批请求应在事件发出后完成注册");
            }
            received.push(event);
        }

        assert!(matches!(
            &received[0],
            AgentOutput::ToolStarted {
                tool_call_id,
                tool_name,
                ..
            } if tool_call_id == "provider-call-1" && tool_name == "echo"
        ));
        assert!(matches!(&received[1], AgentOutput::ApprovalWaiting { .. }));
        assert!(matches!(
            &received[2],
            AgentOutput::ApprovalResolved {
                decision: ApprovalDecision::ApproveOnce,
                ..
            }
        ));
        assert!(matches!(
            &received[3],
            AgentOutput::ToolCompleted { output, .. } if output == "echo:ok"
        ));
        assert!(matches!(
            &received[4],
            AgentOutput::TextDelta(text) if text == "工具已执行"
        ));
        assert!(matches!(&received[5], AgentOutput::Completed));
        assert_eq!(model.request_count(), 2);
        let calls = calls.lock().await;
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].name, "echo");
        assert_eq!(calls[0].arguments, r#"{"value":"ok"}"#);
    }

    #[tokio::test]
    async fn max_turns_exhaustion_completes_gracefully_with_partial_text() {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let mut executor = CompositeExecutor::new();
        executor.register(Box::new(RecordingToolExecutor {
            calls: calls.clone(),
        }));
        // 注入一个很小的轮次预算，每轮都返回工具调用把预算耗尽；
        // 首轮先输出一段文本，验证有文本时按完成收尾。
        let budget = 5;
        let mut turns: Vec<Vec<MockStreamEvent>> = Vec::new();
        for index in 0..budget {
            let mut events = Vec::new();
            if index == 0 {
                events.push(MockStreamEvent::text("开始分析"));
            }
            events.push(MockStreamEvent::tool_call(
                &format!("call-{index}"),
                "echo",
                serde_json::json!({"value": index.to_string()}),
            ));
            events.push(MockStreamEvent::final_response_with_default_usage());
            turns.push(events);
        }
        let model = MockCompletionModel::from_stream_turns(turns);
        let approval_manager = Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new()))));
        let backend = RigBackend::with_budget(model.clone(), Arc::new(executor), budget);
        let request = BackendRunRequest {
            run_id: Uuid::new_v4(),
            session: BackendSession {
                id: Uuid::new_v4(),
                model: "test-model".to_string(),
                backend_handle: None,
            },
            messages: vec![ChatMessage {
                role: "user".to_string(),
                text: "持续分析".to_string(),
                ..Default::default()
            }],
            workspace_path: Some("/workspace".to_string()),
            cancellation: CancellationToken::new(),
            approval_manager: approval_manager.clone(),
        };

        let mut events = backend.start_run(request).await.unwrap().events;
        let mut saw_text = false;
        let mut terminal: Option<AgentOutput> = None;
        while let Some(event) = events.next().await {
            if let AgentOutput::TextDelta(_) = &event {
                saw_text = true;
            }
            if let AgentOutput::ApprovalWaiting { approval_id, .. } = &event {
                let mut responded = approval_manager
                    .respond(*approval_id, ApprovalDecision::ApproveOnce)
                    .await;
                for _ in 0..100 {
                    if responded {
                        break;
                    }
                    tokio::task::yield_now().await;
                    responded = approval_manager
                        .respond(*approval_id, ApprovalDecision::ApproveOnce)
                        .await;
                }
                assert!(responded, "审批请求应在事件发出后完成注册");
            }
            if matches!(
                event,
                AgentOutput::Completed | AgentOutput::Failed(_) | AgentOutput::Cancelled
            ) {
                terminal = Some(event);
                break;
            }
        }

        assert!(saw_text, "首轮文本应被流式输出");
        // 轮次预算耗尽后按完成收尾，而不是把 MaxTurnsError 原文抛给用户。
        assert!(matches!(terminal, Some(AgentOutput::Completed)));
        assert_eq!(model.request_count(), budget);
        assert_eq!(calls.lock().await.len(), budget);
    }

    #[tokio::test]
    async fn cancelling_while_waiting_for_rig_tool_approval_is_terminal() {
        let model = MockCompletionModel::from_stream_turns([[
            MockStreamEvent::tool_call(
                "internal-call-1",
                "echo",
                serde_json::json!({"value": "ok"}),
            ),
            MockStreamEvent::final_response_with_default_usage(),
        ]]);
        let calls = Arc::new(Mutex::new(Vec::new()));
        let mut executor = CompositeExecutor::new();
        executor.register(Box::new(RecordingToolExecutor {
            calls: calls.clone(),
        }));
        let cancellation = CancellationToken::new();
        let backend = RigBackend::new(model, Arc::new(executor));
        let request = BackendRunRequest {
            run_id: Uuid::new_v4(),
            session: BackendSession {
                id: Uuid::new_v4(),
                model: "test-model".to_string(),
                backend_handle: None,
            },
            messages: vec![ChatMessage {
                role: "user".to_string(),
                text: "调用 echo".to_string(),
                ..Default::default()
            }],
            workspace_path: None,
            cancellation: cancellation.clone(),
            approval_manager: Arc::new(ApprovalManager::new(Arc::new(Mutex::new(Vec::new())))),
        };

        let mut events = backend.start_run(request).await.unwrap().events;
        assert!(matches!(
            events.next().await,
            Some(AgentOutput::ToolStarted { .. })
        ));
        assert!(matches!(
            events.next().await,
            Some(AgentOutput::ApprovalWaiting { .. })
        ));
        cancellation.cancel();
        let remaining = events.collect::<Vec<_>>().await;

        assert_eq!(
            remaining
                .iter()
                .filter(|event| matches!(event, AgentOutput::Cancelled))
                .count(),
            1
        );
        assert!(
            !remaining
                .iter()
                .any(|event| matches!(event, AgentOutput::Completed | AgentOutput::Failed(_)))
        );
        assert!(calls.lock().await.is_empty());
    }
}
