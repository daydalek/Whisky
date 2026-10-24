//! Running-process table: the rows `processes.list` returns, the optimistic
//! removal behind `processes.kill`, and the adaptive poll cadence.
//!
//! Pure like [`crate::programs`]: kill bookkeeping and cadence selection are
//! testable without a bridge process or a live Wine server.

use std::collections::BTreeMap;
use std::time::Duration;

use crate::bridge::dto::ProcessDto;

/// Poll cadence while at least one process is alive: exits are changes the
/// page has to show quickly.
pub(crate) const ALIVE_POLL: Duration = Duration::from_secs(3);
/// Poll cadence when nothing runs: the list can only change if something is
/// started elsewhere, and the next tick still reports it.
pub(crate) const IDLE_POLL: Duration = Duration::from_secs(8);

/// Cadence selection as a pure function so the alive/idle split is testable.
pub(crate) fn poll_interval(any_alive: bool) -> Duration {
    if any_alive { ALIVE_POLL } else { IDLE_POLL }
}

/// What a `processes.kill` reply did to the optimistically removed row.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum KillOutcome {
    /// No removal was pending for this PID (a duplicate reply).
    Unknown,
    /// The helper killed the process; the row stays off screen.
    Removed,
    /// The helper did not kill anything; the row is back and the caller
    /// should surface the failure.
    Restored(ProcessDto),
}

#[derive(Debug, Default)]
pub(crate) struct ProcessTable {
    rows: Vec<ProcessDto>,
    /// Rows pulled off screen for a kill, with their list index, restored on a
    /// failed reply. Polls keep hiding them until the reply settles.
    pending: BTreeMap<i64, (usize, ProcessDto)>,
}

impl ProcessTable {
    /// Replace the rows with the newest snapshot, keeping pending kills hidden.
    pub(crate) fn apply(&mut self, rows: Vec<ProcessDto>) {
        self.rows = rows
            .into_iter()
            .filter(|row| !self.pending.contains_key(&row.pid))
            .collect();
    }

    pub(crate) fn rows(&self) -> &[ProcessDto] {
        &self.rows
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    /// Whether anything is on screen — drives [`poll_interval`].
    pub(crate) fn any_alive(&self) -> bool {
        !self.rows.is_empty()
    }

    /// Optimistic removal. Returns `false` when no such row is on screen.
    pub(crate) fn begin_kill(&mut self, pid: i64) -> bool {
        let Some(index) = self.rows.iter().position(|row| row.pid == pid) else {
            return false;
        };
        let row = self.rows.remove(index);
        self.pending.insert(pid, (index, row));
        true
    }

    /// Settle the kill. A `killed: true` reply finishes the removal; anything
    /// else puts the row back where it was.
    pub(crate) fn finish_kill(&mut self, pid: i64, killed: bool) -> KillOutcome {
        let Some((index, row)) = self.pending.remove(&pid) else {
            return KillOutcome::Unknown;
        };
        if killed {
            return KillOutcome::Removed;
        }
        let index = index.min(self.rows.len());
        self.rows.insert(index, row.clone());
        KillOutcome::Restored(row)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(pid: i64, name: &str) -> ProcessDto {
        ProcessDto {
            pid,
            name: name.into(),
            memory: Some("24 K".into()),
            kind: Some("app".into()),
            source: Some("untracked".into()),
            started_at: None,
            macos_pid: None,
        }
    }

    fn pids(table: &ProcessTable) -> Vec<i64> {
        table.rows().iter().map(|row| row.pid).collect()
    }

    #[test]
    fn kill_removes_the_row_optimistically_and_a_failed_reply_rolls_it_back() {
        let mut table = ProcessTable::default();
        table.apply(vec![row(1, "a.exe"), row(2, "b.exe"), row(3, "c.exe")]);

        // Optimistic: the row leaves the list at once.
        assert!(table.begin_kill(2));
        assert_eq!(pids(&table), [1, 3]);
        // A poll during the call must not resurrect it.
        table.apply(vec![row(1, "a.exe"), row(2, "b.exe"), row(3, "c.exe")]);
        assert_eq!(pids(&table), [1, 3]);

        // The helper refused (killed: false): the row is restored in place.
        assert_eq!(
            table.finish_kill(2, false),
            KillOutcome::Restored(row(2, "b.exe"))
        );
        assert_eq!(pids(&table), [1, 2, 3]);

        // A settled kill leaves the row removed and the reply idempotent.
        assert!(table.begin_kill(2));
        assert_eq!(table.finish_kill(2, true), KillOutcome::Removed);
        assert_eq!(pids(&table), [1, 3]);
        assert_eq!(table.finish_kill(2, true), KillOutcome::Unknown);
    }

    #[test]
    fn killing_an_unlisted_pid_is_a_no_op() {
        let mut table = ProcessTable::default();
        table.apply(vec![row(1, "a.exe")]);
        assert!(!table.begin_kill(999));
        assert_eq!(pids(&table), [1]);
        assert_eq!(table.finish_kill(999, true), KillOutcome::Unknown);
    }

    #[test]
    fn poll_cadence_follows_liveness() {
        assert_eq!(poll_interval(true), Duration::from_secs(3));
        assert_eq!(poll_interval(false), Duration::from_secs(8));
        let mut table = ProcessTable::default();
        table.apply(vec![row(1, "a.exe")]);
        assert_eq!(poll_interval(table.any_alive()), ALIVE_POLL);
        assert!(table.begin_kill(1));
        assert_eq!(table.finish_kill(1, true), KillOutcome::Removed);
        assert!(table.is_empty());
        assert_eq!(poll_interval(table.any_alive()), IDLE_POLL);
    }
}
