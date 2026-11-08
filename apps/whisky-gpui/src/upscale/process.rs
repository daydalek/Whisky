//! Bounded execution of the external inference helper.
//!
//! Shared by the Linux ncnn passes and the CoreML realcugan helper: one
//! spawn, a 120-second ceiling by default, cancellation that kills and
//! reaps only the child it started, and a bounded stderr tail drained on a
//! separate thread so a chatty helper cannot deadlock on a full pipe.

use std::io::Read;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, sync_channel};
use std::time::{Duration, Instant};

/// Kept tail of helper diagnostics reported on failure.
const STDERR_LIMIT: usize = 16 * 1024;
/// Poll interval while the helper runs.
const POLL: Duration = Duration::from_millis(40);

/// Default ceiling for one helper invocation.
pub(super) const HELPER_TIMEOUT: Duration = Duration::from_secs(120);

/// Owns the spawned helper: any exit path that has not already reaped it —
/// a `?` early return, panic unwinding, cancellation, timeout — kills and
/// waits the child. Only this process's child is ever signalled.
struct ChildGuard {
    child: Option<Child>,
}

impl ChildGuard {
    fn new(child: Child) -> Self {
        Self { child: Some(child) }
    }

    fn child(&mut self) -> &mut Child {
        self.child.as_mut().expect("owned child")
    }

    /// The child already exited and was reaped by `try_wait`, or was just
    /// killed and reaped by the caller — `Drop` becomes a no-op.
    fn finish(&mut self) {
        self.child = None;
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// Spawns `command` with a null stdin/stdout and a drained stderr; returns
/// `Some(())` only when the process exits 0 and `expected_output` is a real
/// file. Cancellation, deadline or a wait error kills and reaps the child.
pub(super) fn run_helper(
    mut command: Command,
    expected_output: &Path,
    timeout: Duration,
    cancel: &AtomicBool,
) -> Option<()> {
    if cancel.load(Ordering::Relaxed) {
        return None;
    }
    let child = command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| eprintln!("cover upscaler: could not start helper: {error}"))
        .ok()?;
    monitor_child(child, expected_output, timeout, cancel)
}

/// Owns `child` from the moment it is spawned: the guard is constructed
/// first, so every exit path — `?`, panic, cancel, timeout — still kills and
/// reaps it. Tests drive the same monitor directly on their own child.
fn monitor_child(
    child: Child,
    expected_output: &Path,
    timeout: Duration,
    cancel: &AtomicBool,
) -> Option<()> {
    let mut child = ChildGuard::new(child);
    let diagnostics = drain_stderr(child.child().stderr.take()?);
    let deadline = Instant::now() + timeout;
    loop {
        match child.child().try_wait() {
            Ok(Some(status)) => {
                child.finish();
                let detail = receive_diagnostics(&diagnostics);
                if !status.success() || !expected_output.is_file() {
                    log_failure(format!("helper exited with {status}; {detail}"));
                    return None;
                }
                return Some(());
            }
            Ok(None) => {
                if cancel.load(Ordering::Relaxed) || Instant::now() >= deadline {
                    kill_wait(child.child());
                    child.finish();
                    let detail = receive_diagnostics(&diagnostics);
                    log_failure(format!(
                        "{}; {detail}",
                        if cancel.load(Ordering::Relaxed) {
                            "helper cancelled"
                        } else {
                            "helper timed out"
                        }
                    ));
                    return None;
                }
                std::thread::sleep(POLL);
            }
            Err(_) => {
                kill_wait(child.child());
                child.finish();
                let detail = receive_diagnostics(&diagnostics);
                log_failure(format!("could not wait for helper; {detail}"));
                return None;
            }
        }
    }
}

/// Reads the helper's stderr on a dedicated thread, keeping only the last
/// `STDERR_LIMIT` bytes, so the child never blocks on a full pipe.
fn drain_stderr(mut stderr: std::process::ChildStderr) -> Receiver<String> {
    let (sender, receiver) = sync_channel(1);
    std::thread::spawn(move || {
        let mut tail = Vec::with_capacity(STDERR_LIMIT);
        let mut buffer = [0_u8; 4096];
        loop {
            match stderr.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(count) => {
                    if count >= STDERR_LIMIT {
                        tail.clear();
                        tail.extend_from_slice(&buffer[count - STDERR_LIMIT..count]);
                    } else {
                        let overflow = tail
                            .len()
                            .saturating_add(count)
                            .saturating_sub(STDERR_LIMIT);
                        if overflow > 0 {
                            tail.drain(..overflow);
                        }
                        tail.extend_from_slice(&buffer[..count]);
                    }
                }
            }
        }
        let _ = sender.send(String::from_utf8_lossy(&tail).into_owned());
    });
    receiver
}

fn receive_diagnostics(receiver: &Receiver<String>) -> String {
    receiver
        .recv_timeout(Duration::from_millis(100))
        .unwrap_or_else(|_| "stderr unavailable".to_owned())
}

