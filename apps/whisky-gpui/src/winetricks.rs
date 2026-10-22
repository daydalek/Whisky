//! Winetricks catalog, installed verbs, and install-job state.
//!
//! `winetricks.catalog` returns the bundled `verbs.txt` categories.
//! `winetricks.installed` reads a bottle's installed set.
//! `winetricks.install` is a `BridgeJobStore` job whose latest progress line
//! is polled through `jobs.get`; its result is the authoritative installed set.

use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;
use serde_json::Value;

use crate::scan::JobStatus;

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CatalogDto {
    #[serde(default)]
    pub(crate) categories: Vec<CategoryDto>,
}

impl CatalogDto {
    pub(crate) fn verb_count(&self) -> usize {
        self.categories
            .iter()
            .map(|category| category.verbs.len())
            .sum()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CategoryDto {
    pub(crate) id: String,
    #[serde(default)]
    pub(crate) verbs: Vec<VerbDto>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct VerbDto {
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) description: String,
}

/// `winetricks.installed` reply. `fromCache` only describes how the helper
/// learned the set; both sources are authoritative for the UI.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct InstalledDto {
    #[serde(default)]
    pub(crate) verbs: Vec<String>,
    #[serde(default)]
    pub(crate) from_cache: bool,
}

/// The subset of job progress this sheet renders.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct InstallProgress {
    pub(crate) stage: Option<String>,
    pub(crate) verb: Option<String>,
    pub(crate) index: Option<u64>,
    pub(crate) total: Option<u64>,
    pub(crate) line: Option<String>,
    pub(crate) exit_code: Option<i32>,
}

impl InstallProgress {
    pub(crate) fn from_value(value: &Value) -> Self {
        Self {
            stage: value
                .get("stage")
                .and_then(Value::as_str)
                .map(str::to_owned),
            verb: value.get("verb").and_then(Value::as_str).map(str::to_owned),
            index: value.get("index").and_then(Value::as_u64),
            total: value.get("total").and_then(Value::as_u64),
            line: value.get("line").and_then(Value::as_str).map(str::to_owned),
            exit_code: value
                .get("exitCode")
                .and_then(Value::as_i64)
                .and_then(|value| i32::try_from(value).ok()),
        }
    }

    pub(crate) fn count_label(&self) -> Option<String> {
        Some(format!("{} / {}", self.index?, self.total?))
    }
}

/// `winetricks.install` job result. `installed` is the full set after the run;
/// `succeeded` and `failed` describe only this request.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct InstallResultDto {
    #[serde(default)]
    pub(crate) installed: Vec<String>,
    #[serde(default)]
    pub(crate) succeeded: Vec<String>,
    #[serde(default)]
    pub(crate) failed: Vec<FailureDto>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FailureDto {
    #[serde(default)]
    pub(crate) verb: String,
    #[serde(default)]
    pub(crate) reason: String,
}

impl FailureDto {
    pub(crate) fn label(&self) -> String {
        if self.reason.is_empty() {
            self.verb.clone()
        } else {
            format!("{}：{}", self.verb, self.reason)
        }
    }
}

/// One `winetricks.install` job as the sheet tracks it.
#[derive(Debug, Clone)]
pub(crate) struct InstallJob {
    pub(crate) container: String,
    pub(crate) job_id: Option<String>,
    pub(crate) status: Option<JobStatus>,
    pub(crate) progress: InstallProgress,
    pub(crate) finished: bool,
    pub(crate) error: Option<String>,
    pub(crate) succeeded: Vec<String>,
    pub(crate) failed: Vec<FailureDto>,
}

impl InstallJob {
    pub(crate) fn new(container: &str) -> Self {
        Self {
            container: container.to_owned(),
            job_id: None,
            status: None,
            progress: InstallProgress::default(),
            finished: false,
            error: None,
            succeeded: Vec::new(),
            failed: Vec::new(),
        }
    }

    pub(crate) fn running(&self) -> bool {
        !self.finished && !self.status.is_some_and(|status| status.is_terminal())
    }

    pub(crate) fn label(&self) -> String {
        install_label(self)
    }
}

/// Supervised updates for one install job.
#[derive(Debug)]
pub(crate) enum InstallUpdate {
    Started {
        job_id: String,
    },
    Progress {
        status: JobStatus,
        progress: InstallProgress,
    },
    Completed {
        installed: Vec<String>,
        succeeded: Vec<String>,
        failed: Vec<FailureDto>,
    },
    Failed {
        status: JobStatus,
        reason: String,
    },
}

/// Catalog and per-bottle state the sheet shares with the bridge worker.
#[derive(Default)]
pub(crate) struct WinetricksState {
    pub(crate) catalog: Option<CatalogDto>,
    pub(crate) catalog_pending: bool,
    pub(crate) catalog_error: Option<String>,
    /// Installed verbs keyed by container path.
    pub(crate) installed: BTreeMap<String, BTreeSet<String>>,
    pub(crate) installed_pending: BTreeSet<String>,
    pub(crate) installed_error: BTreeMap<String, String>,
    pub(crate) category: Option<String>,
    pub(crate) selected: Option<String>,
    pub(crate) job: Option<InstallJob>,
}

