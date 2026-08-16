//! SQLite persistence for provider configurations.

use anyhow::{Context, Result};
use disco_protocol::types::{ProviderId, Vendor};
use serde::{Deserialize, Serialize};

use crate::Database;

/// A persisted provider configuration.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderConfig {
    pub provider_id: ProviderId,
    pub vendor: Vendor,
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    pub thinking_enabled: bool,
    pub updated_at: String,
}

impl Database {
    /// Save or update a provider configuration.
    pub fn save_provider_config(&self, config: &ProviderConfig) -> Result<()> {
        let vendor_str = serde_json::to_string(&config.vendor)
            .context("Failed to serialize vendor")?
            .trim_matches('"')
            .to_string();
        let now = Self::now_iso8601();

        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT OR REPLACE INTO provider_profiles
             (id, vendor, base_url, api_key, model, thinking_enabled, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            rusqlite::params![
                config.provider_id.as_str(),
                vendor_str,
                config.base_url,
                config.api_key,
                config.model,
                config.thinking_enabled as i32,
                &now,
            ],
        )
        .with_context(|| format!("Failed to save provider config {}", config.provider_id))?;

        Ok(())
    }

    /// Get a provider configuration by its stable profile ID.
    pub fn get_provider_config(&self, provider_id: &ProviderId) -> Result<Option<ProviderConfig>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id, vendor, base_url, api_key, model, thinking_enabled, updated_at
                 FROM provider_profiles
                 WHERE id = ?1",
            )
            .context("Failed to prepare get_provider_config query")?;

        let result = stmt
            .query_row(rusqlite::params![provider_id.as_str()], |row| {
                let vendor_str: String = row.get(1)?;
                let vendor: Vendor =
                    serde_json::from_str(&format!("\"{vendor_str}\"")).unwrap_or(Vendor::Openai);
                Ok(ProviderConfig {
                    provider_id: ProviderId::new(row.get::<_, String>(0)?),
                    vendor,
                    base_url: row.get(2)?,
                    api_key: row.get(3)?,
                    model: row.get(4)?,
                    thinking_enabled: row.get::<_, i32>(5)? != 0,
                    updated_at: row.get(6)?,
                })
            })
            .optional()
            .context("Failed to query provider config")?;

        Ok(result)
    }

    /// List all provider configurations.
    pub fn list_provider_configs(&self) -> Result<Vec<ProviderConfig>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id, vendor, base_url, api_key, model, thinking_enabled, updated_at
                 FROM provider_profiles
                 ORDER BY id",
            )
            .context("Failed to prepare list_provider_configs query")?;

        let rows = stmt.query_map([], |row| {
            let vendor_str: String = row.get(1)?;
            let vendor: Vendor =
                serde_json::from_str(&format!("\"{vendor_str}\"")).unwrap_or(Vendor::Openai);
            Ok(ProviderConfig {
                provider_id: ProviderId::new(row.get::<_, String>(0)?),
                vendor,
                base_url: row.get(2)?,
                api_key: row.get(3)?,
                model: row.get(4)?,
                thinking_enabled: row.get::<_, i32>(5)? != 0,
                updated_at: row.get(6)?,
            })
        })?;

        let mut configs = Vec::new();
        for row in rows {
            configs.push(row.context("Failed to read provider config row")?);
        }
        Ok(configs)
    }

    /// Delete a provider configuration by its stable profile ID.
    pub fn delete_provider_config(&self, provider_id: &ProviderId) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "DELETE FROM provider_profiles WHERE id = ?1",
            rusqlite::params![provider_id.as_str()],
        )
        .with_context(|| format!("Failed to delete provider config {provider_id}"))?;

        Ok(())
    }
}

/// Helper trait for rusqlite OptionalExtension.
trait OptionalExtension<T> {
    fn optional(self) -> Result<Option<T>>;
}

