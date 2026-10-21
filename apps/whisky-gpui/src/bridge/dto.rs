//! Owned wire types for the methods this frontend consumes.
//!
//! Unknown fields are deliberately accepted: the Swift service adds methods and
//! payload keys independently of this frontend.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use whisky_bridge::Capabilities;

use crate::model::Game;

/// Methods this frontend cannot work without.
///
/// The plan names `containers.list`, but the helper actually exposes the
/// container catalogue as `workspace.containers` (`ApplicationService.methods`
/// in `Service.swift`). Library reads are `library.entries` with a `container`
/// path; there is no separate activity method — each entry carries its
/// `activity` snapshot. The allow-list is checked against wire names.
pub(crate) const REQUIRED_METHODS: &[&str] = &["workspace.containers", "library.entries"];

/// Methods the headless runtime probe cannot work without.
pub(crate) const RUNTIME_METHODS: &[&str] = &["runtime.snapshot"];

/// The full runtime surface this frontend drives (`RuntimeService.methods`).
/// Checked before `--runtime-watch` so the probe fails with a clear message
/// instead of a remote `method_unavailable`.
pub(crate) const RUNTIME_SESSION_METHODS: &[&str] = &[
    "runtime.configure",
    "runtime.snapshot",
    "runtime.events",
    "runtime.launch",
    "runtime.cancel",
    "runtime.stop",
];

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
        self.missing_methods(REQUIRED_METHODS)
    }

    /// The subset of `required` the helper does not advertise.
    pub(crate) fn missing_methods(&self, required: &[&'static str]) -> Vec<&'static str> {
        required
            .iter()
            .copied()
            .filter(|required| !self.methods.iter().any(|method| method == required))
            .collect()
    }
}

/// One `runtime.snapshot` result (`RuntimeService.snapshot` in Swift).
///
/// `sequence` is a decimal string because the Swift controller keeps a 64-bit
/// cursor. Unknown keys are ignored so the helper can grow the payload.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RuntimeSnapshotDto {
    #[serde(default)]
    pub(crate) sequence: String,
    #[serde(default)]
    pub(crate) entries: Vec<RuntimeEntryDto>,
    #[serde(default)]
    pub(crate) query_failures: BTreeMap<String, String>,
}

/// Per-entry runtime state; `capabilities` is the `LibraryRuntimeCapabilities`
/// option-set bitmask.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RuntimeEntryDto {
    pub(crate) id: String,
    pub(crate) state: String,
    #[serde(default)]
    pub(crate) capabilities: i64,
}

/// One `runtime.events` result (`RuntimeService.runtimeEvents`).
///
/// `after` is a decimal cursor; `resyncRequired` means the cursor fell behind
/// the 128-event ring and local state must be replaced wholesale. `events` is
/// filtered by the helper to entries newer than the cursor, so an empty array
/// is normal.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RuntimeEventBatchDto {
    #[serde(default)]
    pub(crate) sequence: String,
    #[serde(default)]
    pub(crate) resync_required: bool,
    #[serde(default)]
    pub(crate) events: Vec<RuntimeEventDto>,
    /// The service always includes it; optional here so a truncated frame
    /// cannot take the session down.
    #[serde(default)]
    pub(crate) snapshot: Option<RuntimeSnapshotDto>,
}

/// One buffered event. The helper wraps the payload as `{sequence, event}`;
/// the sequence is redundant with the batch cursor, so only the payload is kept.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct RuntimeEventDto {
    pub(crate) event: RuntimeEventPayloadDto,
}

/// `RuntimeService.encodeEvent` tags each payload with `kind`. Unknown kinds are
/// tolerated: a newer helper may publish events this build cannot interpret.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub(crate) enum RuntimeEventPayloadDto {
    /// A complete state snapshot, not a delta.
    State { value: RuntimeSnapshotDto },
    LaunchResult {
        #[serde(rename = "entryID", default)]
        entry_id: String,
        #[serde(default)]
        status: String,
        #[serde(default)]
        error: Option<String>,
    },
    Failure {
        #[serde(default)]
        message: String,
    },
    #[serde(other)]
    Unknown,
}

/// `runtime.launch` reply: either `{accepted, entryID}` or the clipboard
/// prompt `{accepted: false, interaction: {…}}` from `LaunchInteractionBroker`.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct LaunchReplyDto {
    #[serde(default)]
    pub(crate) accepted: bool,
    #[serde(default)]
    pub(crate) interaction: Option<ClipboardInteractionDto>,
}

