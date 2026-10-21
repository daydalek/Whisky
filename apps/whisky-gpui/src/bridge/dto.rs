//! Owned wire types for the methods this frontend consumes.
//!
//! Unknown fields are deliberately accepted: the Swift service adds methods and
//! payload keys independently of this frontend.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
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

/// One `library.entries` record (`EntryRecord` in `Workspace.swift`).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct EntryDto {
    pub(crate) id: String,
    pub(crate) name: String,
    /// Bottle path; used to confirm which sidebar slot owns the entry.
    #[serde(default)]
    pub(crate) container: Option<String>,
    /// Launching executable for pinned/folder entries.
    #[serde(default)]
    pub(crate) executable: Option<String>,
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
            rating: self
                .activity
                .rating
                .and_then(|rating| u8::try_from(rating).ok())
                .filter(|rating| *rating <= 10),
            play_time: self
                .activity
                .play_time
                .filter(|seconds| seconds.is_finite() && *seconds > 0.0)
                .map(|seconds| seconds.round() as u64),
            last_played: self
                .activity
                .last_played
                .filter(|seconds| seconds.is_finite() && *seconds > 0.0)
                .map(|seconds| seconds as u64),
            executable: self.executable.as_deref().map(expand_path),
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
}
