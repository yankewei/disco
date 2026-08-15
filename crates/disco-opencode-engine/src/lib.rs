//! OpenCode binding for Disco's generic ACP engine ([`disco_acp_engine`]).
//!
//! OpenCode exposes two surfaces: a headless HTTP server (`opencode serve`) and the
//! Agent Client Protocol subprocess (`opencode acp`). Per ADR 0002, Disco integrates
//! through ACP: Disco owns durable run events, approvals, and conversation history
//! while the OpenCode agent runs its own sandbox, tool, and approval semantics.
//!
//! Everything protocol-shaped (connection thread, ACP lifecycle, `session/update`
//! projection) lives in the generic engine. This crate is only the OpenCode
//! [`AcpSpec`]: where the binary lives, how it enters ACP mode, how its model list
//! is parsed, and how a model is pinned on a session. The `OpenCode*` aliases keep
//! existing call sites stable; new agents (Kimi CLI, Pi, ...) should get their own
//! spec crate instead of extending this one.

use disco_acp_engine::{
    AcpError, AcpInstallation, AcpModel, AcpRuntime, AcpSpec, SessionConfigId,
    SessionConfigOptionValue, SessionConfigValueId, discover,
};
use std::env;
use std::path::{Path, PathBuf};

pub use disco_acp_engine::{
    AcpModel as OpenCodeModel, AcpRuntime as OpenCodeRuntime, AcpTurnResult as OpenCodeTurnResult,
};

/// The OpenCode wiring for the generic ACP engine.
pub fn opencode_spec() -> AcpSpec {
    AcpSpec {
        name: "OpenCode",
        version_args: &["--version"],
        binary_candidates: opencode_candidates,
        acp_args,
        list_models,
        model_config,
    }
}

/// Discovers the `opencode` binary and reports its version.
pub fn discover_opencode() -> Result<AcpInstallation, AcpError> {
    discover(&opencode_spec())
}

/// Spawns `opencode acp` for `workspace` and completes the ACP handshake.
pub fn connect(workspace: &Path) -> Result<AcpRuntime, AcpError> {
    AcpRuntime::connect(opencode_spec(), workspace)
}

/// The opencode CLI enters ACP mode through `acp`; `--cwd` pins the agent's
/// project context to the workspace, with the session workspace additionally
/// pinned per-session via `session/new` `cwd`.
fn acp_args(workspace: &Path) -> Vec<String> {
    vec![
        "acp".into(),
        "--cwd".into(),
        workspace.to_string_lossy().into_owned(),
    ]
}

/// Lists the models OpenCode currently exposes through its own configuration.
///
/// Runs `opencode models --verbose` as a one-shot subprocess: the verbose output
/// interleaves `provider/model` id lines with per-model JSON metadata blocks.
/// Only the JSON blocks are parsed, so surrounding separator text can change
/// without breaking the parse. Models OpenCode marks as non-active are skipped,
/// matching what an ACP session advertises through its config options.
pub fn list_models(installation: &AcpInstallation) -> Result<Vec<AcpModel>, AcpError> {
    let output = std::process::Command::new(&installation.path)
        .arg("models")
        .arg("--verbose")
        .output()?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(AcpError::ModelListing(if detail.is_empty() {
            format!(
                "opencode models exited with {status}",
                status = output.status
            )
        } else {
            detail
        }));
    }
    let models = parse_models_output(&String::from_utf8_lossy(&output.stdout));
    if models.is_empty() {
        return Err(AcpError::ModelListing(
            "opencode models returned no active models".into(),
        ));
    }
    Ok(models)
}

/// The opencode CLI builds its model selector as config option id "model"
/// with values in `provider/model` form, matching `opencode models` output.
fn model_config(model_id: &str) -> (SessionConfigId, SessionConfigOptionValue) {
    (
        SessionConfigId::new("model"),
        SessionConfigOptionValue::ValueId {
            value: SessionConfigValueId::new(model_id),
        },
    )
}

