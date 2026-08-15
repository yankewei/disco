use std::collections::HashMap;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Arc;

use anyhow::{Context, Result};
use disco_core::ApprovalManager;
use disco_persist::Database;
use disco_providers::ModelProvider;
use disco_protocol::types::Vendor;
use disco_tools::CompositeExecutor;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};
use uuid::Uuid;

use crate::router;

/// Shared application state accessible from all connection handlers.
pub struct AppState {
    pub db: Database,
    /// 默认/主服务商（来自环境变量；可为 None，表示尚未配置任何服务商）。
    pub provider: Option<Arc<dyn ModelProvider>>,
    /// Map of configured providers by vendor.
    pub providers: Mutex<HashMap<Vendor, Arc<dyn ModelProvider>>>,
    /// Active runs keyed by run ID.
    pub active_runs: Mutex<HashMap<Uuid, CancellationToken>>,
    /// Active approval managers keyed by run ID.
    pub active_approval: Mutex<HashMap<Uuid, Arc<ApprovalManager>>>,
    /// Tool executor composite.
    pub executor: Arc<CompositeExecutor>,
    /// Shutdown signal.
    pub shutdown: CancellationToken,
}

impl AppState {
    /// Get the provider for a given vendor. Falls back to the default provider.
    pub async fn get_provider(&self, vendor: Option<Vendor>) -> Option<Arc<dyn ModelProvider>> {
        if let Some(vendor) = vendor {
            let providers = self.providers.lock().await;
            if let Some(provider) = providers.get(&vendor) {
                return Some(provider.clone());
            }
        }
        self.provider.clone()
    }

    /// Register a provider for a vendor.
    pub async fn set_provider(&self, vendor: Vendor, provider: Arc<dyn ModelProvider>) {
        let mut providers = self.providers.lock().await;
        providers.insert(vendor, provider);
    }

    /// Remove a provider for a vendor.
    #[allow(dead_code)]
    pub async fn remove_provider(&self, vendor: &Vendor) {
        let mut providers = self.providers.lock().await;
        providers.remove(vendor);
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
