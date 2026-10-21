//! Helper discovery, process lifecycle, handshake validation, reconnects, the
//! small read-request queue the UI drives, and the runtime session.
//!
//! All bridge work is blocking, so it runs on one dedicated thread. The UI only
//! receives events over an async channel and sends commands; it never touches
//! the child process. Requests are handled one at a time (one in-flight call),
//! and the last successful `library.entries` result is cached for the current
//! bottle only, so switching bottles always refetches.
//!
//! The runtime session is a cursor poll, not a push channel: `library.entries`
//! reads and `runtime.*` calls share the same worker, so a `runtime.events`
//! poll can never overlap a `runtime.configure`. A poll is scheduled with
//! `recv_timeout`, which also means any command pre-empts the wait.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{
    self, Receiver as CommandReceiver, RecvTimeoutError, Sender as CommandSender,
};
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::json;
use whisky_bridge::Client;

use super::{
    BridgeStatus,
    dto::{
        ActivityDto, BridgeFailureDto, CandidatesDto, Container, ContainerList, DescribeResponse,
        EntryDto, EntryList, FoldersDto, HiddenReplyDto, JobDto, JobStartDto, KillReplyDto,
        LaunchReplyDto, LibraryPageDto, PreferencesSchemaDto, ProcessDto, ProgramDto,
        RUNTIME_METHODS, RUNTIME_SESSION_METHODS, RuntimeEntryDto, RuntimeEventBatchDto,
        RuntimeEventPayloadDto, RuntimeSnapshotDto, ScanResultDto,
    },
};
use crate::config::{self, ConfigField};
use crate::runtime::{
    CAP_LAUNCH, ClipboardDecision, ClipboardPrompt, LaunchOutcome, RuntimeAction, RuntimeState,
    RuntimeUpdate, interpret_launch_reply, poll_interval, primary_action_for,
};
use crate::scan::{self, JobStatus, PageAccumulator};

/// Executable product declared in `WhiskyBridge/Package.swift`.
const HELPER_PRODUCT: &str = "whisky-bridge";
const CALL_TIMEOUT: Duration = Duration::from_secs(5);
pub(crate) const BACKOFF_MIN_MS: u64 = 500;
pub(crate) const BACKOFF_MAX_MS: u64 = 8_000;
/// How long the worker blocks when there is nothing to poll and nothing to do.
/// Commands still wake it immediately.
const PARK: Duration = Duration::from_secs(3_600);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EntryMutation {
    Rating,
    Hidden,
}

/// Which `programs.*` write a `ProgramFailed` event names, so the UI rolls
/// back exactly the flag that was rejected.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ProgramMutation {
    Pin,
    Block,
}

/// One `folders.*` mutation. Every reply is the whole folder payload, so the UI
/// never has to merge a local guess.
#[derive(Debug, Clone)]
pub(crate) enum FolderEdit {
    AddRoot(String),
    RemoveRoot(String),
    Assign { path: String, assigned: bool },
    Exclude { path: String, excluded: bool },
    Executable { path: String, executable: Option<String> },
}

impl FolderEdit {
    fn call(&self, container: &str) -> (&'static str, serde_json::Value) {
        match self {
            Self::AddRoot(path) => (
                "folders.addRoot",
                json!({"container": container, "path": path}),
            ),
            Self::RemoveRoot(path) => (
                "folders.removeRoot",
                json!({"container": container, "path": path}),
            ),
            Self::Assign { path, assigned } => (
                "folders.assign",
                json!({"container": container, "path": path, "assigned": assigned}),
            ),
            Self::Exclude { path, excluded } => (
                "folders.exclude",
                json!({"container": container, "path": path, "excluded": excluded}),
            ),
            Self::Executable { path, executable } => (
                "folders.executable",
                json!({
                    "container": container,
                    "path": path,
                    "executable": executable.clone().map_or(serde_json::Value::Null, Into::into),
                }),
            ),
        }
    }
}

/// Scan lifecycle as the sheet renders it. `status` is always one of the
/// `BridgeJobStore` strings; `stage` is `scanning` from the helper or `paging`
/// while this frontend walks `library.page`.
#[derive(Debug)]
pub(crate) enum ScanUpdate {
    Started {
        job_id: String,
    },
    Progress {
        status: JobStatus,
        stage: Option<String>,
        loaded: Option<usize>,
        total: Option<u64>,
    },
    Completed {
        entries: Vec<EntryDto>,
    },
    Failed {
        status: JobStatus,
        reason: String,
    },
}

#[derive(Debug)]
pub(crate) enum BridgeEvent {
    Status(BridgeStatus),
    /// The container catalogue, emitted once per connected session.
    Containers(Vec<Container>),
    /// Entries for one container path, in bridge order.
    Entries {
        container: String,
        entries: Vec<EntryDto>,
    },
    /// Per-entry runtime state for the configured container.
    Runtime(RuntimeUpdate),
    /// The helper stopped before launching and needs a clipboard decision.
    ClipboardPrompt(ClipboardPrompt),
    /// Something the runtime refused. Shown on the existing error surface; a
    /// failed poll emits this once per streak and then backs off silently.
    RuntimeFailed {
        reason: String,
    },
    /// `runtime.configure` did not take effect. The bottle is removed from the
    /// configured set so the next Play retries instead of launching against an
    /// unconfigured entry.
    ConfigureFailed {
        container: String,
        reason: String,
    },
    /// A read failed. `container` is `None` for catalogue failures.
    LoadFailed {
        container: Option<String>,
        reason: String,
    },
    /// `.exe` files found under a folder entry, for the in-app picker.
    Candidates {
        candidates: CandidatesDto,
    },
    /// `preferences.read` plus the `preferences.schema` allow-list.
    Preferences {
        values: serde_json::Value,
        schema: PreferencesSchemaDto,
    },
    /// The activity record `entry.rating` returned, not an echo of the request.
    EntryRating {
        container: String,
        entry_id: String,
        activity: ActivityDto,
    },
    /// The `entry.hidden` reply. The record owns the resulting visibility.
    EntryHidden {
        container: String,
        entry_id: String,
        hidden: bool,
    },
    /// A per-entry mutation was rejected; the UI rolls back its optimistic
    /// value and reuses the toast for `reason`.
    EntryFailed {
        mutation: EntryMutation,
        container: String,
        entry_id: String,
        reason: String,
    },
    /// `configuration.schema` plus `configuration.read` for one bottle.
    Configuration {
        container: String,
        capabilities: Vec<String>,
        schema: Vec<ConfigField>,
        values: BTreeMap<String, serde_json::Value>,
    },
    /// One `configuration.set` succeeded; `values` is the helper's readback.
    ConfigurationSaved {
        container: String,
        field: String,
        values: BTreeMap<String, serde_json::Value>,
    },
    /// `field` is `None` when the whole page failed to load.
    ConfigurationFailed {
        container: String,
        field: Option<String>,
        reason: String,
    },
    Folders {
        container: String,
        folders: FoldersDto,
    },
    FoldersFailed {
        container: String,
        reason: String,
    },
    Environment {
        container: String,
        values: BTreeMap<String, String>,
    },
    EnvironmentFailed {
        container: String,
        reason: String,
    },
    /// The `programs.list` payload for one container. Also the reply to a
    /// successful pin/block, so it is always authoritative; `settled` names
    /// the mutation whose optimistic edit it retires.
    Programs {
        container: String,
        programs: Vec<ProgramDto>,
        settled: Option<(ProgramMutation, String)>,
    },
    ProgramsFailed {
        container: String,
        reason: String,
    },
    /// A pin/block write was rejected; the UI rolls its optimistic flag back.
    ProgramFailed {
        mutation: ProgramMutation,
        container: String,
        path: String,
        reason: String,
    },
    /// The `processes.list` snapshot for one container.
    Processes {
        container: String,
        processes: Vec<ProcessDto>,
    },
    ProcessesFailed {
        container: String,
        reason: String,
    },
    /// The `processes.kill` reply. `killed: false` means the helper signalled
    /// nothing and the UI rolls its optimistic removal back.
    ProcessKilled {
        container: String,
        pid: i64,
        killed: bool,
    },
    ProcessKillFailed {
        container: String,
        pid: i64,
        reason: String,
    },
    Scan {
        container: String,
        update: ScanUpdate,
    },
}

enum Command {
    Retry,
    Shutdown,
    LoadEntries(String),
    ConfigureRuntime(String),
    Launch {
        container: String,
        entry_id: String,
        /// Launch this executable instead of the entry's default one; the
        /// program Play path uses it (`RuntimeService.launch`'s `executable`).
        executable: Option<String>,
    },
    /// The prompt is carried as received so the second call echoes exactly the
    /// token the helper issued, through the same code path the tests cover.
    DecideClipboard {
        prompt: ClipboardPrompt,
        decision: ClipboardDecision,
    },
    Cancel {
        container: String,
        entry_id: String,
    },
    Stop {
        container: String,
        entry_id: String,
    },
    SetRating {
        container: String,
        entry_id: String,
        rating: Option<i64>,
    },
    SetHidden {
        container: String,
        entry_id: String,
        hidden: bool,
    },
    LoadPreferences,
    SetPreference {
        key: String,
        value: serde_json::Value,
    },
    LoadConfiguration(String),
    SetConfiguration {
        container: String,
        field: String,
        value: serde_json::Value,
    },
    LoadFolders(String),
    EditFolders {
        container: String,
        edit: FolderEdit,
    },
    /// `folders.candidates` for one folder entry.
    LoadCandidates {
        container: String,
        folder: String,
    },
    LoadEnvironment(String),
    SetEnvironment {
        container: String,
        key: String,
        value: Option<String>,
        /// A renamed key: removed before the new one is written.
        replacing: Option<String>,
    },
    LoadPrograms(String),
    SetProgramPinned {
        container: String,
        path: String,
        name: String,
        pinned: bool,
    },
    SetProgramBlocked {
        container: String,
        path: String,
        blocked: bool,
    },
    LoadProcesses(String),
    KillProcess {
        container: String,
        pid: i64,
    },
    StartScan(String),
    CancelScan,
    /// Window activation: polling pauses while the app is in the background.
    SetActive(bool),
}

