//! Installed-program table: the rows `programs.list` returns and the
//! optimistic pin/block bookkeeping behind `programs.pin` / `programs.block`.
//!
//! Everything here is pure so the optimistic update and its rollback can be
//! tested without a window or a bridge process. Both mutations reply with the
//! whole refreshed list (`Service.programCall`), which [`ProgramTable::apply`]
//! stores verbatim except where an edit is still in flight.

use std::collections::BTreeMap;

use crate::bridge::dto::ProgramDto;
use crate::runtime::PendingEdits;

/// Empty-state copy for the Programs page.
pub(crate) const EMPTY_PROGRAMS: &str = "暂无程序";

#[derive(Debug, Default)]
pub(crate) struct ProgramTable {
    rows: BTreeMap<String, ProgramDto>,
    /// Last committed `pinned` flag per path, for rollback on a rejection.
    pins: PendingEdits<bool>,
    /// Last committed `blocked` flag per path.
    blocks: PendingEdits<bool>,
}

impl ProgramTable {
    /// Replace the list with an authoritative reply. A row whose pin or block
    /// edit is still in flight keeps its optimistic flag: the reply may have
    /// raced a second click and must not flash the old value back.
    pub(crate) fn apply(&mut self, programs: Vec<ProgramDto>) {
        let previous = std::mem::take(&mut self.rows);
        for mut program in programs {
            let path = program.path.clone();
            if self.pins.contains(&path) && let Some(row) = previous.get(&path) {
                program.pinned = row.pinned;
            }
            if self.blocks.contains(&path) && let Some(row) = previous.get(&path) {
                program.blocked = row.blocked;
            }
            self.rows.insert(path, program);
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    pub(crate) fn row(&self, path: &str) -> Option<&ProgramDto> {
        self.rows.get(path)
    }

    /// Pinned programs first, then by name — the SwiftUI program browser's
    /// order.
    pub(crate) fn ordered(&self) -> Vec<&ProgramDto> {
        let mut rows: Vec<&ProgramDto> = self.rows.values().collect();
        rows.sort_by(|left, right| {
            right
                .pinned
                .cmp(&left.pinned)
                .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
        });
        rows
    }

    /// Flip `pinned` optimistically. Returns `false` when the path is unknown.
    pub(crate) fn set_pinned(&mut self, path: &str, pinned: bool) -> bool {
        let Some(row) = self.rows.get_mut(path) else {
            return false;
        };
        self.pins.begin(path, row.pinned);
        row.pinned = pinned;
        true
    }

    /// Flip `blocked` optimistically. Returns `false` when the path is unknown.
    pub(crate) fn set_blocked(&mut self, path: &str, blocked: bool) -> bool {
        let Some(row) = self.rows.get_mut(path) else {
            return false;
        };
        self.blocks.begin(path, row.blocked);
        row.blocked = blocked;
        true
    }

    /// The helper accepted the write; its reply is now authoritative.
    pub(crate) fn commit_pin(&mut self, path: &str) {
        self.pins.succeed(path);
    }

    pub(crate) fn commit_block(&mut self, path: &str) {
        self.blocks.succeed(path);
    }

    /// Restore the last committed `pinned` flag; `true` when there was
    /// something to roll back.
    pub(crate) fn rollback_pin(&mut self, path: &str) -> bool {
        let Some(previous) = self.pins.fail(path) else {
            return false;
        };
        if let Some(row) = self.rows.get_mut(path) {
            row.pinned = previous;
        }
        true
    }

    pub(crate) fn rollback_block(&mut self, path: &str) -> bool {
        let Some(previous) = self.blocks.fail(path) else {
            return false;
        };
        if let Some(row) = self.rows.get_mut(path) {
            row.blocked = previous;
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn program(path: &str, name: &str, pinned: bool, blocked: bool) -> ProgramDto {
        ProgramDto {
            path: path.into(),
            name: name.into(),
            pinned,
            blocked,
            available: true,
        }
    }

    fn flags(table: &ProgramTable, path: &str) -> (bool, bool) {
        let row = table.row(path).expect("row");
        (row.pinned, row.blocked)
    }

    #[test]
    fn pin_and_block_update_optimistically_and_roll_back_on_rejection() {
        let mut table = ProgramTable::default();
        table.apply(vec![program("/a/sample.exe", "Sample", false, false)]);

        // Optimistic: the row shows the new flag before any reply.
        assert!(table.set_pinned("/a/sample.exe", true));
        assert_eq!(flags(&table, "/a/sample.exe"), (true, false));

        // The helper rejected the write: the committed flag returns.
        assert!(table.rollback_pin("/a/sample.exe"));
        assert_eq!(flags(&table, "/a/sample.exe"), (false, false));
        // Rollback runs once.
        assert!(!table.rollback_pin("/a/sample.exe"));

        // The same for the blocklist flag.
        assert!(table.set_blocked("/a/sample.exe", true));
        assert_eq!(flags(&table, "/a/sample.exe"), (false, true));
        assert!(table.rollback_block("/a/sample.exe"));
        assert_eq!(flags(&table, "/a/sample.exe"), (false, false));

        // A successful mutation just settles the edit.
        assert!(table.set_pinned("/a/sample.exe", true));
        table.commit_pin("/a/sample.exe");
        assert_eq!(flags(&table, "/a/sample.exe"), (true, false));
        assert!(!table.rollback_pin("/a/sample.exe"));

        // Unknown paths never move.
        assert!(!table.set_pinned("/missing.exe", true));
    }

    #[test]
    fn an_authoritative_list_keeps_in_flight_optimistic_flags() {
        let mut table = ProgramTable::default();
        table.apply(vec![
            program("/a/sample.exe", "Sample", false, false),
            program("/k/kanon.exe", "kanon", false, false),
        ]);
        // Two clicks in flight when the first reply lands.
        assert!(table.set_pinned("/a/sample.exe", true));
        assert!(table.set_blocked("/k/kanon.exe", true));
        // The reply reflects only the first edit; the second stays optimistic.
        table.apply(vec![
            program("/a/sample.exe", "Sample", true, false),
            program("/k/kanon.exe", "kanon", false, false),
        ]);
        assert_eq!(flags(&table, "/a/sample.exe"), (true, false));
        assert_eq!(flags(&table, "/k/kanon.exe"), (false, true));
        table.commit_pin("/a/sample.exe");
        table.commit_block("/k/kanon.exe");
    }

    #[test]
    fn an_empty_program_list_is_the_empty_state() {
        let mut table = ProgramTable::default();
        assert!(table.is_empty());
        assert_eq!(EMPTY_PROGRAMS, "暂无程序");
        table.apply(vec![]);
        assert!(table.is_empty());
        table.apply(vec![program("/a/sample.exe", "Sample", true, false)]);
        assert!(!table.is_empty());
        assert_eq!(table.ordered().len(), 1);
    }

    #[test]
    fn pinned_programs_order_before_unpinned_ones_by_name() {
        let mut table = ProgramTable::default();
        table.apply(vec![
            program("/z/zork.exe", "zork", false, false),
            program("/b/braid.exe", "Braid", true, false),
            program("/a/sample.exe", "Sample", false, false),
        ]);
        let names: Vec<&str> = table.ordered().iter().map(|row| row.name.as_str()).collect();
        assert_eq!(names, ["Braid", "Sample", "zork"]);
    }
}