/// The clipboard prompt payload. `kind` is `"clipboard"`; the token is one-use
/// and must be echoed back verbatim.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ClipboardInteractionDto {
    pub(crate) kind: String,
    pub(crate) token: String,
    #[serde(default)]
    pub(crate) content_type: String,
    #[serde(default)]
    pub(crate) size_bytes: i64,
    #[serde(default)]
    pub(crate) preview: Option<String>,
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

/// `preferences.schema`: the keys the helper will accept on `preferences.set`.
/// Anything outside this set has no persistence and must stay in memory.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PreferencesSchemaDto {
    #[serde(default)]
    pub(crate) booleans: BTreeMap<String, bool>,
    #[serde(default)]
    pub(crate) strings: BTreeMap<String, String>,
    #[serde(default)]
    pub(crate) paths: Vec<String>,
}

impl PreferencesSchemaDto {
    /// Every key the helper advertises, regardless of its type.
    pub(crate) fn keys(&self) -> impl Iterator<Item = &str> {
        self.booleans
            .keys()
            .chain(self.strings.keys())
            .chain(self.paths.iter())
            .map(String::as_str)
    }
}

/// `entry.hidden` reply. The record, not the request, is what the UI stores.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HiddenReplyDto {
    #[serde(rename = "entryID")]
    pub(crate) entry_id: String,
    pub(crate) hidden: bool,
}

/// `folders.read` and every `folders.*` mutation reply
/// (`Service+Folders.encodeFolders`).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FoldersDto {
    #[serde(default)]
    pub(crate) roots: Vec<String>,
    #[serde(default)]
    pub(crate) assigned_folders: Vec<String>,
    #[serde(default)]
    pub(crate) excluded_folders: Vec<String>,
    /// Folder path → executable path (or null when the selection was cleared).
    #[serde(default)]
    pub(crate) executables: BTreeMap<String, Option<String>>,
    #[serde(default)]
    pub(crate) known_folders: Vec<String>,
    #[serde(default)]
    pub(crate) automatic_metadata: bool,
}

impl FoldersDto {
    pub(crate) fn is_assigned(&self, path: &str) -> bool {
        self.assigned_folders.iter().any(|folder| folder == path)
    }

    pub(crate) fn is_excluded(&self, path: &str) -> bool {
        self.excluded_folders.iter().any(|folder| folder == path)
    }

    pub(crate) fn executable_for(&self, path: &str) -> Option<&str> {
        self.executables.get(path).and_then(Option::as_deref)
    }
}

/// One `programs.list` record (`ContainerProgram` in `ContainerPrograms.swift`).
/// `pinned` programs are also library entries; `blocked` programs are hidden
/// from the launcher path but stay listed so the block can be undone.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProgramDto {
    pub(crate) path: String,
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) pinned: bool,
    #[serde(default)]
    pub(crate) blocked: bool,
    #[serde(default)]
    pub(crate) available: bool,
}

impl ProgramDto {
    /// The library entry a pinned program gains (`ContainerProgram.entry`).
    pub(crate) fn entry_id(&self) -> String {
        format!("pinned:{}", self.path)
    }
}

/// One `processes.list` row (`ProcessRecord` in `ProcessService.swift`).
///
/// Every field the snapshot cannot compute honestly is optional and omitted by
/// the helper when unknown: `startedAt` and `macosPid` only exist for
/// registry-tracked rows, and `memory` is the tasklist display string, not a
/// byte count.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProcessDto {
    pub(crate) pid: i64,
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) memory: Option<String>,
    #[serde(default)]
    pub(crate) kind: Option<String>,
    #[serde(default)]
    pub(crate) source: Option<String>,
    /// Unix seconds, matching the bridge's `dateUnit`.
    #[serde(default)]
    pub(crate) started_at: Option<f64>,
    #[serde(default)]
    pub(crate) macos_pid: Option<i64>,
}

/// `processes.kill` reply. `killed: false` means the snapshot did not contain
/// the PID and nothing was signalled; it is a reply, not an error.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct KillReplyDto {
    #[serde(default)]
    pub(crate) killed: bool,
}

/// `library.scan` reply: a `BridgeJobStore` handle.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct JobStartDto {
    #[serde(rename = "jobID")]
    pub(crate) job_id: String,
}

/// `BridgeFailure` as `jobs.get` encodes it in `error`.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct BridgeFailureDto {
    #[serde(default)]
    pub(crate) code: String,
    #[serde(default)]
    pub(crate) message: String,
}

impl BridgeFailureDto {
    pub(crate) fn reason(&self) -> String {
        if self.code.is_empty() {
            self.message.clone()
        } else {
            format!("{}: {}", self.code, self.message)
        }
    }
}

