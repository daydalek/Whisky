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
        Container, ContainerList, DescribeResponse, EntryDto, EntryList, LaunchReplyDto,
        RUNTIME_METHODS, RUNTIME_SESSION_METHODS, RuntimeEventBatchDto,
        RuntimeEventPayloadDto, RuntimeSnapshotDto,
    },
};
use crate::runtime::{
    ClipboardDecision, ClipboardPrompt, LaunchOutcome, RuntimeState, RuntimeUpdate,
    interpret_launch_reply, poll_interval,
};

/// Executable product declared in `WhiskyBridge/Package.swift`.
const HELPER_PRODUCT: &str = "whisky-bridge";
const CALL_TIMEOUT: Duration = Duration::from_secs(5);
pub(crate) const BACKOFF_MIN_MS: u64 = 500;
pub(crate) const BACKOFF_MAX_MS: u64 = 8_000;
/// How long the worker blocks when there is nothing to poll and nothing to do.
/// Commands still wake it immediately.
const PARK: Duration = Duration::from_secs(3_600);

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
    /// A read failed. `container` is `None` for catalogue failures.
    LoadFailed {
        container: Option<String>,
        reason: String,
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

    pub(crate) fn launch(&self, container: &str, entry_id: &str) {
        let _ = self.commands.send(Command::Launch {
            container: container.to_owned(),
            entry_id: entry_id.to_owned(),
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
        loop {
            // A live session blocks only until its next poll is due. Anything
            // else parks, and a command still wakes the worker immediately.
            let wait_for = match (&live, foreground) {
                (Some(live), true) => live.due.saturating_duration_since(Instant::now()),
                _ => PARK,
            };
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
                            emit_event(&events, BridgeEvent::RuntimeFailed { reason });
                        }
                        Err(CallFailure::Session(reason)) => reconnect = Some(reason),
                    }
                }
                Some(Command::Launch { container, entry_id }) => {
                    // `mode` is omitted: the helper defaults to "standard",
                    // and a terminal launch needs the `.terminal` bit.
                    let params = json!({ "container": container, "entryID": entry_id });
                    if let Err(failure) = runtime_launch(
                        &mut client,
                        params,
                        &container,
                        &entry_id,
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
            }
            if let Some(reason) = reconnect {
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

fn runtime_launch(
    client: &mut Client,
    params: serde_json::Value,
    container: &str,
    entry_id: &str,
    events: &smol::channel::Sender<BridgeEvent>,
) -> Result<(), CallFailure> {
    let value = client.call("runtime.launch", params).map_err(classify)?;
    let reply: LaunchReplyDto = serde_json::from_value(value)
        .map_err(|error| CallFailure::Remote(format!("invalid launch payload: {error}")))?;
    match interpret_launch_reply(container, entry_id, reply) {
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

/// `--print-library [--bottle <name-or-path>]`: read-only, no window. Prints
/// containers and their entry counts as JSON; failures go to stderr.
pub(crate) fn print_library(bottle: Option<&str>) -> i32 {
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
    if let Some(selector) = bottle {
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
}