impl WinetricksState {
    pub(crate) fn ensure_category(&mut self) {
        let Some(catalog) = &self.catalog else { return };
        if self.category.as_ref().is_some_and(|active| {
            catalog
                .categories
                .iter()
                .any(|category| &category.id == active)
        }) {
            return;
        }
        self.category = catalog
            .categories
            .first()
            .map(|category| category.id.clone());
    }

    pub(crate) fn installed_for(&self, container: &str) -> Option<&BTreeSet<String>> {
        self.installed.get(container)
    }

    pub(crate) fn set_installed(&mut self, container: &str, verbs: Vec<String>) {
        self.installed
            .insert(container.to_owned(), verbs.into_iter().collect());
        self.installed_error.remove(container);
        self.installed_pending.remove(container);
    }
}

pub(crate) fn category_label(id: &str) -> &str {
    match id {
        "apps" => "应用",
        "benchmarks" => "基准测试",
        "dlls" => "DLL",
        "fonts" => "字体",
        "games" => "游戏",
        "settings" => "设置",
        other => other,
    }
}

/// Case-insensitive name/description search, optionally narrowed to installed
/// verbs. The helper's category order and verb order are preserved.
pub(crate) fn filtered_verbs<'a>(
    category: &'a CategoryDto,
    query: &str,
    installed_only: bool,
    installed: Option<&BTreeSet<String>>,
) -> Vec<&'a VerbDto> {
    let query = query.trim().to_lowercase();
    category
        .verbs
        .iter()
        .filter(|verb| {
            (!installed_only || installed.is_some_and(|installed| installed.contains(&verb.name)))
                && (query.is_empty()
                    || verb.name.to_lowercase().contains(&query)
                    || verb.description.to_lowercase().contains(&query))
        })
        .collect()
}