impl<T> OptionalExtension<T> for std::result::Result<T, rusqlite::Error> {
    fn optional(self) -> Result<Option<T>> {
        match self {
            Ok(value) => Ok(Some(value)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(anyhow::anyhow!("SQLite error: {e}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn temp_db() -> Database {
        let dir = std::env::temp_dir().join(format!("disco-test-{}", Uuid::new_v4()));
        Database::open(&dir.join("test.db")).unwrap()
    }

    #[test]
    fn save_and_get_provider_config() {
        let db = temp_db();
        let config = ProviderConfig {
            provider_id: ProviderId::legacy_default_for_vendor(Vendor::Openai),
            vendor: Vendor::Openai,
            base_url: "https://api.openai.com/v1".to_string(),
            api_key: "sk-test".to_string(),
            model: "gpt-4".to_string(),
            thinking_enabled: false,
            updated_at: String::new(),
        };

        db.save_provider_config(&config).unwrap();

        let loaded = db
            .get_provider_config(&ProviderId::legacy_default_for_vendor(Vendor::Openai))
            .unwrap()
            .unwrap();
        assert_eq!(loaded.vendor, Vendor::Openai);
        assert_eq!(loaded.base_url, "https://api.openai.com/v1");
        assert_eq!(loaded.api_key, "sk-test");
        assert_eq!(loaded.model, "gpt-4");
        assert!(!loaded.thinking_enabled);
    }

    #[test]
    fn update_provider_config() {
        let db = temp_db();
        let config = ProviderConfig {
            provider_id: ProviderId::legacy_default_for_vendor(Vendor::Deepseek),
            vendor: Vendor::Deepseek,
            base_url: "https://api.deepseek.com/v1".to_string(),
            api_key: "sk-old".to_string(),
            model: "deepseek-chat".to_string(),
            thinking_enabled: false,
            updated_at: String::new(),
        };

        db.save_provider_config(&config).unwrap();

        // Update
        let updated = ProviderConfig {
            api_key: "sk-new".to_string(),
            model: "deepseek-reasoner".to_string(),
            thinking_enabled: true,
            ..config
        };
        db.save_provider_config(&updated).unwrap();

        let loaded = db
            .get_provider_config(&ProviderId::legacy_default_for_vendor(Vendor::Deepseek))
            .unwrap()
            .unwrap();
        assert_eq!(loaded.api_key, "sk-new");
        assert_eq!(loaded.model, "deepseek-reasoner");
        assert!(loaded.thinking_enabled);
    }

    #[test]
    fn list_provider_configs() {
        let db = temp_db();

        db.save_provider_config(&ProviderConfig {
            provider_id: ProviderId::legacy_default_for_vendor(Vendor::Openai),
            vendor: Vendor::Openai,
            base_url: "https://api.openai.com/v1".to_string(),
            api_key: "sk-1".to_string(),
            model: "gpt-4".to_string(),
            thinking_enabled: false,
            updated_at: String::new(),
        })
        .unwrap();

        db.save_provider_config(&ProviderConfig {
            provider_id: ProviderId::legacy_default_for_vendor(Vendor::Deepseek),
            vendor: Vendor::Deepseek,
            base_url: "https://api.deepseek.com/v1".to_string(),
            api_key: "sk-2".to_string(),
            model: "deepseek-chat".to_string(),
            thinking_enabled: false,
            updated_at: String::new(),
        })
        .unwrap();

        let configs = db.list_provider_configs().unwrap();
        assert_eq!(configs.len(), 2);
    }

    #[test]
    fn delete_provider_config() {
        let db = temp_db();

        db.save_provider_config(&ProviderConfig {
            provider_id: ProviderId::legacy_default_for_vendor(Vendor::Openai),
            vendor: Vendor::Openai,
            base_url: "https://api.openai.com/v1".to_string(),
            api_key: "sk-test".to_string(),
            model: "gpt-4".to_string(),
            thinking_enabled: false,
            updated_at: String::new(),
        })
        .unwrap();

        let provider_id = ProviderId::legacy_default_for_vendor(Vendor::Openai);
        db.delete_provider_config(&provider_id).unwrap();

        let loaded = db.get_provider_config(&provider_id).unwrap();
        assert!(loaded.is_none());
    }

    #[test]
    fn get_nonexistent_provider_config() {
        let db = temp_db();
        let loaded = db
            .get_provider_config(&ProviderId::legacy_default_for_vendor(Vendor::Glm))
            .unwrap();
        assert!(loaded.is_none());
    }

    #[test]
    fn kimi_provider_config_with_thinking() {
        let db = temp_db();

        db.save_provider_config(&ProviderConfig {
            provider_id: ProviderId::legacy_default_for_vendor(Vendor::MoonshotKimi),
            vendor: Vendor::MoonshotKimi,
            base_url: "https://api.moonshot.cn/v1".to_string(),
            api_key: "sk-kimi".to_string(),
            model: "kimi-latest".to_string(),
            thinking_enabled: true,
            updated_at: String::new(),
        })
        .unwrap();

        let loaded = db
            .get_provider_config(&ProviderId::legacy_default_for_vendor(Vendor::MoonshotKimi))
            .unwrap()
            .unwrap();
        assert_eq!(loaded.vendor, Vendor::MoonshotKimi);
        assert!(loaded.thinking_enabled);
    }

    #[test]
    fn codex_app_server_and_codex_api_are_distinct_profiles() {
        let db = temp_db();

        db.save_provider_config(&ProviderConfig {
            provider_id: ProviderId::new(ProviderId::CODEX_APP_SERVER),
            vendor: Vendor::Codex,
            base_url: String::new(),
            api_key: String::new(),
            model: "o4-mini".to_string(),
            thinking_enabled: false,
            updated_at: String::new(),
        })
        .unwrap();
        db.save_provider_config(&ProviderConfig {
            provider_id: ProviderId::new(ProviderId::CODEX_API),
            vendor: Vendor::Openai,
            base_url: "https://api.openai.com/v1".to_string(),
            api_key: "sk-test".to_string(),
            model: "gpt-5-codex".to_string(),
            thinking_enabled: false,
            updated_at: String::new(),
        })
        .unwrap();

        let configs = db.list_provider_configs().unwrap();
        assert_eq!(configs.len(), 2);
        assert!(
            configs
                .iter()
                .any(|config| config.provider_id.as_str() == ProviderId::CODEX_APP_SERVER)
        );
        assert!(
            configs
                .iter()
                .any(|config| config.provider_id.as_str() == ProviderId::CODEX_API)
        );
    }
}
