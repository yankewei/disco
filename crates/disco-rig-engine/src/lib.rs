//! Rig-backed in-process agent engine primitives.
//!
//! Provider clients and live model transport are intentionally composed by the
//! application. This crate owns durable Rig run state and its versioned envelope.

use rig::agent::run::AgentRun;
use rig::client::ModelListingClient;
use rig::providers::openai;
use serde::{Deserialize, Serialize};
use thiserror::Error;

const CHECKPOINT_SCHEMA_VERSION: u32 = 1;
const RIG_VERSION: &str = "0.41.0";

/// Lists the models advertised by an OpenAI-compatible provider.
pub async fn list_models(base_url: &str, api_key: &str) -> Result<Vec<String>, String> {
    let client = openai::Client::builder()
        .api_key(api_key.to_string())
        .base_url(base_url)
        .build()
        .map_err(|error| format!("Could not build the provider client: {error}"))?;
    let models = client
        .list_models()
        .await
        .map_err(|error| format!("Could not list models: {error}"))?;
    Ok(models.into_iter().map(|model| model.id).collect())
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RigEngineConfig {
    pub provider: String,
    pub model: String,
    pub preamble: String,
    pub maximum_turns: usize,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RigRunCheckpoint {
    pub schema_version: u32,
    pub adapter_version: String,
    pub rig_version: String,
    pub run_json: String,
}

impl RigRunCheckpoint {
    pub fn new(prompt: impl Into<String>, maximum_turns: usize) -> Result<Self, CheckpointError> {
        let run = AgentRun::new(prompt.into()).max_turns(maximum_turns);
        Self::capture(&run)
    }

    pub fn capture(run: &AgentRun) -> Result<Self, CheckpointError> {
        Ok(Self {
            schema_version: CHECKPOINT_SCHEMA_VERSION,
            adapter_version: env!("CARGO_PKG_VERSION").into(),
            rig_version: RIG_VERSION.into(),
            run_json: serde_json::to_string(run)?,
        })
    }

    pub fn restore(&self) -> Result<AgentRun, CheckpointError> {
        if self.schema_version != CHECKPOINT_SCHEMA_VERSION {
            return Err(CheckpointError::UnsupportedSchema(self.schema_version));
        }
        Ok(serde_json::from_str(&self.run_json)?)
    }
}

#[derive(Debug, Error)]
pub enum CheckpointError {
    #[error("Rig checkpoint schema {0} is unsupported")]
    UnsupportedSchema(u32),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[cfg(test)]
mod tests {
    use super::*;
    use rig::agent::run::AgentRunStep;

    #[test]
    fn checkpoint_restores_the_next_model_step() {
        let checkpoint =
            RigRunCheckpoint::new("Inspect the current workspace", 8).expect("checkpoint");
        let mut restored = checkpoint.restore().expect("checkpoint should restore");

        assert!(matches!(
            restored.next_step().expect("step should be available"),
            AgentRunStep::CallModel { .. }
        ));
    }

    #[test]
    fn checkpoint_rejects_unknown_schema_versions() {
        let mut checkpoint = RigRunCheckpoint::new("Inspect", 2).expect("checkpoint");
        checkpoint.schema_version += 1;
        assert!(matches!(
            checkpoint.restore(),
            Err(CheckpointError::UnsupportedSchema(_))
        ));
    }
}
