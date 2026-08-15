// Approval flow: gate tool execution on user approval.
//
// The ApprovalManager bridges the agent loop (which blocks on approval
// decisions) and the daemon router (which receives decisions from the
// client). It uses `tokio::sync::oneshot` channels so each approval
// request blocks exactly the task that needs it.

use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::{Mutex, oneshot};
use uuid::Uuid;

use disco_protocol::types::{ApprovalDecision, ApprovalImpact};

// MARK: - Approval request

/// A request for user approval before executing a tool.
#[derive(Debug, Clone)]
pub struct ApprovalRequest {
    pub id: Uuid,
    pub run_id: Uuid,
    pub kind: String,
    pub title: String,
    pub reason: Option<String>,
    pub impact: ApprovalImpact,
    pub fingerprint: String,
    pub allows_session_approval: bool,
}

// MARK: - ApprovalManager

/// Manages pending approval requests for a single run.
///
/// The agent loop calls `request_approval` which blocks until the router
/// (or UI) calls `respond` with a decision. Session-level approvals are
/// tracked so that subsequent requests with the same fingerprint are
/// automatically approved.
pub struct ApprovalManager {
    /// Pending approval requests. Keyed by approval ID.
    /// The sender is the oneshot half; the agent loop holds the receiver.
    pending: Mutex<HashMap<Uuid, oneshot::Sender<ApprovalDecision>>>,
    /// Fingerprints approved for the session. These bypass future requests.
    session_approved: Arc<Mutex<Vec<String>>>,
}

impl ApprovalManager {
    /// Create a new ApprovalManager.
    ///
    /// `session_approved` is shared with the agent loop so that it can
    /// check and update session-level approvals without going through
    /// the manager.
    pub fn new(session_approved: Arc<Mutex<Vec<String>>>) -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
            session_approved,
        }
    }

    /// Request approval for a tool execution.
    ///
    /// If the fingerprint has already been approved for the session,
    /// returns `ApproveOnce` immediately. Otherwise, blocks until the
    /// router calls `respond` with a decision.
    pub async fn request_approval(&self, request: &ApprovalRequest) -> ApprovalDecision {
        // Check session approval
        {
            let approved = self.session_approved.lock().await;
            if approved.contains(&request.fingerprint) {
                return ApprovalDecision::ApproveOnce;
            }
        }

        // Create a oneshot channel for this request
        let (tx, rx) = oneshot::channel();

        // Register the pending request
        {
            let mut pending = self.pending.lock().await;
            pending.insert(request.id, tx);
        }

        // Wait for a decision from the router
        match rx.await {
            Ok(decision) => {
                // If approved for session, record the fingerprint
                if decision == ApprovalDecision::ApproveForSession {
                    let mut approved = self.session_approved.lock().await;
                    approved.push(request.fingerprint.clone());
                }
                decision
            }
            Err(_) => {
                // Sender dropped (e.g., run cancelled)
                ApprovalDecision::Decline
            }
        }
    }

    /// Respond to a pending approval request.
    ///
    /// Returns `true` if the approval was found and the decision was sent.
    pub async fn respond(&self, approval_id: Uuid, decision: ApprovalDecision) -> bool {
        let mut pending = self.pending.lock().await;
        if let Some(tx) = pending.remove(&approval_id) {
            tx.send(decision).is_ok()
        } else {
            false
        }
    }

    /// Cancel all pending approval requests (e.g., when the run is cancelled).
    pub async fn cancel_all(&self) {
        let mut pending = self.pending.lock().await;
        pending.clear();
        // Dropping the senders causes all waiting receivers to get Err,
        // which the agent loop interprets as Decline.
    }
}

// MARK: - Helpers

/// Generate a fingerprint for a tool call. Used for session-level approval
/// deduplication.
pub fn make_fingerprint(tool_name: &str, arguments: &str) -> String {
    format!("{tool_name}:{arguments}")
}

