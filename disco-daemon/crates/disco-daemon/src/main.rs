mod acp;
mod compaction_service;
mod daemon;
mod provider_service;
mod run_service;
mod session_service;

use std::collections::HashMap;
use std::sync::Arc;

use daemon::{AppState, ProviderRuntime, api_key_provider_runtime};
use disco_backends::{ClaudeCodeAdapter, CodexAdapter, OpenCodeAdapter, OpenCodeServerManager};
use disco_core::RunCoordinator;
use disco_persist::{Database, default_db_path};
use disco_protocol::types::{ProviderId, Vendor};
use disco_providers::{CodexProvider, UnavailableModelProvider};
use disco_tools::CompositeExecutor;
use disco_tools::file_edit::FileEditExecutor;
use disco_tools::search::SearchExecutor;
use disco_tools::shell::ShellExecutor;
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;
use tracing::info;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() {
    // daemon 只以 ACP stdio server 运行；stdout 专用于 JSON-RPC frame，日志统一写 stderr。
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    info!("disco-daemon starting...");

    // SQLite 的 WAL/SHM 伴随文件在首次写入时按进程 umask 创建。
    // 数据库内含明文 Provider 凭据，收紧 umask 确保所有伴随文件默认 0600。
    #[cfg(unix)]
    unsafe {
        libc::umask(0o077);
    }

    // Initialize database
    let db_path = default_db_path();
    info!("Database path: {}", db_path.display());
    let db = match Database::open(&db_path) {
        Ok(db) => db,
        Err(e) => {
            tracing::error!("Failed to open database: {e}");
            std::process::exit(1);
        }
    };

    // Create tool executor
    let mut composite = CompositeExecutor::new();
    composite.register(Box::new(ShellExecutor::new()));
    composite.register(Box::new(FileEditExecutor::new()));
    composite.register(Box::new(SearchExecutor::new()));
    let executor = Arc::new(composite);
    info!(
        "Tool executor registered: {} tools",
        executor.all_definitions().len()
    );

    // 默认服务商可选：没有环境变量时 daemon 仍可启动，
    // 用户可通过 UI 配置服务商（含 Codex 订阅，无需 API Key）。
    let environment_runtime = match std::env::var("OPENAI_API_KEY") {
        Ok(api_key) => {
            let base_url = std::env::var("OPENAI_BASE_URL")
                .unwrap_or_else(|_| "https://api.openai.com/v1".to_string());
            let model = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "gpt-4o".to_string());
            match api_key_provider_runtime(
                Vendor::Openai,
                base_url.clone(),
                api_key,
                model.clone(),
                executor.clone(),
            ) {
                Ok(runtime) => {
                    info!("Default Rig provider: model={model} base_url={base_url}");
                    Some(runtime)
                }
                Err(error) => {
                    tracing::warn!("Failed to create default Rig provider: {error}");
                    None
                }
            }
        }
        Err(_) => {
            tracing::warn!("No default provider from environment");
            tracing::warn!("Set OPENAI_API_KEY, or configure a provider in the app settings");
            None
        }
    };

    // Provider 保存账户/模型配置；Backend 保存 agent 运行语义。二者都按稳定 Provider ID 索引。
    let opencode_server_manager =
        Arc::new(OpenCodeServerManager::new(disco_providers::find_opencode()));
    let mut runtime_by_provider_id = HashMap::new();
    match db.list_provider_configs() {
        Ok(configs) => {
            for config in configs {
                let runtime = if config.provider_id.as_str() == ProviderId::CODEX_APP_SERVER {
                    let executable = CodexProvider::find_codex();
                    let reasoning_effort = config.reasoning_effort.clone();
                    ProviderRuntime {
                        compaction_provider: Arc::new(CodexProvider::new(
                            executable.clone(),
                            config.model,
                            reasoning_effort.clone(),
                            None,
                            None,
                        )),
                        backend: Arc::new(CodexAdapter::new(executable, reasoning_effort)),
                    }
                } else if config.provider_id.as_str() == ProviderId::OPENCODE_APP_SERVER {
                    ProviderRuntime {
                        backend: Arc::new(OpenCodeAdapter::new_with_server_manager(
                            opencode_server_manager.clone(),
                            config.reasoning_effort.clone(),
                        )),
                        compaction_provider: Arc::new(UnavailableModelProvider::new(
                            "OpenCode provider 不支持上下文压缩",
                        )),
                    }
                } else if config.provider_id.as_str() == ProviderId::CLAUDE_CODE {
                    ProviderRuntime {
                        backend: Arc::new(ClaudeCodeAdapter::new(
                            ClaudeCodeAdapter::find_executable(),
                            config.reasoning_effort.clone(),
                        )),
                        compaction_provider: Arc::new(UnavailableModelProvider::new(
                            "Claude Code provider 不支持 Disco 发起的本地上下文压缩",
                        )),
                    }
                } else {
                    match api_key_provider_runtime(
                        config.vendor,
                        config.base_url,
                        config.api_key,
                        config.model,
                        executor.clone(),
                    ) {
                        Ok(runtime) => runtime,
                        Err(error) => {
                            tracing::warn!(
                                "Failed to create provider runtime {}: {error}",
                                config.provider_id
                            );
                            continue;
                        }
                    }
                };
                info!("Loaded provider config: {}", config.provider_id);
                runtime_by_provider_id.insert(config.provider_id, runtime);
            }
        }
        Err(e) => {
            tracing::warn!("Failed to load provider configs: {e}");
        }
    }

    if let Some(runtime) = environment_runtime {
        let provider_id = ProviderId::legacy_default_for_vendor(Vendor::Openai);
        runtime_by_provider_id.entry(provider_id).or_insert(runtime);
    }

    // Create application state
    let shutdown = CancellationToken::new();
    let app = Arc::new(AppState {
        db,
        runtime_by_provider_id: Mutex::new(runtime_by_provider_id),
        opencode_model_catalog: Mutex::new(HashMap::new()),
        opencode_server_manager,
        run_coordinator: RunCoordinator::new(),
        executor,
        shutdown: shutdown.clone(),
        state_lock: Mutex::new(()),
        state_revision: std::sync::atomic::AtomicU64::new(0),
        event_journal: crate::daemon::EventJournal::new(),
    });

    if let Err(error) = acp::run_acp_stdio_server(app).await {
        tracing::error!(%error, "ACP stdio daemon stopped with an error");
        std::process::exit(1);
    }
}
