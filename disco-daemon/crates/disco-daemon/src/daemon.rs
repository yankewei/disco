use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use disco_backends::{
    OpenCodeServerManager, deepseek_runtime, openai_chat_runtime, openai_responses_runtime,
};
use disco_core::{AgentBackend, RunCoordinator};
use disco_persist::Database;
use disco_protocol::types::{ModelCatalogEntry, ProviderId, Vendor};
use disco_providers::ModelProvider;
use disco_tools::CompositeExecutor;
use serde::Serialize;
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

/// 一个 Provider profile 对应的运行时依赖。
pub struct ProviderRuntime {
    pub backend: Arc<dyn AgentBackend>,
    /// 迁移期仅供上下文压缩使用；后续由 Backend 自己实现 compact capability。
    pub compaction_provider: Arc<dyn ModelProvider>,
}

/// daemon 进程内的事件 epoch，以及每个 session 的单调序号和有限重放窗口。
///
/// 事件不写入 SQLite：它们是连接恢复用的短期运行时日志，权威历史仍由 session
/// 消息持久化提供。daemon 重启后 epoch 改变，客户端必须重新以快照为准。
#[derive(Debug, Clone, Serialize)]
pub struct EventReplayEntry {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub epoch: String,
    pub sequence: u64,
    pub update: serde_json::Value,
}

#[derive(Debug, Default)]
struct EventJournalState {
    next_sequence_by_session: HashMap<Uuid, u64>,
    entries_by_session: HashMap<Uuid, VecDeque<EventReplayEntry>>,
    order: VecDeque<(Uuid, u64)>,
}

#[derive(Debug)]
pub struct EventJournal {
    epoch: String,
    state: Mutex<EventJournalState>,
}

impl EventJournal {
    const MAX_ENTRIES_PER_SESSION: usize = 512;
    const MAX_ENTRIES_TOTAL: usize = 4096;

    pub fn new() -> Self {
        Self {
            epoch: Uuid::new_v4().to_string(),
            state: Mutex::new(EventJournalState::default()),
        }
    }

    pub fn epoch(&self) -> &str {
        &self.epoch
    }

    pub async fn record(&self, session_id: Uuid, update: serde_json::Value) -> EventReplayEntry {
        let mut state = self.state.lock().await;
        let sequence = state
            .next_sequence_by_session
            .entry(session_id)
            .and_modify(|value| *value += 1)
            .or_insert(1);
        let entry = EventReplayEntry {
            session_id: session_id.to_string(),
            epoch: self.epoch.clone(),
            sequence: *sequence,
            update,
        };
        let mut evicted_sequences = Vec::new();
        {
            let entries = state.entries_by_session.entry(session_id).or_default();
            entries.push_back(entry.clone());
            while entries.len() > Self::MAX_ENTRIES_PER_SESSION {
                if let Some(evicted) = entries.pop_front() {
                    evicted_sequences.push(evicted.sequence);
                }
            }
        }
        for sequence in evicted_sequences {
            state.order.retain(|key| *key != (session_id, sequence));
        }
        state.order.push_back((session_id, entry.sequence));
        while state.order.len() > Self::MAX_ENTRIES_TOTAL {
            let Some((evicted_session_id, evicted_sequence)) = state.order.pop_front() else {
                break;
            };
            let remove_session = state
                .entries_by_session
                .get_mut(&evicted_session_id)
                .map(|entries| {
                    if let Some(index) = entries
                        .iter()
                        .position(|entry| entry.sequence == evicted_sequence)
                    {
                        entries.remove(index);
                    }
                    entries.is_empty()
                })
                .unwrap_or(false);
            if remove_session {
                state.entries_by_session.remove(&evicted_session_id);
            }
        }
        entry
    }

    /// 清理 session 的可重放 payload 和 sequence；删除后的 session 需要重新建立游标。
    pub async fn clear_session(&self, session_id: Uuid) {
        let mut state = self.state.lock().await;
        state.entries_by_session.remove(&session_id);
        state.order.retain(|key| key.0 != session_id);
        state.next_sequence_by_session.remove(&session_id);
    }

    pub async fn replay(
        &self,
        session_id: Uuid,
        epoch: Option<&str>,
        after_sequence: u64,
    ) -> Vec<EventReplayEntry> {
        let state = self.state.lock().await;
        let after_sequence = if epoch == Some(self.epoch.as_str()) {
            after_sequence
        } else {
            0
        };
        state
            .entries_by_session
            .get(&session_id)
            .into_iter()
            .flatten()
            .filter(|entry| entry.sequence > after_sequence)
            .cloned()
            .collect()
    }
}

