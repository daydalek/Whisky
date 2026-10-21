//! Scan job lifecycle and catalogue pagination.
//!
//! `library.scan` starts a `BridgeJobStore` job and returns `{jobID}`. The job's
//! `status` strings are the ones `BridgeJobStore.start` writes:
//! `queued`, `running`, `cancelling`, `completed`, `failed`, `cancelled`.
//! The only `progress.stage` `ApplicationService.scanLibrary` emits is
//! `scanning`; `library.page` replies carry `nextOffset` (`null` at the end).
//!
//! Everything in this module is pure so the merge rules are testable without a
//! helper process.

use serde_json::{Value, json};

use crate::bridge::dto::{EntryDto, LibraryPageDto};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum JobStatus {
    Queued,
    Running,
    Cancelling,
    Completed,
    Failed,
    Cancelled,
}

impl JobStatus {
    pub(crate) fn from_wire(raw: &str) -> Option<Self> {
        match raw {
            "queued" => Some(Self::Queued),
            "running" => Some(Self::Running),
            "cancelling" => Some(Self::Cancelling),
            "completed" => Some(Self::Completed),
            "failed" => Some(Self::Failed),
            "cancelled" => Some(Self::Cancelled),
            _ => None,
        }
    }

    pub(crate) fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }

    /// Sheet copy for the status, paired with the job's stage.
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Queued => "排队中…",
            Self::Running => "正在扫描…",
            Self::Cancelling => "正在取消…",
            Self::Completed => "扫描完成",
            Self::Failed => "扫描失败",
            Self::Cancelled => "已取消",
        }
    }
}

/// Progress line for the sheet. `scanning` comes from the helper; `paging` is
/// this frontend's own phase while it walks `library.page`.
pub(crate) fn progress_label(status: JobStatus, stage: Option<&str>) -> &'static str {
    match (status, stage) {
        (JobStatus::Queued, _) => "排队中…",
        (JobStatus::Running, Some("paging")) => "正在载入条目…",
        (JobStatus::Running, _) => "正在扫描…",
        (JobStatus::Cancelling, _) => "正在取消…",
        (JobStatus::Completed, _) => "扫描完成",
        (JobStatus::Failed, _) => "扫描失败",
        (JobStatus::Cancelled, _) => "已取消",
    }
}

/// `library.page` request. `snapshotID` identifies the scan result; `offset`
/// and `limit` must stay within 0…total and 1…100.
pub(crate) fn page_payload(snapshot_id: &str, offset: u64, limit: u64) -> Value {
    json!({
        "snapshotID": snapshot_id,
        "offset": offset,
        "limit": limit,
    })
}

/// Accumulates pages in order. `nextOffset` is the only stop condition: a page
/// that does not advance, or whose length disagrees with the offset it claims,
/// is an error rather than a silently truncated catalogue.
#[derive(Debug)]
pub(crate) struct PageAccumulator {
    pub(crate) total: u64,
    pub(crate) offset: u64,
    entries: Vec<EntryDto>,
    finished: bool,
}

impl PageAccumulator {
    pub(crate) fn start(total: u64) -> Self {
        Self {
            total,
            offset: 0,
            entries: Vec::new(),
            finished: false,
        }
    }

    pub(crate) fn loaded(&self) -> usize {
        self.entries.len()
    }

    #[cfg(test)]
    pub(crate) fn finished(&self) -> bool {
        self.finished
    }

    /// Apply one page. Returns the next offset to request, or `None` when the
    /// reply ended the catalogue (`nextOffset == null`).
    pub(crate) fn apply(&mut self, page: &LibraryPageDto) -> Result<Option<u64>, String> {
        if self.finished {
            return Err("a page arrived after the catalogue ended".to_owned());
        }
        if page.total != self.total {
            return Err(format!(
                "total changed during pagination: {} then {}",
                self.total, page.total
            ));
        }
        let expected_end = self.offset + page.entries.len() as u64;
        if expected_end > self.total {
            return Err("a page returned more entries than the catalogue holds".to_owned());
        }
        if expected_end > crate::config::MAX_ENTRIES as u64 {
            return Err("catalogue exceeds 50000 entries".to_owned());
        }
        self.entries.extend(page.entries.iter().cloned());
        let Some(next) = page.next_offset else {
            if expected_end != self.total {
                return Err(format!(
                    "pagination ended at {expected_end} of {}",
                    self.total
                ));
            }
            self.finished = true;
            return Ok(None);
        };
        if next != expected_end {
            return Err(format!(
                "page at {} returned {} entries but nextOffset {next}",
                self.offset,
                page.entries.len()
            ));
        }
        if next >= self.total {
            return Err("nextOffset is not below total".to_owned());
        }
        self.offset = next;
        Ok(Some(next))
    }