pub(crate) fn install_label(job: &InstallJob) -> String {
    let status = job.status.unwrap_or(JobStatus::Queued);
    let verb = job.progress.verb.as_deref().unwrap_or("");
    match (status, job.progress.stage.as_deref()) {
        (JobStatus::Queued, _) => "排队中…".to_owned(),
        (JobStatus::Running, Some("preparing")) if !verb.is_empty() => {
            format!("正在准备 {verb}…")
        }
        (JobStatus::Running, Some("output")) if !verb.is_empty() => {
            format!("正在安装 {verb}…")
        }
        (JobStatus::Running, Some("installed")) if !verb.is_empty() => {
            format!("已安装 {verb}")
        }
        (JobStatus::Running, Some("failed")) if !verb.is_empty() => {
            format!("安装失败：{verb}")
        }
        (JobStatus::Running, _) => "正在安装组件…".to_owned(),
        (JobStatus::Cancelling, _) => "正在取消…".to_owned(),
        (JobStatus::Completed, _) if !job.failed.is_empty() => {
            if job.succeeded.is_empty() {
                "安装失败".to_owned()
            } else {
                "部分组件安装失败".to_owned()
            }
        }
        (JobStatus::Completed, _) => "安装完成".to_owned(),
        (JobStatus::Failed, _) => "安装失败".to_owned(),
        (JobStatus::Cancelled, _) => "已取消".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CATALOG_FIXTURE: &str = r#"{
        "categories": [
            {"id": "apps", "verbs": [
                {"name": "7zip", "description": "7-Zip 24.09", "futureField": 1},
                {"name": "utorrent", "description": "µTorrent 2.2.1 (BitTorrent, 2011)"}
            ]},
            {"id": "dlls", "verbs": [
                {"name": "vcrun2022", "description": "Visual C++ 2015–2022"},
                {"name": "d3dx9", "description": "DirectX 9"}
            ]}
        ],
        "futureField": true
    }"#;

    fn catalog() -> CatalogDto {
        serde_json::from_str(CATALOG_FIXTURE).expect("catalog")
    }

    fn installed() -> BTreeSet<String> {
        ["7zip", "vcrun2022"]
            .into_iter()
            .map(str::to_owned)
            .collect()
    }

    #[test]
    fn catalog_decodes_categories_and_verbs_and_accepts_unknown_fields() {
        let catalog = catalog();
        assert_eq!(catalog.categories.len(), 2);
        assert_eq!(catalog.verb_count(), 4);
        assert_eq!(catalog.categories[0].id, "apps");
        assert_eq!(catalog.categories[0].verbs[1].name, "utorrent");
        assert_eq!(
            catalog.categories[0].verbs[1].description,
            "µTorrent 2.2.1 (BitTorrent, 2011)"
        );
    }

    #[test]
    fn filtering_matches_names_and_descriptions_case_insensitively() {
        let catalog = catalog();
        let apps = &catalog.categories[0];
        let names = |verbs: Vec<&VerbDto>| {
            verbs
                .into_iter()
                .map(|verb| verb.name.clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(
            names(filtered_verbs(apps, "", false, None)),
            ["7zip", "utorrent"]
        );
        assert_eq!(names(filtered_verbs(apps, "ZIP", false, None)), ["7zip"]);
        assert_eq!(
            names(filtered_verbs(apps, "bit", false, None)),
            ["utorrent"]
        );
        assert!(filtered_verbs(apps, "missing", false, None).is_empty());
    }

    #[test]
    fn installed_filter_needs_a_loaded_set_and_keeps_catalog_order() {
        let catalog = catalog();
        let app_names = |installed_only, installed_set| {
            filtered_verbs(&catalog.categories[0], "", installed_only, installed_set)
                .into_iter()
                .map(|verb| verb.name.as_str())
                .collect::<Vec<_>>()
        };
        let installed = installed();
        assert_eq!(app_names(true, Some(&installed)), ["7zip"]);
        // Loading has not finished: nothing is claimed installed.
        assert!(app_names(true, None).is_empty());
        assert_eq!(app_names(false, None), ["7zip", "utorrent"]);
    }

    #[test]
    fn installed_payload_decodes_both_cache_sources() {
        let dto: InstalledDto = serde_json::from_str(
            r#"{"verbs": ["vcrun2022", "7zip"], "fromCache": true, "futureField": 2}"#,
        )
        .expect("installed");
        assert_eq!(dto.verbs, ["vcrun2022", "7zip"]);
        assert!(dto.from_cache);
        let empty: InstalledDto = serde_json::from_str("{}").expect("empty installed");
        assert!(empty.verbs.is_empty());
        assert!(!empty.from_cache);
    }

    #[test]
    fn progress_decodes_the_helpers_latest_line() {
        let value = serde_json::json!({
            "stage": "output",
            "verb": "vcrun2022",
            "index": 2,
            "total": 3,
            "line": "Downloading vc_redist.x64.exe",
            "futureField": true
        });
        let progress = InstallProgress::from_value(&value);
        assert_eq!(progress.stage.as_deref(), Some("output"));
        assert_eq!(progress.verb.as_deref(), Some("vcrun2022"));
        assert_eq!(progress.index, Some(2));
        assert_eq!(progress.total, Some(3));
        assert_eq!(
            progress.line.as_deref(),
            Some("Downloading vc_redist.x64.exe")
        );
        assert_eq!(progress.count_label().as_deref(), Some("2 / 3"));
        assert_eq!(
            InstallProgress::from_value(&Value::Null),
            InstallProgress::default()
        );
    }

    #[test]
    fn result_decodes_installed_succeeded_and_failures() {
        let result: InstallResultDto = serde_json::from_str(
            r#"{
                "verbs": ["vcrun2022", "d3dx9"],
                "installed": ["7zip", "vcrun2022"],
                "succeeded": ["vcrun2022"],
                "failed": [{"verb": "d3dx9", "reason": "winetricks exited with code 1"}],
                "exitCodes": {"vcrun2022": 0, "d3dx9": 1},
                "futureField": null
            }"#,
        )
        .expect("result");
        assert_eq!(result.installed, ["7zip", "vcrun2022"]);
        assert_eq!(result.succeeded, ["vcrun2022"]);
        assert_eq!(result.failed.len(), 1);
        assert_eq!(
            result.failed[0].label(),
            "d3dx9：winetricks exited with code 1"
        );
    }

    #[test]
    fn labels_follow_the_job_status_and_current_verb() {
        let mut job = InstallJob::new("/bottle");
        assert_eq!(job.label(), "排队中…");
        assert!(job.running());
        job.status = Some(JobStatus::Running);
        job.progress = InstallProgress {
            stage: Some("preparing".into()),
            verb: Some("vcrun2022".into()),
            ..Default::default()
        };
        assert_eq!(job.label(), "正在准备 vcrun2022…");
        job.progress.stage = Some("output".into());
        job.progress.line = Some("line".into());
        assert_eq!(job.label(), "正在安装 vcrun2022…");
        job.progress.stage = Some("installed".into());
        assert_eq!(job.label(), "已安装 vcrun2022");
        job.status = Some(JobStatus::Cancelling);
        assert_eq!(job.label(), "正在取消…");
        job.status = Some(JobStatus::Cancelled);
        job.finished = true;
        assert!(!job.running());
        assert_eq!(job.label(), "已取消");

        let mut mixed = InstallJob::new("/bottle");
        mixed.status = Some(JobStatus::Completed);
        mixed.finished = true;
        mixed.failed = vec![FailureDto {
            verb: "bad".into(),
            reason: "winetricks exited with code 1".into(),
        }];
        assert_eq!(mixed.label(), "安装失败");
        mixed.succeeded = vec!["good".into()];
        assert_eq!(mixed.label(), "部分组件安装失败");
    }

    #[test]
    fn an_empty_catalog_is_valid_and_selects_no_category() {
        let catalog: CatalogDto = serde_json::from_str(r#"{"categories": []}"#).unwrap();
        let mut state = WinetricksState {
            catalog: Some(catalog),
            ..Default::default()
        };
        state.ensure_category();
        assert_eq!(state.category, None);
        assert_eq!(category_label("dlls"), "DLL");
        assert_eq!(category_label("prefix"), "prefix");
    }
}
