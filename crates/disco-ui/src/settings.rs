use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

const KEYCHAIN_SERVICE: &str = "dev.disco.providers";

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct RemoteProviderSettings {
    pub endpoint: String,
    pub model: String,
    pub credential_configured: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct CodexUiSettings {
    pub selected_model: Option<String>,
    pub kimi_code: RemoteProviderSettings,
    pub deepseek: RemoteProviderSettings,
}

impl CodexUiSettings {
    pub fn load(path: &Path) -> Result<Self, String> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let bytes = fs::read(path).map_err(|error| format!("Could not read settings: {error}"))?;
        serde_json::from_slice(&bytes).map_err(|error| format!("Could not parse settings: {error}"))
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("Could not create the settings folder: {error}"))?;
        }
        let temporary = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec_pretty(self)
            .map_err(|error| format!("Could not encode settings: {error}"))?;
        fs::write(&temporary, bytes)
            .map_err(|error| format!("Could not write settings: {error}"))?;
        fs::rename(&temporary, path).map_err(|error| format!("Could not replace settings: {error}"))
    }
}

pub fn save_api_key(provider_id: &str, api_key: &str) -> Result<(), String> {
    let entry = keyring::Entry::new(KEYCHAIN_SERVICE, provider_id)
        .map_err(|error| format!("Could not open macOS Keychain: {error}"))?;
    entry
        .set_password(api_key)
        .map_err(|error| format!("Could not save the API key to macOS Keychain: {error}"))
}

#[cfg(test)]
mod tests {
    use super::CodexUiSettings;

    #[test]
    fn empty_settings_use_the_app_server_default_model() {
        let settings = CodexUiSettings::default();

        assert_eq!(settings.selected_model, None);
        assert!(!settings.kimi_code.credential_configured);
        assert!(!settings.deepseek.credential_configured);
    }

    #[test]
    fn legacy_settings_gain_empty_remote_provider_configs() {
        let settings: CodexUiSettings = serde_json::from_str(r#"{"selected_model":"gpt-codex"}"#)
            .expect("legacy settings should remain readable");

        assert_eq!(settings.selected_model.as_deref(), Some("gpt-codex"));
        assert_eq!(settings.kimi_code, Default::default());
        assert_eq!(settings.deepseek, Default::default());
    }
}
