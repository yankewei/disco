//! GPUI workspace shell driven by the kernel's run projection.

use disco_domain::{EngineKind, RunId, RunStatus, SessionId};
use disco_kernel::{
    ActivityItem, EventJournal, Kernel, KernelError, RunProjection, ScriptedEngine,
};
use gpui::{
    Context, InteractiveElement, IntoElement, ParentElement, Render, StatefulInteractiveElement,
    Styled, Window, div, img, px, rgb,
};

const APP_LOGO_ASSET: &str = "images/app-logo.png";
const DEEPSEEK_ICON_ASSET: &str = "icons/providers/deepseek.svg";

const CANVAS: u32 = 0x111315;
const RAIL: u32 = 0x17191c;
const SIDEBAR: u32 = 0x1c1f22;
const PANEL: u32 = 0x202327;
const PANEL_ELEVATED: u32 = 0x272b30;
const BORDER: u32 = 0x34383e;
const TEXT: u32 = 0xe6e7e9;
const MUTED: u32 = 0x8e949c;
const AMBER: u32 = 0xe9a23b;
const AMBER_HOVER: u32 = 0xf0b45b;
const AMBER_ACTIVE: u32 = 0xd28b2e;
const GREEN: u32 = 0x69b578;

pub struct DiscoWorkspace<J: EventJournal> {
    kernel: Kernel<J>,
    run_id: RunId,
    projection: RunProjection,
    engine: ScriptedEngine,
}

impl<J: EventJournal> DiscoWorkspace<J> {
    pub fn new(journal: J) -> Result<Self, KernelError> {
        let kernel = Kernel::new(journal);
        let run_id = RunId::new();
        let mut projection = kernel.start_run(
            run_id,
            SessionId::new(),
            EngineKind::Rig,
            Some("~/Documents/github/disco".into()),
            "Inspect the repository and establish a clean Rust coding-agent architecture.",
        )?;
        let mut engine = ScriptedEngine::coding_agent_demo();
        let initial = engine
            .advance()
            .expect("the coding agent script has an initial batch");
        for event in initial.events {
            projection = kernel.record(run_id, event)?;
        }

        Ok(Self {
            kernel,
            run_id,
            projection,
            engine,
        })
    }

    fn advance_demo(&mut self) {
        let Some(batch) = self.engine.advance() else {
            return;
        };
        for event in batch.events {
            if let Ok(projection) = self.kernel.record(self.run_id, event) {
                self.projection = projection;
            }
        }
    }

