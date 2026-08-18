use std::sync::Arc;

use disco_backends::CodexAdapter;
use disco_protocol::types::{ModelCatalogEntry, ProviderId, Vendor};
use disco_providers::CodexProvider;

use crate::daemon::{AppState, ProviderRuntime, api_key_provider_runtime};

/// Provider 配置产品操作的协议无关错误。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderError {
    InvalidParams(String),
    Internal(String),
}

impl ProviderError {
    pub fn into_acp_error(self) -> agent_client_protocol::Error {
        match self {
            ProviderError::InvalidParams(message) => {
                agent_client_protocol::Error::invalid_params().data(message)
            }
            ProviderError::Internal(message) => {
                agent_client_protocol::Error::internal_error().data(message)
            }
        }
    }
}

/// 校验/解析 Provider profile ID；保留 ID 与 vendor 的固定对应关系。
pub fn resolve_provider_id(
    provider_id: Option<ProviderId>,
    vendor: Vendor,
) -> Result<ProviderId, ProviderError> {
    let provider_id = provider_id.unwrap_or_else(|| ProviderId::legacy_default_for_vendor(vendor));
    let vendor_matches_reserved_id = match provider_id.as_str() {
        ProviderId::CODEX_APP_SERVER => vendor == Vendor::Codex,
        ProviderId::CODEX_API => vendor == Vendor::Openai,
        _ => true,
    };
    if !vendor_matches_reserved_id {
        return Err(ProviderError::InvalidParams(format!(
            "Provider {} 与 vendor {:?} 不匹配",
            provider_id, vendor
        )));
    }
    Ok(provider_id)
}

/// 配置并装配一个 Provider：持久化配置、构建 backend runtime 并原子替换。
pub async fn configure_provider(
    app: &Arc<AppState>,
    params: disco_protocol::ProviderConfigureParams,
) -> Result<disco_protocol::ProviderConfigureResult, ProviderError> {
    let provider_id = resolve_provider_id(params.provider_id.clone(), params.vendor)?;
    let config = disco_persist::provider_configs::ProviderConfig {
        provider_id,
        vendor: params.vendor,
        base_url: params.base_url.clone(),
        api_key: params.api_key.clone(),
        model: params.model.clone(),
        thinking_enabled: params.thinking_enabled,
        updated_at: String::new(),
    };

    let runtime = if config.provider_id.as_str() == ProviderId::CODEX_APP_SERVER {
        let executable = CodexProvider::find_codex();
        ProviderRuntime {
            compaction_provider: Arc::new(CodexProvider::new(
                executable.clone(),
                params.model.clone(),
                None,
                None,
                None,
            )),
            backend: Arc::new(CodexAdapter::new(executable, None)),
        }
    } else {
        api_key_provider_runtime(
            params.vendor,
            params.base_url.clone(),
            params.api_key.clone(),
            params.model.clone(),
            app.executor.clone(),
        )
        .map_err(|error| ProviderError::InvalidParams(error.to_string()))?
    };

    app.db
        .save_provider_config(&config)
        .map_err(|error| ProviderError::Internal(format!("保存 Provider 配置失败：{error}")))?;
    app.set_provider_runtime(config.provider_id.clone(), runtime)
        .await;

    Ok(disco_protocol::ProviderConfigureResult {
        provider_id: config.provider_id,
        vendor: params.vendor,
    })
}

/// 返回已配置的 Provider 列表（不含 API Key）。
pub fn list_providers(
    app: &Arc<AppState>,
) -> Result<Vec<disco_protocol::ProviderEntry>, ProviderError> {
    app.db
        .list_provider_configs()
        .map(|configs| {
            configs
                .into_iter()
                .map(|config| disco_protocol::ProviderEntry {
                    provider_id: config.provider_id,
                    vendor: config.vendor,
                    base_url: config.base_url,
                    model: config.model,
                    thinking_enabled: config.thinking_enabled,
                })
                .collect()
        })
        .map_err(|error| ProviderError::Internal(format!("读取 Provider 列表失败：{error}")))
}

/// 返回 Provider 的默认模型目录。
pub fn list_provider_models(
    params: disco_protocol::ProviderModelsParams,
) -> Result<Vec<ModelCatalogEntry>, ProviderError> {
    resolve_provider_id(params.provider_id, params.vendor)?;
    Ok(get_default_models(params.vendor))
}

