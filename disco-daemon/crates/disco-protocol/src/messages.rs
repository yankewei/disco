use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::types::*;

// MARK: - Provider 配置（daemon 内部服务共享；ACP facade 据此构造 extension 响应）

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderConfigureParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_id: Option<ProviderId>,
    pub vendor: Vendor,
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    #[serde(default)]
    pub thinking_enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderConfigureResult {
    pub provider_id: ProviderId,
    pub vendor: Vendor,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderEntry {
    pub provider_id: ProviderId,
    pub vendor: Vendor,
    pub base_url: String,
    pub model: String,
    pub thinking_enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderModelsParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_id: Option<ProviderId>,
    pub vendor: Vendor,
}

// MARK: - 审批（run service 产生的协议无关审批请求）

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApprovalRequestedData {
    pub run_id: Uuid,
    pub session_id: Uuid,
    pub approval_id: Uuid,
    pub kind: ApprovalKind,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub impact: ApprovalImpact,
    pub fingerprint: String,
    pub allows_session_approval: bool,
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip<T: Serialize + for<'de> Deserialize<'de> + PartialEq + std::fmt::Debug>(
        value: &T,
    ) {
        let json = serde_json::to_string(value).unwrap();
        let decoded: T = serde_json::from_str(&json).unwrap();
        assert_eq!(value, &decoded);
    }

    #[test]
    fn approval_impact_command_round_trip() {
        let impact = ApprovalImpact::Command {
            executable: "rm".into(),
            arguments: vec!["-rf".into(), "build/".into()],
            cwd: "/Users/test".into(),
        };
        round_trip(&impact);

        let json = serde_json::to_string(&impact).unwrap();
        assert!(json.contains("\"type\":\"command\""));
    }

    #[test]
    fn approval_impact_file_change_round_trip() {
        let impact = ApprovalImpact::FileChange {
            paths: vec!["src/main.rs".into()],
            summary: "修改了主文件".into(),
            diff: Some("@@ -1,3 +1,4 @@\n+new line".into()),
        };
        round_trip(&impact);
    }

    #[test]
    fn vendor_serialization() {
        let v = Vendor::Deepseek;
        let json = serde_json::to_string(&v).unwrap();
        assert_eq!(json, "\"deepseek\"");

        let v: Vendor = serde_json::from_str("\"kimi_code\"").unwrap();
        assert_eq!(v, Vendor::KimiCode);
    }

    #[test]
    fn provider_configure_params_round_trip() {
        let params = ProviderConfigureParams {
            provider_id: Some(ProviderId::legacy_default_for_vendor(Vendor::Deepseek)),
            vendor: Vendor::Deepseek,
            base_url: "https://api.deepseek.com/v1".into(),
            api_key: "sk-xxx".into(),
            model: "deepseek-chat".into(),
            thinking_enabled: false,
        };
        round_trip(&params);
    }

    #[test]
    fn approval_requested_data_round_trip() {
        let data = ApprovalRequestedData {
            run_id: Uuid::nil(),
            session_id: Uuid::nil(),
            approval_id: Uuid::nil(),
            kind: ApprovalKind::Command,
            title: "执行命令".into(),
            reason: None,
            impact: ApprovalImpact::Command {
                executable: "ls".into(),
                arguments: vec![],
                cwd: "/tmp".into(),
            },
            fingerprint: "fp".into(),
            allows_session_approval: true,
        };
        round_trip(&data);
    }
}
