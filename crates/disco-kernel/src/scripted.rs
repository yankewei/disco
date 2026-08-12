use disco_domain::{RunEventPayload, TokenUsage, ToolCall};
use std::collections::VecDeque;

/// Deterministic engine used by the desktop shell and integration tests before
/// live model credentials are configured.
pub struct ScriptedEngine {
    batches: VecDeque<ScriptedBatch>,
}

pub struct ScriptedBatch {
    pub action_label: &'static str,
    pub events: Vec<RunEventPayload>,
}

impl ScriptedEngine {
    #[must_use]
    pub fn coding_agent_demo() -> Self {
        Self {
            batches: VecDeque::from([
                ScriptedBatch {
                    action_label: "Prepare run",
                    events: vec![
                        RunEventPayload::PlanUpdated {
                            steps: vec![
                                "Map the workspace and architecture constraints".into(),
                                "Inspect the event kernel and tool boundary".into(),
                                "Report the first implementation slice".into(),
                            ],
                        },
                        RunEventPayload::ToolRequested {
                            call: ToolCall {
                                call_id: "tool-list-root".into(),
                                name: "filesystem_list".into(),
                                arguments: serde_json::json!({ "path": "." }),
                            },
                        },
                    ],
                },
                ScriptedBatch {
                    action_label: "Run tool",
                    events: vec![RunEventPayload::ToolStarted {
                        call_id: "tool-list-root".into(),
                    }],
                },
                ScriptedBatch {
                    action_label: "Return result",
                    events: vec![
                        RunEventPayload::ToolOutputDelta {
                            call_id: "tool-list-root".into(),
                            output: "Cargo.toml · crates/ · packaging/ · scripts/".into(),
                        },
                        RunEventPayload::ToolCompleted {
                            call_id: "tool-list-root".into(),
                            success: true,
                            output: "4 top-level entries inspected".into(),
                        },
                    ],
                },
                ScriptedBatch {
                    action_label: "Generate answer",
                    events: vec![
                        RunEventPayload::AssistantContentDelta {
                            text: "The Rust workspace now has explicit boundaries for domain events, orchestration, persistence, tools, Rig integration, and GPUI presentation. The UI is a projection of durable run events, so approvals and resumable engines can be added without coupling protocol details to views.".into(),
                        },
                        RunEventPayload::UsageUpdated {
                            usage: TokenUsage {
                                input_tokens: 2_164,
                                output_tokens: 682,
                                total_tokens: 2_846,
                            },
                        },
                    ],
                },
                ScriptedBatch {
                    action_label: "Complete run",
                    events: vec![RunEventPayload::RunCompleted],
                },
            ]),
        }
    }

    #[must_use]
    pub fn next_action_label(&self) -> &'static str {
        self.batches
            .front()
            .map_or("Run complete", |batch| batch.action_label)
    }

    pub fn advance(&mut self) -> Option<ScriptedBatch> {
        self.batches.pop_front()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finishes_with_exactly_one_terminal_event() {
        let mut engine = ScriptedEngine::coding_agent_demo();
        let mut terminal_events = 0;
        while let Some(batch) = engine.advance() {
            terminal_events += batch
                .events
                .iter()
                .filter(|event| event.terminal_status().is_some())
                .count();
        }

        assert_eq!(terminal_events, 1);
        assert_eq!(engine.next_action_label(), "Run complete");
    }
}
