//! Helper discovery, process lifecycle, handshake validation, reconnects, and
//! the small read-request queue the UI drives.
//!
//! All bridge work is blocking, so it runs on one dedicated thread. The UI only
//! receives events over an async channel and sends commands; it never touches
//! the child process. Requests are handled one at a time (one in-flight call),
//! and the last successful `library.entries` result is cached for the current
//! bottle only, so switching bottles always refetches.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{
    self, Receiver as CommandReceiver, RecvTimeoutError, Sender as CommandSender,
};
use std::time::Duration;

use serde::Serialize;
use serde_json::json;
use whisky_bridge::Client;

use super::{
    BridgeStatus,
    dto::{Container, ContainerList, DescribeResponse, EntryDto, EntryList},
};

/// Executable product declared in `WhiskyBridge/Package.swift`.
const HELPER_PRODUCT: &str = "whisky-bridge";
const CALL_TIMEOUT: Duration = Duration::from_secs(5);
pub(crate) const BACKOFF_MIN_MS: u64 = 500;
pub(crate) const BACKOFF_MAX_MS: u64 = 8_000;

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
}

impl Drop for BridgeSupervisor {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Shutdown);
    }
}

fn run(events: smol::channel::Sender<BridgeEvent>, commands: CommandReceiver<Command>) {
    let mut attempt = 0_u32;
    'session: loop {
        emit(&events, BridgeStatus::Locating);
        let helper = match locate_helper() {
            Ok(helper) => helper,
            Err(reason) => {
                if fail_and_wait(&events, &commands, &mut attempt, reason, true) {
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
                if fail_and_wait(&events, &commands, &mut attempt, reason, true) {
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
            if fail_and_wait(&events, &commands, &mut attempt, reason, false) {
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
                if fail_and_wait(&events, &commands, &mut attempt, reason, true) {
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
        emit_event(
            &events,
            BridgeEvent::Containers(containers),
        );
        // One bottle at a time is enough: a request for another container
        // invalidates the cached snapshot, matching "invalidate on switch".
        // `runtime.events` is not polled in M1b: the helper does not construct
        // `RuntimeService`, so there is no cursor that could invalidate reads.
        let mut cache: Option<(String, EntryList)> = None;
        loop {
            match commands.recv() {
                Ok(Command::Shutdown) | Err(_) => {
                    client.close();
                    emit(&events, BridgeStatus::Stopped);
                    return;
                }
                Ok(Command::Retry) => {
                    client.close();
                    attempt = 0;
                    continue 'session;
                }
                Ok(Command::LoadEntries(container)) => {
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
                            client.close();
                            if fail_and_wait(
                                &events,
                                &commands,
                                &mut attempt,
                                reason,
                                true,
                            ) {
                                emit(&events, BridgeStatus::Stopped);
                                return;
                            }
                            continue 'session;
                        }
                    }
                }
            }
        }
    }
}

/// Surface a failure, then wait for the next automatic or manual attempt.
/// Returns true when the worker must stop.
fn fail_and_wait(
    events: &smol::channel::Sender<BridgeEvent>,
    commands: &CommandReceiver<Command>,
    attempt: &mut u32,
    reason: String,
    retryable: bool,
) -> bool {
    emit(
        events,
        BridgeStatus::Failed {
            reason,
            retryable,
        },
    );
    match wait(commands, backoff_delay(*attempt)) {
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

fn wait(commands: &CommandReceiver<Command>, delay: Duration) -> Wake {
    let deadline = std::time::Instant::now() + delay;
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        match commands.recv_timeout(remaining) {
            Ok(Command::Retry) => return Wake::Retry,
            Ok(Command::Shutdown) | Err(RecvTimeoutError::Disconnected) => return Wake::Stop,
            // A read queued for the failed session is dropped; the catalogue
            // event after reconnecting makes the UI issue fresh requests.
            Ok(Command::LoadEntries(_)) => continue,
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