enum Wake {
    Retry,
    Timeout,
    Stop,
}

/// Owns the supervisor thread. Dropping it asks the worker to close the helper
/// and exit; it is not joined because a helper call may still be in flight and
/// join would block the UI thread.
pub(crate) struct BridgeSupervisor {
    commands: CommandSender<Command>,
    _thread: Option<std::thread::JoinHandle<()>>,
}

impl BridgeSupervisor {
    pub(crate) fn start() -> (Self, smol::channel::Receiver<BridgeEvent>) {
        let (events, receiver) = smol::channel::unbounded();
        let (commands, command_rx) = mpsc::channel();
        let worker_events = events.clone();
        let thread = std::thread::Builder::new()
            .name("whisky-bridge".into())
            .spawn(move || run(worker_events, command_rx))
            .map_err(|error| {
                let _ = events.send_blocking(BridgeEvent::Status(BridgeStatus::Failed {
                    reason: format!("Cannot start the bridge supervisor thread: {error}"),
                    retryable: false,
                }));
                error
            })
            .ok();
        (
            Self {
                commands,
                _thread: thread,
            },
            receiver,
        )
    }

    /// Ask the worker to discard the current session and connect again now.
    pub(crate) fn retry(&self) {
        let _ = self.commands.send(Command::Retry);
    }

    /// Queue a read-only library request. The worker coalesces nothing: callers
    /// only send this on an explicit bottle switch or retry, never per frame.
    pub(crate) fn load_entries(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadEntries(container.to_owned()));
    }

    /// Point the runtime at one container. The reply is a resync: the UI
    /// replaces its table instead of merging.
    pub(crate) fn configure_runtime(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::ConfigureRuntime(container.to_owned()));
    }

    pub(crate) fn launch(&self, container: &str, entry_id: &str, executable: Option<&str>) {
        let _ = self.commands.send(Command::Launch {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
            executable: executable.map(str::to_owned),
        });
    }

    /// Answer the clipboard prompt. The second call carries the one-use token.
    pub(crate) fn resolve_clipboard(&self, prompt: ClipboardPrompt, decision: ClipboardDecision) {
        let _ = self
            .commands
            .send(Command::DecideClipboard { prompt, decision });
    }

    pub(crate) fn cancel(&self, container: &str, entry_id: &str) {
        let _ = self.commands.send(Command::Cancel {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
        });
    }

    pub(crate) fn stop(&self, container: &str, entry_id: &str) {
        let _ = self.commands.send(Command::Stop {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
        });
    }

    /// `entry.rating` with `null` clearing the rating.
    pub(crate) fn set_rating(&self, container: &str, entry_id: &str, rating: Option<i64>) {
        let _ = self.commands.send(Command::SetRating {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
            rating,
        });
    }

    /// `entry.hidden`; the reply carries the record the UI stores.
    pub(crate) fn set_hidden(&self, container: &str, entry_id: &str, hidden: bool) {
        let _ = self.commands.send(Command::SetHidden {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
            hidden,
        });
    }

    /// Read every preference once per connected session.
    pub(crate) fn load_preferences(&self) {
        let _ = self.commands.send(Command::LoadPreferences);
    }

    /// Write one preference. The UI debounces this; the worker just executes.
    pub(crate) fn set_preference(&self, key: &str, value: serde_json::Value) {
        let _ = self.commands.send(Command::SetPreference {
            key: key.to_owned(),
            value,
        });
    }

    /// `configuration.schema` + `configuration.read` for one bottle.
    pub(crate) fn load_configuration(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadConfiguration(container.to_owned()));
    }

    /// `configuration.set` for one field; the reply is a whole-file readback.
    pub(crate) fn set_configuration(
        &self,
        container: &str,
        field: &str,
        value: serde_json::Value,
    ) {
        let _ = self.commands.send(Command::SetConfiguration {
            container: container.to_owned(),
            field: field.to_owned(),
            value,
        });
    }

    pub(crate) fn load_folders(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadFolders(container.to_owned()));
    }

    pub(crate) fn edit_folders(&self, container: &str, edit: FolderEdit) {
        let _ = self.commands.send(Command::EditFolders {
            container: container.to_owned(),
            edit,
        });
    }

    pub(crate) fn load_candidates(&self, container: &str, folder: &str) {
        let _ = self.commands.send(Command::LoadCandidates {
            container: container.to_owned(),
            folder: folder.to_owned(),
        });
    }

    pub(crate) fn load_environment(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadEnvironment(container.to_owned()));
    }

    /// `environment.set`. `value: None` removes `key`; `replacing` names an old
    /// key that is removed first, because the bridge has no rename call.
    pub(crate) fn set_environment(
        &self,
        container: &str,
        key: &str,
        value: Option<&str>,
        replacing: Option<&str>,
    ) {
        let _ = self.commands.send(Command::SetEnvironment {
            container: container.to_owned(),
            key: key.to_owned(),
            value: value.map(str::to_owned),
            replacing: replacing.map(str::to_owned),
        });
    }

    pub(crate) fn start_scan(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::StartScan(container.to_owned()));
    }

    pub(crate) fn cancel_scan(&self) {
        let _ = self.commands.send(Command::CancelScan);
    }

    /// `programs.list` for one bottle. The pin/block mutations reply with the
    /// same payload, so one event type carries all three.
    pub(crate) fn load_programs(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadPrograms(container.to_owned()));
    }

    /// `programs.pin`; the reply is the refreshed program list.
    pub(crate) fn set_program_pinned(&self, container: &str, path: &str, name: &str, pinned: bool) {
        let _ = self.commands.send(Command::SetProgramPinned {
            container: container.to_owned(),
            path: path.to_owned(),
            name: name.to_owned(),
            pinned,
        });
    }

    /// `programs.block`; the reply is the refreshed program list.
    pub(crate) fn set_program_blocked(&self, container: &str, path: &str, blocked: bool) {
        let _ = self.commands.send(Command::SetProgramBlocked {
            container: container.to_owned(),
            path: path.to_owned(),
            blocked,
        });
    }

    /// `processes.list` for one bottle. The Processes page polls this.
    pub(crate) fn load_processes(&self, container: &str) {
        let _ = self
            .commands
            .send(Command::LoadProcesses(container.to_owned()));
    }

    /// `processes.kill` with the default graceful semantics.
    pub(crate) fn kill_process(&self, container: &str, pid: i64) {
        let _ = self.commands.send(Command::KillProcess {
            container: container.to_owned(),
            pid,
        });
    }

    pub(crate) fn set_active(&self, active: bool) {
        let _ = self.commands.send(Command::SetActive(active));
    }
}

impl Drop for BridgeSupervisor {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Shutdown);
    }
}

