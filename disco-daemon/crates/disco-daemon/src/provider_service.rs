use std::sync::Arc;

use disco_backends::{CodexAdapter, ModelEntry, OpenCodeAdapter};
use disco_protocol::types::{ModelCatalogEntry, ProviderId, Vendor};
use disco_providers::{CodexProvider, UnavailableModelProvider};

use crate::daemon::{AppState, ProviderRuntime, api_key_provider_runtime};

fn opencode_runtime(adapter: OpenCodeAdapter) -> ProviderRuntime {
    ProviderRuntime {
        backend: Arc::new(adapter),
        compaction_provider: Arc::new(UnavailableModelProvider::new(
            "OpenCode provider 不支持上下文压缩",
        )),
    }
}

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
        ProviderId::OPENCODE_APP_SERVER => vendor == Vendor::OpenCode,
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
        reasoning_effort: params.reasoning_effort.clone(),
        updated_at: String::new(),
    };

    let runtime = if config.provider_id.as_str() == ProviderId::CODEX_APP_SERVER {
        let executable = CodexProvider::find_codex();
        ProviderRuntime {
            compaction_provider: Arc::new(CodexProvider::new(
                executable.clone(),
                params.model.clone(),
                params.reasoning_effort.clone(),
                None,
                None,
            )),
            backend: Arc::new(CodexAdapter::new(
                executable,
                params.reasoning_effort.clone(),
            )),
        }
    } else if config.provider_id.as_str() == ProviderId::OPENCODE_APP_SERVER {
        let runtime = opencode_runtime(OpenCodeAdapter::new_with_server_manager(
            app.opencode_server_manager.clone(),
            params.reasoning_effort.clone(),
        ));
        // 配置更新后清除模型目录缓存，下次请求重新从 server 拉取。
        app.opencode_model_catalog.lock().await.clear();
        runtime
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

    let _state_guard = app.state_lock.lock().await;
    app.db
        .save_provider_config(&config)
        .map_err(|error| ProviderError::Internal(format!("保存 Provider 配置失败：{error}")))?;
    app.set_provider_runtime_locked(config.provider_id.clone(), runtime)
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

/// 返回 Provider 的模型目录。
///
/// - OpenCode：从当前 runtime 的本地 server API 刷新读取，结果写入运行时元数据缓存。
/// - API Key 类服务商：带凭据时用 Rig `list_models()` 实时查询，失败回退内置目录。
/// - 其他：内置默认目录。
pub async fn list_provider_models(
    app: &Arc<AppState>,
    params: disco_protocol::ProviderModelsParams,
) -> Result<Vec<ModelCatalogEntry>, ProviderError> {
    let provider_id = resolve_provider_id(params.provider_id, params.vendor)?;
    match params.vendor {
        Vendor::OpenCode => opencode_model_catalog(app, provider_id, params.workspace_path).await,
        Vendor::Codex => {
            let executable = CodexProvider::find_codex();
            codex_app_server_models(&executable).await
        }
        Vendor::Deepseek
        | Vendor::Openai
        | Vendor::MoonshotKimi
        | Vendor::KimiCode
        | Vendor::Glm => {
            api_key_vendor_models(
                params.vendor,
                params.base_url.as_deref(),
                params.api_key.as_deref(),
            )
            .await
        }
    }
}

/// Codex app-server 模式的“验证”：通过与 app-server 的 `model/list` 查询真实模型。
///
/// 建立 initialize 握手即证明本地 codex CLI 可用（含登录态），`model/list` 返回
/// 真实模型及其 effort 能力，替代内置硬编码目录。
async fn codex_app_server_models(
    executable: &str,
) -> Result<Vec<ModelCatalogEntry>, ProviderError> {
    let entries = disco_providers::list_codex_models(executable)
        .await
        .map_err(|error| {
            ProviderError::InvalidParams(format!("验证 codex app-server 失败：{error}"))
        })?;
    if entries.is_empty() {
        return Err(ProviderError::InvalidParams(
            "codex app-server 未返回任何可用模型".to_string(),
        ));
    }
    Ok(entries
        .into_iter()
        .map(|entry| ModelCatalogEntry {
            id: entry.id,
            display_name: entry.display_name,
            // model/list 不提供上下文窗口，由客户端按已知模型兜底
            context_window: None,
            supported_reasoning_efforts: entry
                .supported_reasoning_efforts
                .map(|efforts| efforts.into_iter().map(|e| e.reasoning_effort).collect()),
            default_reasoning_effort: entry.default_reasoning_effort,
        })
        .collect())
}

/// 用 Rig 实时获取 API Key 类服务商的模型列表。
///
/// 带凭据时请求失败会直接报错（让“验证”真实反映凭据可用性）；
/// 未提供凭据时回退内置目录。
async fn api_key_vendor_models(
    vendor: Vendor,
    base_url: Option<&str>,
    api_key: Option<&str>,
) -> Result<Vec<ModelCatalogEntry>, ProviderError> {
    let base_url = base_url.map(str::trim).filter(|value| !value.is_empty());
    let api_key = api_key.map(str::trim).filter(|value| !value.is_empty());
    let (Some(base_url), Some(api_key)) = (base_url, api_key) else {
        return Ok(get_default_models(vendor));
    };
    let result = match vendor {
        Vendor::Deepseek => disco_backends::list_models_deepseek(base_url, api_key).await,
        _ => disco_backends::list_models_openai_compat(base_url, api_key).await,
    };
    let models = result.map_err(|error| {
        ProviderError::InvalidParams(format!("验证凭据失败，无法获取模型列表：{error}"))
    })?;
    let chat_models: Vec<ModelEntry> = models.into_iter().filter(is_chat_capable_model).collect();
    if chat_models.is_empty() {
        return Err(ProviderError::InvalidParams(
            "凭据可用但服务商未返回可对话模型".to_string(),
        ));
    }
    Ok(chat_models
        .into_iter()
        .map(|model| ModelCatalogEntry {
            id: model.id,
            display_name: model.display_name,
            context_window: model.context_window,
            supported_reasoning_efforts: None,
            default_reasoning_effort: None,
        })
        .collect())
}

/// 判断实时模型目录中的条目是否适合当前统一 chat completions runtime。
///
/// 标准 OpenAI `/models` 响应通常没有能力字段，因此在服务商未声明类型时，
/// 还需要用稳定的非对话模型命名标记做保守过滤。未知模型默认保留，避免误删
/// 第三方服务商的自定义 chat 模型。
fn is_chat_capable_model(model: &ModelEntry) -> bool {
    if let Some(model_type) = model.model_type.as_deref() {
        let normalized_type = model_type.trim().to_ascii_lowercase();
        if matches!(
            normalized_type.as_str(),
            "embedding" | "audio" | "image" | "moderation" | "rerank"
        ) {
            return false;
        }
    }

    const NON_CHAT_MODEL_MARKERS: &[&str] = &[
        "embedding",
        "embed-",
        "whisper",
        "text-to-speech",
        "tts-",
        "dall-e",
        "moderation",
        "rerank",
        "audio-",
    ];
    let normalized_id = model.id.to_ascii_lowercase();
    !NON_CHAT_MODEL_MARKERS
        .iter()
        .any(|marker| normalized_id.contains(marker))
}

/// 返回 OpenCode 模型目录：每次验证都通过当前 runtime 的 server API 读取真实列表。
///
/// server 不可用或未返回模型列表时返回错误（让设置页验证如实失败），
/// 不缓存失败结果。
async fn opencode_model_catalog(
    app: &Arc<AppState>,
    provider_id: ProviderId,
    workspace_path: Option<String>,
) -> Result<Vec<ModelCatalogEntry>, ProviderError> {
    // None 仅用于兼容旧客户端；新客户端总是传当前会话所属项目目录。
    let cache_key = workspace_path
        .as_deref()
        .filter(|path| !path.trim().is_empty())
        .unwrap_or("__daemon_current_directory__")
        .to_string();
    let backend = app.get_backend(&provider_id).await.ok_or_else(|| {
        ProviderError::Internal(format!(
            "Provider {} 当前没有可用的 OpenCode Backend",
            provider_id
        ))
    })?;
    let catalog = backend.list_models(workspace_path).await.map_err(|error| {
        ProviderError::InvalidParams(format!("无法读取 OpenCode 模型列表：{error}"))
    })?;
    if catalog.is_empty() {
        return Err(ProviderError::InvalidParams(
            "OpenCode 没有返回可用的已连接模型，请先在 OpenCode CLI 中登录 provider。".to_string(),
        ));
    }
    app.opencode_model_catalog
        .lock()
        .await
        .insert(cache_key, catalog.clone());
    Ok(catalog)
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
        // OpenCode 模型目录来自本地 server API，不使用静态兜底列表。
        Vendor::OpenCode => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::run_service::test_support::{ScriptedBackend, make_test_app};

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    #[cfg(unix)]
    use uuid::Uuid;

    /// 临时可执行的 fake codex 脚本（模仿 disco-backends 测试的 FakeCodexExecutable）。
    #[cfg(unix)]
    struct FakeCodex {
        directory: std::path::PathBuf,
        path: std::path::PathBuf,
    }

    #[cfg(unix)]
    impl FakeCodex {
        fn new(script: &str) -> Self {
            let directory =
                std::env::temp_dir().join(format!("disco-probe-codex-{}", Uuid::new_v4()));
            std::fs::create_dir_all(&directory).unwrap();
            let path = directory.join("codex");
            std::fs::write(&path, script).unwrap();
            let mut permissions = std::fs::metadata(&path).unwrap().permissions();
            permissions.set_mode(0o700);
            std::fs::set_permissions(&path, permissions).unwrap();
            Self { directory, path }
        }

        fn path(&self) -> String {
            self.path.display().to_string()
        }
    }

    #[cfg(unix)]
    impl Drop for FakeCodex {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
            let _ = std::fs::remove_dir(&self.directory);
        }
    }

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
                reasoning_effort: None,
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

        // OpenCode 模型目录只来自本地 server，内置目录应为空。
        assert!(get_default_models(Vendor::OpenCode).is_empty());
    }

    #[test]
    fn non_chat_models_are_filtered_from_live_catalogs() {
        let embedding = ModelEntry {
            id: "text-embedding-3-small".to_string(),
            display_name: None,
            model_type: None,
            context_window: None,
        };
        let typed_audio = ModelEntry {
            id: "custom-audio-model".to_string(),
            display_name: None,
            model_type: Some("audio".to_string()),
            context_window: None,
        };
        let custom_chat = ModelEntry {
            id: "vendor-chat-pro".to_string(),
            display_name: None,
            model_type: None,
            context_window: Some(131_072),
        };

        assert!(!is_chat_capable_model(&embedding));
        assert!(!is_chat_capable_model(&typed_audio));
        assert!(is_chat_capable_model(&custom_chat));
    }

    #[test]
    fn opencode_provider_id_maps_to_reserved_profile() {
        let provider_id = ProviderId::legacy_default_for_vendor(Vendor::OpenCode);
        assert_eq!(provider_id.as_str(), ProviderId::OPENCODE_APP_SERVER);

        let result = resolve_provider_id(Some(provider_id.clone()), Vendor::OpenCode);
        assert!(result.is_ok());

        let mismatch = resolve_provider_id(Some(provider_id), Vendor::Openai);
        assert!(matches!(mismatch, Err(ProviderError::InvalidParams(_))));
    }

    #[tokio::test]
    async fn list_provider_models_validates_reserved_ids() {
        let (app, _session_id) = make_test_app(Arc::new(ScriptedBackend {
            outputs: vec![],
            backend_handle: None,
        }));

        let models = list_provider_models(
            &app,
            disco_protocol::ProviderModelsParams {
                provider_id: None,
                vendor: Vendor::Openai,
                base_url: None,
                api_key: None,
                workspace_path: None,
            },
        )
        .await
        .unwrap();
        assert!(models.iter().any(|m| m.id == "gpt-4o"));

        let error = list_provider_models(
            &app,
            disco_protocol::ProviderModelsParams {
                provider_id: Some(ProviderId::new(ProviderId::CODEX_APP_SERVER)),
                vendor: Vendor::Openai,
                base_url: None,
                api_key: None,
                workspace_path: None,
            },
        )
        .await
        .unwrap_err();
        assert!(matches!(error, ProviderError::InvalidParams(_)));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn codex_provider_models_uses_live_model_list() {
        // 用 fake codex 脚本模拟 app-server：处理 initialize 后响应 model/list。
        let fake = FakeCodex::new(
            r###"#!/bin/sh
read -r init_line
printf '%s\n' '{"id":0,"result":{"protocolVersion":"1"}}'
read -r init_notification
read -r list_line
printf '%s\n' '{"id":1,"result":{"data":[{"id":"gpt-5.6-sol","model":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}]}]}}'"###,
        );

        let models = crate::provider_service::codex_app_server_models(&fake.path())
            .await
            .expect("fake codex app-server 应返回模型列表");
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, "gpt-5.6-sol");
        assert_eq!(models[0].default_reasoning_effort.as_deref(), Some("low"));
        assert_eq!(
            models[0]
                .supported_reasoning_efforts
                .as_ref()
                .map(|e| e.len()),
            Some(2)
        );
    }
}
