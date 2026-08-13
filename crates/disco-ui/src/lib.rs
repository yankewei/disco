//! Native GPUI client for a locally installed Codex app-server.

mod composer_input;
mod settings;

pub use composer_input::{ComposerInput, init as init_composer_input};

use std::path::PathBuf;

use composer_input::ComposerSubmitted;
use disco_codex_engine::{CodexModel, CodexRuntime, CodexTurnResult};
use disco_domain::{
    EngineKind, RunEventPayload, RunId, RunStatus, SessionId, TokenUsage, ToolCall,
};
use disco_kernel::{ActivityItem, EventJournal, Kernel, RunProjection};
use gpui::prelude::FluentBuilder;
use gpui::{
    AppContext, Context, Entity, FontWeight, InteractiveElement, IntoElement, ParentElement,
    Render, StatefulInteractiveElement, Styled, Window, div, img, px, rgb,
};
use serde_json::json;
use settings::{CodexUiSettings, save_api_key};

const APP_LOGO_ASSET: &str = "images/app-logo.png";
const CODEX_ICON_ASSET: &str = "icons/providers/codex.png";
const DEEPSEEK_ICON_ASSET: &str = "icons/providers/deepseek.svg";
const KIMI_ICON_ASSET: &str = "icons/providers/kimi-code.png";
const CHEVRON_DOWN_ASSET: &str = "icons/ui/chevron-down.svg";
const CHEVRON_UP_ASSET: &str = "icons/ui/chevron-up.svg";
const SETTINGS_ICON_ASSET: &str = "icons/ui/settings.svg";
const BACK_ICON_ASSET: &str = "icons/ui/back.svg";
const PROVIDERS_ICON_ASSET: &str = "icons/ui/providers.svg";
const SEND_ICON_ASSET: &str = "icons/ui/send.svg";
const STOP_ICON_ASSET: &str = "icons/ui/stop.svg";
const CANVAS: u32 = 0xffffff;
const SIDEBAR: u32 = 0xf3f4f6;
const SURFACE: u32 = 0xffffff;
const SURFACE_SUBTLE: u32 = 0xf5f6f8;
const SURFACE_HOVER: u32 = 0xe9ebef;
const BORDER: u32 = 0xe1e3e7;
const BORDER_STRONG: u32 = 0xd3d6dc;
const TEXT: u32 = 0x222327;
const MUTED: u32 = 0x6e727a;
const MUTED_LIGHT: u32 = 0x9a9ea6;
const BLUE: u32 = 0x007aff;
const BLUE_HOVER: u32 = 0x006ee6;
const BLUE_ACTIVE: u32 = 0x0062cc;
const BLUE_TINT: u32 = 0xeaf3ff;
const BLUE_INK: u32 = 0x174a7e;
const GREEN: u32 = 0x28a745;
const RED: u32 = 0xd7373f;
const SETTINGS_CANVAS: u32 = 0xf7f7f8;
const SETTINGS_SIDEBAR: u32 = 0xededef;
const SETTINGS_SELECTION: u32 = 0x0a84ff;
const SETTINGS_CONTROL: u32 = 0xe8e8ed;
const SETTINGS_SEPARATOR: u32 = 0xd1d1d6;
const TYPE_CAPTION: f32 = 11.;
const TYPE_UI: f32 = 12.5;
const TYPE_BODY: f32 = 13.5;
const TYPE_TITLE: f32 = 15.;
const APP_SIDEBAR_WIDTH: f32 = 252.;
const APP_TOP_BAR_HEIGHT: f32 = 52.;
const APP_SIDEBAR_TOP_INSET: f32 = 50.;
const CHAT_COLUMN_WIDTH: f32 = 760.;
const RADIUS_SMALL: f32 = 6.;
const RADIUS_MEDIUM: f32 = 9.;
const RADIUS_LARGE: f32 = 12.;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum WorkspacePage {
    #[default]
    Chat,
    Settings,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum ProviderKind {
    #[default]
    Codex,
    KimiCode,
    DeepSeek,
}

impl ProviderKind {
    const fn name(self) -> &'static str {
        match self {
            Self::Codex => "Codex",
            Self::KimiCode => "Kimi Code",
            Self::DeepSeek => "DeepSeek",
        }
    }

    const fn icon(self) -> &'static str {
        match self {
            Self::Codex => CODEX_ICON_ASSET,
            Self::KimiCode => KIMI_ICON_ASSET,
            Self::DeepSeek => DEEPSEEK_ICON_ASSET,
        }
    }
}

#[derive(Clone, Copy)]
struct ProviderSummary {
    kind: ProviderKind,
    name: &'static str,
    description: &'static str,
    icon: &'static str,
    configured: bool,
    status: &'static str,
}

#[derive(Debug)]
struct ChatConversation {
    session_id: SessionId,
    turns: Vec<RunProjection>,
}

impl ChatConversation {
    fn new() -> Self {
        Self {
            session_id: SessionId::new(),
            turns: Vec::new(),
        }
    }

    fn begin(&mut self, projection: RunProjection) -> bool {
        if self
            .turns
            .last()
            .is_some_and(|turn| !turn.status.is_terminal())
        {
            return false;
        }
        self.turns.push(projection);
        true
    }

    fn update(&mut self, projection: RunProjection) {
        if let Some(turn) = self
            .turns
            .iter_mut()
            .find(|turn| turn.run_id == projection.run_id)
        {
            *turn = projection;
        }
    }

    fn turns(&self) -> &[RunProjection] {
        &self.turns
    }

    fn current(&self) -> Option<&RunProjection> {
        self.turns.last()
    }

    fn title_prompt(&self) -> Option<&str> {
        self.turns.first().and_then(|turn| turn.prompt.as_deref())
    }

    fn can_begin_turn(&self) -> bool {
        self.current().is_none_or(|turn| turn.status.is_terminal())
    }
}

pub type CodexConnection = Result<(CodexRuntime, Vec<CodexModel>), String>;

pub struct DiscoWorkspace<J: EventJournal> {
    kernel: Kernel<J>,
    conversation: ChatConversation,
    composer: Entity<ComposerInput>,
    workspace_path: PathBuf,
    workspace_label: String,
    page: WorkspacePage,
    settings_path: PathBuf,
    settings: CodexUiSettings,
    runtime: Option<CodexRuntime>,
    runtime_error: Option<String>,
    models: Vec<CodexModel>,
    selected_model_id: Option<String>,
    selected_effort: String,
    codex_thread_id: Option<String>,
    model_menu_open: bool,
    model_menu_provider: ProviderKind,
    selected_chat_provider: ProviderKind,
    thinking_menu_open: bool,
    selected_provider: Option<ProviderKind>,
    kimi_endpoint_input: Entity<ComposerInput>,
    kimi_model_input: Entity<ComposerInput>,
    kimi_api_key_input: Entity<ComposerInput>,
    deepseek_endpoint_input: Entity<ComposerInput>,
    deepseek_model_input: Entity<ComposerInput>,
    deepseek_api_key_input: Entity<ComposerInput>,
    settings_notice: Option<(bool, String)>,
    stop_requested: bool,
}

impl<J: EventJournal> DiscoWorkspace<J> {
    pub fn new(
        journal: J,
        composer: Entity<ComposerInput>,
        settings_path: PathBuf,
        workspace_path: PathBuf,
        connection: CodexConnection,
        cx: &mut Context<Self>,
    ) -> Self {
        cx.subscribe(&composer, |workspace, _, event: &ComposerSubmitted, cx| {
            workspace.start_run(event.text.clone(), cx);
            cx.notify();
        })
        .detach();
        cx.observe(&composer, |_, _, cx| cx.notify()).detach();

        let saved = CodexUiSettings::load(&settings_path).unwrap_or_default();
        let kimi_endpoint_input = cx.new(|cx| {
            ComposerInput::new(cx)
                .with_placeholder("API endpoint")
                .with_content(saved.kimi_code.endpoint.clone())
        });
        let kimi_model_input = cx.new(|cx| {
            ComposerInput::new(cx)
                .with_placeholder("Model ID")
                .with_content(saved.kimi_code.model.clone())
        });
        let kimi_api_key_input = cx.new(|cx| {
            ComposerInput::new(cx)
                .with_placeholder("Enter a new API key")
                .secure(true)
        });
        let deepseek_endpoint_input = cx.new(|cx| {
            ComposerInput::new(cx)
                .with_placeholder("API endpoint")
                .with_content(saved.deepseek.endpoint.clone())
        });
        let deepseek_model_input = cx.new(|cx| {
            ComposerInput::new(cx)
                .with_placeholder("Model ID")
                .with_content(saved.deepseek.model.clone())
        });
        let deepseek_api_key_input = cx.new(|cx| {
            ComposerInput::new(cx)
                .with_placeholder("Enter a new API key")
                .secure(true)
        });
        for input in [
            &kimi_endpoint_input,
            &kimi_model_input,
            &kimi_api_key_input,
            &deepseek_endpoint_input,
            &deepseek_model_input,
            &deepseek_api_key_input,
        ] {
            cx.observe(input, |_, _, cx| cx.notify()).detach();
        }
        let (runtime, runtime_error, models) = match connection {
            Ok((runtime, models)) => (Some(runtime), None, models),
            Err(error) => (None, Some(error), Vec::new()),
        };
        let selected_model_id = saved
            .selected_model
            .clone()
            .filter(|saved| models.iter().any(|model| model.id == *saved))
            .or_else(|| {
                models
                    .iter()
                    .find(|model| model.is_default)
                    .or_else(|| models.first())
                    .map(|model| model.id.clone())
            });
        let selected_effort = selected_model_id
            .as_deref()
            .and_then(|selected| models.iter().find(|model| model.id == selected))
            .map(|model| model.default_reasoning_effort.clone())
            .unwrap_or_else(|| "medium".into());
        let workspace_label = workspace_path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "Local workspace".into());