pub fn get_default_models(vendor: Vendor) -> Vec<ModelCatalogEntry> {
    match vendor {
        Vendor::Openai => vec![
            ModelCatalogEntry {
                id: "gpt-4o".to_string(),
                display_name: Some("GPT-4o".to_string()),
                context_window: Some(128000),
                supported_reasoning_efforts: None,
                default_reasoning_effort: None,
            },
            ModelCatalogEntry {
                id: "gpt-4o-mini".to_string(),
                display_name: Some("GPT-4o mini".to_string()),
                context_window: Some(128000),
                supported_reasoning_efforts: None,
                default_reasoning_effort: None,
            },
            ModelCatalogEntry {
                id: "o4-mini".to_string(),
                display_name: Some("o4-mini".to_string()),
                context_window: Some(200000),
                supported_reasoning_efforts: Some(vec![
                    "low".to_string(),
                    "medium".to_string(),
                    "high".to_string(),
                ]),
                default_reasoning_effort: Some("medium".to_string()),
            },
        ],
        Vendor::Deepseek => vec![
            ModelCatalogEntry {
                id: "deepseek-chat".to_string(),
                display_name: Some("DeepSeek Chat".to_string()),
                context_window: Some(64000),
                supported_reasoning_efforts: None,
                default_reasoning_effort: None,
            },
            ModelCatalogEntry {
                id: "deepseek-reasoner".to_string(),
                display_name: Some("DeepSeek Reasoner".to_string()),
                context_window: Some(64000),
                supported_reasoning_efforts: None,
                default_reasoning_effort: None,
            },
        ],
        Vendor::MoonshotKimi | Vendor::KimiCode => vec![ModelCatalogEntry {
            id: "kimi-latest".to_string(),
            display_name: Some("Kimi".to_string()),
            context_window: Some(128000),
            supported_reasoning_efforts: Some(vec![
                "none".to_string(),
                "low".to_string(),
                "high".to_string(),
            ]),
            default_reasoning_effort: Some("high".to_string()),
        }],
        Vendor::Glm => vec![ModelCatalogEntry {
            id: "glm-4-plus".to_string(),
            display_name: Some("GLM-4 Plus".to_string()),
            context_window: Some(128000),
            supported_reasoning_efforts: None,
            default_reasoning_effort: None,
        }],
        Vendor::Codex => vec![ModelCatalogEntry {
            id: "codex".to_string(),
            display_name: Some("Codex".to_string()),
            context_window: Some(200000),
            supported_reasoning_efforts: Some(vec![
                "low".to_string(),
                "medium".to_string(),
                "high".to_string(),
            ]),
            default_reasoning_effort: Some("medium".to_string()),
        }],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::run_service::test_support::{ScriptedBackend, make_test_app};

    #[tokio::test]
    async fn configure_and_list_providers() {
        let (app, _session_id) = make_test_app(Arc::new(ScriptedBackend {
            outputs: vec![],
            backend_handle: None,
        }));

        let result = configure_provider(
            &app,
            disco_protocol::ProviderConfigureParams {
                provider_id: None,
                vendor: Vendor::Deepseek,
                base_url: "https://api.deepseek.com/v1".to_string(),
                api_key: "sk-test".to_string(),
                model: "deepseek-chat".to_string(),
                thinking_enabled: false,
            },
        )
        .await
        .unwrap();
        assert_eq!(result.vendor, Vendor::Deepseek);
        assert_eq!(result.provider_id.as_str(), "deepseek_api");

        let providers = list_providers(&app).unwrap();
        let configured = providers
            .iter()
            .find(|provider| provider.vendor == Vendor::Deepseek)
            .expect("配置后的 provider 应出现在列表中");
        assert_eq!(configured.model, "deepseek-chat");
        assert!(app.get_backend(&result.provider_id).await.is_some());
    }

    #[test]
    fn reserved_provider_id_rejects_mismatched_vendor() {
        let result = resolve_provider_id(
            Some(ProviderId::new(ProviderId::CODEX_APP_SERVER)),
            Vendor::Openai,
        );
        assert!(matches!(result, Err(ProviderError::InvalidParams(_))));
    }

    #[test]
    fn default_models_cover_major_vendors() {
        let models = get_default_models(Vendor::Openai);
        assert!(!models.is_empty());
        assert!(models.iter().any(|m| m.id == "gpt-4o"));

        let models = get_default_models(Vendor::Deepseek);
        assert!(models.iter().any(|m| m.id == "deepseek-chat"));

        assert!(!get_default_models(Vendor::Codex).is_empty());
    }

    #[test]
    fn list_provider_models_validates_reserved_ids() {
        let models = list_provider_models(disco_protocol::ProviderModelsParams {
            provider_id: None,
            vendor: Vendor::Openai,
        })
        .unwrap();
        assert!(models.iter().any(|m| m.id == "gpt-4o"));

        let error = list_provider_models(disco_protocol::ProviderModelsParams {
            provider_id: Some(ProviderId::new(ProviderId::CODEX_APP_SERVER)),
            vendor: Vendor::Openai,
        })
        .unwrap_err();
        assert!(matches!(error, ProviderError::InvalidParams(_)));
    }
}