/// Build an `ApprovalImpact` from a tool call. Currently produces a
/// generic Command impact; in the future each executor can provide its
/// own impact details.
pub fn impact_from_tool_call(tool_name: &str, arguments: &str) -> ApprovalImpact {
    // Try to extract command from arguments JSON
    if let Ok(json) = serde_json::from_str::<serde_json::Value>(arguments) {
        if let Some(cmd) = json.get("command").and_then(|v| v.as_str()) {
            return ApprovalImpact::Command {
                executable: cmd.split_whitespace().next().unwrap_or(cmd).to_string(),
                arguments: cmd
                    .split_whitespace()
                    .skip(1)
                    .map(String::from)
                    .collect(),
                cwd: json
                    .get("cwd")
                    .and_then(|v| v.as_str())
                    .unwrap_or(".")
                    .to_string(),
            };
        }
        if let Some(path) = json.get("path").and_then(|v| v.as_str()) {
            return ApprovalImpact::FileChange {
                paths: vec![path.to_string()],
                summary: format!("{tool_name} on {path}"),
                diff: None,
            };
        }
    }

    // Fallback: generic permission impact
    ApprovalImpact::Permission {
        scope: tool_name.to_string(),
        description: format!("Execute tool: {tool_name}"),
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use disco_protocol::types::ApprovalDecision;

    fn make_session_approved() -> Arc<Mutex<Vec<String>>> {
        Arc::new(Mutex::new(Vec::new()))
    }

    fn make_request(id: Uuid, fingerprint: &str) -> ApprovalRequest {
        ApprovalRequest {
            id,
            run_id: Uuid::new_v4(),
            kind: "command".to_string(),
            title: "Run command".to_string(),
            reason: None,
            impact: ApprovalImpact::Command {
                executable: "ls".to_string(),
                arguments: vec!["-la".to_string()],
                cwd: "/tmp".to_string(),
            },
            fingerprint: fingerprint.to_string(),
            allows_session_approval: true,
        }
    }

    #[tokio::test]
    async fn request_and_approve() {
        let session = make_session_approved();
        let manager = ApprovalManager::new(session);
        let approval_id = Uuid::new_v4();
        let request = make_request(approval_id, "fp1");

        // Spawn a task that requests approval
        let manager = Arc::new(manager);
        let mgr_clone = manager.clone();
        let handle = tokio::spawn(async move {
            mgr_clone.request_approval(&request).await
        });

        // Give the request time to register
        tokio::task::yield_now().await;

        // Respond with approval
        let responded = manager.respond(approval_id, ApprovalDecision::ApproveOnce).await;
        assert!(responded);

        // The requesting task should complete
        let decision = handle.await.unwrap();
        assert_eq!(decision, ApprovalDecision::ApproveOnce);
    }

    #[tokio::test]
    async fn request_and_decline() {
        let session = make_session_approved();
        let manager = ApprovalManager::new(session);
        let approval_id = Uuid::new_v4();
        let request = make_request(approval_id, "fp2");

        let manager = Arc::new(manager);
        let mgr_clone = manager.clone();
        let handle = tokio::spawn(async move {
            mgr_clone.request_approval(&request).await
        });

        tokio::task::yield_now().await;

        let responded = manager.respond(approval_id, ApprovalDecision::Decline).await;
        assert!(responded);

        let decision = handle.await.unwrap();
        assert_eq!(decision, ApprovalDecision::Decline);
    }

    #[tokio::test]
    async fn session_approval_skips_second_request() {
        let session = make_session_approved();
        let manager = ApprovalManager::new(session.clone());
        let manager = Arc::new(manager);

        // First request: approve for session
        let id1 = Uuid::new_v4();
        let req1 = make_request(id1, "fp_session");

        let mgr1 = manager.clone();
        let h1 = tokio::spawn(async move {
            mgr1.request_approval(&req1).await
        });

        tokio::task::yield_now().await;
        manager.respond(id1, ApprovalDecision::ApproveForSession).await;
        let d1 = h1.await.unwrap();
        assert_eq!(d1, ApprovalDecision::ApproveForSession);

        // Verify fingerprint is recorded
        assert!(session.lock().await.contains(&"fp_session".to_string()));

        // Second request with same fingerprint: should auto-approve
        let id2 = Uuid::new_v4();
        let req2 = make_request(id2, "fp_session");
        let d2 = manager.request_approval(&req2).await;
        assert_eq!(d2, ApprovalDecision::ApproveOnce);
    }

    #[tokio::test]
    async fn respond_to_unknown_approval_returns_false() {
        let session = make_session_approved();
        let manager = ApprovalManager::new(session);
        let result = manager
            .respond(Uuid::new_v4(), ApprovalDecision::ApproveOnce)
            .await;
        assert!(!result);
    }

    #[tokio::test]
    async fn cancel_all_drops_pending() {
        let session = make_session_approved();
        let manager = ApprovalManager::new(session);
        let manager = Arc::new(manager);

        let id = Uuid::new_v4();
        let req = make_request(id, "fp_cancel");

        let mgr = manager.clone();
        let handle = tokio::spawn(async move {
            mgr.request_approval(&req).await
        });

        tokio::task::yield_now().await;

        // Cancel all pending
        manager.cancel_all().await;

        // The requesting task should get Decline (sender dropped)
        let decision = handle.await.unwrap();
        assert_eq!(decision, ApprovalDecision::Decline);
    }

    #[test]
    fn fingerprint_generation() {
        let fp = make_fingerprint("shell", r#"{"command":"ls"}"#);
        assert_eq!(fp, r#"shell:{"command":"ls"}"#);
    }

    #[test]
    fn impact_from_shell_command() {
        let impact = impact_from_tool_call("shell", r#"{"command":"ls -la /tmp","cwd":"/home"}"#);
        match impact {
            ApprovalImpact::Command { executable, arguments, cwd } => {
                assert_eq!(executable, "ls");
                assert_eq!(arguments, vec!["-la", "/tmp"]);
                assert_eq!(cwd, "/home");
            }
            _ => panic!("Expected Command impact"),
        }
    }

    #[test]
    fn impact_from_file_edit() {
        let impact = impact_from_tool_call("file_edit", r#"{"path":"src/main.rs"}"#);
        match impact {
            ApprovalImpact::FileChange { paths, .. } => {
                assert_eq!(paths, vec!["src/main.rs"]);
            }
            _ => panic!("Expected FileChange impact"),
        }
    }

    #[test]
    fn impact_fallback_for_unknown_tool() {
        let impact = impact_from_tool_call("unknown_tool", r#"{"key":"value"}"#);
        match impact {
            ApprovalImpact::Permission { scope, .. } => {
                assert_eq!(scope, "unknown_tool");
            }
            _ => panic!("Expected Permission impact"),
        }
    }
}
