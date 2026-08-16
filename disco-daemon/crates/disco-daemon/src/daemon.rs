use std::collections::HashMap;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Arc;

use crate::router;
use anyhow::{Context, Result};
use disco_backends::{
    RigBackend, deepseek_provider, openai_chat_provider, openai_responses_provider,
};
use disco_core::{AgentBackend, RunCoordinator};
use disco_persist::Database;
use disco_protocol::types::{ProviderId, Vendor};
use disco_providers::ModelProvider;
use disco_tools::CompositeExecutor;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};

/// 一个 Provider profile 对应的运行时依赖。
pub struct ProviderRuntime {
    pub backend: Arc<dyn AgentBackend>,
    /// 迁移期仅供上下文压缩使用；RigBackend 落地后由 Backend 自己实现 compact capability。
    pub compaction_provider: Arc<dyn ModelProvider>,
}

/// 根据产品层的 Vendor 选择 Rig provider 协议，并组装 API Key 后端。
pub fn api_key_provider_runtime(
    vendor: Vendor,
    base_url: String,
    api_key: String,
    model: String,
    executor: Arc<CompositeExecutor>,
) -> Result<ProviderRuntime> {
    let provider = match vendor {
        Vendor::Openai | Vendor::Codex => openai_responses_provider(base_url, api_key, model)?,
        Vendor::Deepseek => deepseek_provider(base_url, api_key, model)?,
        Vendor::MoonshotKimi | Vendor::KimiCode | Vendor::Glm => {
            openai_chat_provider(base_url, api_key, model)?
        }
    };
    Ok(ProviderRuntime {
        backend: Arc::new(RigBackend::new(provider.clone(), executor)),
        compaction_provider: provider,
    })
}

/// Shared application state accessible from all connection handlers.
pub struct AppState {
    pub db: Database,
    /// Provider 配置对应的运行时依赖，配置更新时原子替换。
    pub runtime_by_provider_id: Mutex<HashMap<ProviderId, ProviderRuntime>>,
    /// 活动运行、会话互斥、取消和审批路由。
    pub run_coordinator: RunCoordinator,
    /// Tool executor composite.
    pub executor: Arc<CompositeExecutor>,
    /// Shutdown signal.
    pub shutdown: CancellationToken,
}

impl AppState {
    pub async fn get_backend(&self, provider_id: &ProviderId) -> Option<Arc<dyn AgentBackend>> {
        self.runtime_by_provider_id
            .lock()
            .await
            .get(provider_id)
            .map(|runtime| runtime.backend.clone())
    }

    pub async fn get_compaction_provider(
        &self,
        provider_id: &ProviderId,
    ) -> Option<Arc<dyn ModelProvider>> {
        self.runtime_by_provider_id
            .lock()
            .await
            .get(provider_id)
            .map(|runtime| runtime.compaction_provider.clone())
    }

    pub async fn set_provider_runtime(&self, provider_id: ProviderId, runtime: ProviderRuntime) {
        self.runtime_by_provider_id
            .lock()
            .await
            .insert(provider_id, runtime);
    }
}

/// Return the default socket path: ~/Library/Application Support/disco/disco.sock
pub fn default_socket_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").expect("HOME environment variable not set");
    std::path::PathBuf::from(home)
        .join("Library/Application Support/disco")
        .join("disco.sock")
}

/// Run the daemon: listen on a Unix socket and handle connections.
///
/// This function runs until the shutdown token is cancelled.
pub async fn run_daemon(socket_path: &Path, app: Arc<AppState>) -> Result<()> {
    // Remove stale socket file if it exists
    if socket_path.exists() {
        std::fs::remove_file(socket_path)
            .with_context(|| format!("Failed to remove stale socket {}", socket_path.display()))?;
    }

    // Ensure parent directory exists
    if let Some(parent) = socket_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create directory {}", parent.display()))?;
    }

    let listener = UnixListener::bind(socket_path)
        .with_context(|| format!("Failed to bind Unix socket {}", socket_path.display()))?;
    // socket 上会传输 API Key 等敏感数据，仅允许当前用户连接。
    #[cfg(unix)]
    std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o600))
        .with_context(|| format!("Failed to set socket permissions {}", socket_path.display()))?;

    info!("Daemon listening on {}", socket_path.display());

    loop {
        tokio::select! {
            accept_result = listener.accept() => {
                match accept_result {
                    Ok((stream, _addr)) => {
                        let app = app.clone();
                        tokio::spawn(async move {
                            if let Err(e) = handle_connection(stream, app).await {
                                error!("Connection handler error: {e}");
                            }
                        });
                    }
                    Err(e) => {
                        error!("Failed to accept connection: {e}");
                    }
                }
            }
            _ = app.shutdown.cancelled() => {
                info!("Shutdown signal received, stopping daemon");
                break;
            }
        }
    }

    // Clean up socket file
    if socket_path.exists() {
        let _ = std::fs::remove_file(socket_path);
    }

    Ok(())
}

/// Handle a single client connection.
///
/// Reads JSONL requests, dispatches them, and writes JSONL responses/events.
async fn handle_connection(stream: UnixStream, app: Arc<AppState>) -> Result<()> {
    let (reader, writer) = stream.into_split();
    let mut buf_reader = BufReader::new(reader);

    // Channel for outgoing messages (responses + events)
    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel::<String>(128);

    // Writer task: reads from channel and writes to socket
    let writer_handle = tokio::spawn(async move {
        let mut writer = writer;
        while let Some(line) = out_rx.recv().await {
            if let Err(e) = writer.write_all(line.as_bytes()).await {
                debug!("Write error (client disconnected?): {e}");
                break;
            }
        }
    });

    // Reader loop: read JSONL lines and dispatch
    let mut line = String::new();
    loop {
        line.clear();
        let bytes_read = match buf_reader.read_line(&mut line).await {
            Ok(0) => {
                debug!("Client disconnected (EOF)");
                break;
            }
            Ok(n) => n,
            Err(e) => {
                warn!("Read error: {e}");
                break;
            }
        };

        if bytes_read == 0 {
            break;
        }

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        // Parse the request
        let req = match disco_protocol::decode_request(trimmed) {
            Ok(req) => req,
            Err(e) => {
                warn!("Failed to parse request: {e}");
                let resp = disco_protocol::Response {
                    id: 0,
                    result: None,
                    error: Some(disco_protocol::RpcError::invalid_params(&e.to_string())),
                };
                if let Ok(jsonl) = disco_protocol::encode_jsonl(&resp) {
                    let _ = out_tx.send(jsonl).await;
                }
                continue;
            }
        };

        debug!("Received request: id={} method={}", req.id, req.method);

        // Route the request
        let is_shutdown = req.method == "shutdown";
        router::handle_request(&req, &app, &out_tx).await;

        if is_shutdown {
            info!("Shutdown requested by client");
            break;
        }
    }

    // Drop the sender to signal the writer task to finish
    drop(out_tx);
    let _ = writer_handle.await;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_socket_path_is_under_home() {
        let path = default_socket_path();
        assert!(path.to_str().unwrap().contains("disco.sock"));
    }
}