        Self {
            kernel: Kernel::new(journal),
            conversation: ChatConversation::new(),
            composer,
            workspace_path,
            workspace_label,
            page: WorkspacePage::Chat,
            settings_path,
            settings: saved,
            runtime,
            runtime_error,
            models,
            selected_model_id,
            selected_effort,
            codex_thread_id: None,
            model_menu_open: false,
            model_menu_provider: ProviderKind::Codex,
            selected_chat_provider: ProviderKind::Codex,
            thinking_menu_open: false,
            selected_provider: Some(ProviderKind::Codex),
            kimi_endpoint_input,
            kimi_model_input,
            kimi_api_key_input,
            deepseek_endpoint_input,
            deepseek_model_input,
            deepseek_api_key_input,
            settings_notice: None,
            stop_requested: false,
        }
    }

    fn selected_model(&self) -> Option<&CodexModel> {
        let selected = self.selected_model_id.as_deref()?;
        self.models.iter().find(|model| model.id == selected)
    }

    fn select_model(&mut self, model_id: String) {
        let Some(model) = self.models.iter().find(|model| model.id == model_id) else {
            return;
        };
        self.selected_effort = model.default_reasoning_effort.clone();
        self.selected_model_id = Some(model.id.clone());
        self.selected_chat_provider = ProviderKind::Codex;
        self.model_menu_open = false;
        self.thinking_menu_open = false;
        self.settings.selected_model = self.selected_model_id.clone();
        if let Err(error) = self.settings.save(&self.settings_path) {
            self.runtime_error = Some(error);
        }
    }

    fn select_model_menu_provider(&mut self, provider: ProviderKind) {
        self.model_menu_provider = provider;
        self.thinking_menu_open = false;
    }

    fn open_provider_settings(&mut self, provider: ProviderKind) {
        self.page = WorkspacePage::Settings;
        self.selected_provider = Some(provider);
        self.model_menu_open = false;
        self.thinking_menu_open = false;
        self.settings_notice = None;
    }

    fn select_effort(&mut self, effort: String) {
        if self
            .selected_model()
            .is_some_and(|model| model.reasoning_efforts.contains(&effort))
        {
            self.selected_effort = effort;
        }
        self.thinking_menu_open = false;
    }

    fn save_remote_provider(&mut self, provider: ProviderKind, cx: &mut Context<Self>) {
        let (provider_id, endpoint_input, model_input, api_key_input, was_configured) =
            match provider {
                ProviderKind::KimiCode => (
                    "kimi-code",
                    self.kimi_endpoint_input.clone(),
                    self.kimi_model_input.clone(),
                    self.kimi_api_key_input.clone(),
                    self.settings.kimi_code.credential_configured,
                ),
                ProviderKind::DeepSeek => (
                    "deepseek",
                    self.deepseek_endpoint_input.clone(),
                    self.deepseek_model_input.clone(),
                    self.deepseek_api_key_input.clone(),
                    self.settings.deepseek.credential_configured,
                ),
                ProviderKind::Codex => return,
            };
        let endpoint = endpoint_input.read(cx).content().trim().to_owned();
        let model = model_input.read(cx).content().trim().to_owned();
        let api_key = api_key_input.read(cx).content().trim().to_owned();
        if endpoint.is_empty() || model.is_empty() {
            self.settings_notice = Some((
                false,
                "Endpoint and model are required before this provider can be configured.".into(),
            ));
            return;
        }
        if api_key.is_empty() && !was_configured {
            self.settings_notice = Some((
                false,
                "Enter an API key. Disco stores it in macOS Keychain.".into(),
            ));
            return;
        }
        if !api_key.is_empty()
            && let Err(error) = save_api_key(provider_id, &api_key)
        {
            self.settings_notice = Some((false, error));
            return;
        }

        let provider_settings = match provider {
            ProviderKind::KimiCode => &mut self.settings.kimi_code,
            ProviderKind::DeepSeek => &mut self.settings.deepseek,
            ProviderKind::Codex => return,
        };
        provider_settings.endpoint = endpoint;
        provider_settings.model = model;
        provider_settings.credential_configured = was_configured || !api_key.is_empty();
        match self.settings.save(&self.settings_path) {
            Ok(()) => {
                api_key_input.update(cx, |input, cx| input.set_content("", cx));
                self.settings_notice = Some((
                    true,
                    "Provider configuration saved. The API key is in macOS Keychain.".into(),
                ));
            }
            Err(error) => self.settings_notice = Some((false, error)),
        }
    }

    fn start_run(&mut self, prompt: String, cx: &mut Context<Self>) {
        if !self.conversation.can_begin_turn() {
            return;
        }
        self.model_menu_open = false;
        self.thinking_menu_open = false;
        let run_id = RunId::new();
        let started = self.kernel.start_run(
            run_id,
            self.conversation.session_id,
            EngineKind::Codex,
            Some(self.workspace_path.to_string_lossy().into_owned()),
            prompt.clone(),
        );
        let Ok(projection) = started else {
            let mut projection = RunProjection::empty(run_id);
            projection.prompt = Some(prompt);
            projection.status = RunStatus::Failed;
            projection.failure_message = Some("Could not persist the Codex run.".into());
            self.conversation.begin(projection);
            return;
        };
        if !self.conversation.begin(projection) {
            return;
        }

        let Some(runtime) = self.runtime.clone() else {
            self.record_failure(
                run_id,
                "codex_not_available",
                self.runtime_error
                    .clone()
                    .unwrap_or_else(|| "Codex CLI is not available.".into()),
            );
            return;
        };
        runtime.prepare_turn();
        self.stop_requested = false;
        let Some(model) = self.selected_model_id.clone() else {
            self.record_failure(
                run_id,
                "model_not_available",
                "Codex returned no models.".into(),
            );
            return;
        };
        let thread_id = self.codex_thread_id.clone();
        let workspace = self.workspace_path.clone();
        let effort = self.selected_effort.clone();
        let prompt = self
            .conversation
            .current()
            .and_then(|turn| turn.prompt.clone())
            .unwrap_or_default();
        let request = cx.background_executor().spawn(async move {
            runtime.run_turn(thread_id.as_deref(), &workspace, &prompt, &model, &effort)
        });
        cx.spawn(async move |workspace, cx| {
            let result = request.await.map_err(|error| error.to_string());
            workspace
                .update(cx, |workspace, cx| {
                    workspace.finish_run(run_id, result);
                    cx.notify();
                })
                .ok();
        })
        .detach();
    }

    fn terminal_event(interrupted: bool) -> RunEventPayload {
        // An interrupted codex turn ends as Cancelled, never Completed.
        if interrupted {
            RunEventPayload::RunCancelled
        } else {
            RunEventPayload::RunCompleted
        }
    }

    fn finish_run(&mut self, run_id: RunId, result: Result<CodexTurnResult, String>) {
        self.stop_requested = false;
        match result {
            Ok(result) => {
                self.codex_thread_id = Some(result.thread_id);
                for activity in result.activities {
                    let detail = activity.detail.clone();
                    let call = ToolCall {
                        call_id: activity.id.clone(),
                        name: activity.title,
                        arguments: json!({ "detail": detail }),
                    };
                    self.record(run_id, RunEventPayload::ToolRequested { call });
                    self.record(
                        run_id,
                        RunEventPayload::ToolCompleted {
                            call_id: activity.id,
                            success: activity.success,
                            output: activity.detail,
                        },
                    );
                }
                if !result.text.is_empty() {
                    self.record(
                        run_id,
                        RunEventPayload::AssistantContentDelta { text: result.text },
                    );
                }
                self.record(
                    run_id,
                    RunEventPayload::UsageUpdated {
                        usage: TokenUsage {
                            input_tokens: result.usage.input_tokens,
                            output_tokens: result.usage.output_tokens,
                            total_tokens: result.usage.total_tokens,
                        },
                    },
                );
                self.record(run_id, Self::terminal_event(result.interrupted));
            }
            Err(error) => self.record_failure(run_id, "codex_turn_failed", error),
        }
    }

    fn record(&mut self, run_id: RunId, payload: RunEventPayload) {
        if let Ok(projection) = self.kernel.record(run_id, payload) {
            self.conversation.update(projection);
        }
    }

    fn record_failure(&mut self, run_id: RunId, code: &str, message: String) {
        self.record(
            run_id,
            RunEventPayload::RunFailed {
                code: code.into(),
                message,
                retryable: true,
            },
        );
    }

    fn submit_composer(&mut self, cx: &mut Context<Self>) {
        if !self.conversation.can_begin_turn() {
            return;
        }
        let prompt = self
            .composer
            .update(cx, |composer, cx| composer.take_content(cx));
        if let Some(prompt) = prompt {
            self.start_run(prompt, cx);
        }
    }

    fn stop_run(&mut self) {
        if self.stop_requested
            || self
                .conversation
                .current()
                .is_none_or(|turn| turn.status.is_terminal())
        {
            return;
        }
        let Some(runtime) = self.runtime.as_ref() else {
            return;
        };
        match runtime.interrupt_turn() {
            Ok(()) => self.stop_requested = true,
            Err(_) => {
                // Do not record a terminal RunFailed here: the turn is still
                // executing, and a terminal event would orphan its real outcome
                // (finish_run's events are rejected as EventAfterTerminal) and
                // flip the UI back to send mode mid-run. Leave the run running;
                // stop_requested stays false so the stop button stays active
                // for a retry.
            }
        }
    }

    fn new_task(&mut self) {
        self.conversation = ChatConversation::new();
        self.codex_thread_id = None;
        self.model_menu_open = false;
        self.thinking_menu_open = false;
        self.page = WorkspacePage::Chat;
        self.stop_requested = false;
    }

    fn status_label(&self) -> &'static str {
        let Some(current) = self.conversation.current() else {
            return if self.runtime.is_some() {
                "Codex ready"
            } else {
                "Codex unavailable"
            };
        };
        match current.status {
            RunStatus::Queued => "Queued",
            RunStatus::Running => "Codex working",
            RunStatus::WaitingForTool => "Running tool",
            RunStatus::WaitingForApproval => "Approval required",
            RunStatus::WaitingForUserInput => "Input required",
            RunStatus::Completed => "Completed",
            RunStatus::Failed => "Failed",
            RunStatus::Cancelled => "Cancelled",
        }
    }

    fn status_color(&self) -> u32 {
        let Some(current) = self.conversation.current() else {
            return if self.runtime.is_some() { GREEN } else { RED };
        };
        match current.status {
            RunStatus::Completed => GREEN,
            RunStatus::Failed | RunStatus::Cancelled => RED,
            _ => BLUE,
        }
    }

    fn compact_title(prompt: &str) -> String {
        const MAX_CHARS: usize = 34;
        if prompt.chars().count() <= MAX_CHARS {
            return prompt.to_owned();
        }
        let mut title = prompt.chars().take(MAX_CHARS).collect::<String>();
        title.push('…');
        title
    }

    fn model_count_label(count: usize) -> String {
        if count == 1 {
            "1 model".into()
        } else {
            format!("{count} models")
        }
    }

    fn reasoning_effort_label(effort: &str) -> String {
        match effort {
            "low" => "Low".into(),
            "medium" => "Medium".into(),
            "high" => "High".into(),
            "xhigh" => "Extra high".into(),
            _ => effort.into(),
        }
    }

    fn activity_row(item: &ActivityItem) -> impl IntoElement {
        div()
            .flex()
            .items_start()
            .gap_2()
            .px_3()
            .py_2()
            .child(
                div()
                    .mt(px(5.))
                    .size(px(6.))
                    .rounded_full()
                    .bg(rgb(if item.completed { GREEN } else { BLUE })),
            )
            .child(
                div()
                    .min_w(px(0.))
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(TEXT))
                            .child(item.title.clone()),
                    )
                    .child(
                        div()
                            .text_size(px(TYPE_CAPTION))
                            .line_height(px(16.))
                            .text_color(rgb(MUTED))
                            .child(item.detail.clone()),
                    ),
            )
    }

    fn conversation_turn(turn: RunProjection) -> impl IntoElement {
        let prompt = turn.prompt.unwrap_or_default();
        let is_working = !turn.status.is_terminal();
        let assistant = turn.assistant_text;
        let activities = turn.activities;
        let usage = turn.usage;
        let failure = turn.failure_message;

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap_4()
            .child(
                div().w_full().flex().justify_end().child(
                    div()
                        .max_w(px(620.))
                        .px_3()
                        .py_2()
                        .rounded(px(RADIUS_LARGE))
                        .bg(rgb(BLUE_TINT))
                        .text_size(px(TYPE_BODY))
                        .line_height(px(20.))
                        .text_color(rgb(BLUE_INK))
                        .child(prompt),
                ),
            )
            .child(
                div()
                    .min_w(px(0.))
                    .max_w(px(700.))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .when(!assistant.is_empty(), |column| {
                        column.child(
                            div()
                                .text_size(px(TYPE_BODY))
                                .line_height(px(21.))
                                .child(assistant),
                        )
                    })
                    .when(is_working, |column| {
                        column.child(
                            div()
                                .text_size(px(TYPE_UI))
                                .text_color(rgb(MUTED))
                                .child("Working…"),
                        )
                    })
                    .when_some(failure, |column, message| {
                        column.child(
                            div()
                                .px_3()
                                .py_2()
                                .rounded(px(RADIUS_MEDIUM))
                                .bg(rgb(0xffeeee))
                                .text_size(px(TYPE_UI))
                                .text_color(rgb(RED))
                                .child(message),
                        )
                    })
                    .when(!activities.is_empty(), |column| {
                        column.child(
                            div()
                                .rounded(px(RADIUS_MEDIUM))
                                .bg(rgb(SURFACE_SUBTLE))
                                .border_1()
                                .border_color(rgb(BORDER))
                                .children(activities.iter().map(Self::activity_row)),
                        )
                    })
                    .when(usage.total_tokens > 0, |column| {
                        column.child(
                            div()
                                .text_size(px(TYPE_CAPTION))
                                .text_color(rgb(MUTED_LIGHT))
                                .child(format!(
                                    "{} input · {} output · {} total tokens",
                                    usage.input_tokens, usage.output_tokens, usage.total_tokens
                                )),
                        )
                    }),
            )
    }

    fn sidebar(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let prompt = self.conversation.title_prompt().unwrap_or_default();
        let status = self.status_label();
        let has_run = !self.conversation.turns().is_empty();
        div()
            .w(px(APP_SIDEBAR_WIDTH))
            .h_full()
            .flex_shrink_0()
            .flex()
            .flex_col()
            .bg(rgb(SIDEBAR))
            .border_r_1()
            .border_color(rgb(BORDER))
            .child(div().h(px(APP_SIDEBAR_TOP_INSET)))
            .child(
                div()
                    .id("new-task")
                    .mx_3()
                    .h(px(36.))
                    .px_3()
                    .flex()
                    .items_center()
                    .justify_between()
                    .rounded(px(RADIUS_MEDIUM))
                    .bg(rgb(SURFACE))
                    .border_1()
                    .border_color(rgb(BORDER_STRONG))
                    .shadow_xs()
                    .cursor_pointer()
                    .hover(|style| style.bg(rgb(SURFACE_HOVER)))
                    .active(|style| style.bg(rgb(0xdde3eb)))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.new_task();
                        cx.notify();
                    }))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::MEDIUM)
                            .child(div().text_size(px(TYPE_TITLE)).child("＋"))
                            .child("New Task"),
                    )
                    .child(
                        div()
                            .text_size(px(TYPE_CAPTION))
                            .text_color(rgb(MUTED))
                            .child("⌘N"),
                    ),
            )
            .child(
                div()
                    .px_5()
                    .pt_4()
                    .pb_2()
                    .text_size(px(TYPE_CAPTION))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(rgb(MUTED_LIGHT))
                    .child("RECENT"),
            )
            .when(has_run, |sidebar| {
                sidebar.child(
                    div()
                        .mx_3()
                        .h(px(40.))
                        .px_3()
                        .flex()
                        .items_center()
                        .justify_between()
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(rgb(BLUE_TINT))
                        .child(
                            div()
                                .min_w(px(0.))
                                .truncate()
                                .text_size(px(TYPE_UI))
                                .font_weight(FontWeight::MEDIUM)
                                .child(Self::compact_title(prompt)),
                        )
                        .child(
                            div()
                                .ml_2()
                                .flex_shrink_0()
                                .text_size(px(TYPE_CAPTION))
                                .text_color(rgb(MUTED))
                                .child(status),
                        ),
                )
            })
            .when(!has_run, |sidebar| {
                sidebar.child(
                    div()
                        .px_5()
                        .py_3()
                        .text_size(px(TYPE_UI))
                        .text_color(rgb(MUTED))
                        .child("No conversations yet"),
                )
            })
            .child(div().flex_grow())
            .child(
                div()
                    .mx_4()
                    .py_3()
                    .flex()
                    .items_center()
                    .justify_between()
                    .border_t_1()
                    .border_color(rgb(BORDER))
                    .child(
                        div()
                            .min_w(px(0.))
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                div()
                                    .size(px(24.))
                                    .rounded(px(RADIUS_SMALL))
                                    .overflow_hidden()
                                    .child(img(APP_LOGO_ASSET).size_full()),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_size(px(TYPE_UI))
                                    .font_weight(FontWeight::MEDIUM)
                                    .child(self.workspace_label.clone()),
                            ),
                    )
                    .child(
                        div()
                            .id("open-settings")
                            .size(px(38.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(RADIUS_MEDIUM))
                            .cursor_pointer()
                            .bg(rgb(if self.page == WorkspacePage::Settings {
                                BLUE_TINT
                            } else {
                                SIDEBAR
                            }))
                            .hover(|style| style.bg(rgb(SURFACE_HOVER)))
                            .active(|style| style.bg(rgb(0xdde3eb)))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.page = WorkspacePage::Settings;
                                this.model_menu_open = false;
                                this.thinking_menu_open = false;
                                cx.notify();
                            }))
                            .child(img(SETTINGS_ICON_ASSET).size(px(19.))),
                    ),
            )
    }

    fn model_picker_provider_row(
        &self,
        provider: ProviderKind,
        detail: String,
        ready: bool,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let selected = self.model_menu_provider == provider;
        div()
            .id(("chat-provider", provider as usize))
            .h(px(46.))
            .px_2()
            .flex()
            .items_center()
            .gap_2()
            .rounded(px(RADIUS_MEDIUM))
            .cursor_pointer()
            .bg(rgb(if selected { SURFACE } else { SURFACE_SUBTLE }))
            .text_color(rgb(if selected { TEXT } else { MUTED }))
            .hover(|style| style.bg(rgb(SURFACE)))
            .active(|style| style.bg(rgb(SURFACE_HOVER)))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.select_model_menu_provider(provider);
                cx.notify();
            }))
            .child(
                div()
                    .size(px(26.))
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(RADIUS_SMALL))
                    .overflow_hidden()
                    .bg(rgb(if provider == ProviderKind::KimiCode {
                        0x101114
                    } else {
                        SURFACE
                    }))
                    .child(img(provider.icon()).max_w(px(22.)).max_h(px(22.))),
            )
            .child(
                div()
                    .min_w(px(0.))
                    .flex_grow()
                    .flex()
                    .flex_col()
                    .gap(px(1.))
                    .child(
                        div()
                            .truncate()
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::MEDIUM)
                            .child(provider.name()),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(px(TYPE_CAPTION))
                            .text_color(rgb(MUTED_LIGHT))
                            .child(detail),
                    ),
            )
            .child(
                div()
                    .size(px(6.))
                    .flex_shrink_0()
                    .rounded_full()
                    .bg(rgb(if ready { GREEN } else { MUTED_LIGHT })),
            )
    }

    fn remote_model_picker_detail(
        &self,
        provider: ProviderKind,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let settings = match provider {
            ProviderKind::KimiCode => &self.settings.kimi_code,
            ProviderKind::DeepSeek => &self.settings.deepseek,
            ProviderKind::Codex => unreachable!("Codex models come from app-server"),
        };
        let configured = settings.credential_configured;
        let model = settings.model.clone();
        div()
            .size_full()
            .px_5()
            .py_4()
            .flex()
            .flex_col()
            .items_start()
            .child(
                div()
                    .size(px(34.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(RADIUS_MEDIUM))
                    .overflow_hidden()
                    .bg(rgb(if provider == ProviderKind::KimiCode {
                        0x101114
                    } else {
                        SURFACE_SUBTLE
                    }))
                    .child(img(provider.icon()).max_w(px(28.)).max_h(px(28.))),
            )
            .child(
                div()
                    .mt_3()
                    .text_size(px(TYPE_BODY))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(provider.name()),
            )
            .child(
                div()
                    .mt_1()
                    .max_w(px(290.))
                    .text_size(px(TYPE_UI))
                    .line_height(px(18.))
                    .text_color(rgb(MUTED))
                    .child(if configured {
                        "This provider is configured, but remote execution is not connected in this build. It cannot be selected for a real run yet."
                    } else {
                        "Configure the endpoint, model, and API key before this provider can be used."
                    }),
            )
            .when(configured && !model.is_empty(), |content| {
                content.child(
                    div()
                        .mt_4()
                        .w_full()
                        .px_3()
                        .py_2()
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(rgb(SURFACE_SUBTLE))
                        .child(
                            div()
                                .text_size(px(TYPE_CAPTION))
                                .text_color(rgb(MUTED_LIGHT))
                                .child("Configured model"),
                        )
                        .child(
                            div()
                                .mt_1()
                                .truncate()
                                .text_size(px(TYPE_UI))
                                .font_weight(FontWeight::MEDIUM)
                                .child(model),
                        ),
                )
            })
            .child(div().flex_grow())
            .child(
                div()
                    .id(("chat-provider-settings", provider as usize))
                    .h(px(30.))
                    .px_3()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(RADIUS_SMALL))
                    .cursor_pointer()
                    .bg(rgb(SETTINGS_CONTROL))
                    .text_size(px(TYPE_UI))
                    .font_weight(FontWeight::MEDIUM)
                    .hover(|style| style.bg(rgb(SURFACE_HOVER)))
                    .active(|style| style.bg(rgb(0xd9dbe0)))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.open_provider_settings(provider);
                        cx.notify();
                    }))
                    .child(if configured {
                        "Open provider settings"
                    } else {
                        "Configure provider"
                    }),
            )
    }

    fn model_picker(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let codex_ready = self.runtime.is_some();
        let codex_count = self.models.len();
        let codex_count_label = Self::model_count_label(codex_count);
        let kimi_configured = self.settings.kimi_code.credential_configured;
        let deepseek_configured = self.settings.deepseek.credential_configured;
        let selected_model_id = self.selected_model_id.clone();
        let model_menu_provider = self.model_menu_provider;

        div()
            .absolute()
            .bottom(px(46.))
            .left(px(0.))
            .w(px(520.))
            .h(px(300.))
            .flex()
            .overflow_hidden()
            .rounded(px(RADIUS_LARGE))
            .bg(rgb(SURFACE))
            .border_1()
            .border_color(rgb(BORDER_STRONG))
            .shadow_lg()
            .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                this.model_menu_open = false;
                cx.notify();
            }))
            .child(
                div()
                    .w(px(166.))
                    .h_full()
                    .p_2()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .bg(rgb(SURFACE_SUBTLE))
                    .border_r_1()
                    .border_color(rgb(BORDER))
                    .child(
                        div()
                            .h(px(26.))
                            .px_2()
                            .flex()
                            .items_center()
                            .text_size(px(TYPE_CAPTION))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(MUTED_LIGHT))
                            .child("PROVIDERS"),
                    )
                    .child(self.model_picker_provider_row(
                        ProviderKind::Codex,
                        if codex_ready {
                            codex_count_label.clone()
                        } else {
                            "Unavailable".into()
                        },
                        codex_ready,
                        cx,
                    ))
                    .child(self.model_picker_provider_row(
                        ProviderKind::KimiCode,
                        if kimi_configured {
                            "Configured".into()
                        } else {
                            "Set up".into()
                        },
                        false,
                        cx,
                    ))
                    .child(self.model_picker_provider_row(
                        ProviderKind::DeepSeek,
                        if deepseek_configured {
                            "Configured".into()
                        } else {
                            "Set up".into()
                        },
                        false,
                        cx,
                    )),
            )
            .child(
                div()
                    .min_w(px(0.))
                    .h_full()
                    .flex_grow()
                    .flex()
                    .flex_col()
                    .when(model_menu_provider == ProviderKind::Codex, |panel| {
                        panel
                            .child(
                                div()
                                    .h(px(44.))
                                    .px_4()
                                    .flex()
                                    .items_center()
                                    .justify_between()
                                    .border_b_1()
                                    .border_color(rgb(BORDER))
                                    .child(
                                        div()
                                            .text_size(px(TYPE_UI))
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .child("Codex models"),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(TYPE_CAPTION))
                                            .text_color(rgb(MUTED_LIGHT))
                                            .child(format!("{codex_count_label} available")),
                                    ),
                            )
                            .when(self.models.is_empty(), |panel| {
                                panel.child(
                                    div()
                                        .flex_grow()
                                        .px_5()
                                        .flex()
                                        .items_center()
                                        .justify_center()
                                        .text_size(px(TYPE_UI))
                                        .text_color(rgb(MUTED))
                                        .child("Codex app-server did not return any models."),
                                )
                            })
                            .when(!self.models.is_empty(), |panel| {
                                panel.child(
                                    div()
                                        .id("provider-model-list")
                                        .min_h(px(0.))
                                        .flex_grow()
                                        .overflow_y_scroll()
                                        .p_2()
                                        .children(self.models.iter().enumerate().map(
                                            |(index, model)| {
                                                let selected = selected_model_id.as_deref()
                                                    == Some(model.id.as_str());
                                                let id = model.id.clone();
                                                div()
                                                    .id(("provider-model-option", index))
                                                    .min_h(px(50.))
                                                    .px_3()
                                                    .py_2()
                                                    .flex()
                                                    .items_center()
                                                    .justify_between()
                                                    .rounded(px(RADIUS_MEDIUM))
                                                    .cursor_pointer()
                                                    .bg(rgb(if selected {
                                                        BLUE_TINT
                                                    } else {
                                                        SURFACE
                                                    }))
                                                    .hover(|style| style.bg(rgb(SURFACE_SUBTLE)))
                                                    .active(|style| style.bg(rgb(SURFACE_HOVER)))
                                                    .on_click(cx.listener(move |this, _, _, cx| {
                                                        this.select_model(id.clone());
                                                        cx.notify();
                                                    }))
                                                    .child(
                                                        div()
                                                            .min_w(px(0.))
                                                            .flex_grow()
                                                            .flex()
                                                            .flex_col()
                                                            .gap(px(2.))
                                                            .child(
                                                                div()
                                                                    .truncate()
                                                                    .text_size(px(TYPE_UI))
                                                                    .font_weight(FontWeight::MEDIUM)
                                                                    .child(
                                                                        model.display_name.clone(),
                                                                    ),
                                                            )
                                                            .child(
                                                                div()
                                                                    .truncate()
                                                                    .text_size(px(TYPE_CAPTION))
                                                                    .text_color(rgb(MUTED))
                                                                    .child(
                                                                        model.description.clone(),
                                                                    ),
                                                            ),
                                                    )
                                                    .child(
                                                        div()
                                                            .ml_3()
                                                            .w(px(18.))
                                                            .flex_shrink_0()
                                                            .text_size(px(TYPE_UI))
                                                            .text_color(rgb(BLUE))
                                                            .child(if selected {
                                                                "✓"
                                                            } else {
                                                                ""
                                                            }),
                                                    )
                                            },
                                        )),
                                )
                            })
                    })
                    .when(model_menu_provider == ProviderKind::KimiCode, |panel| {
                        panel.child(self.remote_model_picker_detail(ProviderKind::KimiCode, cx))
                    })
                    .when(model_menu_provider == ProviderKind::DeepSeek, |panel| {
                        panel.child(self.remote_model_picker_detail(ProviderKind::DeepSeek, cx))
                    }),
            )
    }

    fn provider_row(&self, provider: ProviderSummary, cx: &mut Context<Self>) -> impl IntoElement {
        let selected = self.selected_provider == Some(provider.kind);
        div()
            .id(("provider-row", provider.kind as usize))
            .h(px(60.))
            .px_4()
            .flex()
            .items_center()
            .gap_3()
            .cursor_pointer()
            .bg(rgb(if selected { 0xf7f7f8 } else { SURFACE }))
            .hover(|style| style.bg(rgb(0xf3f3f5)))
            .active(|style| style.bg(rgb(0xe3e3e6)))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.selected_provider = if this.selected_provider == Some(provider.kind) {
                    None
                } else {
                    Some(provider.kind)
                };
                this.settings_notice = None;
                cx.notify();
            }))
            .child(
                div()
                    .size(px(32.))
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(RADIUS_MEDIUM))
                    .overflow_hidden()
                    .bg(rgb(if provider.kind == ProviderKind::KimiCode {
                        0x101114
                    } else {
                        0xf8f8fa
                    }))
                    .child(
                        img(provider.icon)
                            .w(px(if provider.kind == ProviderKind::KimiCode {
                                27.
                            } else {
                                28.
                            }))
                            .h(px(if provider.kind == ProviderKind::KimiCode {
                                11.
                            } else {
                                28.
                            })),
                    ),
            )
            .child(
                div()
                    .min_w(px(0.))
                    .flex_grow()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(provider.name),
                    )
                    .child(
                        div()
                            .text_size(px(TYPE_CAPTION))
                            .text_color(rgb(MUTED))
                            .child(provider.description),
                    ),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .h(px(20.))
                            .px_2()
                            .flex()
                            .items_center()
                            .gap_2()
                            .rounded_full()
                            .bg(rgb(SURFACE_SUBTLE))
                            .text_size(px(TYPE_CAPTION))
                            .text_color(rgb(MUTED))
                            .child(div().size(px(7.)).rounded_full().bg(rgb(
                                if provider.configured {
                                    GREEN
                                } else {
                                    MUTED_LIGHT
                                },
                            )))
                            .child(provider.status),
                    )
                    .child(
                        div()
                            .size(px(24.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(
                                img(if selected {
                                    CHEVRON_UP_ASSET
                                } else {
                                    CHEVRON_DOWN_ASSET
                                })
                                .w(px(10.))
                                .h(px(6.)),
                            ),
                    ),
            )
    }

    fn provider_accordion_item(
        &self,
        provider: ProviderSummary,
        detail: impl IntoElement,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let expanded = self.selected_provider == Some(provider.kind);
        div()
            .overflow_hidden()
            .rounded(px(RADIUS_LARGE))
            .bg(rgb(SURFACE))
            .border_1()
            .border_color(rgb(SETTINGS_SEPARATOR))
            .child(self.provider_row(provider, cx))
            .when(expanded, |item| {
                item.child(div().border_t_1().border_color(rgb(0xe5e5e8)).child(detail))
            })
    }

    fn settings_input(label: &'static str, input: Entity<ComposerInput>) -> impl IntoElement {
        div()
            .h(px(44.))
            .px_3()
            .flex()
            .items_center()
            .justify_between()
            .child(
                div()
                    .w(px(116.))
                    .flex_shrink_0()
                    .text_size(px(TYPE_UI))
                    .child(label),
            )
            .child(
                div()
                    .h(px(30.))
                    .w(px(400.))
                    .px_2()
                    .flex()
                    .items_center()
                    .rounded(px(RADIUS_SMALL))
                    .bg(rgb(0xffffff))
                    .border_1()
                    .border_color(rgb(0xb8b8bd))
                    .child(input),
            )
    }

    fn remote_provider_detail(
        &self,
        provider: ProviderKind,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<J> {
        let (endpoint, model, api_key, configured) = match provider {
            ProviderKind::KimiCode => (
                self.kimi_endpoint_input.clone(),
                self.kimi_model_input.clone(),
                self.kimi_api_key_input.clone(),
                self.settings.kimi_code.credential_configured,
            ),
            ProviderKind::DeepSeek => (
                self.deepseek_endpoint_input.clone(),
                self.deepseek_model_input.clone(),
                self.deepseek_api_key_input.clone(),
                self.settings.deepseek.credential_configured,
            ),
            ProviderKind::Codex => unreachable!("Codex uses its local runtime settings"),
        };
        div()
            .px_4()
            .py_4()
            .flex()
            .flex_col()
            .gap_3()
            .bg(rgb(0xfafafa))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(Self::settings_input("API endpoint", endpoint))
                    .child(Self::settings_input("Model", model))
                    .child(Self::settings_input("API key", api_key)),
            )
            .child(
                div()
                    .px_3()
                    .text_size(px(TYPE_CAPTION))
                    .line_height(px(16.))
                    .text_color(rgb(MUTED))
                    .child(if configured {
                        "The API key is stored in macOS Keychain. Leave the field blank to keep it."
                    } else {
                        "Endpoint and model are required. The API key is stored only in macOS Keychain."
                    }),
            )
            .when_some(self.settings_notice.clone(), |content, (success, notice)| {
                content.child(
                    div()
                        .px_3()
                        .py_2()
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(rgb(if success { 0xeaf7ee } else { 0xffecee }))
                        .text_size(px(TYPE_UI))
                        .text_color(rgb(if success { 0x217a38 } else { RED }))
                        .child(notice),
                )
            })
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_end()
                    .pt_1()
                    .child(
                        div()
                            .id(("save-provider", provider as usize))
                            .h(px(28.))
                            .px_4()
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(RADIUS_SMALL))
                            .cursor_pointer()
                            .bg(rgb(BLUE))
                            .text_size(px(TYPE_CAPTION))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(rgb(SURFACE))
                            .hover(|style| style.bg(rgb(BLUE_HOVER)))
                            .active(|style| style.bg(rgb(BLUE_ACTIVE)))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.save_remote_provider(provider, cx);
                                cx.notify();
                            }))
                            .child("Save"),
                    ),
            )
    }

    fn codex_provider_detail(&self, cx: &mut Context<Self>) -> impl IntoElement + use<J> {
        let connected = self.runtime.is_some();
        let installation = self.runtime.as_ref().map(CodexRuntime::installation);
        let model_count = self.models.len();
        div()
            .px_4()
            .py_4()
            .flex()
            .flex_col()
            .gap_3()
            .bg(rgb(0xfafafa))
            .child(
                div()
                    .px_1()
                    .text_size(px(TYPE_UI))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Runtime"),
            )
            .child(
                div()
                    .overflow_hidden()
                    .rounded(px(RADIUS_LARGE))
                    .bg(rgb(SURFACE))
                    .border_1()
                    .border_color(rgb(SETTINGS_SEPARATOR))
                    .child(
                        div()
                            .h(px(42.))
                            .px_3()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(div().text_size(px(TYPE_UI)).child("Status"))
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .text_size(px(TYPE_UI))
                                    .text_color(rgb(MUTED))
                                    .child(
                                        div().size(px(8.)).rounded_full().bg(rgb(if connected {
                                            GREEN
                                        } else {
                                            RED
                                        })),
                                    )
                                    .child(if connected {
                                        "Connected"
                                    } else {
                                        "Unavailable"
                                    }),
                            ),
                    )
                    .child(div().h(px(1.)).ml(px(16.)).bg(rgb(0xe5e5e8)))
                    .when_some(installation, |group, installation| {
                        group.child(
                            div()
                                .min_h(px(42.))
                                .px_3()
                                .py_2()
                                .flex()
                                .items_center()
                                .justify_between()
                                .child(div().text_size(px(TYPE_UI)).child("Command line tool"))
                                .child(
                                    div()
                                        .max_w(px(440.))
                                        .flex()
                                        .flex_col()
                                        .items_end()
                                        .gap_1()
                                        .child(
                                            div()
                                                .text_size(px(TYPE_UI))
                                                .text_color(rgb(MUTED))
                                                .child(installation.version.clone()),
                                        )
                                        .child(
                                            div()
                                                .text_size(px(TYPE_CAPTION))
                                                .text_color(rgb(MUTED_LIGHT))
                                                .child(installation.path.display().to_string()),
                                        ),
                                ),
                        )
                    })
                    .when_some(self.runtime_error.clone(), |group, error| {
                        group.child(
                            div()
                                .px_4()
                                .py_3()
                                .border_t_1()
                                .border_color(rgb(0xe5e5e8))
                                .text_size(px(TYPE_CAPTION))
                                .line_height(px(16.))
                                .text_color(rgb(RED))
                                .child(error),
                        )
                    }),
            )
            .child(
                div()
                    .mt_2()
                    .px_1()
                    .flex()
                    .items_center()
                    .justify_between()
                    .text_size(px(TYPE_UI))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Default model")
                    .child(
                        div()
                            .text_size(px(TYPE_CAPTION))
                            .font_weight(FontWeight::NORMAL)
                            .text_color(rgb(MUTED_LIGHT))
                            .child(Self::model_count_label(model_count)),
                    ),
            )
            .child(
                div()
                    .id("settings-codex-model-list")
                    .max_h(px(228.))
                    .overflow_y_scroll()
                    .overflow_x_hidden()
                    .rounded(px(RADIUS_LARGE))
                    .bg(rgb(SURFACE))
                    .border_1()
                    .border_color(rgb(SETTINGS_SEPARATOR))
                    .when(model_count == 0, |list| {
                        list.child(
                            div()
                                .h(px(44.))
                                .px_3()
                                .flex()
                                .items_center()
                                .text_size(px(TYPE_UI))
                                .text_color(rgb(MUTED))
                                .child("No models available"),
                        )
                    })
                    .when(model_count > 0, |list| {
                        list.children(self.models.iter().enumerate().map(|(index, model)| {
                            let selected =
                                self.selected_model_id.as_deref() == Some(model.id.as_str());
                            let id = model.id.clone();
                            div()
                                .id(("settings-model", index))
                                .h(px(38.))
                                .px_3()
                                .flex()
                                .items_center()
                                .justify_between()
                                .cursor_pointer()
                                .bg(rgb(SURFACE))
                                .hover(|style| style.bg(rgb(0xf3f3f5)))
                                .active(|style| style.bg(rgb(0xe3e3e6)))
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.select_model(id.clone());
                                    cx.notify();
                                }))
                                .child(
                                    div()
                                        .text_size(px(TYPE_UI))
                                        .font_weight(if selected {
                                            FontWeight::MEDIUM
                                        } else {
                                            FontWeight::NORMAL
                                        })
                                        .child(model.display_name.clone()),
                                )
                                .child(
                                    div()
                                        .w(px(22.))
                                        .text_size(px(TYPE_UI))
                                        .text_color(rgb(SETTINGS_SELECTION))
                                        .child(if selected { "✓" } else { "" }),
                                )
                                .when(index + 1 < model_count, |row| {
                                    row.border_b_1().border_color(rgb(0xe5e5e8))
                                })
                        }))
                    }),
            )
    }

    fn settings_page(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let connected = self.runtime.is_some();
        div()
            .absolute()
            .top(px(0.))
            .right(px(0.))
            .bottom(px(0.))
            .left(px(0.))
            .flex()
            .bg(rgb(SETTINGS_CANVAS))
            .child(
                div()
                    .w(px(APP_SIDEBAR_WIDTH))
                    .h_full()
                    .px_3()
                    .pt(px(APP_SIDEBAR_TOP_INSET))
                    .pb_3()
                    .flex()
                    .flex_col()
                    .border_r_1()
                    .border_color(rgb(0xd7d9dc))
                    .bg(rgb(SETTINGS_SIDEBAR))
                    .child(
                        div()
                            .id("close-settings")
                            .w_full()
                            .h(px(36.))
                            .px_2()
                            .flex()
                            .items_center()
                            .gap_2()
                            .rounded(px(RADIUS_MEDIUM))
                            .cursor_pointer()
                            .bg(rgb(0xf7f7f8))
                            .border_1()
                            .border_color(rgb(0xd5d7db))
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(TEXT))
                            .hover(|style| style.bg(rgb(0xffffff)))
                            .active(|style| style.bg(rgb(0xdfe1e5)))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.page = WorkspacePage::Chat;
                                cx.notify();
                            }))
                            .child(img(BACK_ICON_ASSET).size(px(16.)))
                            .child("Back to Chat"),
                    )
                    .child(
                        div()
                            .mt_5()
                            .px_2()
                            .pb_2()
                            .text_size(px(TYPE_CAPTION))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(MUTED))
                            .child("SETTINGS"),
                    )
                    .child(
                        div()
                            .id("settings-providers")
                            .w_full()
                            .h(px(36.))
                            .px_2()
                            .flex()
                            .items_center()
                            .gap_2()
                            .rounded(px(RADIUS_MEDIUM))
                            .cursor_pointer()
                            .bg(rgb(SETTINGS_SELECTION))
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(SURFACE))
                            .hover(|style| style.bg(rgb(0x168bf9)))
                            .active(|style| style.bg(rgb(0x006edc)))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.settings_notice = None;
                                cx.notify();
                            }))
                            .child(img(PROVIDERS_ICON_ASSET).size(px(16.)))
                            .child("Providers"),
                    ),
            )
            .child(
                div()
                    .min_w(px(0.))
                    .h_full()
                    .flex_grow()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .h(px(APP_TOP_BAR_HEIGHT))
                            .flex_shrink_0()
                            .flex()
                            .items_center()
                            .justify_center()
                            .border_b_1()
                            .border_color(rgb(0xdedee1))
                            .bg(rgb(0xf8f8f9))
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("Providers"),
                    )
                    .child(
                        div()
                            .id("settings-scroll")
                            .min_h(px(0.))
                            .flex_grow()
                            .overflow_y_scroll()
                            .px_6()
                            .py_5()
                            .child(
                        div()
                            .w_full()
                            .max_w(px(680.))
                            .mx_auto()
                            .flex()
                            .flex_col()
                            .gap_4()
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap_1()
                                    .child(
                                        div()
                                            .text_size(px(TYPE_TITLE))
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .child("Model providers"),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(TYPE_UI))
                                            .text_color(rgb(MUTED))
                                            .child("Choose where Disco gets its models and credentials."),
                                    ),
                            )
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap_3()
                                    .child(self.provider_accordion_item(
                                        ProviderSummary {
                                            kind: ProviderKind::Codex,
                                            name: "Codex",
                                            description: "Local CLI and app-server",
                                            icon: CODEX_ICON_ASSET,
                                            configured: connected,
                                            status: if connected { "Connected" } else { "Unavailable" },
                                        },
                                        self.codex_provider_detail(cx),
                                        cx,
                                    ))
                                    .child(self.provider_accordion_item(
                                        ProviderSummary {
                                            kind: ProviderKind::KimiCode,
                                            name: "Kimi Code",
                                            description: "OpenAI-compatible API",
                                            icon: KIMI_ICON_ASSET,
                                            configured: self.settings.kimi_code.credential_configured,
                                            status: if self.settings.kimi_code.credential_configured {
                                                "Configured"
                                            } else {
                                                "Not configured"
                                            },
                                        },
                                        self.remote_provider_detail(ProviderKind::KimiCode, cx),
                                        cx,
                                    ))
                                    .child(self.provider_accordion_item(
                                        ProviderSummary {
                                            kind: ProviderKind::DeepSeek,
                                            name: "DeepSeek",
                                            description: "OpenAI-compatible API",
                                            icon: DEEPSEEK_ICON_ASSET,
                                            configured: self.settings.deepseek.credential_configured,
                                            status: if self.settings.deepseek.credential_configured {
                                                "Configured"
                                            } else {
                                                "Not configured"
                                            },
                                        },
                                        self.remote_provider_detail(ProviderKind::DeepSeek, cx),
                                        cx,
                                    )),
                            ),
                    ),
            )
            )
    }
}