    /// The merged catalogue, in the order the helper returned it.
    pub(crate) fn into_entries(self) -> Vec<EntryDto> {
        self.entries
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn entry(name: &str) -> EntryDto {
        EntryDto {
            id: format!("pinned:{name}"),
            name: name.to_owned(),
            container: None,
            executable: None,
            needs_executable: false,
            icon: None,
            hidden: false,
            metadata: None,
            activity: Default::default(),
            cover: None,
            cover_aspect_ratio: None,
        }
    }

    fn page(names: &[&str], total: u64, next: Option<u64>) -> LibraryPageDto {
        LibraryPageDto {
            entries: names.iter().map(|name| entry(name)).collect(),
            total,
            next_offset: next,
        }
    }

    fn names(entries: &[EntryDto]) -> Vec<&str> {
        entries.iter().map(|entry| entry.name.as_str()).collect()
    }

    #[test]
    fn pages_merge_in_order_and_stop_exactly_at_a_null_next_offset() {
        let mut scan = PageAccumulator::start(6);
        assert_eq!(scan.apply(&page(&["a", "b"], 6, Some(2))), Ok(Some(2)));
        assert_eq!(
            scan.apply(&page(&["c", "d", "e"], 6, Some(5))),
            Ok(Some(5))
        );
        assert_eq!(scan.apply(&page(&["f"], 6, None)), Ok(None));
        assert!(scan.finished());
        assert_eq!(scan.loaded(), 6);
        assert_eq!(names(&scan.into_entries()), ["a", "b", "c", "d", "e", "f"]);
    }

    #[test]
    fn a_zero_entry_scan_finishes_immediately_with_the_empty_catalogue() {
        let mut scan = PageAccumulator::start(0);
        assert_eq!(scan.apply(&page(&[], 0, None)), Ok(None));
        assert!(scan.finished());
        assert!(scan.into_entries().is_empty());
    }

    #[test]
    fn a_page_that_does_not_advance_is_rejected() {
        let mut scan = PageAccumulator::start(10);
        scan.apply(&page(&["a"], 10, Some(1))).unwrap();
        let error = scan.apply(&page(&["b"], 10, Some(1))).unwrap_err();
        assert!(error.contains("nextOffset 1"), "{error}");
    }

    #[test]
    fn a_changed_total_or_a_short_final_page_is_rejected() {
        let mut scan = PageAccumulator::start(10);
        assert!(scan.apply(&page(&["a"], 9, Some(1))).is_err());

        let mut scan = PageAccumulator::start(10);
        let error = scan.apply(&page(&["a"], 10, None)).unwrap_err();
        assert!(error.contains("ended at 1 of 10"), "{error}");
    }

    #[test]
    fn a_page_after_the_end_is_rejected() {
        let mut scan = PageAccumulator::start(0);
        scan.apply(&page(&[], 0, None)).unwrap();
        assert!(scan.apply(&page(&[], 0, None)).is_err());
    }

    #[test]
    fn page_requests_stay_inside_the_helper_limits() {
        assert_eq!(
            page_payload("snapshot-1", 0, 100),
            json!({"snapshotID": "snapshot-1", "offset": 0, "limit": 100})
        );
        assert!((1..=100).contains(&crate::config::PAGE_LIMIT));
    }

    #[test]
    fn every_job_status_the_store_writes_maps_to_a_label() {
        let table = [
            ("queued", JobStatus::Queued, "排队中…", false),
            ("running", JobStatus::Running, "正在扫描…", false),
            ("cancelling", JobStatus::Cancelling, "正在取消…", false),
            ("completed", JobStatus::Completed, "扫描完成", true),
            ("failed", JobStatus::Failed, "扫描失败", true),
            ("cancelled", JobStatus::Cancelled, "已取消", true),
        ];
        for (wire, status, label, terminal) in table {
            let decoded = JobStatus::from_wire(wire).expect(wire);
            assert_eq!(decoded, status);
            assert_eq!(decoded.label(), label);
            assert_eq!(decoded.is_terminal(), terminal);
        }
        assert_eq!(JobStatus::from_wire("succeeded"), None);
        assert_eq!(JobStatus::from_wire(""), None);
    }

    #[test]
    fn paging_has_its_own_stage_because_the_helper_reports_only_scanning() {
        assert_eq!(progress_label(JobStatus::Queued, None), "排队中…");
        assert_eq!(progress_label(JobStatus::Running, Some("scanning")), "正在扫描…");
        assert_eq!(progress_label(JobStatus::Running, None), "正在扫描…");
        assert_eq!(progress_label(JobStatus::Running, Some("paging")), "正在载入条目…");
        assert_eq!(progress_label(JobStatus::Cancelling, None), "正在取消…");
        assert_eq!(progress_label(JobStatus::Cancelled, None), "已取消");
    }
}