/// One `jobs.get` / `jobs.cancel` record. `status` is validated by
/// `scan::JobStatus`; `progress` is the helper's opaque payload (`stage` for a
/// scan); `result` is `{snapshotID, total}` once the scan succeeds.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JobDto {
    #[serde(default)]
    pub(crate) status: String,
    #[serde(default)]
    pub(crate) progress: Value,
    #[serde(default)]
    pub(crate) result: Option<Value>,
    #[serde(default)]
    pub(crate) error: Option<BridgeFailureDto>,
}

impl JobDto {
    pub(crate) fn stage(&self) -> Option<&str> {
        self.progress.get("stage").and_then(Value::as_str)
    }
}

/// The `library.scan` operation result, carried in `jobs.get`'s `result`.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ScanResultDto {
    #[serde(rename = "snapshotID")]
    pub(crate) snapshot_id: String,
    #[serde(default)]
    pub(crate) total: u64,
}

/// One `library.page` reply (`ApplicationService.pageLibrary`).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LibraryPageDto {
    #[serde(default)]
    pub(crate) entries: Vec<EntryDto>,
    #[serde(default)]
    pub(crate) total: u64,
    /// `null` ends the catalogue; the Rust side keeps it as `Option`.
    #[serde(default)]
    pub(crate) next_offset: Option<u64>,
}

/// One `library.entries` record (`EntryRecord` in `Workspace.swift`).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct EntryDto {
    pub(crate) id: String,
    pub(crate) name: String,
    /// Bottle path; used to confirm which sidebar slot owns the entry.
    #[serde(default)]
    pub(crate) container: Option<String>,
    /// Launching executable for pinned/folder entries. A folder entry carries
    /// its folder, which cannot be run.
    #[serde(default)]
    pub(crate) executable: Option<String>,
    /// Where the entry came from (`pinned`, `steam`, `folder`).
    #[serde(default)]
    pub(crate) source: Option<String>,
    /// A folder entry with no executable chosen yet. Play asks for a file
    /// before it can launch.
    #[serde(default)]
    pub(crate) needs_executable: bool,
    /// Executable to extract an icon from, when the source has no artwork.
    #[serde(default)]
    pub(crate) icon: Option<String>,
    #[serde(default)]
    pub(crate) hidden: bool,
    #[serde(default)]
    pub(crate) metadata: Option<MetadataDto>,
    #[serde(default)]
    pub(crate) activity: ActivityDto,
    /// Resolved on-disk artwork (custom cover or cached remote cover).
    #[serde(default)]
    pub(crate) cover: Option<String>,
    /// Width / height of the artwork, used to keep wide covers wide.
    #[serde(default)]
    pub(crate) cover_aspect_ratio: Option<f64>,
}

pub(crate) type EntryList = Vec<EntryDto>;

/// The subset of `GameMetadata` the library surfaces read.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MetadataDto {
    #[serde(default)]
    pub(crate) title: Option<String>,
    #[serde(default)]
    pub(crate) summary: Option<String>,
    #[serde(default)]
    pub(crate) developer: Option<String>,
    /// `YYYY-MM-DD`; the Swift type keeps it as a string.
    #[serde(default)]
    pub(crate) release_date: Option<String>,
}

/// `GameActivity`; dates arrive as Unix seconds (`dateEncodingStrategy`).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ActivityDto {
    #[serde(default)]
    pub(crate) play_time: Option<f64>,
    #[serde(default)]
    pub(crate) rating: Option<i64>,
    #[serde(default)]
    pub(crate) last_played: Option<f64>,
    /// Confirmed session completion; the Swift library sorts `recent` by it.
    #[serde(default)]
    pub(crate) last_session_ended_at: Option<f64>,
}

impl ActivityDto {
    /// One-based rating (`nil` when unrated), clamped to what the grid supports.
    pub(crate) fn rating(&self) -> Option<u8> {
        self.rating
            .and_then(|rating| u8::try_from(rating).ok())
            .filter(|rating| *rating <= 10)
    }

    pub(crate) fn play_time(&self) -> Option<u64> {
        self.play_time
            .filter(|seconds| seconds.is_finite() && *seconds > 0.0)
            .map(|seconds| seconds.round() as u64)
    }

    pub(crate) fn last_played(&self) -> Option<u64> {
        self.last_played
            .filter(|seconds| seconds.is_finite() && *seconds > 0.0)
            .map(|seconds| seconds as u64)
    }

    pub(crate) fn last_session_ended_at(&self) -> Option<u64> {
        self.last_session_ended_at
            .filter(|seconds| seconds.is_finite() && *seconds > 0.0)
            .map(|seconds| seconds as u64)
    }
}