impl<J: EventJournal> Render for DiscoWorkspace<J> {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let turns = self.conversation.turns().to_vec();
        let has_run = !turns.is_empty();
        let title = if has_run {
            Self::compact_title(self.conversation.title_prompt().unwrap_or_default())
        } else {
            "New conversation".into()
        };
        let can_submit = !self.composer.read(cx).is_empty() && self.conversation.can_begin_turn();
        let is_working = !self.conversation.can_begin_turn();
        let action_enabled = if is_working {
            !self.stop_requested
        } else {
            can_submit
        };
        let selected_model_name = self
            .selected_model()
            .map(|model| model.display_name.clone())
            .unwrap_or_else(|| "Codex unavailable".into());
        let selected_chat_provider = self.selected_chat_provider;
        let effort_options = self
            .selected_model()
            .map(|model| model.reasoning_efforts.clone())
            .unwrap_or_default();
        let selected_effort = self.selected_effort.clone();

        div()
            .size_full()
            .relative()
            .flex()
            .bg(rgb(CANVAS))
            .font_family("-apple-system")
            .text_size(px(TYPE_UI))
            .text_color(rgb(TEXT))
            .child(self.sidebar(cx))
            .child(
                div()
                    .relative()
                    .h_full()
                    .min_w(px(0.))
                    .flex_grow()
                    .flex()
                    .flex_col()
                    .overflow_hidden()
                    .child(
                        div()
                            .h(px(APP_TOP_BAR_HEIGHT))
                            .px_5()
                            .flex()
                            .items_center()
                            .justify_center()
                            .gap_2()
                            .border_b_1()
                            .border_color(rgb(BORDER))
                            .bg(rgb(SURFACE))
                            .child(
                                div()
                                    .max_w(px(520.))
                                    .truncate()
                                    .text_size(px(TYPE_BODY))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(title),
                            )
                            .child(
                                div()
                                    .h(px(24.))
                                    .px_2()
                                    .flex()
                                    .items_center()
                                    .gap(px(6.))
                                    .rounded_full()
                                    .bg(rgb(SURFACE_SUBTLE))
                                    .border_1()
                                    .border_color(rgb(BORDER))
                                    .text_size(px(TYPE_CAPTION))
                                    .text_color(rgb(MUTED))
                                    .child(
                                        div()
                                            .size(px(6.))
                                            .rounded_full()
                                            .bg(rgb(self.status_color())),
                                    )
                                    .child(self.status_label()),
                            ),
                    )
                    .child(
                        div()
                            .id("chat-scroll")
                            .min_h(px(0.))
                            .flex_grow()
                            .overflow_y_scroll()
                            .px_7()
                            .py_5()
                            .when(!has_run, |scroll| {
                                scroll.child(
                                    div()
                                        .size_full()
                                        .flex()
                                        .items_center()
                                        .justify_center()
                                        .child(
                                            div()
                                                .flex()
                                                .flex_col()
                                                .items_center()
                                                .gap_1()
                                                .child(
                                                    div()
                                                        .text_size(px(TYPE_TITLE))
                                                        .font_weight(FontWeight::SEMIBOLD)
                                                        .child(if self.runtime.is_some() {
                                                            "Ask Codex to work in this repository"
                                                        } else {
                                                            "Codex CLI is not available"
                                                        }),
                                                )
                                                .child(
                                                    div()
                                                        .text_size(px(TYPE_UI))
                                                        .text_color(rgb(MUTED))
                                                        .child(if self.runtime.is_some() {
                                                            "Messages, commands, and file changes come from codex app-server."
                                                        } else {
                                                            "Open Settings to see the detected runtime status."
                                                        }),
                                                ),
                                        ),
                                )
                            })
                            .when(has_run, |scroll| {
                                scroll.child(
                                    div()
                                        .w_full()
                                        .max_w(px(CHAT_COLUMN_WIDTH))
                                        .mx_auto()
                                        .flex()
                                        .flex_col()
                                        .gap_6()
                                        .children(turns.into_iter().map(Self::conversation_turn)),
                                )
                            }),
                    )
                    .child(
                        div()
                            .px_6()
                            .pb_5()
                            .pt_1()
                            .child(
                                div()
                                    .relative()
                                    .w_full()
                                    .max_w(px(CHAT_COLUMN_WIDTH))
                                    .h(px(104.))
                                    .mx_auto()
                                    .child(
                                        div()
                                            .size_full()
                                            .p_3()
                                            .flex()
                                            .flex_col()
                                            .justify_between()
                                            .rounded(px(RADIUS_LARGE))
                                            .bg(rgb(0xf9fafb))
                                            .border_1()
                                            .border_color(rgb(BORDER_STRONG))
                                            .shadow_md()
                                            .child(
                                                div()
                                                    .min_w(px(0.))
                                                    .child(self.composer.clone()),
                                            )
                                            .child(
                                                div()
                                                    .flex()
                                                    .items_center()
                                                    .justify_between()
                                                    .child(
                                                        div()
                                                            .flex()
                                                            .items_center()
                                                            .gap_2()
                                                            .child(
                                                                div()
                                                                    .id("model-menu-trigger")
                                                                    .h(px(32.))
                                                                    .px_2()
                                                                    .flex()
                                                                    .items_center()
                                                                    .gap(px(6.))
                                                                    .rounded(px(RADIUS_SMALL))
                                                                    .bg(rgb(0xeff1f4))
                                                                    .cursor_pointer()
                                                                    .hover(|style| style.bg(rgb(SURFACE_HOVER)))
                                                                    .active(|style| style.bg(rgb(0xdde3eb)))
                                                                    .on_click(cx.listener(|this, _, _, cx| {
                                                                        this.model_menu_open = !this.model_menu_open;
                                                                        this.model_menu_provider = this.selected_chat_provider;
                                                                        this.thinking_menu_open = false;
                                                                        cx.notify();
                                                                    }))
                                                                    .child(
                                                                        div()
                                                                            .size(px(18.))
                                                                            .rounded(px(5.))
                                                                            .overflow_hidden()
                                                                            .child(img(selected_chat_provider.icon()).size_full()),
                                                                    )
                                                                    .child(
                                                                        div()
                                                                            .text_size(px(TYPE_UI))
                                                                            .font_weight(FontWeight::MEDIUM)
                                                                            .child(selected_model_name),
                                                                    )
                                                                    .child(
                                                                        div()
                                                                            .w(px(12.))
                                                                            .h(px(12.))
                                                                            .flex()
                                                                            .items_center()
                                                                            .justify_center()
                                                                            .child(
                                                                                img(CHEVRON_DOWN_ASSET)
                                                                                    .w(px(10.))
                                                                                    .h(px(6.)),
                                                                            ),
                                                                    ),
                                                            )
                                                            .child(
                                                                div()
                                                                    .id("thinking-menu-trigger")
                                                                    .h(px(32.))
                                                                    .px_2()
                                                                    .flex()
                                                                    .items_center()
                                                                    .gap(px(6.))
                                                                    .rounded(px(RADIUS_SMALL))
                                                                    .bg(rgb(0xeff1f4))
                                                                    .cursor_pointer()
                                                                    .hover(|style| style.bg(rgb(SURFACE_HOVER)))
                                                                    .active(|style| style.bg(rgb(0xdde3eb)))
                                                                    .on_click(cx.listener(|this, _, _, cx| {
                                                                        this.thinking_menu_open = !this.thinking_menu_open;
                                                                        this.model_menu_open = false;
                                                                        cx.notify();
                                                                    }))
                                                                    .child(
                                                                        div()
                                                                            .text_size(px(TYPE_UI))
                                                                            .font_weight(FontWeight::MEDIUM)
                                                                            .child(Self::reasoning_effort_label(&selected_effort)),
                                                                    )
                                                                    .child(
                                                                        div()
                                                                            .w(px(12.))
                                                                            .h(px(12.))
                                                                            .flex()
                                                                            .items_center()
                                                                            .justify_center()
                                                                            .child(
                                                                                img(CHEVRON_DOWN_ASSET)
                                                                                    .w(px(10.))
                                                                                    .h(px(6.)),
                                                                            ),
                                                                    ),
                                                            ),
                                                    )
                                                    .child(
                                                        div()
                                                            .id("composer-action")
                                                            .size(px(32.))
                                                            .flex()
                                                            .items_center()
                                                            .justify_center()
                                                            .rounded_full()
                                                            .bg(rgb(if is_working {
                                                                0x2c2c2e
                                                            } else if can_submit {
                                                                BLUE
                                                            } else {
                                                                0xe5e5ea
                                                            }))
                                                            .cursor_pointer()
                                                            .hover(move |style| {
                                                                style.bg(rgb(if is_working {
                                                                    if action_enabled {
                                                                        0x3a3a3c
                                                                    } else {
                                                                        0x2c2c2e
                                                                    }
                                                                } else if can_submit {
                                                                    BLUE_HOVER
                                                                } else {
                                                                    0xe5e5ea
                                                                }))
                                                            })
                                                            .active(move |style| {
                                                                style
                                                                    .bg(rgb(if is_working {
                                                                        if action_enabled {
                                                                            0x48484a
                                                                        } else {
                                                                            0x2c2c2e
                                                                        }
                                                                    } else if can_submit {
                                                                        BLUE_ACTIVE
                                                                    } else {
                                                                        0xe5e5ea
                                                                    }))
                                                                    .opacity(0.82)
                                                            })
                                                            .on_click(cx.listener(|this, _, _, cx| {
                                                                if this.conversation.can_begin_turn() {
                                                                    this.submit_composer(cx);
                                                                } else {
                                                                    this.stop_run();
                                                                }
                                                                cx.notify();
                                                            }))
                                                            .when(is_working, |button| {
                                                                button.child(
                                                                    img(STOP_ICON_ASSET)
                                                                        .size(px(12.))
                                                                        .opacity(if action_enabled { 1. } else { 0.55 }),
                                                                )
                                                            })
                                                            .when(!is_working, |button| {
                                                                button.child(
                                                                    img(SEND_ICON_ASSET)
                                                                        .size(px(14.))
                                                                        .opacity(if can_submit { 1. } else { 0.42 }),
                                                                )
                                                            }),
                                                    ),
                                            ),
                                    )
                                    .when(self.model_menu_open, |composer| {
                                        composer.child(self.model_picker(cx))
                                    })
                                    .when(self.thinking_menu_open, |composer| {
                                        composer.child(
                                            div()
                                                .absolute()
                                                .bottom(px(46.))
                                                .left(px(164.))
                                                .w(px(220.))
                                                .p_2()
                                                .rounded(px(RADIUS_LARGE))
                                                .bg(rgb(SURFACE))
                                                .border_1()
                                                .border_color(rgb(BORDER_STRONG))
                                                .shadow_lg()
                                                .on_mouse_down_out(cx.listener(
                                                    |this, _, _, cx| {
                                                        this.thinking_menu_open = false;
                                                        cx.notify();
                                                    },
                                                ))
                                                .children(effort_options.into_iter().enumerate().map(|(index, effort)| {
                                                    let selected = effort == selected_effort;
                                                    let value = effort.clone();
                                                    div()
                                                        .id(("effort-option", index))
                                                        .h(px(36.))
                                                        .px_3()
                                                        .flex()
                                                        .items_center()
                                                        .justify_between()
                                                        .rounded(px(RADIUS_MEDIUM))
                                                        .cursor_pointer()
                                                        .bg(rgb(if selected { BLUE_TINT } else { SURFACE }))
                                                        .hover(|style| style.bg(rgb(SURFACE_HOVER)))
                                                        .active(|style| style.bg(rgb(0xdde3eb)))
                                                        .on_click(cx.listener(move |this, _, _, cx| {
                                                            this.select_effort(value.clone());
                                                            cx.notify();
                                                        }))
                                                        .child(Self::reasoning_effort_label(&effort))
                                                        .child(if selected { "✓" } else { "" })
                                                })),
                                        )
                                    }),
                            ),
                    ),
            )
            .when(self.page == WorkspacePage::Settings, |root| {
                root.child(self.settings_page(cx))
            })
    }
}

