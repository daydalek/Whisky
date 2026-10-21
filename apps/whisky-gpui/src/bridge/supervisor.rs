//! Helper discovery, process lifecycle, handshake validation, and reconnects.
//!
//! All bridge work is blocking, so it runs on one dedicated thread. The UI only
//! receives `BridgeStatus` values over an async channel and issues `retry`
//! commands; it never touches the child process.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{
    self, Receiver as CommandReceiver, RecvTimeoutError, Sender as CommandSender,
};
use std::time::Duration;

use serde_json::json;
use whisky_bridge::Client;

use super::{BridgeStatus, dto::ContainerList, dto::DescribeResponse};

/// Executable product declared in `WhiskyBridge/Package.swift`.
const HELPER_PRODUCT: &str = "whisky-bridge";
const CALL_TIMEOUT: Duration = Duration::from_secs(5);
pub(crate) const BACKOFF_MIN_MS: u64 = 500;
pub(crate) const BACKOFF_MAX_MS: u64 = 8_000;

#[derive(Debug)]
pub(crate) enum BridgeEvent {
    Status(BridgeStatus),
}

enum Command {
    Retry,
    Shutdown,
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
}

impl Drop for BridgeSupervisor {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Shutdown);
    }
}

fn run(events: smol::channel::Sender<BridgeEvent>, commands: CommandReceiver<Command>) {
    let mut attempt = 0_u32;
    loop {
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
        if let Err(error) = log_containers(&mut client) {
            eprintln!("whisky-bridge: {error}");
        }
        match wait(&commands, None) {
            Wake::Retry => {
                client.close();
                attempt = 0;
            }
            Wake::Timeout | Wake::Stop => {
                client.close();
                emit(&events, BridgeStatus::Stopped);
                return;
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
    match wait(commands, Some(backoff_delay(*attempt))) {
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

fn wait(commands: &CommandReceiver<Command>, timeout: Option<Duration>) -> Wake {
    match timeout {
        Some(delay) => match commands.recv_timeout(delay) {
            Ok(Command::Retry) => Wake::Retry,
            Ok(Command::Shutdown) | Err(RecvTimeoutError::Disconnected) => Wake::Stop,
            Err(RecvTimeoutError::Timeout) => Wake::Timeout,
        },
        None => match commands.recv() {
            Ok(Command::Retry) => Wake::Retry,
            Ok(Command::Shutdown) | Err(_) => Wake::Stop,
        },
    }
}

fn emit(events: &smol::channel::Sender<BridgeEvent>, status: BridgeStatus) {
    let _ = events.send_blocking(BridgeEvent::Status(status));
}

fn log_containers(client: &mut Client) -> Result<(), String> {
    let value = client
        .call("workspace.containers", json!({}))
        .map_err(|error| format!("workspace.containers failed: {error}"))?;
    let containers: ContainerList = serde_json::from_value(value)
        .map_err(|error| format!("invalid container payload: {error}"))?;
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
    Ok(())
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
    if let Err(error) = log_containers(&mut client) {
        eprintln!("whisky-bridge: {error}");
        client.close();
        return 1;
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
