mod daemon;
mod router;

use std::collections::HashMap;
use std::sync::Arc;

use daemon::{AppState, ProviderRuntime, api_key_provider_runtime, default_socket_path};
use disco_backends::CodexAdapter;
use disco_core::RunCoordinator;
use disco_persist::{Database, default_db_path};
use disco_protocol::types::{ProviderId, Vendor};
use disco_providers::CodexProvider;
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
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    info!("disco-daemon starting...");

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
    let mut runtime_by_provider_id = HashMap::new();
    match db.list_provider_configs() {
        Ok(configs) => {
            for config in configs {
                let runtime = if config.provider_id.as_str() == ProviderId::CODEX_APP_SERVER {
                    let executable = CodexProvider::find_codex();
                    ProviderRuntime {
                        compaction_provider: Arc::new(CodexProvider::new(
                            executable.clone(),
                            config.model,
                            None,
                            None,
                            None,
                        )),
                        backend: Arc::new(CodexAdapter::new(executable, None)),
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
        run_coordinator: RunCoordinator::new(),
        executor,
        shutdown: shutdown.clone(),
    });

    // Socket path
    let socket_path = default_socket_path();
    info!("Socket path: {}", socket_path.display());

    // Spawn daemon task
    let daemon_app = app.clone();
    let daemon_handle = tokio::spawn(async move {
        if let Err(e) = daemon::run_daemon(&socket_path, daemon_app).await {
            tracing::error!("Daemon error: {e}");
        }
    });

    // Wait for SIGINT or SIGTERM
    info!("Press Ctrl+C to stop");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {
            info!("Received SIGINT, shutting down...");
            shutdown.cancel();
        }
        _ = daemon_handle => {
            info!("Daemon task completed");
        }
    }

    // Clean up
    info!("disco-daemon stopped");
}
