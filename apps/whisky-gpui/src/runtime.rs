//! Runtime session model: per-entry launch state, the primary action a card
//! offers, the clipboard handshake, and the poll cadence.
//!
//! Everything here is pure so the rules can be tested without a window, a
//! bridge process, or a running game. The supervisor owns the wire, the views
//! own the pixels; this module is the shared meaning between them.
//!
//! State strings come from `LibraryEntryState` in `LibraryLaunchSnapshot.swift`:
//! `idle`, `checkingLaunch`, `preparing`, `launching`, `startingSteam`,
//! `waitingForSteam`, `running`. Anything else is treated as unknown and
//! disables the action rather than guessing.

use std::collections::HashMap;
use std::time::Duration;

use serde_json::{Value, json};

use crate::bridge::dto::{ClipboardInteractionDto, LaunchReplyDto, RuntimeEntryDto};

/// `LibraryRuntimeCapabilities` option-set bits (`LibraryRuntime.swift`).
const CAP_LAUNCH: i64 = 1 << 0;
const CAP_CANCEL: i64 = 1 << 1;
const CAP_STOP: i64 = 1 << 2;

/// Poll cadence while at least one entry is not idle. A launch or an exit is
/// the interesting event, and both are only observable through this cursor.
pub(crate) const BUSY_POLL: Duration = Duration::from_secs(1);
/// Poll cadence when every entry is idle: nothing can change on its own except
/// a launch from another frontend, which the next poll still reports.
pub(crate) const IDLE_POLL: Duration = Duration::from_secs(4);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RuntimeState {
    Idle,
    CheckingLaunch,
    Preparing,
    Launching,
    StartingSteam,
    WaitingForSteam,
    Running,
    /// A state this build does not know. Kept as a real value so the entry can
    /// still be listed while its action stays disabled.
    Unknown,
}

impl RuntimeState {
    pub(crate) fn from_wire(raw: &str) -> Self {
        match raw {
            "idle" => Self::Idle,
            "checkingLaunch" => Self::CheckingLaunch,
            "preparing" => Self::Preparing,
            "launching" => Self::Launching,
            "startingSteam" => Self::StartingSteam,
            "waitingForSteam" => Self::WaitingForSteam,
            "running" => Self::Running,
            _ => Self::Unknown,
        }
    }

    /// Anything but idle keeps the fast cadence, including `running`: a game
    /// exiting is a change the card has to show. `Unknown` counts as active for
    /// the same reason — the entry is doing something we cannot name.
    pub(crate) fn is_active(self) -> bool {
        self != Self::Idle
    }