#[cfg(test)]
mod tests {
    use super::{ChatConversation, DiscoWorkspace};
    use disco_domain::{RunEventPayload, RunId, RunStatus};
    use disco_kernel::RunProjection;

    #[test]
    fn conversation_title_is_derived_from_the_real_prompt() {
        assert_eq!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::compact_title("Fix the failing test"),
            "Fix the failing test"
        );
        assert_eq!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::compact_title(
                "Investigate why the authentication token refresh fails after waking the Mac"
            ),
            "Investigate why the authentication…"
        );
    }

    #[test]
    fn model_count_labels_are_grammatical() {
        assert_eq!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::model_count_label(0),
            "0 models"
        );
        assert_eq!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::model_count_label(1),
            "1 model"
        );
        assert_eq!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::model_count_label(6),
            "6 models"
        );
    }

    #[test]
    fn reasoning_effort_labels_are_user_facing() {
        assert_eq!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::reasoning_effort_label("medium"),
            "Medium"
        );
        assert_eq!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::reasoning_effort_label("custom"),
            "custom"
        );
    }

    #[test]
    fn a_conversation_keeps_completed_turns_and_rejects_overlapping_turns() {
        let mut conversation = ChatConversation::new();
        let mut first = RunProjection::empty(RunId::new());
        first.prompt = Some("Remember tulip".into());
        first.status = RunStatus::Completed;
        assert!(conversation.begin(first));

        let mut second = RunProjection::empty(RunId::new());
        second.prompt = Some("What word?".into());
        second.status = RunStatus::Running;
        assert!(conversation.begin(second));
        assert_eq!(conversation.turns().len(), 2);
        assert_eq!(conversation.title_prompt(), Some("Remember tulip"));

        let third = RunProjection::empty(RunId::new());
        assert!(!conversation.begin(third));
        assert_eq!(conversation.turns().len(), 2);
    }

    #[test]
    fn interrupted_runs_end_cancelled_not_completed() {
        assert!(matches!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::terminal_event(true),
            RunEventPayload::RunCancelled
        ));
        assert!(matches!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::terminal_event(false),
            RunEventPayload::RunCompleted
        ));
    }
}