impl EntryDto {
    /// The first candidate that exists on disk. Absence is normal: covers are
    /// optional, so the view keeps its placeholder treatment.
    pub(crate) fn artwork_path(&self) -> Option<PathBuf> {
        [self.cover.as_deref(), self.icon.as_deref()]
            .into_iter()
            .flatten()
            .find_map(existing_file)
    }

    pub(crate) fn title(&self) -> &str {
        if !self.name.is_empty() {
            return &self.name;
        }
        self.metadata
            .as_ref()
            .and_then(|metadata| metadata.title.as_deref())
            .unwrap_or("")
    }

    /// Map a wire entry onto the view model. `bottle` is the one-based sidebar
    /// slot that owns this entry.
    pub(crate) fn into_game(self, bottle: usize) -> Game {
        let art = self.artwork_path();
        let title = {
            let title = self.title().to_owned();
            if title.is_empty() { "Untitled".into() } else { title }
        };
        let metadata = self.metadata.unwrap_or_default();
        Game {
            id: self.id,
            art,
            title,
            studio: non_empty(metadata.developer),
            description: non_empty(metadata.summary),
            release: non_empty(metadata.release_date),
            landscape: self.cover_aspect_ratio.is_some_and(|ratio| ratio > 1.0),
            bottle,
            hidden: self.hidden,
            rating: self.activity.rating(),
            play_time: self.activity.play_time(),
            last_played: self.activity.last_played(),
            executable: self.executable.as_deref().map(expand_path),
            is_folder: self.source.as_deref() == Some("folder"),
            needs_executable: self.needs_executable,
            container: self.container.unwrap_or_default(),
            last_session_ended_at: self.activity.last_session_ended_at(),
        }
    }
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|text| !text.trim().is_empty())
}

/// Expand a leading `~` using `$HOME`; absolute paths pass through unchanged.
pub(crate) fn expand_path(raw: &str) -> PathBuf {
    expand_with_home(
        raw,
        std::env::var_os("HOME").map(PathBuf::from).as_deref(),
    )
}

fn expand_with_home(raw: &str, home: Option<&Path>) -> PathBuf {
    if let Some(home) = home {
        if raw == "~" {
            return home.to_path_buf();
        }
        if let Some(rest) = raw.strip_prefix("~/") {
            return home.join(rest);
        }
    }
    PathBuf::from(raw)
}

