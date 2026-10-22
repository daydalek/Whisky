//! Candidate identity and UI state for existing-container import.
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) struct Candidate {
    pub(crate) path: String,
    pub(crate) name: String,
    pub(crate) device: String,
    pub(crate) inode: String,
}

#[derive(Default)]
pub(crate) struct ImportState {
    pub(crate) request: u64,
    pub(crate) root: Option<String>,
    pub(crate) candidates: Vec<Candidate>,
    pub(crate) selected: BTreeSet<String>,
    pub(crate) loading: bool,
    pub(crate) importing: bool,
    pub(crate) error: Option<String>,
    pub(crate) completed: Option<usize>,
}

impl ImportState {
    pub(crate) fn scanning(request: u64, root: Option<String>) -> Self {
        Self {
            request,
            root,
            loading: true,
            ..Self::default()
        }
    }
    pub(crate) fn loaded(&mut self, request: u64, candidates: Vec<Candidate>) {
        if self.request != request {
            return;
        }
        self.loading = false;
        self.error = None;
        let mut seen = BTreeSet::new();
        self.candidates = candidates
            .into_iter()
            .filter(|candidate| seen.insert(candidate.path.clone()))
            .collect();
        self.selected.clear();
    }
    pub(crate) fn failed(&mut self, request: u64, error: String) {
        if self.request != request {
            return;
        }
        self.loading = false;
        self.importing = false;
        self.error = Some(if error.starts_with("candidate_changed:") {
            "候选容器已变化，请重新扫描后再导入".to_owned()
        } else {
            error
        });
    }
    pub(crate) fn toggle(&mut self, path: &str, checked: bool) {
        if self.loading
            || self.importing
            || !self
                .candidates
                .iter()
                .any(|candidate| candidate.path == path)
        {
            return;
        }
        if checked {
            if self.selected.len() < 128 {
                self.selected.insert(path.to_owned());
            } else {
                self.error = Some("每批最多选择 128 个容器，可分批导入".into());
            }
        } else {
            self.selected.remove(path);
        }
    }
    pub(crate) fn selection(&self) -> Vec<Candidate> {
        self.candidates
            .iter()
            .filter(|candidate| self.selected.contains(&candidate.path))
            .cloned()
            .collect()
    }
    pub(crate) fn imported(&mut self, request: u64, paths: &[String], count: usize) {
        if self.request != request {
            return;
        }
        self.importing = false;
        self.error = None;
        self.completed = Some(count);
        self.candidates
            .retain(|candidate| !paths.contains(&candidate.path));
        self.selected.clear();
    }
}

/// Treat only a complete acknowledgement of the selected identities as success.
pub(crate) fn import_reply(
    value: serde_json::Value,
    expected: &[Candidate],
) -> Result<usize, String> {
    #[derive(Deserialize)]
    struct Reply {
        imported: usize,
        containers: Vec<Candidate>,
    }
    let reply: Reply =
        serde_json::from_value(value).map_err(|error| format!("invalid import reply: {error}"))?;
    if reply.imported > expected.len()
        || reply.containers.len() != expected.len()
        || !expected.iter().all(|candidate| {
            reply.containers.iter().any(|actual| {
                actual.path == candidate.path
                    && actual.device == candidate.device
                    && actual.inode == candidate.inode
            })
        })
    {
        return Err("Import reply does not acknowledge the selected directory identities".into());
    }
    Ok(reply.imported)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn candidate(index: usize) -> Candidate {
        Candidate {
            path: format!("/fixtures/{index}"),
            name: format!("Bottle {index}"),
            device: "1".into(),
            inode: index.to_string(),
        }
    }
    #[test]
    fn stale_scan_and_import_responses_preserve_the_current_panel() {
        let mut state = ImportState::scanning(2, Some("/current".into()));
        state.loaded(1, vec![candidate(1)]);
        state.failed(1, "old failure".into());
        state.imported(1, &[], 3);
        assert!(state.loading && state.error.is_none() && state.completed.is_none());
        state.loaded(2, vec![candidate(2), candidate(2)]);
        assert_eq!(state.candidates.len(), 1);
    }
    #[test]
    fn selection_is_bounded_and_import_completion_removes_only_acknowledged_rows() {
        let mut state = ImportState::scanning(1, None);
        state.loaded(1, (0..140).map(candidate).collect());
        for index in 0..140 {
            state.toggle(&candidate(index).path, true);
        }
        assert_eq!(state.selection().len(), 128);
        assert!(state.error.is_some());
        let selected = state
            .selection()
            .into_iter()
            .map(|candidate| candidate.path)
            .collect::<Vec<_>>();
        state.imported(1, &selected, 128);
        assert_eq!(state.candidates.len(), 12);
        assert!(state.selected.is_empty());
        assert_eq!(state.completed, Some(128));
    }
    #[test]
    fn import_failure_keeps_the_selected_identities_available_for_retry() {
        let mut state = ImportState::scanning(1, None);
        state.loaded(1, vec![candidate(1)]);
        state.toggle("/fixtures/1", true);
        state.importing = true;
        state.failed(1, "candidate_changed".into());
        assert_eq!(state.selection(), vec![candidate(1)]);
        assert!(!state.importing);
        assert!(state.error.is_some());
    }
    #[test]
    fn import_reply_requires_complete_acknowledged_identities() {
        let expected = vec![candidate(1), candidate(2)];
        assert_eq!(
            import_reply(
                serde_json::json!({"imported": 2, "containers": expected}),
                &expected
            )
            .unwrap(),
            2
        );
        assert!(import_reply(serde_json::json!({"imported": 2}), &expected).is_err());
        assert!(import_reply(
            serde_json::json!({"imported": 3, "containers": expected}),
            &expected
        )
        .is_err());
        assert!(import_reply(
            serde_json::json!({"imported": 1, "containers": [candidate(1), candidate(9)]}),
            &expected
        )
        .is_err());
    }
}
