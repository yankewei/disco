//! Native GPUI client for a locally installed Codex app-server.

mod composer_input;
mod markdown;
mod settings;

pub use composer_input::{ComposerInput, init as init_composer_input};

use std::{
    path::{Path, PathBuf},
    process::Command,
};

use composer_input::ComposerSubmitted;
use disco_codex_engine::{CodexModel, CodexRuntime};
use disco_domain::{
    EngineKind, Project, ProjectId, RunEventPayload, RunId, RunStatus, SessionId, ToolCall,
    TurnEvent,
};
use disco_kernel::{ActivityItem, ActivityKind, EventJournal, Kernel, ProjectStore, RunProjection};
use disco_opencode_engine::{OpenCodeModel, OpenCodeRuntime, connect as connect_opencode};
use gpui::prelude::FluentBuilder;
use gpui::{
    AppContext, AsyncApp, ClipboardItem, Context, CursorStyle, ElementId, Entity, FocusHandle,
    Focusable, FontWeight, InteractiveElement, IntoElement, KeyDownEvent, MouseButton,
    ParentElement, PathPromptOptions, Pixels, Point, Render, ScrollHandle, ScrollWheelEvent,
    StatefulInteractiveElement, Styled, WeakEntity, Window, WindowAppearance, anchored, deferred,
    div, img, px, rgb, svg,
};
use serde_json::json;
use settings::{AppConfig, RemoteProviderSettings};

const CODEX_ICON_ASSET: &str = "icons/providers/codex.png";
const DEEPSEEK_ICON_ASSET: &str = "icons/providers/deepseek.svg";
const KIMI_ICON_ASSET: &str = "icons/providers/kimi-code.png";
const OPENCODE_ICON_ASSET: &str = "icons/providers/opencode.svg";
const CHEVRON_DOWN_ASSET: &str = "icons/ui/chevron-down.svg";
const CHEVRON_RIGHT_ASSET: &str = "icons/ui/chevron-right.svg";
const CHEVRON_UP_ASSET: &str = "icons/ui/chevron-up.svg";
const SETTINGS_ICON_ASSET: &str = "icons/ui/settings.svg";
const BACK_ICON_ASSET: &str = "icons/ui/back.svg";
const PROVIDERS_ICON_ASSET: &str = "icons/ui/providers.svg";
const SEND_ICON_ASSET: &str = "icons/ui/send.svg";
const STOP_ICON_ASSET: &str = "icons/ui/stop.svg";
const FOLDER_ICON_ASSET: &str = "icons/ui/folder.svg";
const EYE_ICON_ASSET: &str = "icons/ui/eye.svg";
const EYE_OFF_ICON_ASSET: &str = "icons/ui/eye-off.svg";
const TYPE_CAPTION: f32 = 11.;
const TYPE_UI: f32 = 12.5;
const TYPE_BODY: f32 = 13.5;
const TYPE_TITLE: f32 = 15.;
const APP_SIDEBAR_WIDTH: f32 = 252.;
const APP_TOP_BAR_HEIGHT: f32 = 52.;
const APP_SIDEBAR_TOP_INSET: f32 = 50.;
const CHAT_COLUMN_WIDTH: f32 = 760.;
const CHAT_BUBBLE_MAX_WIDTH: f32 = 600.;
const CHAT_BUBBLE_RADIUS: f32 = 20.;
const RADIUS_SMALL: f32 = 6.;
const RADIUS_MEDIUM: f32 = 9.;
const RADIUS_LARGE: f32 = 12.;

#[derive(Clone, Copy)]
struct AppAppearance {
    canvas: u32,
    surface: u32,
    surface_subtle: u32,
    surface_hover: u32,
    surface_pressed: u32,
    border: u32,
    border_strong: u32,
    text: u32,
    muted: u32,
    muted_light: u32,
    blue: u32,
    blue_hover: u32,
    blue_active: u32,
    blue_tint: u32,
    green: u32,
    red: u32,
    settings_canvas: u32,
    settings_sidebar: u32,
    settings_selection: u32,
    settings_control: u32,
    settings_separator: u32,
    sidebar: SidebarAppearance,
    composer: ComposerAppearance,
    conversation: ConversationAppearance,
}

impl AppAppearance {
    const MACOS_LIGHT: Self = Self {
        canvas: 0xffffff,
        surface: 0xffffff,
        surface_subtle: 0xf5f6f8,
        surface_hover: 0xe7e8eb,
        surface_pressed: 0xd9dbe0,
        border: 0xe1e3e7,
        border_strong: 0xd3d6dc,
        text: 0x222327,
        muted: 0x6e727a,
        muted_light: 0x9a9ea6,
        blue: 0x007aff,
        blue_hover: 0x006ee6,
        blue_active: 0x0062cc,
        blue_tint: 0xeaf3ff,
        green: 0x28a745,
        red: 0xd7373f,
        settings_canvas: 0xf7f7f8,
        settings_sidebar: 0xededef,
        settings_selection: 0x0a84ff,
        settings_control: 0xe8e8ed,
        settings_separator: 0xd1d1d6,
        sidebar: SidebarAppearance::MACOS_LIGHT,
        composer: ComposerAppearance::MACOS_LIGHT,
        conversation: ConversationAppearance::MACOS_LIGHT,
    };

    const MACOS_DARK: Self = Self {
        canvas: 0x1c1c1e,
        surface: 0x242426,
        surface_subtle: 0x2b2b2e,
        surface_hover: 0x37373b,
        surface_pressed: 0x444449,
        border: 0x38383c,
        border_strong: 0x48484d,
        text: 0xf0f0f2,
        muted: 0xa4a4aa,
        muted_light: 0x77777f,
        blue: 0x0a84ff,
        blue_hover: 0x2390ff,
        blue_active: 0x0070df,
        blue_tint: 0x183a5a,
        green: 0x32d74b,
        red: 0xff453a,
        settings_canvas: 0x1c1c1e,
        settings_sidebar: 0x252527,
        settings_selection: 0x0a84ff,
        settings_control: 0x333336,
        settings_separator: 0x3a3a3c,
        sidebar: SidebarAppearance::MACOS_DARK,
        composer: ComposerAppearance::MACOS_DARK,
        conversation: ConversationAppearance::MACOS_DARK,
    };

    const fn for_window(appearance: WindowAppearance) -> Self {
        match appearance {
            WindowAppearance::Dark | WindowAppearance::VibrantDark => Self::MACOS_DARK,
            WindowAppearance::Light | WindowAppearance::VibrantLight => Self::MACOS_LIGHT,
        }
    }
}

#[derive(Clone, Copy)]
struct SidebarAppearance {
    background: u32,
    separator: u32,
    hover: u32,
    pressed: u32,
    selection: u32,
    selection_focused: u32,
    focus: u32,
    text: u32,
    secondary_text: u32,
}

impl SidebarAppearance {
    const MACOS_LIGHT: Self = Self {
        background: 0xf1f1f3,
        separator: 0xd9dade,
        hover: 0xe7e7e9,
        pressed: 0xd9dade,
        selection: 0xdfe0e3,
        selection_focused: 0xd8d9dd,
        focus: 0xe5e5e8,
        text: 0x27282b,
        secondary_text: 0x73767d,
    };

    const MACOS_DARK: Self = Self {
        background: 0x242426,
        separator: 0x3a3a3c,
        hover: 0x303033,
        pressed: 0x3a3a3e,
        selection: 0x3a3a3d,
        selection_focused: 0x444449,
        focus: 0x303034,
        text: 0xe8e8eb,
        secondary_text: 0x98989f,
    };
}

#[derive(Clone, Copy)]
struct ComposerAppearance {
    surface: u32,
    border: u32,
    focus_border: u32,
    control: u32,
    control_border: u32,
    control_hover: u32,
    control_pressed: u32,
    action_disabled: u32,
}

impl ComposerAppearance {
    const MACOS_LIGHT: Self = Self {
        surface: 0xffffff,
        border: 0xd4d5d9,
        focus_border: 0x84aee8,
        control: 0xffffff,
        control_border: 0xd9dade,
        control_hover: 0xf1f1f3,
        control_pressed: 0xe5e5e8,
        action_disabled: 0xe5e5ea,
    };

    const MACOS_DARK: Self = Self {
        surface: 0x242426,
        border: 0x45454a,
        focus_border: 0x3f84d4,
        control: 0x303033,
        control_border: 0x4a4a4f,
        control_hover: 0x3a3a3e,
        control_pressed: 0x444449,
        action_disabled: 0x3a3a3c,
    };
}

#[derive(Clone, Copy)]
struct ConversationAppearance {
    secondary_surface: u32,
    secondary_separator: u32,
    secondary_text: u32,
    warning: u32,
    failure_surface: u32,
}

impl ConversationAppearance {
    const MACOS_LIGHT: Self = Self {
        secondary_surface: 0xf5f5f6,
        secondary_separator: 0xe3e3e6,
        secondary_text: 0x6f7278,
        warning: 0xe49322,
        failure_surface: 0xfff2f2,
    };

    const MACOS_DARK: Self = Self {
        secondary_surface: 0x28282b,
        secondary_separator: 0x3a3a3f,
        secondary_text: 0x9a9aa2,
        warning: 0xff9f0a,
        failure_surface: 0x462427,
    };
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SidebarItem {
    Project(ProjectId),
    Task(ProjectId, SessionId),
}

#[derive(Clone, Copy, Debug)]
struct ProjectContextMenu {
    project_id: ProjectId,
    position: Point<Pixels>,
}

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
    OpenCode,
}