/// Expanded path only when it names a regular file; never creates or probes.
pub(crate) fn existing_file(raw: &str) -> Option<PathBuf> {
    let path = expand_path(raw);
    path.is_file().then_some(path)
}

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

    /// Shape emitted by `RuntimeService.snapshot` (`sequence` is a decimal
    /// string) with unknown keys at both levels.
    const RUNTIME_SNAPSHOT_FIXTURE: &str = r#"{
        "sequence": "12",
        "entries": [
            {
                "id": "pinned:/tmp/Bottles/demo/drive_c/Game/play.exe",
                "state": "idle",
                "capabilities": 11,
                "futureField": true
            }
        ],
        "queryFailures": {"/tmp/Bottles/demo": "wineserver unreachable"},
        "futureField": {"ignored": true}
    }"#;

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
            methods: vec![
                "workspace.containers".into(),
                "library.entries".into(),
                "bridge.describe".into(),
            ],
            capabilities: vec![],
            maximum_frame_bytes: 1_048_576,
            registry: String::new(),
            date_unit: "unix_seconds".into(),
            path_format: "absolute_native".into(),
        };
        assert!(describe.missing_required_methods().is_empty());
    }

    #[test]
    fn recorded_runtime_snapshot_fixture_deserializes_and_accepts_unknown_fields() {
        let snapshot: RuntimeSnapshotDto =
            serde_json::from_str(RUNTIME_SNAPSHOT_FIXTURE).expect("runtime snapshot");
        assert_eq!(snapshot.sequence, "12");
        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].state, "idle");
        assert_eq!(snapshot.entries[0].capabilities, 11);
        assert_eq!(
            snapshot
                .query_failures
                .get("/tmp/Bottles/demo")
                .map(String::as_str),
            Some("wineserver unreachable")
        );
    }

    #[test]
    fn empty_runtime_snapshot_is_a_valid_payload() {
        let snapshot: RuntimeSnapshotDto =
            serde_json::from_str(r#"{"sequence":"0","entries":[],"queryFailures":{}}"#).unwrap();
        assert_eq!(snapshot.sequence, "0");
        assert!(snapshot.entries.is_empty());
        assert!(snapshot.query_failures.is_empty());
    }

    #[test]
    fn runtime_probe_reports_missing_runtime_methods() {
        let mut describe = describe_fixture();
        describe.methods.retain(|method| !method.starts_with("runtime."));
        assert_eq!(
            describe.missing_methods(RUNTIME_METHODS),
            vec!["runtime.snapshot"]
        );
    }

    #[test]
    fn runtime_event_batch_deserializes_state_results_and_tolerates_unknown_kinds() {
        let batch: RuntimeEventBatchDto = serde_json::from_str(
            r#"{
                "sequence": "42",
                "resyncRequired": true,
                "events": [
                    {"sequence": "41", "event": {"kind": "state", "value": {
                        "sequence": "41", "entries": [
                            {"id": "pinned:a", "state": "preparing", "capabilities": 11}
                        ], "queryFailures": {}
                    }}},
                    {"sequence": "42", "event": {"kind": "launchResult",
                        "entryID": "pinned:a", "status": "failed", "program": "a.exe",
                        "error": "wine exited"}},
                    {"sequence": "43", "event": {"kind": "telemetry", "value": 7}}
                ],
                "snapshot": {"sequence": "42", "entries": [], "queryFailures": {}}
            }"#,
        )
        .expect("event batch");
        assert_eq!(batch.sequence, "42");
        assert!(batch.resync_required);
        assert_eq!(batch.events.len(), 3);
        match &batch.events[0].event {
            RuntimeEventPayloadDto::State { value } => {
                assert_eq!(value.entries.len(), 1);
                assert_eq!(value.entries[0].state, "preparing");
                assert_eq!(value.entries[0].capabilities, 11);
            }
            other => panic!("expected a state event, got {other:?}"),
        }
        match &batch.events[1].event {
            RuntimeEventPayloadDto::LaunchResult { entry_id, status, error } => {
                assert_eq!(entry_id, "pinned:a");
                assert_eq!(status, "failed");
                assert_eq!(error.as_deref(), Some("wine exited"));
            }
            other => panic!("expected a launch result, got {other:?}"),
        }
        assert!(matches!(batch.events[2].event, RuntimeEventPayloadDto::Unknown));
        assert_eq!(batch.snapshot.expect("snapshot").sequence, "42");
    }

    #[test]
    fn the_event_tag_may_follow_its_payload_on_the_wire() {
        // `JSONValue.object` is an unordered Swift dictionary: the recorded
        // helper emits `{"value": …, "kind": "state"}`, tag last.
        let event: RuntimeEventDto = serde_json::from_str(
            r#"{"event": {"value": {"sequence": "1", "entries": [], "queryFailures": {}},
                "kind": "state"}}"#,
        )
        .expect("event with a trailing tag");
        assert!(matches!(event.event, RuntimeEventPayloadDto::State { .. }));
    }

    #[test]
    fn an_events_reply_without_a_snapshot_still_deserializes() {
        let batch: RuntimeEventBatchDto =
            serde_json::from_str(r#"{"sequence":"0","resyncRequired":false,"events":[]}"#).unwrap();
        assert!(batch.snapshot.is_none());
        assert!(batch.events.is_empty());
    }

    /// Recorded from `whisky-bridge`, first three entries of
    /// `library.entries` for a sample bottle (a hidden Steam entry plus two
    /// games). Kept verbatim so unknown fields and `lastSessionEndedAt` are
    /// exercised by the real writer.
    const ENTRIES_FIXTURE: &str = include_str!("../../tests/fixtures/library-entries.json");

    fn fixture_entries() -> EntryList {
        serde_json::from_str(ENTRIES_FIXTURE).expect("recorded library payload must deserialize")
    }

    #[test]
    fn recorded_entries_fixture_deserializes_and_accepts_unknown_fields() {
        let entries = fixture_entries();
        assert_eq!(entries.len(), 3);

        let steam = &entries[0];
        assert_eq!(steam.name, "steam");
        assert!(steam.hidden);
        assert!(steam.cover.is_none());

        let air = &entries[1];
        assert_eq!(air.name, "Northwind Signal");
        assert_eq!(
            air.container
                .as_deref()
                .map(|path| path.ends_with("11111111-2222-4333-8444-555555555555")),
            Some(true)
        );
        let metadata = air.metadata.as_ref().expect("metadata");
        assert_eq!(metadata.developer.as_deref(), Some("Folded Atlas"));
        assert_eq!(metadata.release_date.as_deref(), Some("2024-03-12"));
        assert_eq!(metadata.title.as_deref(), Some("Northwind Signal"));
        assert!(air.activity.play_time.is_some_and(|seconds| (seconds - 275.09).abs() < 0.01));
        assert!(air.activity.last_played.is_some());
        assert_eq!(air.activity.rating, None);
    }

    #[test]
    fn recorded_entry_maps_to_a_view_game() {
        let entries = fixture_entries();
        let air = entries[1].clone().into_game(1);
        assert_eq!(air.title, "Northwind Signal");
        assert_eq!(air.studio.as_deref(), Some("Folded Atlas"));
        assert_eq!(air.release.as_deref(), Some("2024-03-12"));
        assert_eq!(air.year(), Some("2024"));
        assert_eq!(air.bottle, 1);
        assert!(!air.hidden);
        assert_eq!(air.rating, None);
        assert_eq!(air.play_time, Some(275));
        assert!(air.last_played.is_some());
        assert_eq!(air.executable, None);

        let eden = entries[2].clone().into_game(1);
        assert_eq!(eden.title, "eden*");
        assert_eq!(eden.rating, Some(8));
        assert_eq!(eden.play_time, Some(84));
        assert!(eden.last_played.is_some());
    }

    /// A folder entry carries its folder, so the helper reports whether an
    /// executable has been chosen for it. Play uses that to ask for a file
    /// instead of sending a launch that can only fail.
    #[test]
    fn a_folder_entry_reports_whether_an_executable_has_been_chosen() {
        let pending: EntryDto = serde_json::from_str(
            r#"{"id":"folder:/bottle:/Games/Sample","name":"Sample","container":"/bottle",
                "source":"folder","executable":"/Games/Sample","needsExecutable":true}"#,
        )
        .expect("folder entry without an executable");
        let game = pending.clone().into_game(1);
        assert!(game.needs_executable);
        assert!(game.is_folder);
        assert_eq!(game.executable.as_deref(), Some(Path::new("/Games/Sample")));

        let resolved: EntryDto = serde_json::from_str(
            r#"{"id":"folder:/bottle:/Games/Sample","name":"Sample","container":"/bottle",
                "source":"folder","executable":"/Games/Sample","needsExecutable":false}"#,
        )
        .expect("folder entry with an executable");
        assert!(!resolved.clone().into_game(1).needs_executable);

        // An older helper omits the key; defaulting to false keeps Play as it
        // is today rather than prompting for every card.
        let legacy: EntryDto = serde_json::from_str(
            r#"{"id":"pinned:/Games/Sample","name":"Sample","container":"/bottle",
                "source":"pinned","executable":"/Games/Sample/sample.exe"}"#,
        )
        .expect("entry without the flag");
        let legacy = legacy.into_game(1);
        assert!(!legacy.needs_executable);
        // A pin names its own executable, so the card offers no choice.
        assert!(!legacy.is_folder);
    }

    #[test]
    fn tilde_expansion_uses_the_supplied_home_and_keeps_absolute_paths() {
        let home = Path::new("/Users/example");
        assert_eq!(
            expand_with_home("~/Games/a.jpg", Some(home)),
            PathBuf::from("/Users/example/Games/a.jpg")
        );
        assert_eq!(
            expand_with_home("~", Some(home)),
            PathBuf::from("/Users/example")
        );
        assert_eq!(
            expand_with_home("/tmp/a.jpg", Some(home)),
            PathBuf::from("/tmp/a.jpg")
        );
        assert_eq!(
            expand_with_home("~/a.jpg", None),
            PathBuf::from("~/a.jpg")
        );
        assert_eq!(
            expand_with_home("relative/a.jpg", Some(home)),
            PathBuf::from("relative/a.jpg")
        );
    }

    fn entry_with_cover(cover: &str) -> EntryDto {
        EntryDto {
            id: "pinned:/entry".into(),
            name: "Entry".into(),
            container: None,
            executable: None,
            needs_executable: false,
            source: None,
            icon: Some("/definitely/missing-icon.png".into()),
            hidden: false,
            metadata: None,
            activity: ActivityDto::default(),
            cover: Some(cover.into()),
            cover_aspect_ratio: None,
        }
    }

    #[test]
    fn missing_artwork_yields_no_path_instead_of_a_broken_image() {
        let entry = entry_with_cover("/definitely/missing-cover.jpg");
        assert_eq!(entry.artwork_path(), None);
        assert_eq!(entry.clone().into_game(2).art, None);
        assert_eq!(
            entry_with_cover("~/definitely/missing-cover.jpg").artwork_path(),
            None
        );
    }

    #[test]
    fn existing_artwork_file_is_returned_unchanged() {
        let artwork = format!("{}/assets/astral.png", env!("CARGO_MANIFEST_DIR"));
        assert_eq!(
            entry_with_cover(&artwork).artwork_path(),
            Some(PathBuf::from(&artwork))
        );
        assert!(existing_file("/definitely/missing.png").is_none());
    }

    #[test]
    fn empty_container_payload_is_an_empty_list_not_an_error() {
        let containers: ContainerList = serde_json::from_str("[]").unwrap();
        assert!(containers.is_empty());
    }

    /// Recorded from `preferences.schema` on this machine. It intentionally
    /// omits the library view keys the GPUI app keeps in memory.
    const PREFERENCES_SCHEMA_FIXTURE: &str = r#"{
        "booleans": {
            "libraryMixedCoverLayout": false,
            "librarySingleLineTitles": false,
            "libraryRefreshAfterExit": true
        },
        "strings": {"libraryCoverFillStyle": "blurred"},
        "paths": ["defaultBottleLocation"]
    }"#;

    #[test]
    fn recorded_preferences_schema_exposes_only_its_writable_keys() {
        let schema: PreferencesSchemaDto =
            serde_json::from_str(PREFERENCES_SCHEMA_FIXTURE).expect("schema");
        let keys = schema.keys().collect::<Vec<_>>();
        assert!(keys.contains(&"libraryMixedCoverLayout"));
        assert!(keys.contains(&"librarySingleLineTitles"));
        assert!(keys.contains(&"libraryRefreshAfterExit"));
        assert!(keys.contains(&"defaultBottleLocation"));
        assert!(!keys.contains(&"libraryDisplayMode"));
        assert!(!keys.contains(&"librarySort"));
        assert!(!keys.contains(&"libraryShowHiddenGames"));
    }

    #[test]
    fn the_rating_reply_is_an_activity_record() {
        // Verbatim shape of `GameActivity` as `entry.rating` returns it.
        let activity: ActivityDto = serde_json::from_str(
            r#"{"schemaVersion": 1, "playTime": 84.3, "rating": 8,
                "lastPlayed": 1792496362.7, "lastSessionEndedAt": 1792496362.7,
                "owner": {"source": "gui"}}"#,
        )
        .expect("activity");
        assert_eq!(activity.rating(), Some(8));
        assert_eq!(activity.play_time(), Some(84));
        assert_eq!(activity.last_played(), Some(1_792_496_362));
        assert_eq!(activity.last_session_ended_at(), Some(1_792_496_362));
    }

    #[test]
    fn the_hidden_reply_carries_the_records_visibility() {
        let reply: HiddenReplyDto =
            serde_json::from_str(r#"{"entryID": "pinned:/a", "hidden": true}"#).expect("reply");
        assert_eq!(reply.entry_id, "pinned:/a");
        assert!(reply.hidden);
    }

    /// Shape of `folders.read` for the recorded `galgame` bottle.
    const FOLDERS_FIXTURE: &str = r#"{
        "roots": ["/Users/example/game"],
        "assignedFolders": [],
        "excludedFolders": ["/Users/example/game/Excluded Sample"],
        "executables": {
            "/Users/example/game/Sample": "/Users/example/game/Sample/sample.exe",
            "/Users/example/game/Hollow": null
        },
        "knownFolders": ["/Users/example/game/Sample"],
        "automaticMetadata": true
    }"#;

    #[test]
    fn recorded_folders_payload_decodes_roots_assignments_and_exclusions() {
        let folders: FoldersDto = serde_json::from_str(FOLDERS_FIXTURE).expect("folders");
        assert_eq!(folders.roots.len(), 1);
        assert!(!folders.is_assigned("/Users/example/game"));
        assert!(folders.is_excluded("/Users/example/game/Excluded Sample"));
        assert_eq!(
            folders.executable_for("/Users/example/game/Sample"),
            Some("/Users/example/game/Sample/sample.exe")
        );
        assert_eq!(folders.executable_for("/Users/example/game/Hollow"), None);
        assert!(folders.automatic_metadata);
    }

    /// Shape of `programs.list` for the recorded `galgame` bottle: a pinned
    /// program with its display name and a discovered one with only the fields
    /// `ContainerProgram` always carries.
    const PROGRAMS_FIXTURE: &str = r#"[
        {
            "path": "/Users/example/game/Sample/sample.exe",
            "name": "Sample",
            "pinned": true,
            "blocked": false,
            "available": true,
            "futureField": 3
        },
        {"path": "/Users/example/game/Hollow/hollow.exe", "name": "hollow"}
    ]"#;

    #[test]
    fn recorded_programs_payload_decodes_and_tolerates_missing_optional_flags() {
        let programs: Vec<ProgramDto> = serde_json::from_str(PROGRAMS_FIXTURE).expect("programs");
        assert_eq!(programs.len(), 2);
        assert_eq!(programs[0].entry_id(), "pinned:/Users/example/game/Sample/sample.exe");
        assert!(programs[0].pinned);
        assert!(!programs[0].blocked);
        assert!(programs[0].available);
        // A discovered program carries no flags at all; they default off.
        assert!(!programs[1].pinned);
        assert!(!programs[1].blocked);
        assert!(!programs[1].available);
    }

    #[test]
    fn an_empty_programs_payload_is_an_empty_list() {
        let programs: Vec<ProgramDto> = serde_json::from_str("[]").unwrap();
        assert!(programs.is_empty());
    }

    /// Shape of `processes.list`: the registry-tracked row carries everything
    /// the snapshot pool can enrich; the untracked row only the tasklist core.
    const PROCESSES_FIXTURE: &str = r#"[
        {
            "pid": 42,
            "name": "game.exe",
            "memory": "24 K",
            "kind": "app",
            "source": "whisky",
            "startedAt": 1700000000,
            "macosPid": 7331,
            "futureField": {"ignored": true}
        },
        {"pid": 84, "name": "services.exe"}
    ]"#;

    #[test]
    fn recorded_processes_payload_decodes_and_tolerates_missing_optionals() {
        let processes: Vec<ProcessDto> = serde_json::from_str(PROCESSES_FIXTURE).expect("processes");
        assert_eq!(processes.len(), 2);
        let game = &processes[0];
        assert_eq!(game.pid, 42);
        assert_eq!(game.name, "game.exe");
        assert_eq!(game.memory.as_deref(), Some("24 K"));
        assert_eq!(game.kind.as_deref(), Some("app"));
        assert_eq!(game.source.as_deref(), Some("whisky"));
        assert_eq!(game.started_at, Some(1_700_000_000.0));
        assert_eq!(game.macos_pid, Some(7_331));
        // A tasklist-only row has none of the enrichment fields.
        let service = &processes[1];
        assert_eq!(service.pid, 84);
        assert_eq!(service.memory, None);
        assert_eq!(service.kind, None);
        assert_eq!(service.started_at, None);
        assert_eq!(service.macos_pid, None);
    }

    #[test]
    fn a_kill_reply_reports_the_boolean_and_defaults_to_false() {
        let reply: KillReplyDto = serde_json::from_str(r#"{"killed": true}"#).expect("reply");
        assert!(reply.killed);
        let reply: KillReplyDto = serde_json::from_str("{}").expect("reply");
        assert!(!reply.killed);
    }

    #[test]
    fn a_completed_scan_job_carries_its_snapshot_and_stage() {
        let job: JobDto = serde_json::from_str(
            r#"{
                "jobID": "J1", "name": "library.scan", "status": "completed",
                "progress": {"stage": "scanning"},
                "result": {"snapshotID": "S1", "total": 42},
                "error": null, "futureField": 1
            }"#,
        )
        .expect("job");
        assert_eq!(job.status, "completed");
        assert_eq!(job.stage(), Some("scanning"));
        let result: ScanResultDto = serde_json::from_value(job.result.unwrap()).unwrap();
        assert_eq!(result.snapshot_id, "S1");
        assert_eq!(result.total, 42);
        assert!(job.error.is_none());
    }

    #[test]
    fn a_cancelled_scan_job_carries_the_bridge_failure() {
        let job: JobDto = serde_json::from_str(
            r#"{
                "jobID": "J1", "name": "library.scan", "status": "cancelled",
                "progress": null,
                "result": null,
                "error": {"code": "cancelled", "message": "Operation cancelled", "retryable": false}
            }"#,
        )
        .expect("job");
        assert_eq!(job.status, "cancelled");
        assert_eq!(
            job.error.as_ref().map(BridgeFailureDto::reason).as_deref(),
            Some("cancelled: Operation cancelled")
        );
    }

    #[test]
    fn a_library_page_with_a_null_next_offset_is_the_last_page() {
        let page: LibraryPageDto = serde_json::from_str(
            r#"{"entries": [], "total": 0, "nextOffset": null}"#,
        )
        .expect("page");
        assert_eq!(page.total, 0);
        assert_eq!(page.next_offset, None);

        let page: LibraryPageDto = serde_json::from_str(
            r#"{"entries": [], "total": 120, "nextOffset": 100}"#,
        )
        .expect("page");
        assert_eq!(page.next_offset, Some(100));
    }
}
