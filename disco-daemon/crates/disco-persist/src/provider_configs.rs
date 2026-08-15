//! SQLite persistence for provider configurations.

use anyhow::{Context, Result};
use disco_protocol::types::Vendor;
use serde::{Deserialize, Serialize};

use crate::Database;

/// A persisted provider configuration.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderConfig {
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
            "INSERT OR REPLACE INTO provider_configs
             (vendor, base_url, api_key, model, thinking_enabled, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![
                vendor_str,
                config.base_url,
                config.api_key,
                config.model,
                config.thinking_enabled as i32,
                &now,
            ],
        )
        .with_context(|| format!("Failed to save provider config for {:?}", config.vendor))?;

        Ok(())
    }

    /// Get a provider configuration by vendor.
    pub fn get_provider_config(&self, vendor: Vendor) -> Result<Option<ProviderConfig>> {
        let vendor_str = serde_json::to_string(&vendor)
            .context("Failed to serialize vendor")?
            .trim_matches('"')
            .to_string();

        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT vendor, base_url, api_key, model, thinking_enabled, updated_at
                 FROM provider_configs
                 WHERE vendor = ?1",
            )
            .context("Failed to prepare get_provider_config query")?;

        let result = stmt
            .query_row(rusqlite::params![vendor_str], |row| {
                let vendor_str: String = row.get(0)?;
                let vendor: Vendor = serde_json::from_str(&format!("\"{vendor_str}\""))
                    .unwrap_or(Vendor::Openai);
                Ok(ProviderConfig {
                    vendor,
                    base_url: row.get(1)?,
                    api_key: row.get(2)?,
                    model: row.get(3)?,
                    thinking_enabled: row.get::<_, i32>(4)? != 0,
                    updated_at: row.get(5)?,
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
                "SELECT vendor, base_url, api_key, model, thinking_enabled, updated_at
                 FROM provider_configs
                 ORDER BY vendor",
            )
            .context("Failed to prepare list_provider_configs query")?;

        let rows = stmt.query_map([], |row| {
            let vendor_str: String = row.get(0)?;
            let vendor: Vendor = serde_json::from_str(&format!("\"{vendor_str}\""))
                .unwrap_or(Vendor::Openai);
            Ok(ProviderConfig {
                vendor,
                base_url: row.get(1)?,
                api_key: row.get(2)?,
                model: row.get(3)?,
                thinking_enabled: row.get::<_, i32>(4)? != 0,
                updated_at: row.get(5)?,
            })
        })?;

        let mut configs = Vec::new();
        for row in rows {
            configs.push(row.context("Failed to read provider config row")?);
        }
        Ok(configs)
    }

    /// Delete a provider configuration by vendor.
    pub fn delete_provider_config(&self, vendor: Vendor) -> Result<()> {
        let vendor_str = serde_json::to_string(&vendor)
            .context("Failed to serialize vendor")?
            .trim_matches('"')
            .to_string();

        let conn = self.conn.lock().unwrap();
        conn.execute(
            "DELETE FROM provider_configs WHERE vendor = ?1",
            rusqlite::params![vendor_str],
        )
        .with_context(|| format!("Failed to delete provider config for {:?}", vendor))?;

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
            vendor: Vendor::Openai,
            base_url: "https://api.openai.com/v1".to_string(),
            api_key: "sk-test".to_string(),
            model: "gpt-4".to_string(),
            thinking_enabled: false,
            updated_at: String::new(),
        };

        db.save_provider_config(&config).unwrap();

        let loaded = db.get_provider_config(Vendor::Openai).unwrap().unwrap();
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

        let loaded = db.get_provider_config(Vendor::Deepseek).unwrap().unwrap();
        assert_eq!(loaded.api_key, "sk-new");
        assert_eq!(loaded.model, "deepseek-reasoner");
        assert!(loaded.thinking_enabled);
    }

    #[test]
    fn list_provider_configs() {
        let db = temp_db();

        db.save_provider_config(&ProviderConfig {
            vendor: Vendor::Openai,
            base_url: "https://api.openai.com/v1".to_string(),
            api_key: "sk-1".to_string(),
            model: "gpt-4".to_string(),
            thinking_enabled: false,
            updated_at: String::new(),
        })
        .unwrap();

        db.save_provider_config(&ProviderConfig {
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
            vendor: Vendor::Openai,
            base_url: "https://api.openai.com/v1".to_string(),
            api_key: "sk-test".to_string(),
            model: "gpt-4".to_string(),
            thinking_enabled: false,
            updated_at: String::new(),
        })
        .unwrap();

        db.delete_provider_config(Vendor::Openai).unwrap();

        let loaded = db.get_provider_config(Vendor::Openai).unwrap();
        assert!(loaded.is_none());
    }

    #[test]
    fn get_nonexistent_provider_config() {
        let db = temp_db();
        let loaded = db.get_provider_config(Vendor::Glm).unwrap();
        assert!(loaded.is_none());
    }

    #[test]
    fn kimi_provider_config_with_thinking() {
        let db = temp_db();

        db.save_provider_config(&ProviderConfig {
            vendor: Vendor::MoonshotKimi,
            base_url: "https://api.moonshot.cn/v1".to_string(),
            api_key: "sk-kimi".to_string(),
            model: "kimi-latest".to_string(),
            thinking_enabled: true,
            updated_at: String::new(),
        })
        .unwrap();

        let loaded = db.get_provider_config(Vendor::MoonshotKimi).unwrap().unwrap();
        assert_eq!(loaded.vendor, Vendor::MoonshotKimi);
        assert!(loaded.thinking_enabled);
    }
}