impl ProviderKind {
    const fn name(self) -> &'static str {
        match self {
            Self::Codex => "Codex",
            Self::KimiCode => "Kimi Code",
            Self::DeepSeek => "DeepSeek",
            Self::OpenCode => "OpenCode",
        }
    }

    const fn icon(self) -> &'static str {
        match self {
            Self::Codex => CODEX_ICON_ASSET,
            Self::KimiCode => KIMI_ICON_ASSET,
            Self::DeepSeek => DEEPSEEK_ICON_ASSET,
            Self::OpenCode => OPENCODE_ICON_ASSET,
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

#[derive(Clone, Debug)]
struct ChatConversation {
    session_id: SessionId,
    codex_thread_id: Option<String>,
    opencode_session_id: Option<String>,
    draft: String,
    turns: Vec<RunProjection>,
}

impl ChatConversation {
    fn new() -> Self {
        Self {
            session_id: SessionId::new(),
            codex_thread_id: None,
            opencode_session_id: None,
            draft: String::new(),
            turns: Vec::new(),
        }
    }

    fn restored(session_id: SessionId) -> Self {
        Self {
            session_id,
            codex_thread_id: None,
            opencode_session_id: None,
            draft: String::new(),
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
        if let Some(thread_id) = &projection.codex_thread_id {
            self.codex_thread_id = Some(thread_id.clone());
        }
        self.turns.push(projection);
        true
    }

    fn update(&mut self, projection: RunProjection) {
        if let Some(thread_id) = &projection.codex_thread_id {
            self.codex_thread_id = Some(thread_id.clone());
        }
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

#[derive(Clone, Debug)]
struct ProjectState {
    project: Project,
    expanded: bool,
    selected_session_id: Option<SessionId>,
    tasks: Vec<ChatConversation>,
}

pub type CodexConnection = Result<(CodexRuntime, Vec<CodexModel>), String>;

pub struct DiscoWorkspace<J: EventJournal> {
    kernel: Kernel<J>,
    projects: Vec<ProjectState>,
    active_project_id: ProjectId,
    active_session_id: SessionId,
    chat_scroll: ScrollHandle,
    chat_scroll_pending: bool,
    sidebar_focus_handle: FocusHandle,
    sidebar_focused_item: SidebarItem,
    project_context_menu: Option<ProjectContextMenu>,
    composer: Entity<ComposerInput>,
    page: WorkspacePage,
    config_path: PathBuf,
    config: AppConfig,
    runtime: Option<CodexRuntime>,
    runtime_error: Option<String>,
    opencode_runtime: Option<OpenCodeRuntime>,
    opencode_version: Option<String>,
    opencode_models: Vec<OpenCodeModel>,
    opencode_models_error: Option<String>,
    selected_opencode_model_id: Option<String>,
    models: Vec<CodexModel>,
    selected_model_id: Option<String>,
    selected_effort: String,
    model_menu_open: bool,
    model_menu_provider: ProviderKind,
    selected_chat_provider: ProviderKind,
    thinking_menu_open: bool,
    selected_provider: Option<ProviderKind>,
    kimi_endpoint_input: Entity<ComposerInput>,
    kimi_api_key_input: Entity<ComposerInput>,
    deepseek_endpoint_input: Entity<ComposerInput>,
    deepseek_api_key_input: Entity<ComposerInput>,
    remote_models: Vec<String>,
    remote_models_loading: bool,
    remote_models_error: Option<String>,
    settings_notice: Option<(bool, String)>,
    project_notice: Option<String>,
    stop_requested: bool,
    /// Runs whose thinking-section expansion was toggled away from its
    /// default (working runs default expanded, terminal runs collapsed).
    /// Membership means "inverted", not "expanded".
    thinking_toggle_overrides: std::collections::HashSet<RunId>,
    /// Runs whose activity-section expansion was toggled away from its
    /// default; same "inverted, not expanded" semantics as
    /// [`thinking_toggle_overrides`].
    activity_toggle_overrides: std::collections::HashSet<RunId>,
    /// Parsed markdown blocks per run, keyed by a hash of the assistant text,
    /// so unchanged text is not re-parsed on every frame.
    markdown_blocks_cache:
        std::collections::HashMap<RunId, (u64, std::sync::Arc<Vec<markdown::Block>>)>,
}

impl<J: EventJournal + ProjectStore> DiscoWorkspace<J> {
    pub fn new(
        journal: J,
        composer: Entity<ComposerInput>,
        config_path: PathBuf,
        workspace_path: PathBuf,
        connection: CodexConnection,
        opencode_version: Option<String>,
        opencode_models: Result<Vec<OpenCodeModel>, String>,
        cx: &mut Context<Self>,
    ) -> Self {
        cx.subscribe(&composer, |workspace, _, event: &ComposerSubmitted, cx| {
            workspace.start_run(event.text.clone(), cx);
            cx.notify();
        })
        .detach();
        cx.observe(&composer, |_, _, cx| cx.notify()).detach();

        let kernel = Kernel::new(journal);
        // The ACP runtime is only connected when OpenCode is installed; tests pass
        // `opencode_version: None` and stay free of subprocess side effects.
        let opencode_runtime = if opencode_version.is_some() {
            connect_opencode(&workspace_path).ok()
        } else {
            None
        };
        let initial_project = Project::new(Self::project_name(&workspace_path), workspace_path);
        let (current_project, mut project_notice) =
            match kernel.register_project(initial_project.clone()) {
                Ok(project) => (project, None),
                Err(error) => (initial_project, Some(error.to_string())),
            };
        let mut stored_projects = kernel
            .list_projects()
            .unwrap_or_else(|_| vec![current_project.clone()]);
        if !stored_projects
            .iter()
            .any(|project| project.id == current_project.id)
        {
            stored_projects.insert(0, current_project.clone());
        }
        let active_project_id = current_project.id;
        let mut projects = stored_projects
            .into_iter()
            .map(|project| {
                let is_current = project.id == active_project_id;
                ProjectState {
                    project,
                    expanded: is_current,
                    selected_session_id: None,
                    tasks: Vec::new(),
                }
            })
            .collect::<Vec<_>>();

        let mut restored_runs = match kernel.restore_all() {
            Ok(runs) => runs,
            Err(error) => {
                project_notice.get_or_insert_with(|| error.to_string());
                Vec::new()
            }
        };
        for run in &mut restored_runs {
            if !run.status.is_terminal()
                && let Ok(interrupted) = kernel.record(
                    run.run_id,
                    RunEventPayload::RunFailed {
                        code: "app_restarted".into(),
                        message: "This task was interrupted when Disco closed.".into(),
                        retryable: true,
                    },
                )
            {
                *run = interrupted;
            }
        }
        for run in restored_runs {
            let Some(session_id) = run.session_id else {
                continue;
            };
            let project_index = run
                .project_id
                .and_then(|project_id| {
                    projects
                        .iter()
                        .position(|project| project.project.id == project_id)
                })
                .or_else(|| {
                    let workspace = Path::new(run.workspace.as_deref()?);
                    projects
                        .iter()
                        .position(|project| project.project.root_path == workspace)
                });
            let Some(project_index) = project_index else {
                continue;
            };
            let project = &mut projects[project_index];
            if let Some(task) = project
                .tasks
                .iter_mut()
                .find(|task| task.session_id == session_id)
            {
                task.begin(run);
            } else {
                let mut task = ChatConversation::restored(session_id);
                task.begin(run);
                project.tasks.push(task);
            }
        }
        for project in &mut projects {
            project
                .tasks
                .sort_by_key(|task| std::cmp::Reverse(task.turns.last().map(|turn| turn.run_id)));
            project.selected_session_id = project.tasks.first().map(|task| task.session_id);
        }
        let active_session_id = if let Some(project) = projects
            .iter_mut()
            .find(|project| project.project.id == active_project_id)
        {
            if project.tasks.is_empty() {
                project.tasks.push(ChatConversation::new());
            }
            let session_id = project.tasks[0].session_id;
            project.selected_session_id = Some(session_id);
            session_id
        } else {
            let task = ChatConversation::new();
            let session_id = task.session_id;
            projects.push(ProjectState {
                project: current_project,
                expanded: true,
                selected_session_id: Some(session_id),
                tasks: vec![task],
            });
            session_id
        };

        let saved = AppConfig::load(&config_path).unwrap_or_default();
        let kimi_endpoint_input = cx.new(|cx| {
            ComposerInput::new(cx)
                .with_placeholder("API endpoint")
                .with_content(saved.kimi_code.endpoint.clone())
        });
        let kimi_api_key_input = cx.new(|cx| {
            ComposerInput::new(cx)
                .with_placeholder("Enter a new API key")
                .with_content(saved.kimi_code.api_key.clone())
                .secure(true)
        });
        let deepseek_endpoint_input = cx.new(|cx| {
            ComposerInput::new(cx)
                .with_placeholder("API endpoint")
                .with_content(saved.deepseek.endpoint.clone())
        });
        let deepseek_api_key_input = cx.new(|cx| {
            ComposerInput::new(cx)
                .with_placeholder("Enter a new API key")
                .with_content(saved.deepseek.api_key.clone())
                .secure(true)
        });
        for input in [
            &kimi_endpoint_input,
            &kimi_api_key_input,
            &deepseek_endpoint_input,
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
        let (opencode_models, opencode_models_error) = match opencode_models {
            Ok(models) => (models, None),
            Err(error) => (Vec::new(), Some(error)),
        };
        let selected_opencode_model_id = saved
            .selected_opencode_model
            .clone()
            .filter(|saved| opencode_models.iter().any(|model| model.id == *saved))
            .or_else(|| opencode_models.first().map(|model| model.id.clone()));
        let sidebar_focus_handle = cx.focus_handle().tab_stop(true);
        Self {
            kernel,
            projects,
            active_project_id,
            active_session_id,
            chat_scroll: ScrollHandle::new(),
            chat_scroll_pending: true,
            sidebar_focus_handle,
            sidebar_focused_item: SidebarItem::Task(active_project_id, active_session_id),
            project_context_menu: None,
            composer,
            page: WorkspacePage::Chat,
            config_path,
            config: saved,
            runtime,
            runtime_error,
            opencode_runtime,
            opencode_version,
            opencode_models,
            opencode_models_error,
            selected_opencode_model_id,
            models,
            selected_model_id,
            selected_effort,
            model_menu_open: false,
            model_menu_provider: ProviderKind::Codex,
            selected_chat_provider: ProviderKind::Codex,
            thinking_menu_open: false,
            selected_provider: Some(ProviderKind::Codex),
            kimi_endpoint_input,
            kimi_api_key_input,
            deepseek_endpoint_input,
            deepseek_api_key_input,
            remote_models: Vec::new(),
            remote_models_loading: false,
            remote_models_error: None,
            settings_notice: None,
            project_notice,
            stop_requested: false,
            thinking_toggle_overrides: std::collections::HashSet::new(),
            activity_toggle_overrides: std::collections::HashSet::new(),
            markdown_blocks_cache: std::collections::HashMap::new(),
        }
    }

    fn project_name(path: &Path) -> String {
        path.file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| path.to_string_lossy().into_owned())
    }

    fn active_project(&self) -> Option<&ProjectState> {
        self.projects
            .iter()
            .find(|project| project.project.id == self.active_project_id)
    }

    fn active_project_mut(&mut self) -> Option<&mut ProjectState> {
        self.projects
            .iter_mut()
            .find(|project| project.project.id == self.active_project_id)
    }

    fn active_task(&self) -> Option<&ChatConversation> {
        self.active_project()?
            .tasks
            .iter()
            .find(|task| task.session_id == self.active_session_id)
    }

    fn active_task_mut(&mut self) -> Option<&mut ChatConversation> {
        let active_session_id = self.active_session_id;
        self.active_project_mut()?
            .tasks
            .iter_mut()
            .find(|task| task.session_id == active_session_id)
    }

    fn visible_sidebar_items(&self) -> Vec<SidebarItem> {
        let mut items = Vec::new();
        for project in &self.projects {
            let project_id = project.project.id;
            items.push(SidebarItem::Project(project_id));
            if project.expanded {
                items.extend(
                    project
                        .tasks
                        .iter()
                        .map(|task| SidebarItem::Task(project_id, task.session_id)),
                );
            }
        }
        items
    }

    fn move_sidebar_selection(&mut self, offset: isize, cx: &mut Context<Self>) {
        if self.run_in_progress() {
            return;
        }
        let items = self.visible_sidebar_items();
        let Some(current_index) = items
            .iter()
            .position(|item| *item == self.sidebar_focused_item)
            .or_else(|| {
                items.iter().position(|item| {
                    *item == SidebarItem::Task(self.active_project_id, self.active_session_id)
                })
            })
        else {
            return;
        };
        let target_index = current_index
            .saturating_add_signed(offset)
            .min(items.len().saturating_sub(1));
        let target = items[target_index];
        match target {
            SidebarItem::Project(project_id) => self.select_project(project_id, cx),
            SidebarItem::Task(project_id, session_id) => {
                self.select_task(project_id, session_id, cx)
            }
        }
        self.sidebar_focused_item = target;
    }

    fn on_sidebar_key_down(
        &mut self,
        event: &KeyDownEvent,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if event.keystroke.modifiers.modified() {
            return;
        }
        match event.keystroke.key.as_str() {
            "up" => self.move_sidebar_selection(-1, cx),
            "down" => self.move_sidebar_selection(1, cx),
            "left" => match self.sidebar_focused_item {
                SidebarItem::Project(project_id) => {
                    if let Some(project) = self
                        .projects
                        .iter_mut()
                        .find(|project| project.project.id == project_id)
                        && project.expanded
                    {
                        project.expanded = false;
                    }
                }
                SidebarItem::Task(project_id, _) => {
                    self.select_project(project_id, cx);
                    self.sidebar_focused_item = SidebarItem::Project(project_id);
                }
            },
            "right" => {
                if let SidebarItem::Project(project_id) = self.sidebar_focused_item
                    && let Some(project) = self
                        .projects
                        .iter_mut()
                        .find(|project| project.project.id == project_id)
                {
                    if project.expanded {
                        if let Some(task) = project.tasks.first() {
                            let session_id = task.session_id;
                            self.select_task(project_id, session_id, cx);
                            self.sidebar_focused_item = SidebarItem::Task(project_id, session_id);
                        }
                    } else {
                        project.expanded = true;
                    }
                }
            }
            "enter" | "return" => match self.sidebar_focused_item {
                SidebarItem::Project(project_id) => self.select_project(project_id, cx),
                SidebarItem::Task(project_id, session_id) => {
                    self.select_task(project_id, session_id, cx)
                }
            },
            _ => return,
        }
        cx.stop_propagation();
        cx.notify();
    }

    fn task_for_run_mut(&mut self, run_id: RunId) -> Option<&mut ChatConversation> {
        self.projects
            .iter_mut()
            .flat_map(|project| project.tasks.iter_mut())
            .find(|task| task.turns.iter().any(|turn| turn.run_id == run_id))
    }

    fn run_in_progress(&self) -> bool {
        // Disco intentionally owns one CodexRuntime/app-server turn at a time.
        // Keep navigation locked across every project until that turn is terminal.
        self.projects
            .iter()
            .flat_map(|project| &project.tasks)
            .any(|task| {
                task.current()
                    .is_some_and(|turn| !turn.status.is_terminal())
            })
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
        self.config.selected_model = self.selected_model_id.clone();
        self.persist_config();
    }

    fn selected_opencode_model(&self) -> Option<&OpenCodeModel> {
        let selected = self.selected_opencode_model_id.as_deref()?;
        self.opencode_models
            .iter()
            .find(|model| model.id == selected)
    }

    fn select_opencode_model(&mut self, model_id: String) {
        if !self
            .opencode_models
            .iter()
            .any(|model| model.id == model_id)
        {
            return;
        }
        self.selected_opencode_model_id = Some(model_id);
        self.selected_chat_provider = ProviderKind::OpenCode;
        self.model_menu_open = false;
        self.thinking_menu_open = false;
        self.config.selected_opencode_model = self.selected_opencode_model_id.clone();
        self.persist_config();
    }

    fn persist_config(&mut self) {
        if let Err(error) = self.config.save(&self.config_path) {
            self.runtime_error = Some(error);
        }
    }

    fn select_model_menu_provider(&mut self, provider: ProviderKind) {
        self.model_menu_provider = provider;
        self.thinking_menu_open = false;
    }

    /// The endpoint and API key inputs plus the persisted settings for a remote
    /// provider. Returns `None` for providers configured outside Disco.
    fn remote_provider(
        &mut self,
        provider: ProviderKind,
    ) -> Option<(
        Entity<ComposerInput>,
        Entity<ComposerInput>,
        &mut RemoteProviderSettings,
    )> {
        match provider {
            ProviderKind::KimiCode => Some((
                self.kimi_endpoint_input.clone(),
                self.kimi_api_key_input.clone(),
                &mut self.config.kimi_code,
            )),
            ProviderKind::DeepSeek => Some((
                self.deepseek_endpoint_input.clone(),
                self.deepseek_api_key_input.clone(),
                &mut self.config.deepseek,
            )),
            ProviderKind::Codex | ProviderKind::OpenCode => None,
        }
    }

    fn open_provider_settings(&mut self, provider: ProviderKind, cx: &mut Context<Self>) {
        self.page = WorkspacePage::Settings;
        self.selected_provider = Some(provider);
        self.model_menu_open = false;
        self.thinking_menu_open = false;
        self.settings_notice = None;
        self.remote_models.clear();
        self.remote_models_error = None;
        self.refresh_remote_models(provider, cx);
    }

    fn refresh_remote_models(&mut self, provider: ProviderKind, cx: &mut Context<Self>) {
        let Some((endpoint_input, api_key_input, _)) = self.remote_provider(provider) else {
            return;
        };
        let endpoint = endpoint_input.read(cx).content().trim().to_owned();
        let api_key = api_key_input.read(cx).content().trim().to_owned();
        if endpoint.is_empty() || api_key.is_empty() {
            self.remote_models_loading = false;
            self.remote_models_error =
                Some("Enter the API endpoint and API key to load models.".into());
            return;
        }
        self.remote_models_loading = true;
        self.remote_models_error = None;
        let request = cx
            .background_executor()
            .spawn(async move { disco_rig_engine::list_models(&endpoint, &api_key).await });
        cx.spawn(async move |workspace, cx| {
            let result = request.await;
            workspace
                .update(cx, |workspace, cx| {
                    workspace.remote_models_loading = false;
                    match result {
                        Ok(models) => workspace.remote_models = models,
                        Err(error) => workspace.remote_models_error = Some(error),
                    }
                    cx.notify();
                })
                .ok();
        })
        .detach();
    }

    fn select_remote_model(&mut self, provider: ProviderKind, model: String) {
        if let Some((_, _, settings)) = self.remote_provider(provider) {
            settings.model = model;
        }
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
        let Some((endpoint_input, api_key_input, provider_settings)) =
            self.remote_provider(provider)
        else {
            return;
        };
        let endpoint = endpoint_input.read(cx).content().trim().to_owned();
        let api_key = api_key_input.read(cx).content().trim().to_owned();
        let notice = if endpoint.is_empty() || provider_settings.model.is_empty() {
            (
                false,
                "The API endpoint and a model selection are required.".into(),
            )
        } else if api_key.is_empty() && !provider_settings.is_configured() {
            (false, "Enter an API key to configure this provider.".into())
        } else {
            provider_settings.endpoint = endpoint;
            if !api_key.is_empty() {
                provider_settings.api_key = api_key;
            }
            match self.config.save(&self.config_path) {
                Ok(()) => (true, "Provider configuration saved.".into()),
                Err(error) => (false, error),
            }
        };
        self.settings_notice = Some(notice);
    }

    fn start_run(&mut self, prompt: String, cx: &mut Context<Self>) {
        if self.run_in_progress() {
            return;
        }
        let Some(project) = self.active_project() else {
            return;
        };
        let project_id = project.project.id;
        let workspace = project.project.root_path.clone();
        let Some(task) = self.active_task() else {
            return;
        };
        let session_id = task.session_id;
        let thread_id = task.codex_thread_id.clone();
        self.model_menu_open = false;
        self.thinking_menu_open = false;
        let run_id = RunId::new();
        let engine = match self.selected_chat_provider {
            ProviderKind::OpenCode => EngineKind::Acp {
                implementation: "opencode".into(),
            },
            _ => EngineKind::Codex,
        };
        let started = self.kernel.start_run(
            run_id,
            project_id,
            session_id,
            engine,
            Some(workspace.to_string_lossy().into_owned()),
            prompt.clone(),
        );
        let Ok(projection) = started else {
            let mut projection = RunProjection::empty(run_id);
            projection.prompt = Some(prompt);
            projection.status = RunStatus::Failed;
            projection.failure_message = Some("Could not persist the Codex run.".into());
            if let Some(task) = self.active_task_mut() {
                task.begin(projection);
            }
            return;
        };
        if self
            .active_task_mut()
            .is_none_or(|task| !task.begin(projection))
        {
            return;
        }
        // Anchor the new turn on the live edge of the transcript.
        self.chat_scroll_pending = true;
        match self.selected_chat_provider {
            ProviderKind::OpenCode => self.start_opencode_turn(run_id, &workspace, cx),
            _ => self.start_codex_turn(run_id, thread_id, &workspace, cx),
        }
    }

    fn start_codex_turn(
        &mut self,
        run_id: RunId,
        thread_id: Option<String>,
        workspace: &Path,
        cx: &mut Context<Self>,
    ) {
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
        let effort = self.selected_effort.clone();
        let prompt = self
            .active_task()
            .and_then(ChatConversation::current)
            .and_then(|turn| turn.prompt.clone())
            .unwrap_or_default();
        let workspace = workspace.to_owned();
        let (events_tx, events_rx) = std::sync::mpsc::channel::<TurnEvent>();
        let engine = cx.background_executor().spawn(async move {
            runtime.run_turn_streaming(
                thread_id.as_deref(),
                &workspace,
                &prompt,
                &model,
                &effort,
                &events_tx,
            )
        });
        cx.spawn(async move |workspace, cx| {
            consume_turn_events(&workspace, run_id, events_rx, cx).await;
            // The sender drops when the engine task settles, so the event
            // drain above is complete by the time this awaits returns.
            let result = engine.await.map_err(|error| error.to_string());
            workspace
                .update(cx, |workspace, cx| {
                    if let Err(error) = result {
                        workspace.record_failure(run_id, "codex_turn_failed", error);
                    }
                    workspace.stop_requested = false;
                    cx.notify();
                })
                .ok();
        })
        .detach();
    }

    fn start_opencode_turn(&mut self, run_id: RunId, workspace: &Path, cx: &mut Context<Self>) {
        let Some(runtime) = self.opencode_runtime.clone() else {
            self.record_failure(
                run_id,
                "opencode_not_available",
                self.opencode_models_error
                    .clone()
                    .unwrap_or_else(|| "OpenCode CLI is not available.".into()),
            );
            return;
        };
        let session = match self.ensure_opencode_session(workspace) {
            Ok(session) => session,
            Err(error) => {
                self.record_failure(run_id, "opencode_session_failed", error);
                return;
            }
        };
        let Some(model) = self.selected_opencode_model_id.clone() else {
            self.record_failure(
                run_id,
                "opencode_model_not_available",
                "No OpenCode model selected.".into(),
            );
            return;
        };
        runtime.prepare_turn();
        self.stop_requested = false;
        let prompt = self
            .active_task()
            .and_then(ChatConversation::current)
            .and_then(|turn| turn.prompt.clone())
            .unwrap_or_default();
        let (events_tx, events_rx) = std::sync::mpsc::channel::<TurnEvent>();
        let engine = cx.background_executor().spawn(async move {
            runtime
                .run_turn_streaming(&session, &prompt, &model, events_tx)
                .map_err(|error| error.to_string())
        });
        cx.spawn(async move |workspace, cx| {
            consume_turn_events(&workspace, run_id, events_rx, cx).await;
            let result = engine.await;
            workspace
                .update(cx, |workspace, cx| {
                    if let Err(error) = result {
                        workspace.record_failure(run_id, "opencode_turn_failed", error);
                    }
                    workspace.stop_requested = false;
                    cx.notify();
                })
                .ok();
        })
        .detach();
    }

    /// Returns the active task's ACP session, creating one on first use. ACP
    /// sessions die with the `opencode acp` process, so they are held in memory
    /// only and recreated after an app restart.
    fn ensure_opencode_session(&mut self, workspace: &Path) -> Result<String, String> {
        if let Some(session) = self
            .active_task()
            .and_then(|task| task.opencode_session_id.clone())
        {
            return Ok(session);
        }
        let Some(runtime) = self.opencode_runtime.as_ref() else {
            return Err("OpenCode CLI is not available.".into());
        };
        let session = runtime
            .new_session(workspace)
            .map_err(|error| error.to_string())?;
        if let Some(task) = self.active_task_mut() {
            task.opencode_session_id = Some(session.clone());
        }
        Ok(session)
    }

    fn terminal_event(interrupted: bool) -> RunEventPayload {
        // An interrupted codex turn ends as Cancelled, never Completed.
        if interrupted {
            RunEventPayload::RunCancelled
        } else {
            RunEventPayload::RunCompleted
        }
    }

    fn apply_turn_event(&mut self, run_id: RunId, event: TurnEvent) {
        let payload = match event {
            TurnEvent::ThreadAttached { thread_id } => {
                RunEventPayload::CodexThreadAttached { thread_id }
            }
            TurnEvent::ReasoningDelta { text } => RunEventPayload::ReasoningDelta { text },
            TurnEvent::AssistantDelta { text } => RunEventPayload::AssistantContentDelta { text },
            TurnEvent::ActivityStarted { activity } => RunEventPayload::ToolRequested {
                call: ToolCall {
                    call_id: activity.id,
                    name: activity.title,
                    arguments: json!({ "detail": activity.detail }),
                },
            },
            TurnEvent::ActivityCompleted {
                id,
                success,
                output,
            } => RunEventPayload::ToolCompleted {
                call_id: id,
                success,
                output,
            },
            TurnEvent::UsageUpdated { usage } => RunEventPayload::UsageUpdated { usage },
            TurnEvent::Finished { interrupted } => Self::terminal_event(interrupted),
            TurnEvent::Failed { code, message } => RunEventPayload::RunFailed {
                code,
                message,
                retryable: true,
            },
        };
        if payload.terminal_status().is_some() {
            self.stop_requested = false;
        }
        self.record(run_id, payload);
    }

    fn record(&mut self, run_id: RunId, payload: RunEventPayload) {
        if let Ok(projection) = self.kernel.record(run_id, payload)
            && let Some(task) = self.task_for_run_mut(run_id)
        {
            task.update(projection);
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
        if self.run_in_progress() || self.active_task().is_none_or(|task| !task.can_begin_turn()) {
            return;
        }
        let prompt = self
            .composer
            .update(cx, |composer, cx| composer.take_content(cx));
        if let Some(prompt) = prompt {
            if let Some(task) = self.active_task_mut() {
                task.draft.clear();
            }
            self.start_run(prompt, cx);
        }
    }

    fn stop_run(&mut self) {
        if self.stop_requested
            || self
                .active_task()
                .and_then(ChatConversation::current)
                .is_none_or(|turn| turn.status.is_terminal())
        {
            return;
        }
        match self.selected_chat_provider {
            ProviderKind::OpenCode => {
                let Some(runtime) = self.opencode_runtime.as_ref() else {
                    return;
                };
                let Some(session) = self
                    .active_task()
                    .and_then(|task| task.opencode_session_id.as_deref())
                    .map(str::to_owned)
                else {
                    return;
                };
                if runtime.cancel_turn(&session).is_err() {
                    return;
                }
            }
            _ => {
                let Some(runtime) = self.runtime.as_ref() else {
                    return;
                };
                if runtime.interrupt_turn().is_err() {
                    // Do not record a terminal RunFailed here: the turn is still
                    // executing, and a terminal event would orphan its real outcome
                    // (the engine's terminal events are rejected as
                    // EventAfterTerminal) and
                    // flip the UI back to send mode mid-run. Leave the run running;
                    // stop_requested stays false so the stop button stays active
                    // for a retry.
                    return;
                }
            }
        }
        self.stop_requested = true;
    }

    fn new_task_for_project(&mut self, project_id: ProjectId, cx: &mut Context<Self>) {
        if self.run_in_progress() {
            return;
        }
        let Some(project_index) = self
            .projects
            .iter()
            .position(|project| project.project.id == project_id)
        else {
            return;
        };
        let current_draft = self.composer.read(cx).content();
        if let Some(task) = self.active_task_mut() {
            task.draft = current_draft;
        }
        let task = ChatConversation::new();
        let session_id = task.session_id;
        let project = &mut self.projects[project_index];
        project.expanded = true;
        project.selected_session_id = Some(session_id);
        project.tasks.insert(0, task);
        self.active_project_id = project_id;
        self.active_session_id = session_id;
        self.sidebar_focused_item = SidebarItem::Task(project_id, session_id);
        self.composer
            .update(cx, |composer, cx| composer.set_content("", cx));
        self.chat_scroll_pending = true;
        self.model_menu_open = false;
        self.thinking_menu_open = false;
        self.page = WorkspacePage::Chat;
        self.stop_requested = false;
    }

    fn toggle_project(&mut self, project_id: ProjectId) {
        if let Some(project) = self
            .projects
            .iter_mut()
            .find(|project| project.project.id == project_id)
        {
            project.expanded = !project.expanded;
        }
    }

    fn select_project(&mut self, project_id: ProjectId, cx: &mut Context<Self>) {
        if self.run_in_progress() && project_id != self.active_project_id {
            return;
        }
        if project_id == self.active_project_id {
            if let Some(project) = self.active_project_mut() {
                project.expanded = true;
            }
            return;
        }
        let existing_session_id = self
            .projects
            .iter()
            .find(|project| project.project.id == project_id)
            .and_then(|project| {
                project
                    .selected_session_id
                    .or_else(|| project.tasks.first().map(|task| task.session_id))
            });
        if let Some(session_id) = existing_session_id {
            self.select_task(project_id, session_id, cx);
        } else {
            self.new_task_for_project(project_id, cx);
        }
    }

    fn select_task(
        &mut self,
        project_id: ProjectId,
        session_id: SessionId,
        cx: &mut Context<Self>,
    ) {
        if self.run_in_progress() && session_id != self.active_session_id {
            return;
        }
        let Some(project_index) = self
            .projects
            .iter()
            .position(|project| project.project.id == project_id)
        else {
            return;
        };
        let Some(task_index) = self.projects[project_index]
            .tasks
            .iter()
            .position(|task| task.session_id == session_id)
        else {
            return;
        };
        if project_id == self.active_project_id && session_id == self.active_session_id {
            self.projects[project_index].expanded = true;
            self.projects[project_index].selected_session_id = Some(session_id);
            return;
        }
        let current_draft = self.composer.read(cx).content();
        if let Some(task) = self.active_task_mut() {
            task.draft = current_draft;
        }
        let draft = self.projects[project_index].tasks[task_index].draft.clone();
        self.projects[project_index].expanded = true;
        self.projects[project_index].selected_session_id = Some(session_id);
        self.active_project_id = project_id;
        self.active_session_id = session_id;
        self.sidebar_focused_item = SidebarItem::Task(project_id, session_id);
        self.chat_scroll_pending = true;
        self.page = WorkspacePage::Chat;
        self.model_menu_open = false;
        self.thinking_menu_open = false;
        self.composer
            .update(cx, |composer, cx| composer.set_content(draft, cx));
    }

    fn open_project_picker(&mut self, cx: &mut Context<Self>) {
        if self.run_in_progress() {
            return;
        }
        let receiver = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Open Project".into()),
        });
        cx.spawn(async move |workspace, cx| {
            let selected = receiver.await;
            workspace
                .update(cx, |workspace, cx| {
                    match selected {
                        Ok(Ok(Some(paths))) => {
                            if let Some(path) = paths.into_iter().next() {
                                workspace.register_project_path(path, cx);
                            }
                        }
                        Ok(Err(error)) => workspace.project_notice = Some(error.to_string()),
                        Err(error) => workspace.project_notice = Some(error.to_string()),
                        Ok(Ok(None)) => {}
                    }
                    cx.notify();
                })
                .ok();
        })
        .detach();
    }

    fn register_project_path(&mut self, path: PathBuf, cx: &mut Context<Self>) {
        if self.run_in_progress() {
            self.project_notice = Some("Finish the running task before opening a project.".into());
            return;
        }
        let root_path = path.canonicalize().unwrap_or(path);
        if !root_path.is_dir() {
            self.project_notice = Some("The selected project folder is unavailable.".into());
            return;
        }
        let candidate = Project::new(Self::project_name(&root_path), root_path);
        match self.kernel.register_project(candidate) {
            Ok(project) => {
                self.project_notice = None;
                let existing_project = self
                    .projects
                    .iter_mut()
                    .find(|existing| existing.project.id == project.id);
                if let Some(existing) = existing_project {
                    existing.project = project.clone();
                    existing.expanded = true;
                    self.select_project(project.id, cx);
                } else {
                    self.projects.insert(
                        0,
                        ProjectState {
                            project: project.clone(),
                            expanded: true,
                            selected_session_id: None,
                            tasks: Vec::new(),
                        },
                    );
                    self.new_task_for_project(project.id, cx);
                }
            }
            Err(error) => self.project_notice = Some(error.to_string()),
        }
    }

    fn render_project_context_menu(
        &self,
        menu: ProjectContextMenu,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let palette = AppAppearance::for_window(cx.window_appearance());
        let project = self
            .projects
            .iter()
            .find(|project| project.project.id == menu.project_id)
            .expect("a context menu can only target a visible project");
        let project_id = menu.project_id;
        let project_path = project.project.root_path.clone();
        let navigation_locked = self.run_in_progress();

        div()
            .id((ElementId::from(project_id.as_uuid()), "context-menu"))
            .w(px(208.))
            .p_1()
            .flex()
            .flex_col()
            .rounded(px(RADIUS_MEDIUM))
            .bg(rgb(palette.surface))
            .border_1()
            .border_color(rgb(palette.border_strong))
            .shadow_lg()
            .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                this.project_context_menu = None;
                cx.notify();
            }))
            .child(
                div()
                    .id((ElementId::from(project_id.as_uuid()), "context-new-task"))
                    .h(px(28.))
                    .px_2()
                    .flex()
                    .items_center()
                    .rounded(px(RADIUS_SMALL))
                    .text_size(px(TYPE_UI))
                    .text_color(rgb(palette.text))
                    .when(navigation_locked, |item| item.opacity(0.42))
                    .when(!navigation_locked, |item| {
                        item.cursor_pointer()
                            .hover(move |style| style.bg(rgb(palette.surface_hover)))
                            .active(move |style| style.bg(rgb(palette.surface_pressed)))
                    })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if !this.run_in_progress() {
                            this.project_context_menu = None;
                            window.focus(&this.sidebar_focus_handle);
                            this.new_task_for_project(project_id, cx);
                        }
                        cx.notify();
                    }))
                    .child("New Task"),
            )
            .child(div().mx_2().my_1().h(px(1.)).bg(rgb(palette.border)))
            .child(
                div()
                    .id((ElementId::from(project_id.as_uuid()), "context-reveal"))
                    .h(px(28.))
                    .px_2()
                    .flex()
                    .items_center()
                    .rounded(px(RADIUS_SMALL))
                    .cursor_pointer()
                    .text_size(px(TYPE_UI))
                    .text_color(rgb(palette.text))
                    .hover(move |style| style.bg(rgb(palette.surface_hover)))
                    .active(move |style| style.bg(rgb(palette.surface_pressed)))
                    .on_click(cx.listener({
                        let project_path = project_path.clone();
                        move |this, _, _, cx| {
                            this.project_context_menu = None;
                            if let Err(error) = Command::new("/usr/bin/open")
                                .arg("-R")
                                .arg(&project_path)
                                .spawn()
                            {
                                this.project_notice =
                                    Some(format!("Could not reveal the project: {error}"));
                            }
                            cx.notify();
                        }
                    }))
                    .child("Reveal in Finder"),
            )
            .child(
                div()
                    .id((ElementId::from(project_id.as_uuid()), "context-copy-path"))
                    .h(px(28.))
                    .px_2()
                    .flex()
                    .items_center()
                    .rounded(px(RADIUS_SMALL))
                    .cursor_pointer()
                    .text_size(px(TYPE_UI))
                    .text_color(rgb(palette.text))
                    .hover(move |style| style.bg(rgb(palette.surface_hover)))
                    .active(move |style| style.bg(rgb(palette.surface_pressed)))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.project_context_menu = None;
                        cx.write_to_clipboard(ClipboardItem::new_string(
                            project_path.to_string_lossy().into_owned(),
                        ));
                        cx.notify();
                    }))
                    .child("Copy Path"),
            )
    }

    fn status_label(&self) -> String {
        let provider = self.selected_chat_provider.name();
        let Some(current) = self.active_task().and_then(ChatConversation::current) else {
            return if self.selected_runtime_ready() {
                format!("{provider} ready")
            } else {
                format!("{provider} unavailable")
            };
        };
        match current.status {
            RunStatus::Queued => "Queued".to_string(),
            RunStatus::Running => format!("{provider} working"),
            RunStatus::WaitingForTool => "Running tool".to_string(),
            RunStatus::WaitingForApproval => "Approval required".to_string(),
            RunStatus::WaitingForUserInput => "Input required".to_string(),
            RunStatus::Completed => "Completed".to_string(),
            RunStatus::Failed => "Failed".to_string(),
            RunStatus::Cancelled => "Cancelled".to_string(),
        }
    }

    fn selected_runtime_ready(&self) -> bool {
        match self.selected_chat_provider {
            ProviderKind::OpenCode => self.opencode_runtime.is_some(),
            _ => self.runtime.is_some(),
        }
    }

    fn status_color(&self, palette: AppAppearance) -> u32 {
        let Some(current) = self.active_task().and_then(ChatConversation::current) else {
            return if self.selected_runtime_ready() {
                palette.green
            } else {
                palette.red
            };
        };
        match current.status {
            RunStatus::Completed => palette.green,
            RunStatus::Failed | RunStatus::Cancelled => palette.red,
            _ => palette.blue,
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

    fn token_count_label(count: u64) -> String {
        let digits = count.to_string();
        let mut formatted = String::with_capacity(digits.len() + digits.len() / 3);
        for (index, digit) in digits.chars().enumerate() {
            if index > 0 && (digits.len() - index).is_multiple_of(3) {
                formatted.push(',');
            }
            formatted.push(digit);
        }
        formatted
    }

    /// Returns the parsed markdown blocks for a run's assistant text, caching
    /// the parse result so per-frame redraws (streaming deltas, hover,
    /// composer input) never re-parse unchanged text. The element tree is
    /// still rebuilt each frame; parsing is the expensive part.
    fn markdown_blocks(
        &mut self,
        run_id: RunId,
        text: &str,
    ) -> std::sync::Arc<Vec<markdown::Block>> {
        let hash = markdown::text_hash(text);
        if let Some((cached_hash, blocks)) = self.markdown_blocks_cache.get(&run_id)
            && *cached_hash == hash
        {
            return blocks.clone();
        }
        let blocks = std::sync::Arc::new(markdown::parse_blocks(text));
        self.markdown_blocks_cache
            .insert(run_id, (hash, blocks.clone()));
        blocks
    }

    /// Toggles a per-run entry in one of the toggle-override sets.
    fn toggle_run_override(overrides: &mut std::collections::HashSet<RunId>, run_id: RunId) {
        if !overrides.remove(&run_id) {
            overrides.insert(run_id);
        }
    }

    /// Drops per-run transient state (toggle overrides, markdown cache) for
    /// runs that no longer appear in any task, so it cannot outlive its run.
    fn prune_transient_run_state(&mut self) {
        let known_run_ids: std::collections::HashSet<RunId> = self
            .projects
            .iter()
            .flat_map(|project| project.tasks.iter())
            .flat_map(|task| task.turns().iter().map(|turn| turn.run_id))
            .collect();
        self.thinking_toggle_overrides
            .retain(|run_id| known_run_ids.contains(run_id));
        self.activity_toggle_overrides
            .retain(|run_id| known_run_ids.contains(run_id));
        self.markdown_blocks_cache
            .retain(|run_id, _| known_run_ids.contains(run_id));
    }

    fn activity_row(item: &ActivityItem, palette: AppAppearance) -> impl IntoElement {
        let appearance = palette.conversation;
        let indicator = if item.completed {
            palette.green
        } else {
            match item.kind {
                ActivityKind::Approval => appearance.warning,
                ActivityKind::Failure => palette.red,
                ActivityKind::Plan | ActivityKind::Tool => palette.blue,
            }
        };
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
                    .bg(rgb(indicator)),
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
                            .text_color(rgb(palette.text))
                            .child(item.title.clone()),
                    )
                    .when(!item.detail.is_empty(), |content| {
                        content.child(
                            div()
                                .text_size(px(TYPE_CAPTION))
                                .line_height(px(16.))
                                .text_color(rgb(appearance.secondary_text))
                                .child(item.detail.clone()),
                        )
                    }),
            )
    }

    fn conversation_turn(
        &mut self,
        turn: RunProjection,
        palette: AppAppearance,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let appearance = palette.conversation;
        let run_id = turn.run_id;
        let prompt = turn.prompt.unwrap_or_default();
        let is_working = !turn.status.is_terminal();
        let assistant = turn.assistant_text;
        let reasoning = turn.reasoning_text;
        let usage = turn.usage;
        let activities = turn
            .activities
            .into_iter()
            .filter(|item| item.kind != ActivityKind::Failure)
            .collect::<Vec<_>>();
        let failure = turn.failure_message;
        let has_response = !assistant.is_empty()
            || !reasoning.is_empty()
            || !activities.is_empty()
            || failure.is_some()
            || is_working;

        // Collapse logic: terminal runs default collapsed, working runs default expanded
        let thinking_expanded = if is_working {
            !self.thinking_toggle_overrides.contains(&run_id) // expanded unless overridden
        } else {
            self.thinking_toggle_overrides.contains(&run_id) // collapsed unless overridden
        };
        let activities_expanded = if is_working {
            !self.activity_toggle_overrides.contains(&run_id)
        } else {
            self.activity_toggle_overrides.contains(&run_id)
        };

        let activity_count = activities.len();
        let reasoning_preview: String = reasoning.chars().take(60).collect();
        // Parse the assistant markdown at most once per text revision; the
        // element tree below is rebuilt every frame from the cached blocks.
        let assistant_blocks = if assistant.is_empty() {
            None
        } else {
            Some(self.markdown_blocks(run_id, &assistant))
        };

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(
                div().w_full().flex().justify_end().child(
                    div()
                        .max_w(px(CHAT_BUBBLE_MAX_WIDTH))
                        .px(px(14.))
                        .py(px(9.))
                        .rounded(px(CHAT_BUBBLE_RADIUS))
                        .bg(rgb(appearance.secondary_surface))
                        .text_size(px(TYPE_BODY))
                        .line_height(px(22.))
                        .text_color(rgb(palette.text))
                        .child(prompt),
                ),
            )
            .when(has_response, |turn_el| {
                turn_el.child(
                    div()
                        .min_w(px(0.))
                        .w_full()
                        .flex()
                        .flex_col()
                        .gap_2()
                        // -- Collapsible Thinking section --
                        .when(!reasoning.is_empty(), |column| {
                            column.child(
                                div()
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(rgb(appearance.secondary_surface))
                                    .overflow_hidden()
                                    .child(
                                        div()
                                            .id((
                                                ElementId::from(run_id.as_uuid()),
                                                "thinking-toggle",
                                            ))
                                            .flex()
                                            .items_center()
                                            .gap_2()
                                            .px_3()
                                            .py_2()
                                            .cursor(CursorStyle::PointingHand)
                                            .on_click(cx.listener(move |this, _, _, cx| {
                                                Self::toggle_run_override(
                                                    &mut this.thinking_toggle_overrides,
                                                    run_id,
                                                );
                                                if this.thinking_toggle_overrides.len() > 256 {
                                                    this.prune_transient_run_state();
                                                }
                                                cx.notify();
                                            }))
                                            .child(
                                                svg()
                                                    .size(px(12.))
                                                    .flex_none()
                                                    .path(if thinking_expanded {
                                                        CHEVRON_DOWN_ASSET
                                                    } else {
                                                        CHEVRON_RIGHT_ASSET
                                                    })
                                                    .text_color(rgb(appearance.secondary_text)),
                                            )
                                            .child(div().size(px(6.)).rounded_full().bg(rgb(
                                                if is_working {
                                                    palette.blue
                                                } else {
                                                    palette.muted_light
                                                },
                                            )))
                                            .child(
                                                div()
                                                    .text_size(px(TYPE_CAPTION))
                                                    .font_weight(FontWeight::MEDIUM)
                                                    .text_color(rgb(appearance.secondary_text))
                                                    .child("Thinking"),
                                            )
                                            .when(
                                                !thinking_expanded && !reasoning_preview.is_empty(),
                                                |header| {
                                                    header.child(
                                                        div()
                                                            .text_size(px(TYPE_CAPTION))
                                                            .text_color(rgb(palette.muted_light))
                                                            .truncate()
                                                            .child(format!(
                                                                "{}…",
                                                                reasoning_preview
                                                            )),
                                                    )
                                                },
                                            ),
                                    )
                                    .when(thinking_expanded, |container| {
                                        container.child(
                                            div()
                                                .px_3()
                                                .pb_2()
                                                .text_size(px(TYPE_BODY))
                                                .line_height(px(21.))
                                                .text_color(rgb(appearance.secondary_text))
                                                .child(reasoning),
                                        )
                                    }),
                            )
                        })
                        // -- Collapsible Activities section --
                        .when(!activities.is_empty(), |column| {
                            column.child(
                                div()
                                    .rounded(px(RADIUS_MEDIUM))
                                    .overflow_hidden()
                                    .bg(rgb(appearance.secondary_surface))
                                    .child(
                                        div()
                                            .id((
                                                ElementId::from(run_id.as_uuid()),
                                                "activity-toggle",
                                            ))
                                            .flex()
                                            .items_center()
                                            .gap_2()
                                            .px_3()
                                            .py_2()
                                            .cursor(CursorStyle::PointingHand)
                                            .on_click(cx.listener(move |this, _, _, cx| {
                                                Self::toggle_run_override(
                                                    &mut this.activity_toggle_overrides,
                                                    run_id,
                                                );
                                                if this.activity_toggle_overrides.len() > 256 {
                                                    this.prune_transient_run_state();
                                                }
                                                cx.notify();
                                            }))
                                            .child(
                                                svg()
                                                    .size(px(12.))
                                                    .flex_none()
                                                    .path(if activities_expanded {
                                                        CHEVRON_DOWN_ASSET
                                                    } else {
                                                        CHEVRON_RIGHT_ASSET
                                                    })
                                                    .text_color(rgb(appearance.secondary_text)),
                                            )
                                            .child(
                                                div()
                                                    .text_size(px(TYPE_CAPTION))
                                                    .font_weight(FontWeight::MEDIUM)
                                                    .text_color(rgb(appearance.secondary_text))
                                                    .child("Activity"),
                                            )
                                            .child(
                                                div()
                                                    .text_size(px(TYPE_CAPTION))
                                                    .text_color(rgb(palette.muted_light))
                                                    .child(format!("{} items", activity_count)),
                                            ),
                                    )
                                    .when(activities_expanded, |container| {
                                        container.children(activities.iter().enumerate().map(
                                            |(index, item)| {
                                                div()
                                                    .when(index > 0, |row| {
                                                        row.border_t_1().border_color(rgb(
                                                            appearance.secondary_separator,
                                                        ))
                                                    })
                                                    .child(Self::activity_row(item, palette))
                                            },
                                        ))
                                    }),
                            )
                        })
                        // -- Assistant response (always visible, markdown rendered) --
                        .when_some(assistant_blocks, |column, blocks| {
                            column.child(markdown::render_blocks(&blocks, palette))
                        })
                        // -- Working indicator --
                        .when(is_working, |column| {
                            column.child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .text_size(px(TYPE_UI))
                                    .text_color(rgb(appearance.secondary_text))
                                    .child(div().size(px(6.)).rounded_full().bg(rgb(palette.blue)))
                                    .child("Working…"),
                            )
                        })
                        // -- Failure message --
                        .when_some(failure, |column, message| {
                            column.child(
                                div()
                                    .px_3()
                                    .py_2()
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(rgb(appearance.failure_surface))
                                    .flex()
                                    .flex_col()
                                    .gap(px(3.))
                                    .child(
                                        div()
                                            .text_size(px(TYPE_UI))
                                            .font_weight(FontWeight::MEDIUM)
                                            .text_color(rgb(palette.red))
                                            .child("Run failed"),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(TYPE_UI))
                                            .line_height(px(18.))
                                            .text_color(rgb(palette.red))
                                            .child(message),
                                    ),
                            )
                        })
                        .when(usage.total_tokens > 0, |column| {
                            // Engines that only report a cumulative count (ACP
                            // context usage) have no input/output split to show.
                            let label = if usage.input_tokens == 0 && usage.output_tokens == 0 {
                                Self::token_count_label(usage.total_tokens)
                            } else {
                                format!(
                                    "{} input · {} output",
                                    Self::token_count_label(usage.input_tokens),
                                    Self::token_count_label(usage.output_tokens)
                                )
                            };
                            column.child(
                                div()
                                    .pt_1()
                                    .text_size(px(TYPE_CAPTION))
                                    .text_color(rgb(palette.muted_light))
                                    .child(label),
                            )
                        }),
                )
            })
    }

    fn project_sidebar_group(
        &self,
        project: ProjectState,
        focus_visible: bool,
        cx: &mut Context<Self>,
    ) -> gpui::Div {
        let palette = AppAppearance::for_window(cx.window_appearance());
        let appearance = palette.sidebar;
        let project_id = project.project.id;
        let is_active_project = project_id == self.active_project_id;
        let navigation_locked = self.run_in_progress();
        let project_disabled = navigation_locked && !is_active_project;
        let project_focused =
            focus_visible && self.sidebar_focused_item == SidebarItem::Project(project_id);
        let project_hover_group = format!("project-row-{project_id}");
        let task_rows = project
            .tasks
            .into_iter()
            .map(|task| {
                let session_id = task.session_id;
                let selected = is_active_project && session_id == self.active_session_id;
                let disabled = navigation_locked && !selected;
                let focused = focus_visible
                    && self.sidebar_focused_item == SidebarItem::Task(project_id, session_id);
                let title = task
                    .title_prompt()
                    .map(Self::compact_title)
                    .unwrap_or_else(|| "New task".into());
                let running = task
                    .current()
                    .is_some_and(|turn| !turn.status.is_terminal());
                div()
                    .id((ElementId::from(session_id.as_uuid()), "task"))
                    .mx_2()
                    .h(px(30.))
                    .pl(px(44.))
                    .pr_2()
                    .flex()
                    .items_center()
                    .justify_between()
                    .rounded(px(RADIUS_SMALL))
                    .bg(rgb(if selected {
                        if focused {
                            appearance.selection_focused
                        } else {
                            appearance.selection
                        }
                    } else if focused {
                        appearance.focus
                    } else {
                        appearance.background
                    }))
                    .when(disabled, |row| row.opacity(0.48))
                    .when(!disabled, |row| {
                        row.cursor_pointer()
                            .hover(move |style| {
                                style.bg(rgb(if selected {
                                    appearance.selection_focused
                                } else {
                                    appearance.hover
                                }))
                            })
                            .active(move |style| style.bg(rgb(appearance.pressed)))
                    })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if !this.run_in_progress() || session_id == this.active_session_id {
                            window.focus(&this.sidebar_focus_handle);
                            this.select_task(project_id, session_id, cx);
                            this.sidebar_focused_item = SidebarItem::Task(project_id, session_id);
                        }
                        cx.notify();
                    }))
                    .child(
                        div()
                            .min_w(px(0.))
                            .truncate()
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::NORMAL)
                            .text_color(rgb(appearance.text))
                            .child(title),
                    )
                    .when(running, |row| {
                        row.child(
                            div()
                                .ml_2()
                                .size(px(7.))
                                .flex_shrink_0()
                                .rounded_full()
                                .bg(rgb(palette.blue)),
                        )
                    })
            })
            .collect::<Vec<_>>();

        div()
            .w_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .id((ElementId::from(project_id.as_uuid()), "project"))
                    .group(project_hover_group.clone())
                    .mx_2()
                    .h(px(30.))
                    .px_1()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .rounded(px(RADIUS_SMALL))
                    .bg(rgb(if project_focused {
                        appearance.focus
                    } else {
                        appearance.background
                    }))
                    .when(project_disabled, |row| row.opacity(0.48))
                    .when(!project_disabled, |row| {
                        row.cursor_pointer()
                            .hover(move |style| style.bg(rgb(appearance.hover)))
                            .active(move |style| style.bg(rgb(appearance.pressed)))
                    })
                    .on_click(
                        cx.listener(move |this, event: &gpui::ClickEvent, window, cx| {
                            if event.standard_click()
                                && (!this.run_in_progress() || project_id == this.active_project_id)
                            {
                                window.focus(&this.sidebar_focus_handle);
                                this.select_project(project_id, cx);
                                this.sidebar_focused_item = SidebarItem::Project(project_id);
                            }
                            cx.notify();
                        }),
                    )
                    .on_mouse_up(
                        MouseButton::Right,
                        cx.listener(move |this, event: &gpui::MouseUpEvent, window, cx| {
                            cx.stop_propagation();
                            window.focus(&this.sidebar_focus_handle);
                            this.sidebar_focused_item = SidebarItem::Project(project_id);
                            this.project_context_menu = Some(ProjectContextMenu {
                                project_id,
                                position: event.position,
                            });
                            cx.notify();
                        }),
                    )
                    .child(
                        div()
                            .id((ElementId::from(project_id.as_uuid()), "project-disclosure"))
                            .size(px(16.))
                            .flex_shrink_0()
                            .flex()
                            .items_center()
                            .cursor_pointer()
                            .justify_center()
                            .on_click(cx.listener(move |this, _, window, cx| {
                                cx.stop_propagation();
                                window.focus(&this.sidebar_focus_handle);
                                this.sidebar_focused_item = SidebarItem::Project(project_id);
                                this.toggle_project(project_id);
                                cx.notify();
                            }))
                            .child(
                                img(if project.expanded {
                                    CHEVRON_DOWN_ASSET
                                } else {
                                    CHEVRON_RIGHT_ASSET
                                })
                                .size(px(8.)),
                            ),
                    )
                    .child(img(FOLDER_ICON_ASSET).size(px(16.)))
                    .child(
                        div()
                            .min_w(px(0.))
                            .flex_grow()
                            .truncate()
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(appearance.text))
                            .child(project.project.name),
                    )
                    .when(is_active_project && !navigation_locked, |row| {
                        row.child(
                            div()
                                .id((ElementId::from(project_id.as_uuid()), "new-task"))
                                .size(px(20.))
                                .flex_shrink_0()
                                .flex()
                                .items_center()
                                .justify_center()
                                .rounded(px(4.))
                                .text_size(px(15.))
                                .text_color(rgb(appearance.secondary_text))
                                .opacity(0.)
                                .group_hover(project_hover_group, |style| style.opacity(1.))
                                .hover(move |style| {
                                    style
                                        .bg(rgb(appearance.hover))
                                        .text_color(rgb(appearance.text))
                                })
                                .active(move |style| style.bg(rgb(appearance.pressed)))
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    cx.stop_propagation();
                                    window.focus(&this.sidebar_focus_handle);
                                    this.new_task_for_project(project_id, cx);
                                    cx.notify();
                                }))
                                .child("＋"),
                        )
                    }),
            )
            .when(project.expanded, |group| group.children(task_rows))
    }

    fn sidebar(&self, focus_visible: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let palette = AppAppearance::for_window(cx.window_appearance());
        let appearance = palette.sidebar;
        let navigation_locked = self.run_in_progress();
        let projects = self.projects.clone();
        let project_groups = projects
            .into_iter()
            .map(|project| self.project_sidebar_group(project, focus_visible, cx))
            .collect::<Vec<_>>();
        div()
            .id("project-sidebar")
            .key_context("ProjectSidebar")
            .track_focus(&self.sidebar_focus_handle)
            .on_key_down(cx.listener(Self::on_sidebar_key_down))
            .w(px(APP_SIDEBAR_WIDTH))
            .h_full()
            .flex_shrink_0()
            .flex()
            .flex_col()
            .bg(rgb(appearance.background))
            .border_r_1()
            .border_color(rgb(appearance.separator))
            .child(div().h(px(APP_SIDEBAR_TOP_INSET)))
            .child(
                div()
                    .h(px(32.))
                    .px_3()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_size(px(TYPE_CAPTION))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(appearance.secondary_text))
                            .child("Projects"),
                    )
                    .child(
                        div()
                            .id("add-project")
                            .size(px(24.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(4.))
                            .text_size(px(17.))
                            .text_color(rgb(appearance.secondary_text))
                            .when(navigation_locked, |button| button.opacity(0.48))
                            .when(!navigation_locked, |button| {
                                button
                                    .cursor_pointer()
                                    .hover(move |style| {
                                        style
                                            .bg(rgb(appearance.hover))
                                            .text_color(rgb(appearance.text))
                                    })
                                    .active(move |style| style.bg(rgb(appearance.pressed)))
                            })
                            .on_click(cx.listener(|this, _, window, cx| {
                                if !this.run_in_progress() {
                                    window.focus(&this.sidebar_focus_handle);
                                    this.open_project_picker(cx);
                                }
                                cx.notify();
                            }))
                            .child("＋"),
                    ),
            )
            .when_some(self.project_notice.clone(), |sidebar, notice| {
                sidebar.child(
                    div()
                        .mx_4()
                        .mb_2()
                        .text_size(px(TYPE_CAPTION))
                        .text_color(rgb(palette.red))
                        .child(notice),
                )
            })
            .child(
                div()
                    .id("projects-scroll")
                    .min_h(px(0.))
                    .flex_grow()
                    .overflow_y_scroll()
                    .pb_3()
                    .children(project_groups),
            )
            .child(
                div()
                    .mx_2()
                    .py_2()
                    .flex()
                    .items_center()
                    .border_t_1()
                    .border_color(rgb(appearance.separator))
                    .child(
                        div()
                            .id("open-settings")
                            .w_full()
                            .h(px(30.))
                            .px_2()
                            .flex()
                            .items_center()
                            .gap_2()
                            .rounded(px(RADIUS_SMALL))
                            .cursor_pointer()
                            .bg(rgb(if self.page == WorkspacePage::Settings {
                                appearance.selection
                            } else {
                                appearance.background
                            }))
                            .hover(move |style| style.bg(rgb(appearance.hover)))
                            .active(move |style| style.bg(rgb(appearance.pressed)))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.page = WorkspacePage::Settings;
                                this.model_menu_open = false;
                                this.thinking_menu_open = false;
                                cx.notify();
                            }))
                            .child(img(SETTINGS_ICON_ASSET).size(px(17.)))
                            .child("Settings"),
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
        let palette = AppAppearance::for_window(cx.window_appearance());
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
            .bg(rgb(if selected {
                palette.surface
            } else {
                palette.surface_subtle
            }))
            .text_color(rgb(if selected {
                palette.text
            } else {
                palette.muted
            }))
            .hover(move |style| style.bg(rgb(palette.surface)))
            .active(move |style| style.bg(rgb(palette.surface_hover)))
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
                        palette.surface
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
                            .text_color(rgb(palette.muted_light))
                            .child(detail),
                    ),
            )
            .child(
                div()
                    .size(px(6.))
                    .flex_shrink_0()
                    .rounded_full()
                    .bg(rgb(if ready {
                        palette.green
                    } else {
                        palette.muted_light
                    })),
            )
    }

    /// The shared layout of a provider detail in the model picker: icon,
    /// title, description, optional extra content, and the settings button.
    fn picker_detail_shell(
        provider: ProviderKind,
        title: &'static str,
        description: String,
        extra: Option<impl IntoElement>,
        button_label: &'static str,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let palette = AppAppearance::for_window(cx.window_appearance());
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
                        palette.surface_subtle
                    }))
                    .child(img(provider.icon()).max_w(px(28.)).max_h(px(28.))),
            )
            .child(
                div()
                    .mt_3()
                    .text_size(px(TYPE_BODY))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(title),
            )
            .child(
                div()
                    .mt_1()
                    .max_w(px(290.))
                    .text_size(px(TYPE_UI))
                    .line_height(px(18.))
                    .text_color(rgb(palette.muted))
                    .child(description),
            )
            .when_some(extra, |content, extra| content.child(extra))
            .child(div().flex_grow())
            .child(Self::picker_settings_button(provider, button_label, cx))
    }

    fn picker_settings_button(
        provider: ProviderKind,
        label: &'static str,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let palette = AppAppearance::for_window(cx.window_appearance());
        div()
            .id(("chat-provider-settings", provider as usize))
            .h(px(30.))
            .px_3()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(RADIUS_SMALL))
            .cursor_pointer()
            .bg(rgb(palette.settings_control))
            .text_size(px(TYPE_UI))
            .font_weight(FontWeight::MEDIUM)
            .hover(move |style| style.bg(rgb(palette.surface_hover)))
            .active(move |style| style.bg(rgb(palette.surface_pressed)))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.open_provider_settings(provider, cx);
                cx.notify();
            }))
            .child(label)
    }

    fn remote_model_picker_detail(
        &mut self,
        provider: ProviderKind,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let palette = AppAppearance::for_window(cx.window_appearance());
        let (configured, model) = match self.remote_provider(provider) {
            Some((_, _, settings)) => (settings.is_configured(), settings.model.clone()),
            None => unreachable!("Codex and OpenCode have their own picker details"),
        };
        let model_box = (configured && !model.is_empty()).then(|| {
            div()
                .mt_4()
                .w_full()
                .px_3()
                .py_2()
                .rounded(px(RADIUS_MEDIUM))
                .bg(rgb(palette.surface_subtle))
                .child(
                    div()
                        .text_size(px(TYPE_CAPTION))
                        .text_color(rgb(palette.muted_light))
                        .child("Configured model"),
                )
                .child(
                    div()
                        .mt_1()
                        .truncate()
                        .text_size(px(TYPE_UI))
                        .font_weight(FontWeight::MEDIUM)
                        .child(model),
                )
        });
        Self::picker_detail_shell(
            provider,
            provider.name(),
            if configured {
                "This provider is configured, but remote execution is not connected in this build. It cannot be selected for a real run yet."
            } else {
                "Configure the endpoint, model, and API key before this provider can be used."
            }
            .to_owned(),
            model_box,
            if configured {
                "Open provider settings"
            } else {
                "Configure provider"
            },
            cx,
        )
    }

    fn model_picker(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let palette = AppAppearance::for_window(cx.window_appearance());
        let codex_ready = self.runtime.is_some();
        let codex_count = self.models.len();
        let codex_count_label = Self::model_count_label(codex_count);
        let kimi_configured = self.config.kimi_code.is_configured();
        let deepseek_configured = self.config.deepseek.is_configured();
        let opencode_ready = self.opencode_version.is_some();
        let opencode_detail = if !self.opencode_models.is_empty() {
            Self::model_count_label(self.opencode_models.len())
        } else {
            self.opencode_version
                .as_deref()
                .map(|version| format!("Installed {version}"))
                .unwrap_or_else(|| "Not installed".into())
        };
        let selected_model_id = self.selected_model_id.clone();
        let model_menu_provider = self.model_menu_provider;

        div()
            .absolute()
            .bottom(px(42.))
            .left(px(0.))
            .w(px(520.))
            .h(px(300.))
            .flex()
            .overflow_hidden()
            .rounded(px(RADIUS_LARGE))
            .bg(rgb(palette.surface))
            .border_1()
            .border_color(rgb(palette.border_strong))
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
                    .bg(rgb(palette.surface_subtle))
                    .border_r_1()
                    .border_color(rgb(palette.border))
                    .child(
                        div()
                            .h(px(26.))
                            .px_2()
                            .flex()
                            .items_center()
                            .text_size(px(TYPE_CAPTION))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(palette.muted_light))
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
                    ))
                    .child(self.model_picker_provider_row(
                        ProviderKind::OpenCode,
                        opencode_detail,
                        opencode_ready,
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
                                    .border_color(rgb(palette.border))
                                    .child(
                                        div()
                                            .text_size(px(TYPE_UI))
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .child("Codex models"),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(TYPE_CAPTION))
                                            .text_color(rgb(palette.muted_light))
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
                                        .text_color(rgb(palette.muted))
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
                                                        palette.blue_tint
                                                    } else {
                                                        palette.surface
                                                    }))
                                                    .hover(move |style| {
                                                        style.bg(rgb(palette.surface_subtle))
                                                    })
                                                    .active(move |style| {
                                                        style.bg(rgb(palette.surface_hover))
                                                    })
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
                                                                    .text_color(rgb(palette.muted))
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
                                                            .text_color(rgb(palette.blue))
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
                    })
                    .when(model_menu_provider == ProviderKind::OpenCode, |panel| {
                        panel.child(self.opencode_model_picker_detail(cx))
                    }),
            )
    }

    fn opencode_model_picker_detail(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let palette = AppAppearance::for_window(cx.window_appearance());
        if self.opencode_models.is_empty() {
            let description = match (
                self.opencode_version.as_deref(),
                self.opencode_models_error.as_deref(),
            ) {
                (Some(version), Some(error)) => format!(
                    "Installed version {version}, but the model list could not be loaded: {error}"
                ),
                (Some(version), None) => {
                    format!("Installed version {version}, but OpenCode returned no models.")
                }
                (None, _) => {
                    "OpenCode CLI is not installed. Install it to use this provider.".into()
                }
            };
            return Self::picker_detail_shell(
                ProviderKind::OpenCode,
                "OpenCode CLI",
                description,
                None::<gpui::Div>,
                "Open provider settings",
                cx,
            )
            .into_any_element();
        }
        let selected_id = self.selected_opencode_model_id.clone();
        let count_label = Self::model_count_label(self.opencode_models.len());
        let version_label = self.opencode_version.as_deref().unwrap_or("installed");
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .h(px(52.))
                    .flex_shrink_0()
                    .px_5()
                    .flex()
                    .items_center()
                    .justify_between()
                    .border_b_1()
                    .border_color(rgb(palette.border))
                    .child(
                        div()
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("OpenCode models"),
                    )
                    .child(
                        div()
                            .text_size(px(TYPE_CAPTION))
                            .text_color(rgb(palette.muted_light))
                            .child(format!("{count_label} · v{version_label}")),
                    ),
            )
            .child(
                div()
                    .id("opencode-model-list")
                    .min_h(px(0.))
                    .flex_grow()
                    .overflow_y_scroll()
                    .p_2()
                    .children(
                        self.opencode_models
                            .iter()
                            .enumerate()
                            .map(|(index, model)| {
                                let selected = selected_id.as_deref() == Some(model.id.as_str());
                                let id = model.id.clone();
                                div()
                                    .id(("opencode-model-option", index))
                                    .min_h(px(46.))
                                    .px_3()
                                    .py_2()
                                    .flex()
                                    .items_center()
                                    .justify_between()
                                    .rounded(px(RADIUS_MEDIUM))
                                    .cursor_pointer()
                                    .bg(rgb(if selected {
                                        palette.blue_tint
                                    } else {
                                        palette.surface
                                    }))
                                    .hover(move |style| style.bg(rgb(palette.surface_subtle)))
                                    .active(move |style| style.bg(rgb(palette.surface_hover)))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.select_opencode_model(id.clone());
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
                                                    .child(model.name.clone()),
                                            )
                                            .child(
                                                div()
                                                    .truncate()
                                                    .text_size(px(TYPE_CAPTION))
                                                    .text_color(rgb(palette.muted))
                                                    .child(model.id.clone()),
                                            ),
                                    )
                                    .child(
                                        div()
                                            .ml_3()
                                            .w(px(18.))
                                            .flex_shrink_0()
                                            .text_size(px(TYPE_UI))
                                            .text_color(rgb(palette.blue))
                                            .child(if selected { "✓" } else { "" }),
                                    )
                            }),
                    ),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .p_3()
                    .border_t_1()
                    .border_color(rgb(palette.border))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(Self::picker_settings_button(
                        ProviderKind::OpenCode,
                        "Open provider settings",
                        cx,
                    )),
            )
            .into_any_element()
    }

    fn provider_row(&self, provider: ProviderSummary, cx: &mut Context<Self>) -> impl IntoElement {
        let palette = AppAppearance::for_window(cx.window_appearance());
        let selected = self.selected_provider == Some(provider.kind);
        div()
            .id(("provider-row", provider.kind as usize))
            .h(px(60.))
            .px_4()
            .flex()
            .items_center()
            .gap_3()
            .cursor_pointer()
            .bg(rgb(if selected {
                palette.surface_subtle
            } else {
                palette.surface
            }))
            .hover(move |style| style.bg(rgb(palette.surface_hover)))
            .active(move |style| style.bg(rgb(palette.surface_pressed)))
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
                        palette.surface_subtle
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
                            .text_color(rgb(palette.muted))
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
                            .bg(rgb(palette.surface_subtle))
                            .text_size(px(TYPE_CAPTION))
                            .text_color(rgb(palette.muted))
                            .child(div().size(px(7.)).rounded_full().bg(rgb(
                                if provider.configured {
                                    palette.green
                                } else {
                                    palette.muted_light
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
        let palette = AppAppearance::for_window(cx.window_appearance());
        let expanded = self.selected_provider == Some(provider.kind);
        div()
            .overflow_hidden()
            .rounded(px(RADIUS_LARGE))
            .bg(rgb(palette.surface))
            .border_1()
            .border_color(rgb(palette.settings_separator))
            .child(self.provider_row(provider, cx))
            .when(expanded, |item| {
                item.child(
                    div()
                        .border_t_1()
                        .border_color(rgb(palette.border))
                        .child(detail),
                )
            })
    }

    fn settings_input(
        label: &'static str,
        input: Entity<ComposerInput>,
        palette: AppAppearance,
        trailing: Option<impl IntoElement>,
    ) -> impl IntoElement {
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
                    .gap_1()
                    .rounded(px(RADIUS_SMALL))
                    .bg(rgb(palette.surface))
                    .border_1()
                    .border_color(rgb(palette.border_strong))
                    .child(div().flex_1().child(input))
                    .when_some(trailing, |row, trailing| row.child(trailing)),
            )
    }

    fn remote_provider_detail(
        &mut self,
        provider: ProviderKind,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<J> {
        let palette = AppAppearance::for_window(cx.window_appearance());
        let (endpoint, api_key, configured) = match self.remote_provider(provider) {
            Some((endpoint, api_key, settings)) => (endpoint, api_key, settings.is_configured()),
            None => unreachable!("Codex and OpenCode have their own provider details"),
        };
        let masked = api_key.read(cx).is_secure();
        let toggle_api_key = api_key.clone();
        let reveal_button = div()
            .id(("reveal-api-key", provider as usize))
            .cursor(CursorStyle::PointingHand)
            .rounded(px(4.))
            .p_1()
            .hover(move |style| style.bg(rgb(palette.surface_hover)))
            .active(move |style| style.bg(rgb(palette.surface_pressed)))
            .on_click(cx.listener(move |_, _, _, cx| {
                toggle_api_key.update(cx, |input, cx| input.set_secure(!input.is_secure(), cx));
            }))
            .child(
                svg()
                    .path(if masked {
                        EYE_ICON_ASSET
                    } else {
                        EYE_OFF_ICON_ASSET
                    })
                    .size(px(16.))
                    .text_color(rgb(palette.muted)),
            );
        div()
            .px_4()
            .py_4()
            .flex()
            .flex_col()
            .gap_3()
            .bg(rgb(palette.surface_subtle))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(Self::settings_input(
                        "API endpoint",
                        endpoint,
                        palette,
                        None::<gpui::Div>,
                    ))
                    .child(Self::settings_input(
                        "API key",
                        api_key,
                        palette,
                        Some(reveal_button),
                    ))
                    .child(self.remote_model_picker(provider, palette, cx)),
            )
            .child(
                div()
                    .px_3()
                    .text_size(px(TYPE_CAPTION))
                    .line_height(px(16.))
                    .text_color(rgb(palette.muted))
                    .child(if configured {
                        "The API key is saved. Enter a new one to replace it."
                    } else {
                        "Enter the API endpoint and API key, then choose a model."
                    }),
            )
            .when_some(
                self.settings_notice.clone(),
                |content, (success, notice)| {
                    content.child(
                        div()
                            .px_3()
                            .py_2()
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(rgb(if success {
                                palette.blue_tint
                            } else {
                                palette.conversation.failure_surface
                            }))
                            .text_size(px(TYPE_UI))
                            .text_color(rgb(if success { palette.green } else { palette.red }))
                            .child(notice),
                    )
                },
            )
            .child(
                div().flex().items_center().justify_end().pt_1().child(
                    div()
                        .id(("save-provider", provider as usize))
                        .h(px(28.))
                        .px_4()
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(RADIUS_SMALL))
                        .cursor_pointer()
                        .bg(rgb(palette.blue))
                        .text_size(px(TYPE_CAPTION))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(rgb(0xffffff))
                        .hover(move |style| style.bg(rgb(palette.blue_hover)))
                        .active(move |style| style.bg(rgb(palette.blue_active)))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.save_remote_provider(provider, cx);
                            cx.notify();
                        }))
                        .child("Save"),
                ),
            )
    }

    fn remote_model_picker(
        &mut self,
        provider: ProviderKind,
        palette: AppAppearance,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let selected_model = match self.remote_provider(provider) {
            Some((_, _, settings)) => settings.model.clone(),
            None => unreachable!("Codex and OpenCode have their own picker details"),
        };
        div()
            .pt_1()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::MEDIUM)
                            .child("Model"),
                    )
                    .child(
                        div()
                            .id(("refresh-models", provider as usize))
                            .h(px(26.))
                            .px_2()
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(RADIUS_SMALL))
                            .cursor_pointer()
                            .bg(rgb(palette.settings_control))
                            .text_size(px(TYPE_CAPTION))
                            .font_weight(FontWeight::MEDIUM)
                            .hover(move |style| style.bg(rgb(palette.surface_hover)))
                            .active(move |style| style.bg(rgb(palette.surface_pressed)))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.refresh_remote_models(provider, cx);
                                cx.notify();
                            }))
                            .child(if self.remote_models_loading {
                                "Fetching…"
                            } else {
                                "Refresh"
                            }),
                    ),
            )
            .when_some(self.remote_models_error.clone(), |content, error| {
                content.child(
                    div()
                        .px_3()
                        .py_2()
                        .rounded(px(RADIUS_SMALL))
                        .bg(rgb(palette.conversation.failure_surface))
                        .text_size(px(TYPE_CAPTION))
                        .text_color(rgb(palette.red))
                        .child(error),
                )
            })
            .when(self.remote_models_loading, |content| {
                content.child(
                    div()
                        .px_3()
                        .py_2()
                        .text_size(px(TYPE_UI))
                        .text_color(rgb(palette.muted))
                        .child("Fetching available models…"),
                )
            })
            .when(
                !self.remote_models_loading && self.remote_models_error.is_none(),
                |content| {
                    if self.remote_models.is_empty() {
                        content.child(
                            div()
                                .px_3()
                                .py_2()
                                .text_size(px(TYPE_UI))
                                .text_color(rgb(palette.muted))
                                .child("No models loaded yet."),
                        )
                    } else {
                        content.child(
                            div()
                                .id(("remote-model-list", provider as usize))
                                .max_h(px(240.))
                                .overflow_y_scroll()
                                .flex()
                                .flex_col()
                                .gap_1()
                                .children(self.remote_models.iter().enumerate().map(
                                    |(index, model)| {
                                        let model_id = model.clone();
                                        let selected = model_id == selected_model;
                                        div()
                                            .id(("remote-model-option", index))
                                            .h(px(34.))
                                            .px_3()
                                            .flex()
                                            .items_center()
                                            .rounded(px(RADIUS_SMALL))
                                            .cursor_pointer()
                                            .bg(rgb(if selected {
                                                palette.blue_tint
                                            } else {
                                                palette.surface
                                            }))
                                            .hover(move |style| {
                                                style.bg(rgb(palette.surface_hover))
                                            })
                                            .active(move |style| {
                                                style.bg(rgb(palette.surface_pressed))
                                            })
                                            .on_click(cx.listener(move |this, _, _, cx| {
                                                this.select_remote_model(
                                                    provider,
                                                    model_id.clone(),
                                                );
                                                cx.notify();
                                            }))
                                            .child(
                                                div()
                                                    .flex_1()
                                                    .truncate()
                                                    .text_size(px(TYPE_UI))
                                                    .text_color(rgb(if selected {
                                                        palette.text
                                                    } else {
                                                        palette.muted
                                                    }))
                                                    .child(model.clone()),
                                            )
                                    },
                                )),
                        )
                    }
                },
            )
    }

    fn codex_provider_detail(&self, cx: &mut Context<Self>) -> impl IntoElement + use<J> {
        let palette = AppAppearance::for_window(cx.window_appearance());
        let connected = self.runtime.is_some();
        let installation = self.runtime.as_ref().map(CodexRuntime::installation);
        let model_count = self.models.len();
        div()
            .px_4()
            .py_4()
            .flex()
            .flex_col()
            .gap_3()
            .bg(rgb(palette.surface_subtle))
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
                    .bg(rgb(palette.surface))
                    .border_1()
                    .border_color(rgb(palette.settings_separator))
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
                                    .text_color(rgb(palette.muted))
                                    .child(div().size(px(8.)).rounded_full().bg(rgb(
                                        if connected {
                                            palette.green
                                        } else {
                                            palette.red
                                        },
                                    )))
                                    .child(if connected {
                                        "Connected"
                                    } else {
                                        "Unavailable"
                                    }),
                            ),
                    )
                    .child(div().h(px(1.)).ml(px(16.)).bg(rgb(palette.border)))
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
                                                .text_color(rgb(palette.muted))
                                                .child(installation.version.clone()),
                                        )
                                        .child(
                                            div()
                                                .text_size(px(TYPE_CAPTION))
                                                .text_color(rgb(palette.muted_light))
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
                                .border_color(rgb(palette.border))
                                .text_size(px(TYPE_CAPTION))
                                .line_height(px(16.))
                                .text_color(rgb(palette.red))
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
                            .text_color(rgb(palette.muted_light))
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
                    .bg(rgb(palette.surface))
                    .border_1()
                    .border_color(rgb(palette.settings_separator))
                    .when(model_count == 0, |list| {
                        list.child(
                            div()
                                .h(px(44.))
                                .px_3()
                                .flex()
                                .items_center()
                                .text_size(px(TYPE_UI))
                                .text_color(rgb(palette.muted))
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
                                .bg(rgb(palette.surface))
                                .hover(move |style| style.bg(rgb(palette.surface_hover)))
                                .active(move |style| style.bg(rgb(palette.surface_pressed)))
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
                                        .text_color(rgb(palette.settings_selection))
                                        .child(if selected { "✓" } else { "" }),
                                )
                                .when(index + 1 < model_count, |row| {
                                    row.border_b_1().border_color(rgb(palette.border))
                                })
                        }))
                    }),
            )
    }

    fn opencode_provider_detail(&self, cx: &mut Context<Self>) -> impl IntoElement + use<J> {
        let palette = AppAppearance::for_window(cx.window_appearance());
        let installed = self.opencode_version.is_some();
        let status = self
            .opencode_version
            .as_deref()
            .map(|version| format!("Installed version {version}"))
            .unwrap_or_else(|| "Not installed".into());
        div()
            .px_4()
            .py_4()
            .flex()
            .flex_col()
            .gap_3()
            .bg(rgb(palette.surface_subtle))
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
                    .bg(rgb(palette.surface))
                    .border_1()
                    .border_color(rgb(palette.settings_separator))
                    .child(
                        div()
                            .h(px(42.))
                            .px_3()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .text_size(px(TYPE_UI))
                                    .text_color(rgb(palette.muted))
                                    .child("opencode acp"),
                            )
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .child(div().size(px(7.)).rounded_full().bg(rgb(
                                        if installed {
                                            palette.green
                                        } else {
                                            palette.muted_light
                                        },
                                    )))
                                    .child(
                                        div()
                                            .text_size(px(TYPE_UI))
                                            .font_weight(FontWeight::MEDIUM)
                                            .child(status),
                                    ),
                            ),
                    ),
            )
            .child(
                div()
                    .px_3()
                    .text_size(px(TYPE_CAPTION))
                    .line_height(px(16.))
                    .text_color(rgb(palette.muted))
                    .child(if installed {
                        match (
                            self.opencode_models_error.as_deref(),
                            self.selected_opencode_model(),
                        ) {
                            (Some(error), _) => {
                                format!("The model list could not be loaded: {error}")
                            }
                            (None, Some(model)) => format!(
                                "{} available · selected: {}. Models, credentials, and \
                                 tools come from OpenCode's own configuration; change \
                                 the selection from the model menu.",
                                Self::model_count_label(self.opencode_models.len()),
                                model.name
                            ),
                            (None, None) => "OpenCode returned no models.".into(),
                        }
                    } else {
                        "Install the OpenCode CLI to use it as a provider. \
                         Models, credentials, and tools come from OpenCode's own \
                         configuration; select them inside OpenCode."
                            .into()
                    }),
            )
    }

    fn settings_page(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let palette = AppAppearance::for_window(cx.window_appearance());
        let connected = self.runtime.is_some();
        let kimi_configured = self.config.kimi_code.is_configured();
        let deepseek_configured = self.config.deepseek.is_configured();
        let opencode_configured = self.opencode_version.is_some();
        let kimi_detail = self.remote_provider_detail(ProviderKind::KimiCode, cx);
        let deepseek_detail = self.remote_provider_detail(ProviderKind::DeepSeek, cx);
        div()
            .absolute()
            .top(px(0.))
            .right(px(0.))
            .bottom(px(0.))
            .left(px(0.))
            .flex()
            .bg(rgb(palette.settings_canvas))
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
                    .border_color(rgb(palette.settings_separator))
                    .bg(rgb(palette.settings_sidebar))
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
                            .bg(rgb(palette.surface_subtle))
                            .border_1()
                            .border_color(rgb(palette.border_strong))
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(palette.text))
                            .hover(move |style| style.bg(rgb(palette.surface)))
                            .active(move |style| style.bg(rgb(palette.surface_pressed)))
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
                            .text_color(rgb(palette.muted))
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
                            .bg(rgb(palette.settings_selection))
                            .text_size(px(TYPE_UI))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(0xffffff))
                            .hover(move |style| style.bg(rgb(palette.blue_hover)))
                            .active(move |style| style.bg(rgb(palette.blue_active)))
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
                            .border_color(rgb(palette.settings_separator))
                            .bg(rgb(palette.surface))
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
                                            .text_color(rgb(palette.muted))
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
                                            configured: kimi_configured,
                                            status: if kimi_configured {
                                                "Configured"
                                            } else {
                                                "Not configured"
                                            },
                                        },
                                        kimi_detail,
                                        cx,
                                    ))
                                    .child(self.provider_accordion_item(
                                        ProviderSummary {
                                            kind: ProviderKind::DeepSeek,
                                            name: "DeepSeek",
                                            description: "OpenAI-compatible API",
                                            icon: DEEPSEEK_ICON_ASSET,
                                            configured: deepseek_configured,
                                            status: if deepseek_configured {
                                                "Configured"
                                            } else {
                                                "Not configured"
                                            },
                                        },
                                        deepseek_detail,
                                        cx,
                                    ))
                                    .child(self.provider_accordion_item(
                                        ProviderSummary {
                                            kind: ProviderKind::OpenCode,
                                            name: "OpenCode",
                                            description: "Local CLI agent (ACP)",
                                            icon: OPENCODE_ICON_ASSET,
                                            configured: opencode_configured,
                                            status: if opencode_configured {
                                                "Installed"
                                            } else {
                                                "Not installed"
                                            },
                                        },
                                        self.opencode_provider_detail(cx),
                                        cx,
                                    )),
                            ),
                    ),
            )
            )
    }
}

