//! Owned wire types for the methods M1a consumes.
//!
//! Unknown fields are deliberately accepted: the Swift service adds methods and
//! payload keys independently of this frontend.

use serde::{Deserialize, Serialize};
use whisky_bridge::Capabilities;

/// Methods this frontend cannot work without.
///
/// The plan names `containers.list`, but the helper actually exposes the
/// container catalogue as `workspace.containers` (`ApplicationService.methods`
/// in `Service.swift`). The allow-list is checked against the wire name.
pub(crate) const REQUIRED_METHODS: &[&str] = &["workspace.containers"];

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DescribeResponse {
    pub(crate) protocol_version: u32,
    pub(crate) platform: String,
    #[serde(default)]
    pub(crate) methods: Vec<String>,
    #[serde(default)]
    pub(crate) capabilities: Vec<String>,
    pub(crate) maximum_frame_bytes: usize,
    #[serde(default)]
    pub(crate) registry: String,
    #[serde(default)]
    pub(crate) date_unit: String,
    #[serde(default)]
    pub(crate) path_format: String,
}

impl DescribeResponse {
    /// `whisky-bridge::Client` performs the handshake while spawning. Reuse its
    /// validated capabilities instead of sending `bridge.describe` twice.
    pub(crate) fn from_capabilities(capabilities: &Capabilities) -> Self {
        Self {
            protocol_version: capabilities.protocol_version,
            platform: capabilities.platform.clone(),
            methods: capabilities.methods.clone(),
            capabilities: capabilities.capabilities.clone(),
            maximum_frame_bytes: capabilities.maximum_frame_bytes,
            registry: capabilities.registry.clone(),
            date_unit: capabilities.date_unit.clone(),
            path_format: capabilities.path_format.clone(),
        }
    }

    /// Required methods absent from the advertised allow-list.
    pub(crate) fn missing_required_methods(&self) -> Vec<&'static str> {
        REQUIRED_METHODS
            .iter()
            .copied()
            .filter(|required| !self.methods.iter().any(|method| method == required))
            .collect()
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Container {
    pub(crate) path: String,
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) available: bool,
}

pub(crate) type ContainerList = Vec<Container>;

#[cfg(test)]
mod tests {
    use super::*;

    /// Recorded from a release build of `WhiskyBridge/.build/release/whisky-bridge`.
    const DESCRIBE_FIXTURE: &str = r#"{
        "result": {
            "protocolVersion": 1,
            "platform": "macos",
            "methods": [
                "bridge.describe", "bridge.shutdown", "configuration.read",
                "configuration.schema", "configuration.set", "entry.hidden",
                "entry.rating", "environment.read", "environment.set",
                "folders.addRoot", "folders.assign", "folders.exclude",
                "folders.executable", "folders.read", "folders.removeRoot",
                "jobs.cancel", "jobs.get", "library.entries", "library.page",
                "library.scan", "preferences.read", "preferences.schema",
                "preferences.set", "programs.block", "programs.list",
                "programs.pin", "system.open", "system.resources",
                "system.reveal", "workspace.containers"
            ],
            "capabilities": ["library.read", "workspace.read"],
            "maximumFrameBytes": 1048576,
            "registry": "/Users/example/Library/Containers/com.franke.Whisky/BottleVM.plist",
            "dateUnit": "unix_seconds",
            "pathFormat": "absolute_native",
            "futureField": {"ignored": true}
        },
        "id": "1",
        "version": 1
    }"#;

    const CONTAINERS_FIXTURE: &str = r#"[
        {"path": "/tmp/Bottles/galgame", "name": "galgame", "available": true, "futureField": 7},
        {"path": "/tmp/Bottles/galgame-win7", "name": "galgame-win7", "available": false}
    ]"#;

    #[derive(Deserialize)]
    struct Envelope {
        result: DescribeResponse,
    }

    fn describe_fixture() -> DescribeResponse {
        let envelope: Envelope = serde_json::from_str(DESCRIBE_FIXTURE).unwrap();
        envelope.result
    }

    #[test]
    fn recorded_describe_fixture_deserializes_and_accepts_unknown_fields() {
        let describe = describe_fixture();
        assert_eq!(describe.protocol_version, 1);
        assert_eq!(describe.platform, "macos");
        assert_eq!(describe.maximum_frame_bytes, 1_048_576);
        assert_eq!(describe.date_unit, "unix_seconds");
        assert_eq!(describe.path_format, "absolute_native");
        assert_eq!(describe.methods.len(), 30);
        assert!(describe.methods.iter().any(|m| m == "workspace.containers"));
        assert!(describe.missing_required_methods().is_empty());
    }

    #[test]
    fn recorded_containers_fixture_deserializes_and_accepts_unknown_fields() {
        let containers: ContainerList = serde_json::from_str(CONTAINERS_FIXTURE).unwrap();
        assert_eq!(containers.len(), 2);
        assert_eq!(containers[0].name, "galgame");
        assert!(containers[0].available);
        assert!(!containers[1].available);
    }

    #[test]
    fn allow_list_rejects_missing_required_methods() {
        let mut describe = describe_fixture();
        describe.methods.retain(|method| method != "workspace.containers");
        assert_eq!(
            describe.missing_required_methods(),
            vec!["workspace.containers"]
        );
    }

    #[test]
    fn allow_list_accepts_the_required_method_in_any_position() {
        let describe = DescribeResponse {
            protocol_version: 1,
            platform: "macos".into(),
            methods: vec!["workspace.containers".into(), "bridge.describe".into()],
            capabilities: vec![],
            maximum_frame_bytes: 1_048_576,
            registry: String::new(),
            date_unit: "unix_seconds".into(),
            path_format: "absolute_native".into(),
        };
        assert!(describe.missing_required_methods().is_empty());
    }
}