fn log_failure(message: String) {
    eprintln!(
        "cover upscaler: {}",
        message.chars().take(STDERR_LIMIT).collect::<String>()
    );
}

/// Kill-and-reap for the child this module spawned; nothing else is touched.
fn kill_wait(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicU64;

    struct TestDir(std::path::PathBuf);

    impl TestDir {
        fn new(name: &str) -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let dir = std::env::temp_dir().join(format!(
                "whisky-process-test-{}-{}-{name}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed),
            ));
            std::fs::create_dir_all(&dir).expect("create test dir");
            Self(dir)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// `/bin/sh -c` fixture command writing its output to `output`.
    fn sh(script: &str) -> Command {
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(script);
        command
    }

    /// Waits for `path` to appear — a deadlock bound, not a timing assertion.
    fn wait_for(path: &Path) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !path.exists() {
            assert!(Instant::now() < deadline, "{path:?} never appeared");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// `kill -0` succeeding means the pid still exists (live or zombie);
    /// failing proves the child was killed AND reaped.
    fn pid_gone(pid_file: &Path) -> bool {
        let pid = std::fs::read_to_string(pid_file).unwrap();
        !Command::new("/bin/sh")
            .arg("-c")
            .arg(format!("kill -0 {}", pid.trim()))
            .status()
            .unwrap()
            .success()
    }

    #[test]
    fn pre_cancelled_helper_is_never_spawned() {
        let dir = TestDir::new("pre-cancel");
        let marker = dir.0.join("started");
        let out = dir.0.join("out.png");
        let cancel = AtomicBool::new(true);
        let result = run_helper(
            sh(&format!("touch '{}'; sleep 5; touch '{}'", marker.display(), out.display())),
            &out,
            HELPER_TIMEOUT,
            &cancel,
        );
        assert!(result.is_none());
        assert!(!marker.exists(), "helper must never start when pre-cancelled");
    }

    #[test]
    fn chatty_stderr_cannot_deadlock_the_pipe() {
        let dir = TestDir::new("chatty");
        let out = dir.0.join("out.png");
        // ~1.1 MiB of stderr versus a 64 KiB pipe: the helper can only finish
        // because the diagnostics thread keeps the pipe drained.
        let result = run_helper(
            sh(&format!(
                "head -c 1100000 /dev/zero | tr '\\0' 'x' >&2; echo ok > '{}'",
                out.display()
            )),
            &out,
            Duration::from_secs(30),
            &AtomicBool::new(false),
        );
        assert_eq!(result, Some(()), "chatty helper must succeed");
        assert!(out.is_file());
    }

    #[test]
    fn cancellation_kills_and_reaps_only_the_owned_child() {
        let dir = TestDir::new("cancel");
        let marker = dir.0.join("started");
        let pid_file = dir.0.join("pid");
        let out = dir.0.join("out.png");
        let cancel = AtomicBool::new(false);
        let out_c = out.clone();
        let marker_c = marker.clone();
        let pid_c = pid_file.clone();
        let cancel = std::sync::Arc::new(cancel);
        let c = cancel.clone();
        let handle = std::thread::spawn(move || {
            run_helper(
                sh(&format!(
                    "echo $$ > '{}'; printf ready > '{}'; exec sleep 60",
                    pid_c.display(),
                    marker_c.display(),
                )),
                &out_c,
                HELPER_TIMEOUT,
                &c,
            )
        });
        wait_for(&marker);
        wait_for(&pid_file);
        cancel.store(true, Ordering::SeqCst);
        let deadline = Instant::now() + Duration::from_secs(10);
        let result = loop {
            if handle.is_finished() {
                break handle.join().expect("join");
            }
            assert!(Instant::now() < deadline, "cancelled run_helper must return");
            std::thread::sleep(Duration::from_millis(10));
        };
        assert!(result.is_none(), "cancelled helper returns None");
        assert!(pid_gone(&pid_file), "the owned child must be killed and reaped");
        assert!(!out.exists(), "no output after cancellation");
    }

    #[test]
    fn timeout_kills_and_reaps_the_owned_child() {
        let dir = TestDir::new("timeout");
        let out = dir.0.join("out.png");
        // Drive the same monitor run_helper uses, on a child this test owns:
        // `exec sleep` means the shell pid IS the helper pid — no descendants.
        let mut command = sh("exec sleep 60");
        let child = command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn sleep helper");
        let pid = child.id();
        // A zero deadline is deterministic: no sleep, no fixture self-report.
        let result = monitor_child(child, &out, Duration::ZERO, &AtomicBool::new(false));
        assert!(result.is_none(), "timed-out helper returns None");
        assert!(
            !Command::new("/bin/sh")
                .arg("-c")
                .arg(format!("kill -0 {pid}"))
                .status()
                .unwrap()
                .success(),
            "the owned child must be killed and reaped"
        );
        assert!(!out.exists());
    }
}