impl<J: EventJournal + ProjectStore> Render for DiscoWorkspace<J> {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let palette = AppAppearance::for_window(cx.window_appearance());
        let turns = self
            .active_task()
            .map_or_else(Vec::new, |task| task.turns().to_vec());
        let has_run = !turns.is_empty();
        // Children of a scroll container measure against unbounded width, so
        // percentage widths never constrain text. Resolve the chat column to
        // concrete pixels from the viewport instead.
        let chat_column_width = (window.viewport_size().width - px(APP_SIDEBAR_WIDTH) - px(56.))
            .min(px(CHAT_COLUMN_WIDTH))
            .max(px(240.));
        let title = if has_run {
            Self::compact_title(
                self.active_task()
                    .and_then(ChatConversation::title_prompt)
                    .unwrap_or_default(),
            )
        } else {
            "New conversation".into()
        };
        let active_task_can_begin = self
            .active_task()
            .is_some_and(ChatConversation::can_begin_turn);
        let can_submit =
            !self.composer.read(cx).is_empty() && active_task_can_begin && !self.run_in_progress();
        let is_working = self.run_in_progress();
        // Message-scroller behavior: a pending jump (new turn, task switch,
        // restore) lands the viewport on the live edge, and while a run streams
        // we keep following the live edge only while the reader stayed there.
        // Scrolling away releases the follow so the reader is never moved
        // against their intent; scrolling back re-engages it.
        let chat_distance_from_bottom =
            self.chat_scroll.offset().y + self.chat_scroll.max_offset().height;
        let chat_at_bottom = chat_distance_from_bottom.abs() <= px(32.);
        if self.chat_scroll_pending {
            self.chat_scroll_pending = false;
            self.chat_scroll.scroll_to_bottom();
        } else if is_working && has_run && chat_at_bottom {
            self.chat_scroll.scroll_to_bottom();
        }
        let action_enabled = if is_working {
            !self.stop_requested
        } else {
            can_submit
        };
        let selected_model_name = match self.selected_chat_provider {
            ProviderKind::OpenCode => self
                .selected_opencode_model()
                .map(|model| model.name.clone())
                .unwrap_or_else(|| "OpenCode unavailable".into()),
            _ => self
                .selected_model()
                .map(|model| model.display_name.clone())
                .unwrap_or_else(|| "Codex unavailable".into()),
        };
        let selected_chat_provider = self.selected_chat_provider;
        let effort_options = self
            .selected_model()
            .map(|model| model.reasoning_efforts.clone())
            .unwrap_or_default();
        let selected_effort = self.selected_effort.clone();
        let sidebar_focus_visible = self.sidebar_focus_handle.is_focused(window);
        let composer_appearance = palette.composer;
        let composer_focused = self.composer.read(cx).focus_handle(cx).is_focused(window);

