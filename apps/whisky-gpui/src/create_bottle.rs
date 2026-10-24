//! Pure helpers for the create-bottle sheet.
//!
//! `bottle.create` takes a Wine `WinVersion` raw value (`win11`, `win10`,
//! `win7`, …). The sheet shows the pretty labels from the design demo; this
//! module maps between the two. Result parsing stays here so the merge rules
//! are testable without a helper process.

use serde::Deserialize;

/// Labels shown in the create-bottle Windows version choice, matching the
/// design sheet order.
pub(crate) const WINDOWS_LABELS: &[&str] = &["Windows 11", "Windows 10", "Windows 7"];

/// Map a sheet label (or a raw `WinVersion` value) to the wire value
/// `bottle.create` accepts. Unknown input falls back to Windows 11.
pub(crate) fn windows_version_wire(label: &str) -> &'static str {
    match label.trim() {
        "Windows 11" | "win11" => "win11",
        "Windows 10" | "win10" => "win10",
        "Windows 7" | "win7" => "win7",
        "Windows 8.1" | "win81" => "win81",
        "Windows 8" | "win8" => "win8",
        "Windows XP" | "winxp" => "winxp",
        _ => "win11",
    }
}

/// Pretty path for the create sheet's location row. Home is collapsed to `~`.
pub(crate) fn display_bottle_location(path: &str) -> String {
    let home = dirs_home();
    match home {
        Some(home) if path == home || path.starts_with(&(home.clone() + "/")) => {
            format!("~{}", &path[home.len()..])
        }
        _ => path.to_owned(),
    }
}

fn dirs_home() -> Option<String> {
    std::env::var_os("HOME").map(|value| value.to_string_lossy().into_owned())
}

/// `bottle.create` job result once `jobs.get` reports `completed`.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub(crate) struct BottleCreatedDto {
    pub(crate) path: String,
    pub(crate) name: String,
}

/// One create-bottle job as the sheet tracks it.
#[derive(Debug, Clone, Default)]
pub(crate) struct CreateBottleState {
    pub(crate) job_id: Option<String>,
    pub(crate) status: Option<crate::scan::JobStatus>,
    pub(crate) stage: Option<String>,
    pub(crate) error: Option<String>,
    /// Set when the job finishes (success or failure) so the sheet can keep
    /// showing the last outcome until the user dismisses or retries.
    pub(crate) finished: bool,
    /// Path of the bottle that was just created, for selection after refresh.
    pub(crate) created_path: Option<String>,
}

impl CreateBottleState {
    pub(crate) fn running(&self) -> bool {
        !self.finished
            && self
                .status
                .is_some_and(|status| !status.is_terminal())
    }
}

/// Progress line for the create sheet.
pub(crate) fn progress_label(status: crate::scan::JobStatus, stage: Option<&str>) -> &'static str {
    use crate::scan::JobStatus;
    match (status, stage) {
        (JobStatus::Queued, _) => "排队中…",
        (JobStatus::Running, Some("initializing")) => "正在初始化容器…",
        (JobStatus::Running, _) => "正在创建容器…",
        (JobStatus::Cancelling, _) => "正在取消…",
        (JobStatus::Completed, _) => "创建完成",
        (JobStatus::Failed, _) => "创建失败",
        (JobStatus::Cancelled, _) => "已取消",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_labels_map_to_win_version_raw_values() {
        assert_eq!(windows_version_wire("Windows 11"), "win11");
        assert_eq!(windows_version_wire("Windows 10"), "win10");
        assert_eq!(windows_version_wire("Windows 7"), "win7");
        assert_eq!(windows_version_wire("win11"), "win11");
        assert_eq!(windows_version_wire("nonsense"), "win11");
    }

    #[test]
    fn display_location_collapses_home() {
        let home = dirs_home().expect("HOME");
        let full = format!("{home}/Library/Containers/Whisky/Bottles");
        assert_eq!(
            display_bottle_location(&full),
            "~/Library/Containers/Whisky/Bottles"
        );
        assert_eq!(display_bottle_location("/tmp/Bottles"), "/tmp/Bottles");
    }

    #[test]
    fn created_dto_matches_the_bridge_result_shape() {
        let dto: BottleCreatedDto = serde_json::from_str(
            r#"{"path":"/tmp/Bottles/new","name":"new","future":true}"#,
        )
        .expect("dto");
        assert_eq!(dto.path, "/tmp/Bottles/new");
        assert_eq!(dto.name, "new");
    }
}