/// 根据产品层的 Vendor 选择 Rig provider 协议，并组装 API Key 后端。
pub fn api_key_provider_runtime(
    vendor: Vendor,
    base_url: String,
    api_key: String,
    model: String,
    executor: Arc<CompositeExecutor>,
) -> anyhow::Result<ProviderRuntime> {
    let runtime = match vendor {
        Vendor::Openai | Vendor::Codex => {
            openai_responses_runtime(base_url, api_key, model, executor)?
        }
        Vendor::Deepseek => deepseek_runtime(base_url, api_key, model, executor)?,
        Vendor::MoonshotKimi | Vendor::KimiCode | Vendor::Glm => {
            openai_chat_runtime(base_url, api_key, model, executor)?
        }
        // OpenCode 走本地 server backend，不会经过 API Key runtime。
        Vendor::OpenCode => anyhow::bail!("OpenCode 使用 server backend，不走 API Key runtime"),
    };
    Ok(ProviderRuntime {
        backend: runtime.backend,
        compaction_provider: runtime.compaction_provider,
    })
}

/// Shared application state accessible from all connection handlers.
pub struct AppState {
    pub db: Database,
    /// Provider 配置对应的运行时依赖，配置更新时原子替换。
    pub runtime_by_provider_id: Mutex<HashMap<ProviderId, ProviderRuntime>>,
    /// OpenCode 模型元数据缓存：来自本地 server API，按项目目录隔离，供上下文估算使用。
    pub opencode_model_catalog: Mutex<HashMap<String, Vec<ModelCatalogEntry>>>,
    /// daemon 进程内共享的 OpenCode server 生命周期管理器。
    pub opencode_server_manager: Arc<OpenCodeServerManager>,
    /// 活动运行、会话互斥、取消和审批路由。
    pub run_coordinator: RunCoordinator,
    /// Tool executor composite.
    pub executor: Arc<CompositeExecutor>,
    /// Shutdown signal.
    pub shutdown: CancellationToken,
    /// 串行化状态快照与持久化变更，确保 revision 对应同一份可观察状态。
    pub state_lock: Mutex<()>,
    /// 所有可观察持久化变更共享的单调 revision；客户端用它判断本地快照是否过期。
    pub state_revision: AtomicU64,
    /// session update 的短期 replay journal。
    pub event_journal: EventJournal,
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

    pub(crate) async fn set_provider_runtime_locked(
        &self,
        provider_id: ProviderId,
        runtime: ProviderRuntime,
    ) {
        self.runtime_by_provider_id
            .lock()
            .await
            .insert(provider_id, runtime);
        self.bump_state_revision();
    }

    pub fn state_revision(&self) -> u64 {
        self.state_revision.load(Ordering::Acquire)
    }

    pub fn bump_state_revision(&self) -> u64 {
        self.state_revision.fetch_add(1, Ordering::AcqRel) + 1
    }
}

#[cfg(test)]
mod tests {
    use super::EventJournal;
    use serde_json::json;
    use uuid::Uuid;

    #[tokio::test]
    async fn event_journal_assigns_per_session_sequences_and_replays_after_cursor() {
        let journal = EventJournal::new();
        let session_id = Uuid::new_v4();
        let first = journal.record(session_id, json!({"n": 1})).await;
        let second = journal.record(session_id, json!({"n": 2})).await;
        let other_session = journal.record(Uuid::new_v4(), json!({"n": 3})).await;

        assert_eq!(first.sequence, 1);
        assert_eq!(second.sequence, 2);
        assert_eq!(other_session.sequence, 1);
        assert_eq!(first.epoch, second.epoch);

        let replay = journal
            .replay(session_id, Some(&first.epoch), first.sequence)
            .await;
        assert_eq!(replay.len(), 1);
        assert_eq!(replay[0].sequence, 2);
        assert_eq!(replay[0].update, json!({"n": 2}));
    }

    #[tokio::test]
    async fn event_journal_resets_cursor_when_epoch_is_unknown() {
        let journal = EventJournal::new();
        let session_id = Uuid::new_v4();
        journal.record(session_id, json!({"n": 1})).await;

        let replay = journal
            .replay(session_id, Some("previous-daemon"), u64::MAX)
            .await;
        assert_eq!(replay.len(), 1);
        assert_eq!(replay[0].sequence, 1);
    }

    #[tokio::test]
    async fn event_journal_clears_deleted_session_payloads_and_sequence() {
        let journal = EventJournal::new();
        let session_id = Uuid::new_v4();
        let first = journal.record(session_id, json!({"n": 1})).await;

        journal.clear_session(session_id).await;
        assert!(
            journal
                .replay(session_id, Some(&first.epoch), 0)
                .await
                .is_empty()
        );

        let next = journal.record(session_id, json!({"n": 2})).await;
        assert_eq!(next.sequence, 1);
        let replay = journal.replay(session_id, Some(&first.epoch), 0).await;
        assert_eq!(replay.len(), 1);
        assert_eq!(replay[0].sequence, next.sequence);
    }
}