        div()
            .size_full()
            .relative()
            .flex()
            .bg(rgb(palette.canvas))
            .font_family("-apple-system")
            .text_size(px(TYPE_UI))
            .text_color(rgb(palette.text))
            .child(self.sidebar(sidebar_focus_visible, cx))
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
                            .border_color(rgb(palette.border))
                            .bg(rgb(palette.surface))
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
                                    .bg(rgb(palette.surface_subtle))
                                    .border_1()
                                    .border_color(rgb(palette.border))
                                    .text_size(px(TYPE_CAPTION))
                                    .text_color(rgb(palette.muted))
                                    .child(
                                        div()
                                            .size(px(6.))
                                            .rounded_full()
                                            .bg(rgb(self.status_color(palette))),
                                    )
                                    .child(self.status_label()),
                            ),
                    )
                    .child(
                        div()
                            .relative()
                            .min_h(px(0.))
                            .flex_grow()
                            .child(
                                div()
                                    .id("chat-scroll")
                                    .track_scroll(&self.chat_scroll)
                                    .on_scroll_wheel(cx.listener(|_, _: &ScrollWheelEvent, _, cx| {
                                        // Re-evaluate the live-edge state so the
                                        // scroll-to-end control tracks the reader.
                                        cx.notify();
                                    }))
                                    .min_h(px(0.))
                                    .h_full()
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
                                                        .text_color(rgb(palette.muted))
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
                                    {
                                        let mut chat_content = div()
                                            .w(chat_column_width)
                                            .mx_auto()
                                            .flex()
                                            .flex_col()
                                            .gap_8();
                                        for turn in turns {
                                            chat_content = chat_content.child(
                                                self.conversation_turn(turn, palette, cx),
                                            );
                                        }
                                        chat_content
                                    },
                                )
                            })
                            )
                            .when(has_run && !chat_at_bottom, |region| {
                                region.child(
                                    div()
                                        .absolute()
                                        .bottom(px(14.))
                                        .left_0()
                                        .right_0()
                                        .flex()
                                        .justify_center()
                                        .child(
                                            div()
                                                .id("chat-scroll-to-bottom")
                                                .size(px(30.))
                                                .flex()
                                                .items_center()
                                                .justify_center()
                                                .rounded_full()
                                                .bg(rgb(palette.surface))
                                                .border_1()
                                                .border_color(rgb(palette.border_strong))
                                                .shadow_md()
                                                .cursor_pointer()
                                                .hover(move |style| {
                                                    style.bg(rgb(palette.surface_hover))
                                                })
                                                .active(move |style| {
                                                    style.bg(rgb(palette.surface_pressed))
                                                })
                                                .on_click(cx.listener(|this, _, _, cx| {
                                                    this.chat_scroll.scroll_to_bottom();
                                                    cx.notify();
                                                }))
                                                .child(img(CHEVRON_DOWN_ASSET).size(px(14.))),
                                        ),
                                )
                            })
                    )
                    .child(
                        div()
                            .px_6()
                            .pb_4()
                            .pt_2()
                            .child(
                                div()
                                    .relative()
                                    .w_full()
                                    .max_w(px(CHAT_COLUMN_WIDTH))
                                    .h(px(100.))
                                    .mx_auto()
                                    .child(
                                        div()
                                            .size_full()
                                            .p_2()
                                            .flex()
                                            .flex_col()
                                            .justify_between()
                                            .rounded(px(RADIUS_LARGE))
                                            .bg(rgb(composer_appearance.surface))
                                            .border_1()
                                            .border_color(rgb(if composer_focused {
                                                composer_appearance.focus_border
                                            } else {
                                                composer_appearance.border
                                            }))
                                            .shadow_sm()
                                            .child(
                                                div()
                                                    .min_w(px(0.))
                                                    .px_1()
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
                                                                    .h(px(28.))
                                                                    .max_w(px(240.))
                                                                    .px_2()
                                                                    .flex()
                                                                    .items_center()
                                                                    .gap(px(6.))
                                                                    .rounded(px(RADIUS_SMALL))
                                                                    .bg(rgb(composer_appearance.control))
                                                                    .border_1()
                                                                    .border_color(rgb(composer_appearance.control_border))
                                                                    .cursor_pointer()
                                                                    .hover(move |style| {
                                                                        style.bg(rgb(composer_appearance.control_hover))
                                                                    })
                                                                    .active(move |style| {
                                                                        style.bg(rgb(composer_appearance.control_pressed))
                                                                    })
                                                                    .on_click(cx.listener(|this, _, _, cx| {
                                                                        this.model_menu_open = !this.model_menu_open;
                                                                        this.model_menu_provider = this.selected_chat_provider;
                                                                        this.thinking_menu_open = false;
                                                                        cx.notify();
                                                                    }))
                                                                    .child(
                                                                        div()
                                                                            .size(px(16.))
                                                                            .flex_shrink_0()
                                                                            .rounded(px(5.))
                                                                            .overflow_hidden()
                                                                            .child(img(selected_chat_provider.icon()).size_full()),
                                                                    )
                                                                    .child(
                                                                        div()
                                                                            .min_w(px(0.))
                                                                            .truncate()
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
                                                            .when(
                                                                selected_chat_provider
                                                                    == ProviderKind::Codex,
                                                                |controls| {
                                                                    controls.child(
                                                                        div()
                                                                            .id("thinking-menu-trigger")
                                                                    .h(px(28.))
                                                                    .px_2()
                                                                    .flex()
                                                                    .items_center()
                                                                    .gap(px(6.))
                                                                    .rounded(px(RADIUS_SMALL))
                                                                    .bg(rgb(composer_appearance.control))
                                                                    .border_1()
                                                                    .border_color(rgb(composer_appearance.control_border))
                                                                    .cursor_pointer()
                                                                    .hover(move |style| {
                                                                        style.bg(rgb(composer_appearance.control_hover))
                                                                    })
                                                                    .active(move |style| {
                                                                        style.bg(rgb(composer_appearance.control_pressed))
                                                                    })
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
                                                                    )
                                                                }),
                                                    )
                                                    .child(
                                                        div()
                                                            .id("composer-action")
                                                            .size(px(28.))
                                                            .flex()
                                                            .items_center()
                                                            .justify_center()
                                                            .rounded_full()
                                                            .bg(rgb(if is_working {
                                                                0x2c2c2e
                                                            } else if can_submit {
                                                                palette.blue
                                                            } else {
                                                                composer_appearance.action_disabled
                                                            }))
                                                            .when(action_enabled, |button| {
                                                                button
                                                                    .cursor_pointer()
                                                                    .hover(move |style| {
                                                                        style.bg(rgb(if is_working {
                                                                            0x3a3a3c
                                                                        } else {
                                                                            palette.blue_hover
                                                                        }))
                                                                    })
                                                                    .active(move |style| {
                                                                        style
                                                                            .bg(rgb(if is_working {
                                                                                0x48484a
                                                                            } else {
                                                                                palette.blue_active
                                                                            }))
                                                                            .opacity(0.82)
                                                                    })
                                                            })
                                                            .on_click(cx.listener(|this, _, _, cx| {
                                                                if !this.run_in_progress()
                                                                    && this
                                                                        .active_task()
                                                                        .is_some_and(
                                                                            ChatConversation::can_begin_turn,
                                                                        )
                                                                {
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
                                                .bottom(px(42.))
                                                .left(px(164.))
                                                .w(px(220.))
                                                .p_2()
                                                .rounded(px(RADIUS_LARGE))
                                                .bg(rgb(palette.surface))
                                                .border_1()
                                                .border_color(rgb(palette.border_strong))
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
                                                        .bg(rgb(if selected {
                                                            palette.blue_tint
                                                        } else {
                                                            palette.surface
                                                        }))
                                                        .hover(move |style| {
                                                            style.bg(rgb(palette.surface_hover))
                                                        })
                                                        .active(move |style| {
                                                            style.bg(rgb(palette.surface_pressed))
                                                        })
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
            .when_some(self.project_context_menu, |root, menu| {
                root.child(
                    deferred(
                        anchored()
                            .position(menu.position)
                            .snap_to_window_with_margin(px(8.))
                            .child(self.render_project_context_menu(menu, cx)),
                    )
                    .with_priority(1),
                )
            })
    }
}

/// Drains streaming [`TurnEvent`]s from an engine turn onto the workspace
/// projection. Polls with a short timer so the foreground thread is never
/// blocked; the loop ends once the engine drops its sender, which happens only
/// after every queued event has been consumed.
///
/// Each poll cycle drains every queued event in one workspace update, merging
/// consecutive assistant/reasoning deltas into a single event. A burst of
/// per-token deltas therefore costs one journal write and one redraw per
/// cycle instead of one per token.
async fn consume_turn_events<J: EventJournal + ProjectStore>(
    workspace: &WeakEntity<DiscoWorkspace<J>>,
    run_id: RunId,
    events: std::sync::mpsc::Receiver<TurnEvent>,
    cx: &mut AsyncApp,
) {
    loop {
        let mut batch: Vec<TurnEvent> = Vec::new();
        let mut disconnected = false;
        loop {
            match events.try_recv() {
                Ok(event) => push_coalesced(&mut batch, event),
                Err(std::sync::mpsc::TryRecvError::Empty) => break,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    disconnected = true;
                    break;
                }
            }
        }
        if !batch.is_empty()
            && workspace
                .update(cx, |workspace, cx| {
                    for event in batch {
                        workspace.apply_turn_event(run_id, event);
                    }
                    cx.notify();
                })
                .is_err()
        {
            break;
        }
        if disconnected {
            break;
        }
        cx.background_executor()
            .timer(std::time::Duration::from_millis(30))
            .await;
    }
}

/// Appends `event` to `batch`, merging it into the trailing event when both
/// are text deltas of the same kind so consecutive deltas persist as one
/// journal event.
fn push_coalesced(batch: &mut Vec<TurnEvent>, event: TurnEvent) {
    if let Some(last) = batch.last_mut() {
        match (last, &event) {
            (TurnEvent::AssistantDelta { text: acc }, TurnEvent::AssistantDelta { text }) => {
                acc.push_str(text);
                return;
            }
            (TurnEvent::ReasoningDelta { text: acc }, TurnEvent::ReasoningDelta { text }) => {
                acc.push_str(text);
                return;
            }
            _ => {}
        }
    }
    batch.push(event);
}

#[cfg(test)]
mod tests {
    use super::{
        AppAppearance, AppConfig, ChatConversation, ComposerInput, DiscoWorkspace, OpenCodeModel,
        push_coalesced,
    };
    use disco_domain::{
        ActivityInfo, EngineKind, Project, RunEvent, RunEventPayload, RunId, RunStatus, SessionId,
        TokenUsage, TurnEvent,
    };
    use disco_kernel::{EventJournal, MemoryJournal, ProjectStore, RunProjection};
    use gpui::{AppContext, TestAppContext, WindowAppearance};
    use std::path::{Path, PathBuf};

    #[test]
    fn project_name_comes_from_the_root_directory() {
        assert_eq!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::project_name(Path::new(
                "/Users/example/code/disco"
            )),
            "disco"
        );
    }

    #[test]
    fn macos_window_appearance_selects_the_matching_palette() {
        let light = AppAppearance::for_window(WindowAppearance::VibrantLight);
        let dark = AppAppearance::for_window(WindowAppearance::VibrantDark);

        assert_eq!(light.canvas, 0xffffff);
        assert_eq!(light.blue, 0x007aff);
        assert_eq!(dark.canvas, 0x1c1c1e);
        assert_eq!(dark.blue, 0x0a84ff);
        assert_ne!(light.sidebar.background, dark.sidebar.background);
        assert_ne!(light.composer.surface, dark.composer.surface);
    }

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
    fn token_counts_use_readable_grouping() {
        assert_eq!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::token_count_label(14),
            "14"
        );
        assert_eq!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::token_count_label(18_051),
            "18,051"
        );
        assert_eq!(
            DiscoWorkspace::<disco_kernel::MemoryJournal>::token_count_label(1_234_567),
            "1,234,567"
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

    #[test]
    fn consecutive_deltas_coalesce_into_one_event_per_kind() {
        let mut batch = Vec::new();
        push_coalesced(&mut batch, TurnEvent::AssistantDelta { text: "a".into() });
        push_coalesced(&mut batch, TurnEvent::AssistantDelta { text: "b".into() });
        push_coalesced(&mut batch, TurnEvent::ReasoningDelta { text: "t".into() });
        push_coalesced(&mut batch, TurnEvent::AssistantDelta { text: "c".into() });
        push_coalesced(&mut batch, TurnEvent::Finished { interrupted: false });
        assert_eq!(
            batch,
            vec![
                TurnEvent::AssistantDelta { text: "ab".into() },
                TurnEvent::ReasoningDelta { text: "t".into() },
                TurnEvent::AssistantDelta { text: "c".into() },
                TurnEvent::Finished { interrupted: false },
            ]
        );
    }

    #[gpui::test]
    fn turn_events_project_onto_durable_run_events(cx: &mut TestAppContext) {
        let workspace = cx.update(|cx| {
            let composer = cx.new(ComposerInput::new);
            cx.new(|cx| {
                DiscoWorkspace::new(
                    MemoryJournal::default(),
                    composer,
                    PathBuf::from(format!("/tmp/disco-settings-{}.json", RunId::new())),
                    PathBuf::from(format!("/tmp/disco-project-{}", RunId::new())),
                    Err("Codex unavailable in test".into()),
                    None,
                    Ok(Vec::new()),
                    cx,
                )
            })
        });

        let run_id = RunId::new();
        let interrupted_run_id = RunId::new();
        let failed_run_id = RunId::new();
        cx.update(|cx| {
            workspace.update(cx, |workspace, _| {
                for id in [run_id, interrupted_run_id, failed_run_id] {
                    workspace
                        .kernel
                        .start_run(
                            id,
                            workspace.active_project_id,
                            workspace.active_session_id,
                            EngineKind::Codex,
                            None,
                            "Stream this",
                        )
                        .expect("run should start");
                }
                workspace.apply_turn_event(
                    run_id,
                    TurnEvent::ThreadAttached {
                        thread_id: "thread-9".into(),
                    },
                );
                workspace.apply_turn_event(
                    run_id,
                    TurnEvent::ReasoningDelta {
                        text: "Thinking ".into(),
                    },
                );
                workspace.apply_turn_event(
                    run_id,
                    TurnEvent::AssistantDelta {
                        text: "Hello ".into(),
                    },
                );
                workspace.apply_turn_event(
                    run_id,
                    TurnEvent::AssistantDelta {
                        text: "world".into(),
                    },
                );
                workspace.apply_turn_event(
                    run_id,
                    TurnEvent::ActivityStarted {
                        activity: ActivityInfo {
                            id: "call-1".into(),
                            title: "Read file".into(),
                            detail: "src/main.rs".into(),
                        },
                    },
                );
                workspace.apply_turn_event(
                    run_id,
                    TurnEvent::ActivityCompleted {
                        id: "call-1".into(),
                        success: true,
                        output: "fn main".into(),
                    },
                );
                workspace.apply_turn_event(
                    run_id,
                    TurnEvent::UsageUpdated {
                        usage: TokenUsage {
                            input_tokens: 10,
                            output_tokens: 5,
                            total_tokens: 15,
                        },
                    },
                );
                workspace.apply_turn_event(run_id, TurnEvent::Finished { interrupted: false });
                workspace.apply_turn_event(
                    interrupted_run_id,
                    TurnEvent::Finished { interrupted: true },
                );
                workspace.apply_turn_event(
                    failed_run_id,
                    TurnEvent::Failed {
                        code: "codex_turn_failed".into(),
                        message: "Codex turn failed: boom".into(),
                    },
                );
            });
        });

        cx.update(|cx| {
            let workspace = workspace.read(cx);
            let projection = workspace
                .kernel
                .restore(run_id)
                .expect("completed run should restore");
            assert_eq!(projection.status, RunStatus::Completed);
            assert_eq!(projection.codex_thread_id.as_deref(), Some("thread-9"));
            assert_eq!(projection.assistant_text, "Hello world");
            assert_eq!(projection.reasoning_text, "Thinking ");
            assert_eq!(projection.usage.total_tokens, 15);
            assert_eq!(projection.activities.len(), 1);

            let interrupted = workspace
                .kernel
                .restore(interrupted_run_id)
                .expect("interrupted run should restore");
            assert_eq!(interrupted.status, RunStatus::Cancelled);

            let failed = workspace
                .kernel
                .restore(failed_run_id)
                .expect("failed run should restore");
            assert_eq!(failed.status, RunStatus::Failed);
            assert_eq!(
                failed.failure_message.as_deref(),
                Some("Codex turn failed: boom")
            );
        });
    }

    #[gpui::test]
    fn switching_tasks_preserves_each_draft(cx: &mut TestAppContext) {
        let marker = RunId::new();
        let (composer, workspace) = cx.update(|cx| {
            let composer = cx.new(ComposerInput::new);
            let workspace = cx.new(|cx| {
                DiscoWorkspace::new(
                    MemoryJournal::default(),
                    composer.clone(),
                    PathBuf::from(format!("/tmp/disco-settings-{marker}.json")),
                    PathBuf::from(format!("/tmp/disco-project-{marker}")),
                    Err("Codex unavailable in test".into()),
                    None,
                    Ok(Vec::new()),
                    cx,
                )
            });
            (composer, workspace)
        });

        let first_session = cx.update(|cx| {
            composer.update(cx, |composer, cx| composer.set_content("first draft", cx));
            workspace.update(cx, |workspace, cx| {
                let first_session = workspace.active_session_id;
                workspace.new_task_for_project(workspace.active_project_id, cx);
                first_session
            })
        });
        cx.update(|cx| {
            assert_eq!(composer.read(cx).content(), "");
            composer.update(cx, |composer, cx| composer.set_content("second draft", cx));
            workspace.update(cx, |workspace, cx| {
                workspace.select_task(workspace.active_project_id, first_session, cx);
            });
            assert_eq!(composer.read(cx).content(), "first draft");
            workspace.update(cx, |workspace, cx| {
                workspace.select_project(workspace.active_project_id, cx);
            });
            assert_eq!(composer.read(cx).content(), "first draft");
        });
    }

    #[gpui::test]
    fn startup_restores_tasks_and_codex_thread_ids(cx: &mut TestAppContext) {
        let journal = MemoryJournal::default();
        let project_path = PathBuf::from(format!("/tmp/disco-project-{}", RunId::new()));
        let project = journal
            .register_project(Project::new("restored", project_path.clone()))
            .expect("project should register");
        let session_id = SessionId::new();
        let run_id = RunId::new();
        for event in [
            RunEvent::new(
                run_id,
                0,
                RunEventPayload::RunStarted {
                    project_id: None,
                    session_id,
                    engine: EngineKind::Codex,
                    workspace: Some(project_path.to_string_lossy().into_owned()),
                    prompt: "Restore this task".into(),
                },
            ),
            RunEvent::new(
                run_id,
                1,
                RunEventPayload::CodexThreadAttached {
                    thread_id: "thread-restored".into(),
                },
            ),
            RunEvent::new(run_id, 2, RunEventPayload::RunCompleted),
        ] {
            journal.append(&event).expect("event should persist");
        }

        let workspace = cx.update(|cx| {
            let composer = cx.new(ComposerInput::new);
            cx.new(|cx| {
                DiscoWorkspace::new(
                    journal,
                    composer,
                    PathBuf::from(format!("/tmp/disco-settings-{}.json", RunId::new())),
                    project_path,
                    Err("Codex unavailable in test".into()),
                    None,
                    Ok(Vec::new()),
                    cx,
                )
            })
        });

        cx.update(|cx| {
            let workspace = workspace.read(cx);
            let task = workspace.active_task().expect("task should restore");
            assert_eq!(workspace.active_project_id, project.id);
            assert_eq!(task.session_id, session_id);
            assert_eq!(task.title_prompt(), Some("Restore this task"));
            assert_eq!(task.codex_thread_id.as_deref(), Some("thread-restored"));
        });
    }

    #[gpui::test]
    fn reopening_the_active_project_does_not_create_a_task(cx: &mut TestAppContext) {
        let project_path = std::env::current_dir().expect("working directory should exist");
        let (composer, workspace) = cx.update(|cx| {
            let composer = cx.new(ComposerInput::new);
            let workspace = cx.new(|cx| {
                DiscoWorkspace::new(
                    MemoryJournal::default(),
                    composer.clone(),
                    PathBuf::from(format!("/tmp/disco-settings-{}.json", RunId::new())),
                    project_path.clone(),
                    Err("Codex unavailable in test".into()),
                    None,
                    Ok(Vec::new()),
                    cx,
                )
            });
            (composer, workspace)
        });

        cx.update(|cx| {
            composer.update(cx, |composer, cx| composer.set_content("keep this", cx));
            let (session_id, task_count) = workspace.update(cx, |workspace, cx| {
                let session_id = workspace.active_session_id;
                let task_count = workspace
                    .active_project()
                    .expect("active project should exist")
                    .tasks
                    .len();
                workspace.register_project_path(project_path, cx);
                (session_id, task_count)
            });
            let workspace = workspace.read(cx);
            assert_eq!(workspace.active_session_id, session_id);
            assert_eq!(
                workspace
                    .active_project()
                    .expect("active project should still exist")
                    .tasks
                    .len(),
                task_count
            );
            assert_eq!(composer.read(cx).content(), "keep this");
        });
    }

    #[gpui::test]
    fn sidebar_navigation_follows_the_visible_project_hierarchy(cx: &mut TestAppContext) {
        let workspace = cx.update(|cx| {
            let composer = cx.new(ComposerInput::new);
            cx.new(|cx| {
                DiscoWorkspace::new(
                    MemoryJournal::default(),
                    composer,
                    PathBuf::from(format!("/tmp/disco-settings-{}.json", RunId::new())),
                    PathBuf::from(format!("/tmp/disco-project-{}", RunId::new())),
                    Err("Codex unavailable in test".into()),
                    None,
                    Ok(Vec::new()),
                    cx,
                )
            })
        });

        cx.update(|cx| {
            workspace.update(cx, |workspace, cx| {
                let first_session = workspace.active_session_id;
                let project_id = workspace.active_project_id;
                workspace.new_task_for_project(project_id, cx);
                let second_session = workspace.active_session_id;

                workspace.move_sidebar_selection(1, cx);
                assert_eq!(workspace.active_session_id, first_session);
                assert_eq!(
                    workspace.sidebar_focused_item,
                    super::SidebarItem::Task(project_id, first_session)
                );

                workspace.move_sidebar_selection(-1, cx);
                assert_eq!(workspace.active_session_id, second_session);
                workspace.move_sidebar_selection(-1, cx);
                assert_eq!(workspace.active_session_id, second_session);
                assert_eq!(
                    workspace.sidebar_focused_item,
                    super::SidebarItem::Project(project_id)
                );
            });
        });
    }

    #[gpui::test]
    fn api_key_inputs_start_masked(cx: &mut TestAppContext) {
        let (_, workspace) = cx.update(|cx| {
            let composer = cx.new(ComposerInput::new);
            let workspace = cx.new(|cx| {
                DiscoWorkspace::new(
                    MemoryJournal::default(),
                    composer.clone(),
                    PathBuf::from(format!("/tmp/disco-settings-{}.json", RunId::new())),
                    PathBuf::from(format!("/tmp/disco-project-{}", RunId::new())),
                    Err("Codex unavailable in test".into()),
                    None,
                    Ok(Vec::new()),
                    cx,
                )
            });
            (composer, workspace)
        });

        cx.update(|cx| {
            assert!(workspace.read(cx).kimi_api_key_input.read(cx).is_secure());
            assert!(
                workspace
                    .read(cx)
                    .deepseek_api_key_input
                    .read(cx)
                    .is_secure()
            );
        });
    }

    fn test_opencode_models() -> Vec<OpenCodeModel> {
        vec![
            OpenCodeModel {
                id: "opencode-go/deepseek-v4-flash".into(),
                name: "DeepSeek V4 Flash (2x usage)".into(),
            },
            OpenCodeModel {
                id: "kimi-for-coding/k3".into(),
                name: "Kimi K3".into(),
            },
        ]
    }

    #[gpui::test]
    fn opencode_selection_falls_back_to_the_first_model(cx: &mut TestAppContext) {
        let workspace = cx.update(|cx| {
            let composer = cx.new(ComposerInput::new);
            cx.new(|cx| {
                DiscoWorkspace::new(
                    MemoryJournal::default(),
                    composer,
                    PathBuf::from(format!("/tmp/disco-settings-{}.json", RunId::new())),
                    PathBuf::from(format!("/tmp/disco-project-{}", RunId::new())),
                    Err("Codex unavailable in test".into()),
                    None,
                    Ok(test_opencode_models()),
                    cx,
                )
            })
        });
        cx.update(|cx| {
            let workspace = workspace.read(cx);
            assert_eq!(
                workspace.selected_opencode_model_id.as_deref(),
                Some("opencode-go/deepseek-v4-flash")
            );
            assert_eq!(
                workspace
                    .selected_opencode_model()
                    .map(|model| model.name.as_str()),
                Some("DeepSeek V4 Flash (2x usage)")
            );
        });
    }

    #[gpui::test]
    fn opencode_selection_keeps_the_saved_model_when_still_available(cx: &mut TestAppContext) {
        let config_path = PathBuf::from(format!("/tmp/disco-settings-{}.json", RunId::new()));
        let mut config = AppConfig::default();
        config.selected_opencode_model = Some("kimi-for-coding/k3".into());
        config.save(&config_path).expect("the config should save");
        let workspace = cx.update(|cx| {
            let composer = cx.new(ComposerInput::new);
            cx.new(|cx| {
                DiscoWorkspace::new(
                    MemoryJournal::default(),
                    composer,
                    config_path,
                    PathBuf::from(format!("/tmp/disco-project-{}", RunId::new())),
                    Err("Codex unavailable in test".into()),
                    None,
                    Ok(test_opencode_models()),
                    cx,
                )
            })
        });
        cx.update(|cx| {
            let workspace = workspace.read(cx);
            assert_eq!(
                workspace.selected_opencode_model_id.as_deref(),
                Some("kimi-for-coding/k3")
            );
        });
    }

    #[gpui::test]
    fn selecting_an_opencode_model_persists_it(cx: &mut TestAppContext) {
        let config_path = PathBuf::from(format!("/tmp/disco-settings-{}.json", RunId::new()));
        let workspace = cx.update(|cx| {
            let composer = cx.new(ComposerInput::new);
            cx.new(|cx| {
                DiscoWorkspace::new(
                    MemoryJournal::default(),
                    composer,
                    config_path.clone(),
                    PathBuf::from(format!("/tmp/disco-project-{}", RunId::new())),
                    Err("Codex unavailable in test".into()),
                    None,
                    Ok(test_opencode_models()),
                    cx,
                )
            })
        });
        cx.update(|cx| {
            workspace.update(cx, |workspace, _| {
                workspace.select_opencode_model("kimi-for-coding/k3".into());
                assert_eq!(
                    workspace.selected_opencode_model_id.as_deref(),
                    Some("kimi-for-coding/k3")
                );
                assert_eq!(
                    workspace.selected_chat_provider,
                    super::ProviderKind::OpenCode
                );
                assert!(!workspace.model_menu_open);
                let saved = AppConfig::load(&config_path).expect("the config should load");
                assert_eq!(
                    saved.selected_opencode_model.as_deref(),
                    Some("kimi-for-coding/k3")
                );
            });
        });
    }
}
