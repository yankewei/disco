mod daemon;
mod router;

use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;
use tracing::info;
use tracing_subscriber::EnvFilter;
use daemon::{AppState, default_socket_path};
use disco_core::RunCoordinator;
use disco_persist::{Database, default_db_path};
use disco_providers::{CodexProvider, ModelProvider, OpenAIResponsesProvider};
use disco_protocol::types::{ProviderId, Vendor};
use disco_tools::CompositeExecutor;
use disco_tools::shell::ShellExecutor;
use disco_tools::file_edit::FileEditExecutor;
use disco_tools::search::SearchExecutor;

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

    // 默认服务商可选：没有环境变量时 daemon 仍可启动，
    // 用户可通过 UI 配置服务商（含 Codex 订阅，无需 API Key）。
    let environment_provider: Option<Arc<dyn ModelProvider>> =
        match OpenAIResponsesProvider::from_env() {
            Ok(provider) => {
                info!(
                    "Default provider: model={} base_url={}",
                    provider.model, provider.base_url
                );
                Some(provider)
            }
            Err(e) => {
                tracing::warn!("No default provider from environment: {e}");
                tracing::warn!("Set OPENAI_API_KEY, or configure a provider in the app settings");
                None
            }
        };

    // Load saved provider configs from database and populate the providers map.
    // codex_app_server 走本地子进程；codex_api 和其他模型 Provider 走模型 API。
    let mut provider_by_id = HashMap::new();
    match db.list_provider_configs() {
        Ok(configs) => {
            for config in configs {
                let provider: Arc<dyn ModelProvider> =
                    if config.provider_id.as_str() == ProviderId::CODEX_APP_SERVER {
                        Arc::new(CodexProvider::new(
                            CodexProvider::find_codex(),
                            config.model,
                            None, // 推理档位暂由 UI 控制，未落库
                            None, // 会话续接暂不启用
                        ))
                    } else {
                        Arc::new(OpenAIResponsesProvider::new(
                            config.base_url,
                            config.api_key,
                            config.model,
                        ))
                    };
                info!("Loaded provider config: {}", config.provider_id);
                provider_by_id.insert(config.provider_id, provider);
            }
        }
        Err(e) => {
            tracing::warn!("Failed to load provider configs: {e}");
        }
    }

    if let Some(provider) = environment_provider {
        provider_by_id
            .entry(ProviderId::legacy_default_for_vendor(Vendor::Openai))
            .or_insert(provider);
    }

    // Create tool executor
    let mut composite = CompositeExecutor::new();
    composite.register(Box::new(ShellExecutor::new()));
    composite.register(Box::new(FileEditExecutor::new()));
    composite.register(Box::new(SearchExecutor::new()));
    let executor = Arc::new(composite);
    info!("Tool executor registered: {} tools", executor.all_definitions().len());

    // Create application state
    let shutdown = CancellationToken::new();
    let app = Arc::new(AppState {
        db,
        provider_by_id: Mutex::new(provider_by_id),
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
