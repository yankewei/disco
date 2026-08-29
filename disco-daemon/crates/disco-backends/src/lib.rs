mod acp;
mod claude_code;
mod codex;
mod opencode;
mod rig;

pub use acp::{AcpAdapter, SessionConfigSelection};
pub use claude_code::ClaudeCodeAdapter;
pub use codex::CodexAdapter;
pub use opencode::{OpenCodeAdapter, OpenCodeServerManager};
pub use rig::{
    ModelEntry, RigRuntime, deepseek_runtime, list_models_deepseek, list_models_openai_compat,
    openai_chat_runtime, openai_responses_runtime,
};
