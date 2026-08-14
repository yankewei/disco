use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct RemoteProviderSettings {
    pub endpoint: String,
    pub model: String,
    pub api_key: String,
}

impl RemoteProviderSettings {
    pub fn is_configured(&self) -> bool {
        !self.api_key.is_empty()
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct AppConfig {
    pub selected_model: Option<String>,
    pub kimi_code: RemoteProviderSettings,
    pub deepseek: RemoteProviderSettings,
}

impl AppConfig {
    pub fn load(path: &Path) -> Result<Self, String> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let contents = fs::read_to_string(path)
            .map_err(|error| format!("Could not read {}: {error}", path.display()))?;
        toml::from_str(&contents)
            .map_err(|error| format!("Could not parse {}: {error}", path.display()))
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("Could not create the config folder: {error}"))?;
        }
        let contents = toml::to_string_pretty(self)
            .map_err(|error| format!("Could not encode config: {error}"))?;
        let temporary = path.with_extension("toml.tmp");
        fs::write(&temporary, contents)
            .map_err(|error| format!("Could not write {}: {error}", path.display()))?;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("Could not secure {}: {error}", path.display()))?;
        fs::rename(&temporary, path)
            .map_err(|error| format!("Could not replace {}: {error}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::{AppConfig, RemoteProviderSettings};
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn empty_config_uses_the_app_server_default_model() {
        let config = AppConfig::default();

        assert_eq!(config.selected_model, None);
        assert!(config.kimi_code.api_key.is_empty());
        assert!(config.deepseek.api_key.is_empty());
    }

    #[test]
    fn config_without_provider_sections_keeps_defaults() {
        let config: AppConfig = toml::from_str(r#"selected_model = "gpt-codex""#)
            .expect("a partial config should parse");

        assert_eq!(config.selected_model.as_deref(), Some("gpt-codex"));
        assert_eq!(config.kimi_code, Default::default());
        assert_eq!(config.deepseek, Default::default());
    }

    #[test]
    fn config_saves_with_keys_and_owner_only_permissions() {
        let directory = tempfile::tempdir().expect("the test directory should be created");
        let path = directory.path().join("config.toml");
        let config = AppConfig {
            selected_model: Some("gpt-codex".into()),
            kimi_code: RemoteProviderSettings {
                endpoint: "https://api.kimi.com/v1".into(),
                model: "kimi-k2".into(),
                api_key: "sk-kimi".into(),
            },
            deepseek: RemoteProviderSettings {
                endpoint: "https://api.deepseek.com/v1".into(),
                model: "deepseek-chat".into(),
                api_key: "sk-deepseek".into(),
            },
        };

        config.save(&path).expect("the config should be saved");

        let loaded = AppConfig::load(&path).expect("the config should load");
        assert_eq!(loaded, config);
        let mode = fs::metadata(&path)
            .expect("the config metadata should be readable")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);
    }
}