fn opencode_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = env::var_os("OPENCODE_BIN") {
        candidates.push(PathBuf::from(path));
    }
    if let Some(paths) = env::var_os("PATH") {
        candidates.extend(env::split_paths(&paths).map(|path| path.join("opencode")));
    }
    if let Some(home) = env::var_os("HOME").map(PathBuf::from) {
        candidates.push(home.join(".local/bin/opencode"));
        candidates.push(home.join(".opencode/bin/opencode"));
    }
    candidates.push(PathBuf::from("/opt/homebrew/bin/opencode"));
    candidates.push(PathBuf::from("/usr/local/bin/opencode"));
    candidates.dedup();
    candidates
}

/// Extracts model entries from `opencode models --verbose` stdout.
///
/// Each entry is a complete top-level JSON object. Id lines between the blocks
/// are ignored; entries parse only when the JSON carries `providerID`, `id`, and
/// `name`, and are dropped when OpenCode marks them non-active.
fn parse_models_output(stdout: &str) -> Vec<AcpModel> {
    let mut models = Vec::new();
    let mut block = String::new();
    let mut depth = 0usize;
    let mut in_block = false;
    for line in stdout.lines() {
        if !in_block {
            in_block = line.trim_start().starts_with('{');
            if !in_block {
                continue;
            }
        }
        block.push_str(line);
        block.push('\n');
        depth += line.bytes().filter(|&byte| byte == b'{').count();
        depth = depth.saturating_sub(line.bytes().filter(|&byte| byte == b'}').count());
        if depth == 0 {
            in_block = false;
            if let Some(model) = parse_model_block(&block) {
                models.push(model);
            }
            block.clear();
        }
    }
    models
}

fn parse_model_block(block: &str) -> Option<AcpModel> {
    let value: serde_json::Value = serde_json::from_str(block).ok()?;
    let status = value.get("status").and_then(serde_json::Value::as_str);
    if status.is_some_and(|status| status != "active") {
        return None;
    }
    Some(AcpModel {
        id: format!(
            "{provider}/{id}",
            provider = value.get("providerID")?.as_str()?,
            id = value.get("id")?.as_str()?
        ),
        name: value.get("name")?.as_str()?.to_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::{AcpModel, parse_models_output};

    #[test]
    fn model_listing_parses_verbose_blocks_and_skips_inactive() {
        let stdout = "\
opencode-go/deepseek-v4-flash
{
  \"id\": \"deepseek-v4-flash\",
  \"providerID\": \"opencode-go\",
  \"name\": \"DeepSeek V4 Flash (2x usage)\",
  \"status\": \"active\"
}
opencode-go/retired-model
{
  \"id\": \"retired-model\",
  \"providerID\": \"opencode-go\",
  \"name\": \"Retired Model\",
  \"status\": \"inactive\"
}
kimi-for-coding/k3
{
  \"id\": \"k3\",
  \"providerID\": \"kimi-for-coding\",
  \"name\": \"Kimi K3\",
  \"status\": \"active\"
}
";
        assert_eq!(
            parse_models_output(stdout),
            vec![
                AcpModel {
                    id: "opencode-go/deepseek-v4-flash".into(),
                    name: "DeepSeek V4 Flash (2x usage)".into(),
                },
                AcpModel {
                    id: "kimi-for-coding/k3".into(),
                    name: "Kimi K3".into(),
                },
            ]
        );
    }

    #[test]
    fn model_listing_keeps_models_without_a_status() {
        let stdout = "\
some-provider/model-a
{
  \"id\": \"model-a\",
  \"providerID\": \"some-provider\",
  \"name\": \"Model A\"
}
";
        assert_eq!(
            parse_models_output(stdout),
            vec![AcpModel {
                id: "some-provider/model-a".into(),
                name: "Model A".into(),
            }]
        );
    }
}