fn run(events: smol::channel::Sender<BridgeEvent>, commands: CommandReceiver<Command>) {
    let mut attempt = 0_u32;
    let mut foreground = true;
    'session: loop {
        emit(&events, BridgeStatus::Locating);
        let helper = match locate_helper() {
            Ok(helper) => helper,
            Err(reason) => {
                if fail_and_wait(&events, &commands, &mut attempt, reason, true, &mut foreground) {
                    emit(&events, BridgeStatus::Stopped);
                    return;
                }
                continue;
            }
        };
        emit(&events, BridgeStatus::Starting);
        let mut client = match Client::spawn(&helper, &[], CALL_TIMEOUT) {
            Ok(client) => client,
            Err(error) => {
                let reason = format!("Cannot start the helper at {}: {error}", helper.display());
                if fail_and_wait(&events, &commands, &mut attempt, reason, true, &mut foreground) {
                    emit(&events, BridgeStatus::Stopped);
                    return;
                }
                continue;
            }
        };
        let describe = DescribeResponse::from_capabilities(client.capabilities());
        let missing = describe.missing_required_methods();
        if !missing.is_empty() {
            let reason = format!(
                "The helper does not advertise required method(s): {}",
                missing.join(", ")
            );
            client.close();
            if fail_and_wait(&events, &commands, &mut attempt, reason, false, &mut foreground) {
                emit(&events, BridgeStatus::Stopped);
                return;
            }
            continue;
        }
        // A session without a catalogue cannot serve the UI, so the handshake
        // is only reported as connected after the first read succeeds.
        let containers = match fetch_containers(&mut client) {
            Ok(containers) => containers,
            Err(failure) => {
                let reason = failure.into_message();
                client.close();
                if fail_and_wait(&events, &commands, &mut attempt, reason, true, &mut foreground) {
                    emit(&events, BridgeStatus::Stopped);
                    return;
                }
                continue;
            }
        };
        attempt = 0;
        emit(
            &events,
            BridgeStatus::Connected {
                helper: helper.display().to_string(),
                // The helper exposes no application version yet; the protocol
                // version is the only version in `bridge.describe`.
                version: format!("protocol {}", describe.protocol_version),
                methods: describe.methods.len(),
            },
        );
        log_container_names(&containers);
        emit_event(&events, BridgeEvent::Containers(containers));
        // One bottle at a time is enough: a request for another container
        // invalidates the cached snapshot, matching "invalidate on switch".
        let mut cache: Option<(String, EntryList)> = None;
        // The configured runtime, if any. Dropped on reconfigure; kept across a
        // poll failure so the last known states stay on screen.
        let mut live: Option<LiveRuntime> = None;
        // At most one scan job. Kept as state, not as a blocking loop, so a
        // cancel command still reaches the worker between polls.
        let mut scan: Option<LiveScan> = None;
        loop {
            // A live session blocks only until its next poll is due. Anything
            // else parks, and a command still wakes the worker immediately.
            let now = Instant::now();
            let mut wait_for = PARK;
            if foreground && let Some(live) = &live {
                wait_for = wait_for.min(live.due.saturating_duration_since(now));
            }
            if let Some(scan) = &scan {
                wait_for = wait_for.min(scan.due.saturating_duration_since(now));
            }
            let command = match commands.recv_timeout(wait_for) {
                Ok(command) => Some(command),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => Some(Command::Shutdown),
            };
            let mut reconnect: Option<String> = None;
            match command {
                // The poll timer fired.
                None => {
                    if let Some(session) = live.as_mut() {
                        match poll_runtime(&mut client, session, &events) {
                            Ok(()) => {}
                            // A poll failure is not a session failure: keep the
                            // last known states, back off, and try again.
                            Err(CallFailure::Remote(reason)) => {
                                session.failures = session.failures.saturating_add(1);
                                session.due =
                                    Instant::now() + backoff_delay(session.failures - 1);
                                if session.failures == 1 {
                                    emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                                }
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                    if let Some(active) = scan.as_mut() {
                        let container = active.container.clone();
                        match poll_scan(&mut client, active, &events) {
                            Ok(None) => {}
                            Ok(Some(ScanTerminal::Completed {
                                snapshot_id,
                                total,
                            })) => {
                                match collect_pages(&mut client, &container, &snapshot_id, total, &events)
                                {
                                    Ok(entries) => {
                                        cache = Some((container.clone(), entries.clone()));
                                        let count = entries.len();
                                        emit_event(
                                            &events,
                                            BridgeEvent::Scan {
                                                container: container.clone(),
                                                update: ScanUpdate::Completed { entries },
                                            },
                                        );
                                        eprintln!(
                                            "whisky-bridge: scan of {container} loaded {count} entries"
                                        );
                                        scan = None;
                                    }
                                    Err(CallFailure::Remote(reason)) => {
                                        emit_event(
                                            &events,
                                            BridgeEvent::Scan {
                                                container,
                                                update: ScanUpdate::Failed {
                                                    status: JobStatus::Failed,
                                                    reason,
                                                },
                                            },
                                        );
                                        scan = None;
                                    }
                                    Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                                }
                            }
                            Ok(Some(ScanTerminal::Failed { status, reason })) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Scan {
                                        container,
                                        update: ScanUpdate::Failed { status, reason },
                                    },
                                );
                                scan = None;
                            }
                            Err(CallFailure::Remote(reason)) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Scan {
                                        container,
                                        update: ScanUpdate::Failed {
                                            status: JobStatus::Failed,
                                            reason,
                                        },
                                    },
                                );
                                scan = None;
                            }
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                }
                Some(Command::Shutdown) => {
                    client.close();
                    emit(&events, BridgeStatus::Stopped);
                    return;
                }
                Some(Command::Retry) => {
                    client.close();
                    attempt = 0;
                    continue 'session;
                }
                Some(Command::SetActive(active)) => {
                    foreground = active;
                    // Returning to the foreground polls at once so the first
                    // frame after activation is not stale by up to a cadence.
                    if active && let Some(session) = live.as_mut() {
                        session.due = Instant::now();
                    }
                }
                Some(Command::LoadEntries(container)) => {
                    if let Some((cached, entries)) = &cache
                        && *cached == container
                    {
                        emit_event(
                            &events,
                            BridgeEvent::Entries {
                                container,
                                entries: entries.clone(),
                            },
                        );
                        continue;
                    }
                    cache = None;
                    match fetch_entries(&mut client, &container) {
                        Ok(entries) => {
                            cache = Some((container.clone(), entries.clone()));
                            emit_event(
                                &events,
                                BridgeEvent::Entries { container, entries },
                            );
                        }
                        Err(CallFailure::Remote(reason)) => {
                            emit_event(
                                &events,
                                BridgeEvent::LoadFailed {
                                    container: Some(container),
                                    reason,
                                },
                            );
                        }
                        Err(CallFailure::Session(reason)) => {
                            emit_event(
                                &events,
                                BridgeEvent::LoadFailed {
                                    container: Some(container),
                                    reason: reason.clone(),
                                },
                            );
                            reconnect = Some(reason);
                        }
                    }
                }
                Some(Command::ConfigureRuntime(container)) => {
                    match configure_runtime(&mut client, &container) {
                        Ok(snapshot) => {
                            // Configure is the only wholesale replace: the new
                            // container's entries have nothing in common with
                            // the old bottle's.
                            let session = LiveRuntime::new(&container, &snapshot);
                            emit_event(
                                &events,
                                BridgeEvent::Runtime(RuntimeUpdate::resync(
                                    &container,
                                    snapshot.entries,
                                )),
                            );
                            live = Some(session);
                        }
                        Err(CallFailure::Remote(reason)) => {
                            // Nothing is configured now, so stop polling: the
                            // cards gate their actions on the configured path.
                            live = None;
                            emit_event(
                                &events,
                                BridgeEvent::ConfigureFailed { container, reason },
                            );
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::Launch {
                    container,
                    entry_id,
                    executable,
                }) => {
                    // `mode` is omitted: the helper defaults to "standard",
                    // and a terminal launch needs the `.terminal` bit.
                    let mut params = json!({ "container": container, "entryID": entry_id });
                    if let Some(executable) = &executable {
                        params["executable"] = json!(executable);
                    }
                    if let Err(failure) = runtime_launch(
                        &mut client,
                        params,
                        &container,
                        &entry_id,
                        executable.as_deref(),
                        &events,
                    ) {
                        match failure {
                            CallFailure::Remote(reason) => {
                                emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                            }
                            CallFailure::Session(reason) => reconnect = Some(reason),
                        }
                    }
                    poll_soon(&mut live);
                }
                Some(Command::DecideClipboard { prompt, decision }) => {
                    let params = prompt.params(decision);
                    if let Err(failure) = runtime_launch(
                        &mut client,
                        params,
                        &prompt.container,
                        &prompt.entry_id,
                        prompt.executable.as_deref(),
                        &events,
                    ) {
                        match failure {
                            CallFailure::Remote(reason) => {
                                emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                            }
                            CallFailure::Session(reason) => reconnect = Some(reason),
                        }
                    }
                    poll_soon(&mut live);
                }
                Some(Command::Cancel { container, entry_id }) => {
                    if let Err(failure) =
                        runtime_control(&mut client, "runtime.cancel", &container, &entry_id)
                    {
                        match failure {
                            CallFailure::Remote(reason) => {
                                emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                            }
                            CallFailure::Session(reason) => reconnect = Some(reason),
                        }
                    }
                    poll_soon(&mut live);
                }
                Some(Command::Stop { container, entry_id }) => {
                    if let Err(failure) =
                        runtime_control(&mut client, "runtime.stop", &container, &entry_id)
                    {
                        match failure {
                            CallFailure::Remote(reason) => {
                                emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                            }
                            CallFailure::Session(reason) => reconnect = Some(reason),
                        }
                    }
                    poll_soon(&mut live);
                }
                Some(Command::SetRating {
                    container,
                    entry_id,
                    rating,
                }) => {
                    let params = json!({
                        "container": container,
                        "entryID": entry_id,
                        "rating": rating,
                    });
                    match client.call("entry.rating", params).map_err(classify) {
                        Ok(value) => match serde_json::from_value::<ActivityDto>(value) {
                            Ok(activity) => emit_event(
                                &events,
                                BridgeEvent::EntryRating {
                                    container,
                                    entry_id,
                                    activity,
                                },
                            ),
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::EntryFailed {
                                    mutation: EntryMutation::Rating,
                                    container,
                                    entry_id,
                                    reason: format!("invalid activity payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::EntryFailed {
                                mutation: EntryMutation::Rating,
                                container,
                                entry_id,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SetHidden {
                    container,
                    entry_id,
                    hidden,
                }) => {
                    let params = json!({
                        "container": container,
                        "entryID": entry_id,
                        "hidden": hidden,
                    });
                    match client.call("entry.hidden", params).map_err(classify) {
                        Ok(value) => match serde_json::from_value::<HiddenReplyDto>(value) {
                            Ok(reply) => emit_event(
                                &events,
                                BridgeEvent::EntryHidden {
                                    container,
                                    entry_id: reply.entry_id,
                                    hidden: reply.hidden,
                                },
                            ),
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::EntryFailed {
                                    mutation: EntryMutation::Hidden,
                                    container,
                                    entry_id,
                                    reason: format!("invalid visibility payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::EntryFailed {
                                mutation: EntryMutation::Hidden,
                                container,
                                entry_id,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadPreferences) => {
                    match load_preferences(&mut client) {
                        Ok((values, schema)) => {
                            emit_event(&events, BridgeEvent::Preferences { values, schema });
                        }
                        // Preferences are a view nicety: a failure keeps the
                        // SwiftUI defaults instead of blanking the library.
                        Err(CallFailure::Remote(reason)) => {
                            eprintln!("whisky-bridge: preferences.read failed: {reason}");
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SetPreference { key, value }) => {
                    let params = json!({ "key": key, "value": value });
                    match client.call("preferences.set", params).map_err(classify) {
                        Ok(_) => {}
                        Err(CallFailure::Remote(reason)) => {
                            eprintln!("whisky-bridge: preferences.set failed for {key}: {reason}");
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadConfiguration(container)) => {
                    match load_configuration(&mut client, &container, &describe) {
                        Ok((schema, values)) => emit_event(
                            &events,
                            BridgeEvent::Configuration {
                                container,
                                capabilities: describe.capabilities.clone(),
                                schema,
                                values,
                            },
                        ),
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ConfigurationFailed {
                                container,
                                field: None,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SetConfiguration {
                    container,
                    field,
                    value,
                }) => {
                    let params = config::set_payload(&container, &field, &value);
                    match client.call("configuration.set", params).map_err(classify) {
                        Ok(reply) => match decode_values(&reply) {
                            Ok(values) => emit_event(
                                &events,
                                BridgeEvent::ConfigurationSaved {
                                    container,
                                    field,
                                    values,
                                },
                            ),
                            Err(reason) => emit_event(
                                &events,
                                BridgeEvent::ConfigurationFailed {
                                    container,
                                    field: Some(field),
                                    reason,
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ConfigurationFailed {
                                container,
                                field: Some(field),
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadFolders(container)) => {
                    match load_folders(&mut client, &container) {
                        Ok(folders) => {
                            emit_event(&events, BridgeEvent::Folders { container, folders });
                        }
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::FoldersFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadCandidates { container, folder }) => {
                    match load_candidates(&mut client, &container, &folder) {
                        Ok(candidates) => {
                            emit_event(&events, BridgeEvent::Candidates { candidates });
                        }
                        Err(CallFailure::Remote(reason)) => {
                            emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::EditFolders { container, edit }) => {
                    let (method, params) = edit.call(&container);
                    match client.call(method, params).map_err(classify) {
                        Ok(reply) => match serde_json::from_value::<FoldersDto>(reply) {
                            Ok(folders) => {
                                emit_event(&events, BridgeEvent::Folders { container, folders });
                            }
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::FoldersFailed {
                                    container,
                                    reason: format!("invalid folders payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::FoldersFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadEnvironment(container)) => {
                    match load_environment(&mut client, &container) {
                        Ok(values) => {
                            emit_event(&events, BridgeEvent::Environment { container, values });
                        }
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::EnvironmentFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SetEnvironment {
                    container,
                    key,
                    value,
                    replacing,
                }) => {
                    match write_environment(&mut client, &container, &key, value, replacing) {
                        Ok(values) => {
                            emit_event(&events, BridgeEvent::Environment { container, values });
                        }
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::EnvironmentFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadPrograms(container)) => {
                    match fetch_programs(&mut client, &container) {
                        Ok(programs) => {
                            emit_event(
                                &events,
                                BridgeEvent::Programs {
                                    container,
                                    programs,
                                    settled: None,
                                },
                            );
                        }
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProgramsFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SetProgramPinned {
                    container,
                    path,
                    name,
                    pinned,
                }) => {
                    let params = json!({
                        "container": container,
                        "executable": path,
                        "name": name,
                        "pinned": pinned,
                    });
                    let settled = Some((ProgramMutation::Pin, path.clone()));
                    match client.call("programs.pin", params).map_err(classify) {
                        Ok(reply) => match serde_json::from_value::<Vec<ProgramDto>>(reply) {
                            Ok(programs) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Programs {
                                        container,
                                        programs,
                                        settled,
                                    },
                                );
                            }
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::ProgramFailed {
                                    mutation: ProgramMutation::Pin,
                                    container,
                                    path,
                                    reason: format!("invalid programs payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProgramFailed {
                                mutation: ProgramMutation::Pin,
                                container,
                                path,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::SetProgramBlocked {
                    container,
                    path,
                    blocked,
                }) => {
                    let params = json!({
                        "container": container,
                        "executable": path,
                        "blocked": blocked,
                    });
                    let settled = Some((ProgramMutation::Block, path.clone()));
                    match client.call("programs.block", params).map_err(classify) {
                        Ok(reply) => match serde_json::from_value::<Vec<ProgramDto>>(reply) {
                            Ok(programs) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Programs {
                                        container,
                                        programs,
                                        settled,
                                    },
                                );
                            }
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::ProgramFailed {
                                    mutation: ProgramMutation::Block,
                                    container,
                                    path,
                                    reason: format!("invalid programs payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProgramFailed {
                                mutation: ProgramMutation::Block,
                                container,
                                path,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::LoadProcesses(container)) => {
                    match fetch_processes(&mut client, &container) {
                        Ok(processes) => {
                            emit_event(&events, BridgeEvent::Processes { container, processes });
                        }
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProcessesFailed { container, reason },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::KillProcess { container, pid }) => {
                    let params = json!({ "container": container, "pid": pid });
                    match client.call("processes.kill", params).map_err(classify) {
                        Ok(reply) => match serde_json::from_value::<KillReplyDto>(reply) {
                            Ok(kill) => emit_event(
                                &events,
                                BridgeEvent::ProcessKilled {
                                    container,
                                    pid,
                                    killed: kill.killed,
                                },
                            ),
                            Err(error) => emit_event(
                                &events,
                                BridgeEvent::ProcessKillFailed {
                                    container,
                                    pid,
                                    reason: format!("invalid kill payload: {error}"),
                                },
                            ),
                        },
                        Err(CallFailure::Remote(reason)) => emit_event(
                            &events,
                            BridgeEvent::ProcessKillFailed {
                                container,
                                pid,
                                reason,
                            },
                        ),
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::StartScan(container)) => {
                    if scan.is_some() {
                        // The sheet disables Scan while a job is live; a second
                        // start must not replace the id the UI cancels by.
                        eprintln!("whisky-bridge: a scan is already running");
                    } else {
                        match start_scan(&mut client, &container) {
                            Ok(job_id) => {
                                emit_event(
                                    &events,
                                    BridgeEvent::Scan {
                                        container: container.clone(),
                                        update: ScanUpdate::Started {
                                            job_id: job_id.clone(),
                                        },
                                    },
                                );
                                scan = Some(LiveScan {
                                    container,
                                    job_id,
                                    due: Instant::now() + SCAN_POLL,
                                    last: None,
                                });
                            }
                            Err(CallFailure::Remote(reason)) => emit_event(
                                &events,
                                BridgeEvent::Scan {
                                    container,
                                    update: ScanUpdate::Failed {
                                        status: JobStatus::Failed,
                                        reason,
                                    },
                                },
                            ),
                            Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                        }
                    }
                }
                Some(Command::CancelScan) => {
                    let cancelled = scan.as_ref().map(|active| active.job_id.clone());
                    match cancelled {
                        Some(job_id) => {
                            match client
                                .call("jobs.cancel", json!({"jobID": job_id}))
                                .map_err(classify)
                            {
                                Ok(_) => {
                                    // Poll on the next tick so the sheet sees
                                    // `cancelling` and then `cancelled`.
                                    if let Some(active) = scan.as_mut() {
                                        active.due = Instant::now();
                                    }
                                }
                                Err(CallFailure::Remote(reason)) => {
                                    let container = scan
                                        .as_ref()
                                        .map(|active| active.container.clone())
                                        .unwrap_or_default();
                                    emit_event(
                                        &events,
                                        BridgeEvent::Scan {
                                            container,
                                            update: ScanUpdate::Failed {
                                                status: JobStatus::Failed,
                                                reason,
                                            },
                                        },
                                    );
                                    scan = None;
                                }
                                Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                            }
                        }
                        // Nothing to cancel: the sheet only offers it while a
                        // job is live.
                        None => eprintln!("whisky-bridge: no scan to cancel"),
                    }
                }
            }
            if let Some(reason) = reconnect {
                if let Some(active) = scan.take() {
                    emit_event(
                        &events,
                        BridgeEvent::Scan {
                            container: active.container,
                            update: ScanUpdate::Failed {
                                status: JobStatus::Failed,
                                reason: "The bridge session ended; the scan was abandoned".into(),
                            },
                        },
                    );
                }
                client.close();
                if fail_and_wait(&events, &commands, &mut attempt, reason, true, &mut foreground)
                {
                    emit(&events, BridgeStatus::Stopped);
                    return;
                }
                continue 'session;
            }
        }
    }
}

/// State the worker keeps for one configured container. Only what the poll
/// schedule needs: the UI owns the entry table.
struct LiveRuntime {
    container: String,
    sequence: String,
    due: Instant,
    /// Consecutive poll failures, for the backoff schedule.
    failures: u32,
    /// Last reported query failures, so they are logged once, not per poll.
    query_failures: BTreeMap<String, String>,
}

impl LiveRuntime {
    fn new(container: &str, snapshot: &RuntimeSnapshotDto) -> Self {
        log_query_failures(&snapshot.query_failures);
        let any_active = snapshot
            .entries
            .iter()
            .any(|entry| RuntimeState::from_wire(&entry.state).is_active());
        Self {
            container: container.to_owned(),
            sequence: snapshot.sequence.clone(),
            due: Instant::now() + poll_interval(any_active),
            failures: 0,
            query_failures: snapshot.query_failures.clone(),
        }
    }
}

fn poll_soon(live: &mut Option<LiveRuntime>) {
    if let Some(session) = live.as_mut() {
        session.due = Instant::now();
    }
}

fn log_query_failures(failures: &BTreeMap<String, String>) {
    for (container, failure) in failures {
        eprintln!("whisky-bridge: runtime query failure for {container}: {failure}");
    }
}

fn configure_runtime(
    client: &mut Client,
    container: &str,
) -> Result<RuntimeSnapshotDto, CallFailure> {
    client
        .call("runtime.configure", json!({ "container": container }))
        .map_err(classify)?;
    // The call already replies with a snapshot; read it back explicitly so the
    // UI always renders a `runtime.snapshot` result.
    fetch_snapshot(client)
}

fn fetch_snapshot(client: &mut Client) -> Result<RuntimeSnapshotDto, CallFailure> {
    let value = client.call("runtime.snapshot", json!({})).map_err(classify)?;
    serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid runtime snapshot: {error}")))
}

/// Read the cursor. The reply's `snapshot` is current as of the request, so it
/// wins over anything the buffered events carry; the events are still read for
/// launch results and driver failures.
fn poll_runtime(
    client: &mut Client,
    session: &mut LiveRuntime,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<(), CallFailure> {
    let value = client
        .call("runtime.events", json!({ "after": session.sequence }))
        .map_err(classify)?;
    let batch: RuntimeEventBatchDto = serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid runtime events payload: {error}")))?;
    let RuntimeEventBatchDto {
        sequence,
        resync_required,
        events: batch_events,
        snapshot,
    } = batch;
    // A state event carries a whole snapshot; keep the newest as a fallback for
    // a reply that omits `snapshot`.
    let mut latest_state = None;
    for event in batch_events {
        match event.event {
            RuntimeEventPayloadDto::State { value } => latest_state = Some(value),
            RuntimeEventPayloadDto::LaunchResult {
                entry_id,
                status,
                error,
            } => {
                if status == "launched" || status == "terminal" {
                    eprintln!("whisky-bridge: {status} {entry_id}");
                } else {
                    let reason = error
                        .clone()
                        .unwrap_or_else(|| format!("The launch of {entry_id} failed."));
                    eprintln!("whisky-bridge: {reason}");
                    emit_event(events, BridgeEvent::RuntimeFailed { reason });
                }
            }
            RuntimeEventPayloadDto::Failure { message } => {
                eprintln!("whisky-bridge: runtime failure: {message}");
                emit_event(
                    events,
                    BridgeEvent::RuntimeFailed {
                        reason: message.clone(),
                    },
                );
            }
            RuntimeEventPayloadDto::Unknown => {}
        }
    }
    let Some(snapshot) = snapshot.or(latest_state) else {
        return Err(CallFailure::Remote(
            "runtime.events returned no snapshot".into(),
        ));
    };
    if snapshot.query_failures != session.query_failures {
        log_query_failures(&snapshot.query_failures);
        session.query_failures = snapshot.query_failures;
    }
    if !sequence.is_empty() {
        session.sequence = sequence;
    }
    let any_active = snapshot
        .entries
        .iter()
        .any(|entry| RuntimeState::from_wire(&entry.state).is_active());
    session.due = Instant::now() + poll_interval(any_active);
    session.failures = 0;
    // A gap in the ring means the delta set is incomplete, so the frontend must
    // replace its table rather than merge.
    let update = if resync_required {
        RuntimeUpdate::resync(&session.container, snapshot.entries)
    } else {
        RuntimeUpdate::merge(&session.container, snapshot.entries)
    };
    emit_event(events, BridgeEvent::Runtime(update));
    Ok(())
}

/// Helpers for the bottle surfaces. Each returns a domain value or a classified
/// failure so the caller decides between an event and a reconnect.

fn load_configuration(
    client: &mut Client,
    container: &str,
    describe: &DescribeResponse,
) -> Result<(Vec<ConfigField>, BTreeMap<String, serde_json::Value>), CallFailure> {
    let schema = client
        .call(
            "configuration.schema",
            json!({ "container": container, "platform": describe.platform }),
        )
        .map_err(classify)?;
    let fields =
        config::decode_schema(&schema, &describe.platform).map_err(CallFailure::Remote)?;
    let read = client
        .call("configuration.read", json!({ "container": container }))
        .map_err(classify)?;
    let values = config::resolved_values(&fields, &read);
    Ok((fields, values))
}

fn decode_values(reply: &serde_json::Value) -> Result<BTreeMap<String, serde_json::Value>, String> {
    reply
        .as_object()
        .map(|map| {
            map.iter()
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect()
        })
        .ok_or_else(|| "configuration reply is not an object".to_owned())
}

fn load_folders(client: &mut Client, container: &str) -> Result<FoldersDto, CallFailure> {
    let reply = client
        .call("folders.read", json!({ "container": container }))
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid folders payload: {error}")))
}

fn load_candidates(
    client: &mut Client,
    container: &str,
    folder: &str,
) -> Result<CandidatesDto, CallFailure> {
    let reply = client
        .call(
            "folders.candidates",
            json!({ "container": container, "path": folder }),
        )
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid candidates payload: {error}")))
}

fn load_environment(
    client: &mut Client,
    container: &str,
) -> Result<BTreeMap<String, String>, CallFailure> {
    let reply = client
        .call("environment.read", json!({ "container": container }))
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid environment payload: {error}")))
}

fn write_environment(
    client: &mut Client,
    container: &str,
    key: &str,
    value: Option<String>,
    replacing: Option<String>,
) -> Result<BTreeMap<String, String>, CallFailure> {
    // The bridge has no rename: remove the old key, then write the new one.
    if let Some(previous) = replacing.filter(|previous| previous != key) {
        client
            .call(
                "environment.set",
                config::environment_payload(container, &previous, None),
            )
            .map_err(classify)?;
    }
    let reply = client
        .call(
            "environment.set",
            config::environment_payload(container, key, value.as_deref()),
        )
        .map_err(classify)?;
    serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid environment payload: {error}")))
}

fn start_scan(client: &mut Client, container: &str) -> Result<String, CallFailure> {
    let reply = client
        .call("library.scan", json!({ "container": container }))
        .map_err(classify)?;
    let start: JobStartDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid scan reply: {error}")))?;
    Ok(start.job_id)
}

/// How often `jobs.get` is polled while a scan is queued or running.
const SCAN_POLL: Duration = Duration::from_millis(250);

struct LiveScan {
    container: String,
    job_id: String,
    due: Instant,
    /// Last reported `(status, stage)`, so the sheet is notified on change only.
    last: Option<(JobStatus, Option<String>)>,
}

enum ScanTerminal {
    Completed { snapshot_id: String, total: u64 },
    Failed { status: JobStatus, reason: String },
}

fn poll_scan(
    client: &mut Client,
    scan: &mut LiveScan,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<Option<ScanTerminal>, CallFailure> {
    let reply = client
        .call("jobs.get", json!({ "jobID": scan.job_id }))
        .map_err(classify)?;
    let job: JobDto = serde_json::from_value(reply)
        .map_err(|error| CallFailure::Remote(format!("invalid job payload: {error}")))?;
    let status = JobStatus::from_wire(&job.status).ok_or_else(|| {
        CallFailure::Remote(format!("unknown job status: {}", job.status))
    })?;
    let stage = job.stage().map(str::to_owned);
    if scan.last.as_ref() != Some(&(status, stage.clone())) {
        emit_event(
            events,
            BridgeEvent::Scan {
                container: scan.container.clone(),
                update: ScanUpdate::Progress {
                    status,
                    stage: stage.clone(),
                    loaded: None,
                    total: None,
                },
            },
        );
        scan.last = Some((status, stage));
    }
    scan.due = Instant::now() + SCAN_POLL;
    match status {
        JobStatus::Completed => {
            let result = job
                .result
                .ok_or_else(|| CallFailure::Remote("completed scan has no result".into()))?;
            let result: ScanResultDto = serde_json::from_value(result)
                .map_err(|error| CallFailure::Remote(format!("invalid scan result: {error}")))?;
            Ok(Some(ScanTerminal::Completed {
                snapshot_id: result.snapshot_id,
                total: result.total,
            }))
        }
        JobStatus::Failed | JobStatus::Cancelled => {
            let reason = job
                .error
                .as_ref()
                .map(BridgeFailureDto::reason)
                .unwrap_or_else(|| status.label().to_owned());
            Ok(Some(ScanTerminal::Failed { status, reason }))
        }
        JobStatus::Queued | JobStatus::Running | JobStatus::Cancelling => Ok(None),
    }
}

/// Walk `library.page` from offset 0 until `nextOffset` is null.
fn collect_pages(
    client: &mut Client,
    container: &str,
    snapshot_id: &str,
    total: u64,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<Vec<EntryDto>, CallFailure> {
    let mut accumulator = PageAccumulator::start(total);
    loop {
        let reply = client
            .call(
                "library.page",
                scan::page_payload(snapshot_id, accumulator.offset, config::PAGE_LIMIT),
            )
            .map_err(classify)?;
        let page: LibraryPageDto = serde_json::from_value(reply)
            .map_err(|error| CallFailure::Remote(format!("invalid library page: {error}")))?;
        let next = accumulator.apply(&page).map_err(CallFailure::Remote)?;
        // One event per ten pages keeps the channel quiet on a large catalogue
        // without leaving the sheet frozen.
        if accumulator.loaded() % (config::PAGE_LIMIT as usize * 10) == 0
            || next.is_none()
        {
            emit_event(
                events,
                BridgeEvent::Scan {
                    container: container.to_owned(),
                    update: ScanUpdate::Progress {
                        status: JobStatus::Running,
                        stage: Some("paging".into()),
                        loaded: Some(accumulator.loaded()),
                        total: Some(accumulator.total),
                    },
                },
            );
        }
        if next.is_none() {
            return Ok(accumulator.into_entries());
        }
    }
}

fn runtime_launch(
    client: &mut Client,
    params: serde_json::Value,
    container: &str,
    entry_id: &str,
    executable: Option<&str>,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<(), CallFailure> {
    let value = client.call("runtime.launch", params).map_err(classify)?;
    let reply: LaunchReplyDto = serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid launch payload: {error}")))?;
    match interpret_launch_reply(container, entry_id, executable, reply) {
        LaunchOutcome::Accepted => Ok(()),
        LaunchOutcome::Prompt(prompt) => {
            emit_event(events, BridgeEvent::ClipboardPrompt(prompt));
            Ok(())
        }
        LaunchOutcome::Rejected => Err(CallFailure::Remote(format!(
            "The helper did not accept the launch of {entry_id}."
        ))),
    }
}

fn runtime_control(
    client: &mut Client,
    method: &str,
    container: &str,
    entry_id: &str,
) -> Result<(), CallFailure> {
    let value = client
        .call(method, json!({ "container": container, "entryID": entry_id }))
        .map_err(classify)?;
    let accepted = value
        .get("accepted")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    if !accepted {
        return Err(CallFailure::Remote(format!(
            "{method} was not accepted for {entry_id}"
        )));
    }
    Ok(())
}

/// Surface a failure, then wait for the next automatic or manual attempt.
/// Returns true when the worker must stop.
fn fail_and_wait(
    events: &smol::channel::Sender<BridgeEvent>,
    commands: &CommandReceiver<Command>,
    attempt: &mut u32,
    reason: String,
    retryable: bool,
    foreground: &mut bool,
) -> bool {
    emit(
        events,
        BridgeStatus::Failed {
            reason,
            retryable,
        },
    );
    match wait(commands, backoff_delay(*attempt), foreground) {
        Wake::Stop => true,
        Wake::Retry => {
            *attempt = 0;
            false
        }
        Wake::Timeout => {
            *attempt = attempt.saturating_add(1);
            false
        }
    }
}

fn wait(commands: &CommandReceiver<Command>, delay: Duration, foreground: &mut bool) -> Wake {
    let deadline = Instant::now() + delay;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match commands.recv_timeout(remaining) {
            Ok(Command::Retry) => return Wake::Retry,
            Ok(Command::Shutdown) | Err(RecvTimeoutError::Disconnected) => return Wake::Stop,
            // Activation is the only command that outlives the session.
            Ok(Command::SetActive(active)) => *foreground = active,
            // Reads and runtime intents queued for the failed session are
            // dropped; the catalogue event after reconnecting makes the UI
            // issue fresh requests.
            Ok(_) => {}
            Err(RecvTimeoutError::Timeout) => return Wake::Timeout,
        }
    }
}

fn emit(events: &smol::channel::Sender<BridgeEvent>, status: BridgeStatus) {
    let _ = events.send_blocking(BridgeEvent::Status(status));
}

fn emit_event(events: &smol::channel::Sender<BridgeEvent>, event: BridgeEvent) {
    let _ = events.send_blocking(event);
}

/// A remote error leaves the session usable; anything else ends it.
enum CallFailure {
    Remote(String),
    Session(String),
}

impl CallFailure {
    fn into_message(self) -> String {
        match self {
            Self::Remote(message) | Self::Session(message) => message,
        }
    }
}

fn classify(error: whisky_bridge::Error) -> CallFailure {
    match error {
        whisky_bridge::Error::Remote(error) => {
            CallFailure::Remote(format!("{}: {}", error.code, error.message))
        }
        other => CallFailure::Session(other.to_string()),
    }
}

fn fetch_containers(client: &mut Client) -> Result<ContainerList, CallFailure> {
    let value = client
        .call("workspace.containers", json!({}))
        .map_err(classify)?;
    serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid container payload: {error}")))
}

fn fetch_entries(client: &mut Client, container: &str) -> Result<EntryList, CallFailure> {
    let value = client
        .call("library.entries", json!({ "container": container }))
        .map_err(classify)?;
    serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid library payload: {error}")))
}

fn fetch_programs(client: &mut Client, container: &str) -> Result<Vec<ProgramDto>, CallFailure> {
    let value = client
        .call("programs.list", json!({ "container": container }))
        .map_err(classify)?;
    serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid programs payload: {error}")))
}

fn fetch_processes(client: &mut Client, container: &str) -> Result<Vec<ProcessDto>, CallFailure> {
    let value = client
        .call("processes.list", json!({ "container": container }))
        .map_err(classify)?;
    serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid processes payload: {error}")))
}

/// Read the schema and the stored values in one worker slot. `preferences.read`
/// returns every key the helper knows, so the request carries no filter; the
/// `keys` array is still sent for forward compatibility.
fn load_preferences(
    client: &mut Client,
) -> Result<(serde_json::Value, PreferencesSchemaDto), CallFailure> {
    let schema = client
        .call("preferences.schema", json!({}))
        .map_err(classify)?;
    let schema: PreferencesSchemaDto = serde_json::from_value(schema)
        .map_err(|error| CallFailure::Remote(format!("invalid preferences schema: {error}")))?;
    let keys = schema.keys().map(str::to_owned).collect::<Vec<_>>();
    let values = client
        .call("preferences.read", json!({ "keys": keys }))
        .map_err(classify)?;
    if !values.is_object() {
        return Err(CallFailure::Remote(
            "preferences.read did not return an object".into(),
        ));
    }
    Ok((values, schema))
}

fn log_container_names(containers: &[Container]) {
    let names = containers
        .iter()
        .map(|container| container.name.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    eprintln!(
        "whisky-bridge: {} container(s): {}",
        containers.len(),
        if names.is_empty() { "(none)" } else { &names }
    );
}

/// Capped exponential backoff: 500 ms, 1 s, 2 s, 4 s, then 8 s.
pub(crate) fn backoff_delay(attempt: u32) -> Duration {
    let exponent = attempt.min(4);
    let millis = BACKOFF_MIN_MS.saturating_mul(1_u64 << exponent);
    Duration::from_millis(millis.min(BACKOFF_MAX_MS))
}

/// Resolve the helper in the documented order. Every candidate is checked with
/// `is_file`; no failure path panics.
pub(crate) fn locate_helper() -> Result<PathBuf, String> {
    if let Some(raw) = std::env::var_os("WHISKY_BRIDGE_HELPER") {
        let path = PathBuf::from(raw);
        if !path.is_absolute() {
            return Err(format!(
                "WHISKY_BRIDGE_HELPER must be an absolute path: {}",
                path.display()
            ));
        }
        if path.is_file() {
            return Ok(path);
        }
        return Err(format!(
            "WHISKY_BRIDGE_HELPER does not name a file: {}",
            path.display()
        ));
    }
    if let Ok(executable) = std::env::current_exe()
        && let Some(directory) = executable.parent()
    {
        let candidates = [
            directory.join(HELPER_PRODUCT),
            directory.join(format!("Contents/Resources/{HELPER_PRODUCT}")),
            directory
                .parent()
                .map(|contents| contents.join(format!("Resources/{HELPER_PRODUCT}")))
                .unwrap_or_default(),
        ];
        for candidate in candidates {
            if candidate.is_absolute() && candidate.is_file() {
                return Ok(candidate);
            }
        }
    }
    if let Some(root) = repository_root() {
        for profile in ["release", "debug"] {
            let candidate = root
                .join("WhiskyBridge/.build")
                .join(profile)
                .join(HELPER_PRODUCT);
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
    }
    Err(format!(
        "whisky-bridge helper not found. Set WHISKY_BRIDGE_HELPER to an absolute path, \
         or build it with `swift build --package-path WhiskyBridge -c release`."
    ))
}

/// Walk up from this crate until the directory that contains the Swift package.
fn repository_root() -> Option<PathBuf> {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .find(|directory| directory.join("WhiskyBridge/Package.swift").is_file())
        .map(Path::to_path_buf)
}

/// `--print-bridge-status`: connect, validate, print the describe payload, and
/// report success through the process exit code.
pub(crate) fn print_status() -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &[], CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_required_methods();
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: handshake is missing required method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    match serde_json::to_string_pretty(&describe) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the describe payload: {error}");
            client.close();
            return 1;
        }
    }
    match fetch_containers(&mut client) {
        Ok(containers) => log_container_names(&containers),
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    }
    let _ = client.shutdown(false);
    0
}

/// `--print-runtime`: connect, check the runtime allow-list, read one
/// `runtime.snapshot`, and print it as JSON. Safe with no game running: the
/// payload only reports the configured entries and the event cursor.
pub(crate) fn print_runtime() -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &[], CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(RUNTIME_METHODS);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise runtime method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let payload = match client.call("runtime.snapshot", json!({})) {
        Ok(payload) => payload,
        Err(error) => {
            eprintln!(
                "whisky-bridge: runtime.snapshot failed: {}",
                classify(error).into_message()
            );
            client.close();
            return 1;
        }
    };
    let snapshot: RuntimeSnapshotDto = match serde_json::from_value(payload.clone()) {
        Ok(snapshot) => snapshot,
        Err(error) => {
            eprintln!("whisky-bridge: invalid runtime snapshot: {error}");
            client.close();
            return 1;
        }
    };
    eprintln!(
        "whisky-bridge: runtime sequence {}, {} entry(ies), {} query failure(s)",
        snapshot.sequence,
        snapshot.entries.len(),
        snapshot.query_failures.len()
    );
    for entry in &snapshot.entries {
        eprintln!(
            "whisky-bridge:   {} state={} capabilities={}",
            entry.id, entry.state, entry.capabilities
        );
    }
    for (container, failure) in &snapshot.query_failures {
        eprintln!("whisky-bridge:   {container}: {failure}");
    }
    match serde_json::to_string_pretty(&payload) {
        Ok(rendered) => println!("{rendered}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the runtime snapshot: {error}");
            client.close();
            return 1;
        }
    }
    let _ = client.shutdown(false);
    0
}

/// How often `--runtime-watch` reads the cursor. Deliberately faster than the
/// app's cadence so a short observation window shows something.
const WATCH_INTERVAL: Duration = Duration::from_millis(500);

/// `--runtime-watch --seconds N [--bottle <name-or-path>]`: configure one
/// bottle, poll `runtime.events`, and print each entry's state when it changes.
///
/// Observation only. Nothing here calls `runtime.launch`, so no game and no
/// Steam client can start; the command exists to prove the cursor moves and the
/// snapshot shape matches what the UI stores.
pub(crate) fn watch_runtime(bottle: Option<&str>, seconds: u64) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &[], CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(RUNTIME_SESSION_METHODS);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise runtime method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    eprintln!(
        "whisky-bridge: watching {} for {seconds}s (observation only; no game is launched)",
        container.name
    );
    let snapshot = match configure_runtime(&mut client, &container.path) {
        Ok(snapshot) => snapshot,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let mut previous = BTreeMap::new();
    let mut changes = print_watch_delta(&snapshot, &mut previous);
    let mut cursor = snapshot.sequence.clone();
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let mut polls = 0_u32;
    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        std::thread::sleep(remaining.min(WATCH_INTERVAL));
        if Instant::now() >= deadline {
            break;
        }
        match watch_poll(&mut client, &mut cursor) {
            Ok((snapshot, resync)) => {
                if resync {
                    eprintln!("whisky-bridge: resync required; state replaced");
                }
                changes += print_watch_delta(&snapshot, &mut previous);
            }
            Err(failure) => {
                // A failed poll must not end the watch; the next tick retries.
                eprintln!("whisky-bridge: poll failed: {}", failure.into_message());
            }
        }
        polls += 1;
    }
    println!(
        "runtime: {polls} poll(s), {changes} state change(s), sequence {cursor}"
    );
    let _ = client.shutdown(false);
    0
}

fn pick_container<'a>(
    containers: &'a [Container],
    selector: Option<&str>,
) -> Result<&'a Container, String> {
    match selector {
        Some(selector) => containers
            .iter()
            .find(|container| container.name == selector || container.path == selector)
            .ok_or_else(|| format!("no container named or located at {selector}")),
        None => containers
            .iter()
            .find(|container| container.available)
            .ok_or_else(|| "no available container to watch".to_owned()),
    }
}

fn watch_poll(
    client: &mut Client,
    cursor: &mut String,
) -> Result<(RuntimeSnapshotDto, bool), CallFailure> {
    let value = client
        .call("runtime.events", json!({ "after": cursor }))
        .map_err(classify)?;
    let batch: RuntimeEventBatchDto = serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid runtime events payload: {error}")))?;
    if !batch.sequence.is_empty() {
        *cursor = batch.sequence;
    }
    let snapshot = batch.snapshot.ok_or_else(|| {
        CallFailure::Remote("runtime.events returned no snapshot".to_owned())
    })?;
    Ok((snapshot, batch.resync_required))
}

/// Print only what changed since the previous snapshot, one line per entry.
fn print_watch_delta(
    snapshot: &RuntimeSnapshotDto,
    previous: &mut BTreeMap<String, String>,
) -> u32 {
    let mut changes = 0;
    let mut current = BTreeMap::new();
    for entry in &snapshot.entries {
        current.insert(entry.id.clone(), entry.state.clone());
        if previous.get(&entry.id) != Some(&entry.state) {
            println!("runtime: entry {} state={}", entry.id, entry.state);
            changes += 1;
        }
    }
    for id in previous.keys() {
        if !current.contains_key(id) {
            println!("runtime: entry {id} removed");
            changes += 1;
        }
    }
    println!(
        "runtime: sequence {} · {} entry(ies)",
        snapshot.sequence,
        snapshot.entries.len()
    );
    for (container, failure) in &snapshot.query_failures {
        println!("runtime: query failure {container}: {failure}");
    }
    *previous = current;
    changes
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LibrarySummary {
    containers: Vec<BottleSummary>,
    /// Present with `--all`: the merged view the Library page renders.
    #[serde(skip_serializing_if = "Option::is_none")]
    all: Option<AllBottlesSummary>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AllBottlesSummary {
    /// Every entry across every bottle, before display de-duplication.
    total: usize,
    per_bottle: Vec<PerBottleCount>,
}

#[derive(Serialize)]
struct PerBottleCount {
    name: String,
    entries: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BottleSummary {
    path: String,
    name: String,
    available: bool,
    entry_count: usize,
    /// First five entry names, so a headless run shows what the grid will show.
    sample: Vec<String>,
}

/// `--print-library [--bottle <name-or-path>] [--all]`: read-only, no window.
/// Prints containers and their entry counts as JSON; failures go to stderr.
/// `all` merges every bottle and adds the total plus per-bottle counts.
pub(crate) fn print_library(bottle: Option<&str>, all: bool) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &[], CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_required_methods();
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: handshake is missing required method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let mut containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    if let Some(selector) = bottle.filter(|_| !all) {
        let matched: Vec<_> = containers
            .into_iter()
            .filter(|container| container.name == selector || container.path == selector)
            .collect();
        if matched.is_empty() {
            eprintln!("whisky-bridge: no container named or located at {selector}");
            client.close();
            return 1;
        }
        containers = matched;
    }
    let mut summaries = Vec::with_capacity(containers.len());
    for container in containers {
        let entries = if container.available {
            match fetch_entries(&mut client, &container.path) {
                Ok(entries) => entries,
                Err(failure) => {
                    eprintln!(
                        "whisky-bridge: library.entries failed for {}: {}",
                        container.name,
                        failure.into_message()
                    );
                    client.close();
                    return 1;
                }
            }
        } else {
            Vec::new()
        };
        summaries.push(BottleSummary {
            path: container.path,
            name: container.name,
            available: container.available,
            entry_count: entries.len(),
            sample: entries
                .iter()
                .take(5)
                .map(|entry| entry.name.clone())
                .collect(),
        });
    }
    let summary = LibrarySummary {
        all: all.then(|| AllBottlesSummary {
            total: summaries.iter().map(|bottle| bottle.entry_count).sum(),
            per_bottle: summaries
                .iter()
                .map(|bottle| PerBottleCount {
                    name: bottle.name.clone(),
                    entries: bottle.entry_count,
                })
                .collect(),
        }),
        containers: summaries,
    };
    match serde_json::to_string_pretty(&summary) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the library summary: {error}");
            client.close();
            return 1;
        }
    }
    let _ = client.shutdown(false);
    0
}

/// `--print-config [--bottle <name-or-path>]`: read the schema and the stored
/// values, then print the field count, the kind histogram and three samples as
/// JSON. Read-only: it never calls `configuration.set` or a scan.
pub(crate) fn print_config(bottle: Option<&str>) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &[], CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(&["configuration.schema", "configuration.read"]);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise configuration method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    let (fields, values) = match load_configuration(&mut client, &container.path, &describe) {
        Ok(configuration) => configuration,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let sections: Vec<serde_json::Value> = config::group_sections(&fields)
        .into_iter()
        .map(|section| {
            json!({
                "id": section.spec.id,
                "title": section.spec.title,
                "fields": section.fields.len(),
            })
        })
        .collect();
    let samples: Vec<serde_json::Value> = fields
        .iter()
        .take(3)
        .map(|field| {
            json!({
                "id": field.id,
                "title": field.title,
                "titleKey": field.title_key,
                "kind": field.kind.name(),
                "default": field.default,
                "value": values.get(&field.id).cloned().unwrap_or(serde_json::Value::Null),
                "requires": field.requires,
            })
        })
        .collect();
    let report = json!({
        "bottle": container.name,
        "container": container.path,
        "platform": describe.platform,
        "fieldCount": fields.len(),
        "kinds": config::kind_histogram(&fields),
        "sections": sections,
        "disabledFields": fields
            .iter()
            .filter(|field| !field.enabled(&describe.capabilities))
            .map(|field| field.id.clone())
            .collect::<Vec<_>>(),
        "samples": samples,
    });
    match serde_json::to_string_pretty(&report) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the configuration report: {error}");
            client.close();
            return 1;
        }
    }
    eprintln!(
        "whisky-bridge: {} field(s), {} section(s)",
        fields.len(),
        config::group_sections(&fields).len()
    );
    let _ = client.shutdown(false);
    0
}

/// `--print-folders [--bottle <name-or-path>]`: roots with their assignment,
/// exclusion and executable, plus every list the helper stores. Read-only.
pub(crate) fn print_folders(bottle: Option<&str>) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &[], CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(&["folders.read"]);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise folder method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    let folders = match load_folders(&mut client, &container.path) {
        Ok(folders) => folders,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let roots: Vec<serde_json::Value> = folders
        .roots
        .iter()
        .map(|root| {
            json!({
                "path": root,
                "assigned": folders.is_assigned(root),
                "excluded": folders.is_excluded(root),
                "executable": folders.executable_for(root),
            })
        })
        .collect();
    let report = json!({
        "bottle": container.name,
        "container": container.path,
        "automaticMetadata": folders.automatic_metadata,
        "rootCount": folders.roots.len(),
        "roots": roots,
        "assignedFolders": folders.assigned_folders,
        "excludedFolders": folders.excluded_folders,
        "executables": folders.executables,
        "knownFolderCount": folders.known_folders.len(),
    });
    match serde_json::to_string_pretty(&report) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the folders report: {error}");
            client.close();
            return 1;
        }
    }
    eprintln!(
        "whisky-bridge: {} root(s), {} assigned, {} excluded",
        folders.roots.len(),
        folders.assigned_folders.len(),
        folders.excluded_folders.len()
    );
    let _ = client.shutdown(false);
    0
}

/// `--print-programs [--bottle <name-or-path>]`: the bottle's installed
/// programs with their pin/block state, as counts plus a five-row sample.
/// Read-only: it never calls `programs.pin` or `programs.block`.
pub(crate) fn print_programs(bottle: Option<&str>) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &[], CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(&["programs.list"]);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise program method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    let programs = match fetch_programs(&mut client, &container.path) {
        Ok(programs) => programs,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let sample: Vec<serde_json::Value> = programs
        .iter()
        .take(5)
        .map(|program| {
            json!({
                "name": program.name,
                "path": program.path,
                "pinned": program.pinned,
                "blocked": program.blocked,
                "available": program.available,
            })
        })
        .collect();
    let report = json!({
        "bottle": container.name,
        "container": container.path,
        "programCount": programs.len(),
        "pinnedCount": programs.iter().filter(|program| program.pinned).count(),
        "blockedCount": programs.iter().filter(|program| program.blocked).count(),
        "sample": sample,
    });
    match serde_json::to_string_pretty(&report) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the programs report: {error}");
            client.close();
            return 1;
        }
    }
    eprintln!(
        "whisky-bridge: {} program(s), {} pinned, {} blocked",
        programs.len(),
        programs.iter().filter(|program| program.pinned).count(),
        programs.iter().filter(|program| program.blocked).count()
    );
    let _ = client.shutdown(false);
    0
}

/// A PID that cannot name a real Wine process: the kill probe must never
/// signal anything, so it picks `Int32::MAX` and only reads the reply.
const BOGUS_PID: i64 = 2_147_483_647;

/// `--print-processes [--bottle <name-or-path>]`: one `processes.list`
/// snapshot plus a `processes.kill` probe against [`BOGUS_PID`]. Observation
/// only: no game is launched and nothing real is ever signalled. An empty
/// list is a legitimate answer and still exits 0.
pub(crate) fn print_processes(bottle: Option<&str>) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &[], CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(&["processes.list", "processes.kill"]);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise process method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    let processes = match fetch_processes(&mut client, &container.path) {
        Ok(processes) => processes,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let sample: Vec<serde_json::Value> = processes
        .iter()
        .take(5)
        .map(|process| {
            json!({
                "pid": process.pid,
                "name": process.name,
                "memory": process.memory,
                "kind": process.kind,
                "source": process.source,
                "startedAt": process.started_at,
                "macosPid": process.macos_pid,
            })
        })
        .collect();
    // The kill probe: a PID no process can hold. `killed: false` is the only
    // honest answer and proves the reply path without signalling anything.
    let probe = match client.call(
        "processes.kill",
        json!({ "container": container.path, "pid": BOGUS_PID }),
    ) {
        Ok(reply) => serde_json::from_value::<KillReplyDto>(reply)
            .map(|kill| json!({ "pid": BOGUS_PID, "killed": kill.killed }))
            .unwrap_or_else(|error| json!({ "pid": BOGUS_PID, "error": error.to_string() })),
        Err(error) => json!({ "pid": BOGUS_PID, "error": classify(error).into_message() }),
    };
    let report = json!({
        "bottle": container.name,
        "container": container.path,
        "processCount": processes.len(),
        "sample": sample,
        "killProbe": probe,
    });
    match serde_json::to_string_pretty(&report) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the processes report: {error}");
            client.close();
            return 1;
        }
    }
    eprintln!(
        "whisky-bridge: {} process(es); kill probe on bogus pid {}",
        processes.len(),
        BOGUS_PID
    );
    let _ = client.shutdown(false);
    0
}

/// Capability bits of `LibraryRuntimeCapabilities` (`LibraryRuntime.swift`),
/// decoded so the report shows what the button gate will actually see.
fn decode_capabilities(bits: i64) -> Vec<&'static str> {
    const BITS: [(i64, &str); 4] = [
        (1 << 0, "launch"),
        (1 << 1, "cancelLaunch"),
        (1 << 2, "stop"),
        (1 << 3, "terminal"),
    ];
    BITS.iter()
        .filter(|(bit, _)| bits & bit != 0)
        .map(|(_, name)| *name)
        .collect()
}

/// `--diagnose-launch --bottle <name-or-path> [--entry <substring>]`:
/// observation only. Configures one bottle and reports, per matched entry,
/// the id the UI would send as `entryID`, the id `runtime.snapshot` carries,
/// the derived `PrimaryAction`, and both helper-side gates (`configured` and
/// the `.launch` capability). Nothing here calls `runtime.launch`, so no game
/// and no Steam client can start.
pub(crate) fn diagnose_launch(bottle: Option<&str>, entry: Option<&str>) -> i32 {
    let helper = match locate_helper() {
        Ok(helper) => helper,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            return 1;
        }
    };
    eprintln!("whisky-bridge: helper {}", helper.display());
    let mut client = match Client::spawn(&helper, &[], CALL_TIMEOUT) {
        Ok(client) => client,
        Err(error) => {
            eprintln!("whisky-bridge: handshake failed: {error}");
            return 1;
        }
    };
    let describe = DescribeResponse::from_capabilities(client.capabilities());
    let missing = describe.missing_methods(RUNTIME_SESSION_METHODS);
    if !missing.is_empty() {
        eprintln!(
            "whisky-bridge: helper does not advertise runtime method(s): {}",
            missing.join(", ")
        );
        client.close();
        return 1;
    }
    let containers = match fetch_containers(&mut client) {
        Ok(containers) => containers,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let container = match pick_container(&containers, bottle) {
        Ok(container) => container,
        Err(reason) => {
            eprintln!("whisky-bridge: {reason}");
            client.close();
            return 1;
        }
    };
    // The UI's `game.id` is `EntryRecord.id` from `library.entries`; the
    // runtime table and the helper's `configured` gate are keyed by the same
    // `LibraryEntry.id`. Both reads are shown so a divergence is visible.
    let library = match fetch_entries(&mut client, &container.path) {
        Ok(entries) => entries,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    eprintln!(
        "whisky-bridge: configuring {} (observation only; no game is launched)",
        container.name
    );
    let snapshot = match configure_runtime(&mut client, &container.path) {
        Ok(snapshot) => snapshot,
        Err(failure) => {
            eprintln!("whisky-bridge: {}", failure.into_message());
            client.close();
            return 1;
        }
    };
    let by_id: BTreeMap<&str, &RuntimeEntryDto> = snapshot
        .entries
        .iter()
        .map(|entry| (entry.id.as_str(), entry))
        .collect();
    let needle = entry.map(str::to_lowercase);
    let mut reports = Vec::new();
    for record in &library {
        let matches = needle.as_ref().is_none_or(|needle| {
            record.name.to_lowercase().contains(needle.as_str())
                || record.id.to_lowercase().contains(needle.as_str())
        });
        if !matches {
            continue;
        }
        // The UI sends this id as `entryID`; the helper resolves the entry by
        // scanning `workspace.entries` and matching `$0.id == entryID`.
        let ui_entry_id = record.id.as_str();
        let runtime = by_id.get(ui_entry_id).copied();
        let state = runtime.map(|entry| entry.state.clone());
        let capabilities = runtime.map(|entry| entry.capabilities).unwrap_or(0);
        let has_launch = capabilities & CAP_LAUNCH != 0;
        // Mirrors `WhiskyApp::primary_action`: a runtime table row wins, and
        // an entry the helper never listed falls back to the optimistic Play.
        let action = match runtime {
            Some(entry) => {
                let state = RuntimeState::from_wire(&entry.state);
                let action = primary_action_for(state, entry.capabilities);
                json!({
                    "label": action.label,
                    "action": action.action.map(|action| match action {
                        RuntimeAction::Launch => "launch",
                        RuntimeAction::Cancel => "cancel",
                        RuntimeAction::Stop => "stop",
                    }),
                    "enabled": action.enabled,
                    "busy": action.busy,
                    "derivedFrom": "runtimeState",
                })
            }
            None => json!({
                "label": "Play",
                "action": "launch",
                "enabled": true,
                "busy": false,
                "derivedFrom": "optimistic",
            }),
        };
        reports.push(json!({
            "name": record.name,
            "uiEntryID": ui_entry_id,
            "runtimeEntryID": runtime.map(|entry| entry.id.as_str()),
            "idMatches": runtime.is_some(),
            "state": state,
            "capabilities": capabilities,
            "capabilitiesDecoded": decode_capabilities(capabilities),
            "configuredGate": runtime.is_some(),
            "hasLaunchCapability": has_launch,
            "primaryAction": action,
            "executable": record.executable,
            "needsExecutable": record.needs_executable,
        }));
    }
    let report = json!({
        "bottle": container.name,
        "container": container.path,
        "libraryTotal": library.len(),
        "snapshotTotal": snapshot.entries.len(),
        "sequence": snapshot.sequence,
        "queryFailures": snapshot.query_failures,
        "matched": reports,
    });
    match serde_json::to_string_pretty(&report) {
        Ok(payload) => println!("{payload}"),
        Err(error) => {
            eprintln!("whisky-bridge: cannot encode the launch report: {error}");
            client.close();
            return 1;
        }
    }
    eprintln!(
        "whisky-bridge: {} library entr(ies), {} runtime entr(ies), {} matched",
        library.len(),
        snapshot.entries.len(),
        reports.len()
    );
    let _ = client.shutdown(false);
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_grows_and_stays_bounded() {
        let schedule = (0..12).map(backoff_delay).collect::<Vec<_>>();
        assert!(schedule[0] >= Duration::from_millis(250));
        assert!(schedule.iter().all(|delay| *delay <= Duration::from_millis(8_000)));
        assert!(schedule.windows(2).all(|pair| pair[0] <= pair[1]));
        assert_eq!(schedule.last(), Some(&Duration::from_millis(8_000)));
    }

    /// `configuration.read` and the `configuration.set` readback reply with the
    /// whole file's values object. `decode_values` is the seam both the
    /// saved-path merge and the rejection rollback read through, so the shape
    /// is pinned here: a flat field→value map, and nothing else.
    #[test]
    fn configuration_readback_decodes_into_the_value_map() {
        let reply = json!({
            "windowsVersion": "win11",
            "avxEnabled": true,
            "customResolutionWidth": 2560,
            "pinnedDeviceName": ""
        });
        let values = decode_values(&reply).expect("values");
        assert_eq!(values.len(), 4);
        assert_eq!(values["windowsVersion"], json!("win11"));
        assert_eq!(values["avxEnabled"], json!(true));
        assert_eq!(values["customResolutionWidth"], json!(2560));
        assert_eq!(values["pinnedDeviceName"], json!(""));
        // A non-object reply is a protocol error, never an empty map: an
        // empty map would silently roll every field back to its default.
        let error = decode_values(&json!([1, 2])).unwrap_err();
        assert!(error.contains("not an object"), "{error}");
    }
}