    /// Short phase label mirroring Swift's `phaseLabel`, used by the card badge.
    pub(crate) fn phase_label(self) -> &'static str {
        match self {
            Self::CheckingLaunch => "Starting…",
            Self::Preparing => "Preparing…",
            Self::Launching => "Launching…",
            Self::StartingSteam => "Starting Steam",
            Self::WaitingForSteam => "Waiting for Steam",
            Self::Running => "Running",
            Self::Idle | Self::Unknown => "Starting…",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct RuntimeEntry {
    pub(crate) state: RuntimeState,
    pub(crate) capabilities: i64,
}

/// What the primary button does. `None` in [`PrimaryAction`] means the button
/// is informational: it names the phase and cannot be pressed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RuntimeAction {
    Launch,
    Cancel,
    Stop,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PrimaryAction {
    pub(crate) label: &'static str,
    pub(crate) action: Option<RuntimeAction>,
    pub(crate) enabled: bool,
    /// Show the toolkit spinner next to the label (pre-launch phases).
    pub(crate) busy: bool,
}

impl PrimaryAction {
    /// Neutral, disabled "Play": used before a container is configured and for
    /// states this build does not understand. Never panics, never guesses.
    pub(crate) const fn unavailable() -> Self {
        Self {
            label: "Play",
            action: None,
            enabled: false,
            busy: false,
        }
    }
}

/// Derive the button from the state the bridge reported and the entry's
/// capability bits.
///
/// `checkingLaunch` has no cancel: `LibraryRuntimeController.cancelLaunch`
/// only accepts preparing or launching, so offering Cancel there would be a
/// dead control.
pub(crate) fn primary_action_for(state: RuntimeState, capabilities: i64) -> PrimaryAction {
    let can_launch = capabilities & CAP_LAUNCH != 0;
    let can_cancel = capabilities & CAP_CANCEL != 0;
    let can_stop = capabilities & CAP_STOP != 0;
    match state {
        RuntimeState::Idle => PrimaryAction {
            label: "Play",
            action: can_launch.then_some(RuntimeAction::Launch),
            enabled: can_launch,
            busy: false,
        },
        RuntimeState::CheckingLaunch => PrimaryAction {
            label: "Starting…",
            action: None,
            enabled: false,
            busy: true,
        },
        RuntimeState::Preparing | RuntimeState::Launching => {
            if can_cancel {
                PrimaryAction {
                    label: "Cancel",
                    action: Some(RuntimeAction::Cancel),
                    enabled: true,
                    busy: false,
                }
            } else {
                PrimaryAction {
                    label: "Starting…",
                    action: None,
                    enabled: false,
                    busy: true,
                }
            }
        }
        // Programs carry no `stop` capability, so a running program reads as
        // "Running" rather than offering a control that the helper rejects.
        RuntimeState::Running if !can_stop => PrimaryAction {
            label: "Running",
            action: None,
            enabled: false,
            busy: false,
        },
        RuntimeState::Running | RuntimeState::StartingSteam | RuntimeState::WaitingForSteam => {
            if can_stop {
                PrimaryAction {
                    label: "Stop",
                    action: Some(RuntimeAction::Stop),
                    enabled: true,
                    busy: false,
                }
            } else {
                PrimaryAction {
                    label: "Starting…",
                    action: None,
                    enabled: false,
                    busy: true,
                }
            }
        }
        RuntimeState::Unknown => PrimaryAction::unavailable(),
    }
}

/// One `runtime.events`/`runtime.snapshot` result, already reduced to what the
/// UI stores. `resync` means "this list is the whole truth": stale entries are
/// dropped instead of merged.
#[derive(Debug, Clone)]
pub(crate) struct RuntimeUpdate {
    pub(crate) container: String,
    pub(crate) entries: Vec<RuntimeEntryDto>,
    pub(crate) resync: bool,
}

impl RuntimeUpdate {
    pub(crate) fn resync(container: &str, entries: Vec<RuntimeEntryDto>) -> Self {
        Self {
            container: container.to_owned(),
            entries,
            resync: true,
        }
    }

    pub(crate) fn merge(container: &str, entries: Vec<RuntimeEntryDto>) -> Self {
        Self {
            container: container.to_owned(),
            entries,
            resync: false,
        }
    }
}

/// Per-entry runtime state, keyed by bridge entry id.
///
/// `runtime.configure` is additive on the helper side — it drops only the
/// entries of the container being reconfigured — so this table intentionally
/// has no container: an entry is actionable exactly when it is present here,
/// which is also exactly what `runtime.launch` accepts.
#[derive(Debug, Default)]
pub(crate) struct RuntimeTable {
    entries: HashMap<String, RuntimeEntry>,
}

impl RuntimeTable {
    pub(crate) fn apply(&mut self, update: RuntimeUpdate) {
        if update.resync {
            self.entries.clear();
        }
        for entry in update.entries {
            self.entries.insert(
                entry.id,
                RuntimeEntry {
                    state: RuntimeState::from_wire(&entry.state),
                    capabilities: entry.capabilities,
                },
            );
        }
    }

    pub(crate) fn entry(&self, id: &str) -> Option<RuntimeEntry> {
        self.entries.get(id).copied()
    }

    /// Optimistic transition after an accepted mutation. The next snapshot
    /// overwrites it, so this only has to be plausible, never authoritative.
    pub(crate) fn set_state(&mut self, id: &str, state: RuntimeState) {
        if let Some(entry) = self.entries.get_mut(id) {
            entry.state = state;
        }
    }
}

/// Cadence selection as a pure function so the busy/idle split is testable.
pub(crate) fn poll_interval(any_active: bool) -> Duration {
    if any_active { BUSY_POLL } else { IDLE_POLL }
}

/// `ClipboardDecision` as the helper spells it: `LaunchInteractionBroker.resolve`
/// accepts exactly these two strings. Both continue the launch; the difference
/// is whether the clipboard is cleared first. Any other string is rejected with
/// `invalid_params`, so the sheet offers only these plus a dismiss.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ClipboardDecision {
    Clear,
    Keep,
}

impl ClipboardDecision {
    pub(crate) fn as_wire(self) -> &'static str {
        match self {
            Self::Clear => "clear",
            Self::Keep => "keep",
        }
    }
}

/// A pending clipboard preflight. The token is one-use and bound to the entry
/// and clipboard version; it must be sent back unchanged or the helper answers
/// `stale_interaction`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ClipboardPrompt {
    pub(crate) container: String,
    pub(crate) entry_id: String,
    pub(crate) token: String,
    pub(crate) content_type: String,
    pub(crate) size_bytes: i64,
    pub(crate) preview: Option<String>,
}