    fn status_label(&self) -> &'static str {
        match self.projection.status {
            RunStatus::Queued => "Queued",
            RunStatus::Running => "Running",
            RunStatus::WaitingForTool => "Tool activity",
            RunStatus::WaitingForApproval => "Approval required",
            RunStatus::WaitingForUserInput => "Input required",
            RunStatus::Completed => "Completed",
            RunStatus::Failed => "Failed",
            RunStatus::Cancelled => "Cancelled",
        }
    }

    fn activity_row(item: &ActivityItem) -> impl IntoElement {
        let state_color = if item.completed { GREEN } else { AMBER };
        div()
            .flex()
            .items_start()
            .gap_3()
            .px_3()
            .py_3()
            .border_b_1()
            .border_color(rgb(BORDER))
            .child(
                div()
                    .mt_1()
                    .size(px(7.))
                    .rounded_full()
                    .bg(rgb(state_color)),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .flex_grow()
                    .child(
                        div()
                            .text_sm()
                            .text_color(rgb(TEXT))
                            .child(item.title.clone()),
                    )
                    .child(
                        div()
                            .text_xs()
                            .line_height(px(18.))
                            .text_color(rgb(MUTED))
                            .child(item.detail.clone()),
                    ),
            )
    }

    fn rail() -> impl IntoElement {
        div()
            .w(px(58.))
            .h_full()
            .flex()
            .flex_col()
            .items_center()
            .bg(rgb(RAIL))
            .border_r_1()
            .border_color(rgb(BORDER))
            .pt(px(56.))
            .pb_3()
            .gap_3()
            .child(
                div()
                    .size(px(32.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded_md()
                    .overflow_hidden()
                    .bg(rgb(AMBER))
                    .child(img(APP_LOGO_ASSET).size_full()),
            )
            .child(
                div()
                    .mt_2()
                    .size(px(30.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded_md()
                    .bg(rgb(PANEL_ELEVATED))
                    .p(px(5.))
                    .child(img(DEEPSEEK_ICON_ASSET).size_full()),
            )
            .child(
                div()
                    .size(px(30.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded_md()
                    .text_color(rgb(MUTED))
                    .text_xs()
                    .child("+"),
            )
    }

    fn sidebar(active_status: &'static str, active_color: u32) -> impl IntoElement {
        let sessions = [
            ("Rust architecture", active_status),
            ("Tool protocol", "Yesterday"),
            ("GPUI interaction model", "Mon"),
        ];

        div()
            .w(px(252.))
            .h_full()
            .flex()
            .flex_col()
            .bg(rgb(SIDEBAR))
            .border_r_1()
            .border_color(rgb(BORDER))
            .child(
                div()
                    .h(px(52.))
                    .flex()
                    .items_center()
                    .justify_between()
                    .px_4()
                    .border_b_1()
                    .border_color(rgb(BORDER))
                    .child(div().text_sm().text_color(rgb(TEXT)).child("disco"))
                    .child(div().text_xs().text_color(rgb(MUTED)).child("⌘K")),
            )
            .child(
                div()
                    .px_3()
                    .pt_4()
                    .pb_2()
                    .text_xs()
                    .text_color(rgb(MUTED))
                    .child("SESSIONS"),
            )
            .children(
                sessions
                    .into_iter()
                    .enumerate()
                    .map(|(index, (title, meta))| {
                        div()
                            .mx_2()
                            .mb_1()
                            .px_3()
                            .py_3()
                            .rounded_md()
                            .bg(rgb(if index == 0 { PANEL_ELEVATED } else { SIDEBAR }))
                            .child(
                                div()
                                    .text_sm()
                                    .text_color(rgb(if index == 0 { TEXT } else { MUTED }))
                                    .child(title),
                            )
                            .child(
                                div()
                                    .mt_1()
                                    .text_xs()
                                    .text_color(rgb(if index == 0 { active_color } else { MUTED }))
                                    .child(meta),
                            )
                    }),
            )
    }
}

impl<J: EventJournal> Render for DiscoWorkspace<J> {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let status_color = if self.projection.status == RunStatus::Completed {
            GREEN
        } else {
            AMBER
        };
        let is_terminal = self.projection.status.is_terminal();
        let prompt = self.projection.prompt.clone().unwrap_or_default();
        let assistant = if self.projection.assistant_text.is_empty() {
            "The engine response will appear here after tool activity completes.".to_string()
        } else {
            self.projection.assistant_text.clone()
        };

        div()
            .size_full()
            .flex()
            .bg(rgb(CANVAS))
            .text_color(rgb(TEXT))
            .child(Self::rail())
            .child(Self::sidebar(self.status_label(), status_color))
            .child(
                div()
                    .h_full()
                    .flex_grow()
                    .flex()
                    .flex_col()
                    .overflow_hidden()
                    .child(
                        div()
                            .h(px(52.))
                            .flex()
                            .items_center()
                            .justify_between()
                            .px_5()
                            .border_b_1()
                            .border_color(rgb(BORDER))
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .child(div().size(px(7.)).rounded_full().bg(rgb(status_color)))
                                    .child(
                                        div()
                                            .text_sm()
                                            .text_color(rgb(TEXT))
                                            .child(self.status_label()),
                                    )
                                    .child(div().text_xs().text_color(rgb(MUTED)).child("· Rig")),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(rgb(MUTED))
                                    .child("~/Documents/github/disco"),
                            ),
                    )
                    .child(
                        div()
                            .id("run-scroll")
                            .flex_grow()
                            .overflow_y_scroll()
                            .px_7()
                            .py_6()
                            .child(
                                div()
                                    .max_w(px(860.))
                                    .mx_auto()
                                    .flex()
                                    .flex_col()
                                    .gap_5()
                                    .child(
                                        div()
                                            .text_xl()
                                            .line_height(px(29.))
                                            .text_color(rgb(TEXT))
                                            .child(prompt),
                                    )
                                    .child(
                                        div()
                                            .rounded_lg()
                                            .border_1()
                                            .border_color(rgb(BORDER))
                                            .bg(rgb(PANEL))
                                            .overflow_hidden()
                                            .child(
                                                div()
                                                    .px_3()
                                                    .py_2()
                                                    .border_b_1()
                                                    .border_color(rgb(BORDER))
                                                    .text_xs()
                                                    .text_color(rgb(MUTED))
                                                    .child("RUN ACTIVITY"),
                                            )
                                            .children(
                                                self.projection
                                                    .activities
                                                    .iter()
                                                    .map(Self::activity_row),
                                            ),
                                    )
                                    .child(
                                        div()
                                            .flex()
                                            .flex_col()
                                            .gap_2()
                                            .child(
                                                div()
                                                    .text_xs()
                                                    .text_color(rgb(MUTED))
                                                    .child("AGENT"),
                                            )
                                            .child(
                                                div()
                                                    .text_sm()
                                                    .line_height(px(22.))
                                                    .text_color(rgb(
                                                        if self.projection.assistant_text.is_empty()
                                                        {
                                                            MUTED
                                                        } else {
                                                            TEXT
                                                        },
                                                    ))
                                                    .child(assistant),
                                            ),
                                    )
                                    .child(div().text_xs().text_color(rgb(MUTED)).child(format!(
                                        "{} input · {} output · {} total tokens",
                                        self.projection.usage.input_tokens,
                                        self.projection.usage.output_tokens,
                                        self.projection.usage.total_tokens
                                    ))),
                            ),
                    )
                    .child(
                        div().px_7().pb_5().child(
                            div()
                                .max_w(px(860.))
                                .mx_auto()
                                .flex()
                                .items_center()
                                .justify_between()
                                .gap_3()
                                .p_2()
                                .pl_4()
                                .rounded_lg()
                                .border_1()
                                .border_color(rgb(BORDER))
                                .bg(rgb(PANEL))
                                .child(
                                    div()
                                        .text_sm()
                                        .text_color(rgb(MUTED))
                                        .child("Message the agent or add context…"),
                                )
                                .child(
                                    div()
                                        .id("advance-demo")
                                        .px_3()
                                        .py_2()
                                        .rounded_md()
                                        .bg(rgb(if is_terminal { BORDER } else { AMBER }))
                                        .text_sm()
                                        .text_color(rgb(if is_terminal { MUTED } else { CANVAS }))
                                        .cursor_pointer()
                                        .hover(move |style| {
                                            style.bg(rgb(if is_terminal {
                                                BORDER
                                            } else {
                                                AMBER_HOVER
                                            }))
                                        })
                                        .active(move |style| {
                                            style.bg(rgb(if is_terminal {
                                                BORDER
                                            } else {
                                                AMBER_ACTIVE
                                            }))
                                        })
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.advance_demo();
                                            cx.notify();
                                        }))
                                        .child(self.engine.next_action_label()),
                                ),
                        ),
                    ),
            )
    }
}