impl ClipboardPrompt {
    /// `None` when the reply names an interaction this build cannot answer.
    pub(crate) fn new(
        container: &str,
        entry_id: &str,
        interaction: ClipboardInteractionDto,
    ) -> Option<Self> {
        if interaction.kind != "clipboard" {
            return None;
        }
        Some(Self {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
            token: interaction.token,
            content_type: interaction.content_type,
            size_bytes: interaction.size_bytes,
            preview: interaction.preview,
        })
    }

    /// The second `runtime.launch` call. The token travels unchanged.
    pub(crate) fn params(&self, decision: ClipboardDecision) -> Value {
        json!({
            "container": self.container,
            "entryID": self.entry_id,
            "interactionToken": self.token,
            "clipboardDecision": decision.as_wire(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum LaunchOutcome {
    Accepted,
    /// The helper stopped before launching and wants a clipboard decision.
    Prompt(ClipboardPrompt),
    /// Refused without a prompt; the caller reports it on the error surface.
    Rejected,
}

pub(crate) fn interpret_launch_reply(
    container: &str,
    entry_id: &str,
    reply: LaunchReplyDto,
) -> LaunchOutcome {
    match (reply.accepted, reply.interaction) {
        (true, _) => LaunchOutcome::Accepted,
        (false, Some(interaction)) => ClipboardPrompt::new(container, entry_id, interaction)
            .map_or(LaunchOutcome::Rejected, LaunchOutcome::Prompt),
        (false, None) => LaunchOutcome::Rejected,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROGRAM: i64 = CAP_LAUNCH | CAP_CANCEL;
    const STEAM: i64 = CAP_LAUNCH | CAP_CANCEL | CAP_STOP;

    fn dto(id: &str, state: &str, capabilities: i64) -> RuntimeEntryDto {
        RuntimeEntryDto {
            id: id.into(),
            state: state.into(),
            capabilities,
        }
    }

    fn labels(table: &RuntimeTable, id: &str) -> &'static str {
        let entry = table.entry(id).expect("entry");
        primary_action_for(entry.state, entry.capabilities).label
    }

    #[test]
    fn a_launch_sequence_produces_the_expected_button_labels() {
        let mut table = RuntimeTable::default();
        let mut seen = Vec::new();
        for state in ["idle", "preparing", "launching", "running", "idle"] {
            // Deltas only carry the entries that changed; resync only on a
            // configure, which is not what this sequence models.
            table.apply(RuntimeUpdate::merge("bottle", vec![dto("pinned:a", state, STEAM)]));
            seen.push(labels(&table, "pinned:a"));
        }
        assert_eq!(seen, ["Play", "Cancel", "Cancel", "Stop", "Play"]);
    }

    #[test]
    fn checking_launch_has_no_cancel_and_shows_the_progress_treatment() {
        let action = primary_action_for(RuntimeState::CheckingLaunch, STEAM);
        assert_eq!(action.label, "Starting…");
        assert!(action.busy);
        assert!(!action.enabled);
        assert_eq!(action.action, None);
    }

    #[test]
    fn a_running_program_offers_no_stop_because_the_helper_would_refuse() {
        let action = primary_action_for(RuntimeState::Running, PROGRAM);
        assert_eq!(action.label, "Running");
        assert!(!action.enabled);
        assert_eq!(action.action, None);

        let steam = primary_action_for(RuntimeState::Running, STEAM);
        assert_eq!(steam.label, "Stop");
        assert_eq!(steam.action, Some(RuntimeAction::Stop));
    }

    #[test]
    fn idle_without_the_launch_capability_is_disabled() {
        let action = primary_action_for(RuntimeState::Idle, 0);
        assert_eq!(action.label, "Play");
        assert!(!action.enabled);
        assert_eq!(action.action, None);
    }

    #[test]
    fn resync_replaces_state_instead_of_merging_stale_entries() {
        let mut table = RuntimeTable::default();
        table.apply(RuntimeUpdate::resync(
            "bottle",
            vec![dto("pinned:a", "running", STEAM), dto("pinned:b", "idle", STEAM)],
        ));
        assert!(table.entry("pinned:b").is_some());

        // A delta that does not mention `pinned:b` keeps it.
        table.apply(RuntimeUpdate::merge("bottle", vec![dto("pinned:a", "idle", STEAM)]));
        assert!(table.entry("pinned:b").is_some());
        assert_eq!(labels(&table, "pinned:a"), "Play");

        // A resync is the whole truth: the vanished entry is dropped.
        table.apply(RuntimeUpdate::resync("bottle", vec![dto("pinned:a", "running", STEAM)]));
        assert!(table.entry("pinned:b").is_none());
        assert_eq!(labels(&table, "pinned:a"), "Stop");
    }

    #[test]
    fn an_entry_that_was_never_configured_has_no_state() {
        let mut table = RuntimeTable::default();
        assert!(table.entry("pinned:a").is_none());
        table.apply(RuntimeUpdate::resync("bottle", vec![dto("pinned:a", "idle", STEAM)]));
        assert!(table.entry("pinned:a").is_some());
        assert!(table.entry("pinned:b").is_none());
    }

    #[test]
    fn optimistic_transitions_are_overwritten_by_the_next_update() {
        let mut table = RuntimeTable::default();
        table.apply(RuntimeUpdate::resync("bottle", vec![dto("pinned:a", "idle", STEAM)]));
        table.set_state("pinned:a", RuntimeState::Preparing);
        assert_eq!(labels(&table, "pinned:a"), "Cancel");
        table.apply(RuntimeUpdate::merge("bottle", vec![dto("pinned:a", "idle", STEAM)]));
        assert_eq!(labels(&table, "pinned:a"), "Play");
    }

    #[test]
    fn unknown_runtime_states_degrade_to_a_disabled_button() {
        let mut table = RuntimeTable::default();
        table.apply(RuntimeUpdate::resync(
            "bottle",
            vec![dto("pinned:a", "hibernating", STEAM)],
        ));
        let entry = table.entry("pinned:a").expect("entry");
        assert_eq!(entry.state, RuntimeState::Unknown);
        let action = primary_action_for(entry.state, entry.capabilities);
        assert!(!action.enabled);
        assert_eq!(action.action, None);
        assert!(!action.busy);
    }

    #[test]
    fn poll_cadence_follows_activity() {
        assert_eq!(poll_interval(true), Duration::from_secs(1));
        assert_eq!(poll_interval(false), Duration::from_secs(4));
        assert_eq!(poll_interval(RuntimeState::Running.is_active()), BUSY_POLL);
        assert_eq!(poll_interval(RuntimeState::Idle.is_active()), IDLE_POLL);
        assert!(RuntimeState::Unknown.is_active());
    }

    const PROMPT_REPLY: &str = r#"{
        "accepted": false,
        "interaction": {
            "kind": "clipboard",
            "token": "9F0C1E7A-0000-4000-8000-000000000001",
            "contentType": "public.utf8-plain-text",
            "sizeBytes": 42,
            "preview": "copied text",
            "futureField": true
        }
    }"#;

    #[test]
    fn a_clipboard_reply_opens_the_sheet_and_the_decision_keeps_the_token() {
        let reply: LaunchReplyDto = serde_json::from_str(PROMPT_REPLY).expect("reply");
        let outcome = interpret_launch_reply("/tmp/Bottles/demo", "pinned:a", reply);
        let LaunchOutcome::Prompt(prompt) = outcome else {
            panic!("expected a clipboard prompt, got {outcome:?}");
        };
        assert_eq!(prompt.token, "9F0C1E7A-0000-4000-8000-000000000001");
        assert_eq!(prompt.content_type, "public.utf8-plain-text");
        assert_eq!(prompt.size_bytes, 42);
        assert_eq!(prompt.preview.as_deref(), Some("copied text"));

        let clear = prompt.params(ClipboardDecision::Clear);
        assert_eq!(clear["interactionToken"], prompt.token.as_str());
        assert_eq!(clear["entryID"], "pinned:a");
        assert_eq!(clear["container"], "/tmp/Bottles/demo");
        assert_eq!(clear["clipboardDecision"], "clear");
        assert!(clear.get("mode").is_none(), "mode defaults to standard");

        let keep = prompt.params(ClipboardDecision::Keep);
        assert_eq!(keep["interactionToken"], prompt.token.as_str());
        assert_eq!(keep["clipboardDecision"], "keep");
    }

    #[test]
    fn clipboard_decision_strings_match_the_helper() {
        assert_eq!(ClipboardDecision::Clear.as_wire(), "clear");
        assert_eq!(ClipboardDecision::Keep.as_wire(), "keep");
    }

    #[test]
    fn an_accepted_launch_needs_no_sheet_and_an_unknown_interaction_is_rejected() {
        let accepted: LaunchReplyDto =
            serde_json::from_str(r#"{"accepted": true, "entryID": "pinned:a"}"#).unwrap();
        assert_eq!(
            interpret_launch_reply("bottle", "pinned:a", accepted),
            LaunchOutcome::Accepted
        );

        let other: LaunchReplyDto = serde_json::from_str(
            r#"{"accepted": false, "interaction": {"kind": "eula", "token": "t"}}"#,
        )
        .unwrap();
        assert_eq!(
            interpret_launch_reply("bottle", "pinned:a", other),
            LaunchOutcome::Rejected
        );
    }
}
