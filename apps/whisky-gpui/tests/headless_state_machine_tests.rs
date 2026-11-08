//! Integration test runner for the production CLI against a hermetic NDJSON
//! fixture helper.
//!
//! Verifies:
//! - `--print-bridge-status` and `--print-library` talk to the helper named by
//!   WHISKY_BRIDGE_HELPER — never to an ambient real helper.
//! - The wire contract the CLI validates: protocol 1, 1 MiB frames,
//!   unix_seconds dates, absolute_native paths.
//! - A missing helper exits 1 even with WHISKY_GPUI_DEMO_DATA=1: demo mode is
//!   a library concern and does not decouple the CLI from the bridge.
//! - The remote-error wire shape the supervisor classifies on.
//! - Fixtures integrity (library-entries.json, configuration-schema.json).

use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

/// Absolute path of an executable on PATH.
fn resolve_on_path(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|dir| dir.join(name))
            .find(|candidate| candidate.is_file())
    })
}

fn fixture_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

/// One hermetic fixture environment: a unique per-test temp root that doubles
/// as the child's HOME/XDG base so nothing touches real user state.
struct CliFixture {
    root: PathBuf,
    helper: PathBuf,
}

impl CliFixture {
    fn new(tag: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "whisky-gpui-cli-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        // The helper is a temporary executable wrapper around the checked-in
        // Python NDJSON fixture, launched with the resolved absolute python3.
        let python3 = resolve_on_path("python3").expect("python3 on PATH for the fixture helper");
        let helper = root.join("whisky-bridge");
        std::fs::write(
            &helper,
            format!(
                "#!/bin/sh\nexec \"{}\" \"{}\" \"$@\"\n",
                python3.display(),
                fixture_dir().join("mock_bridge_helper.py").display()
            ),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = std::fs::metadata(&helper).unwrap().permissions();
            permissions.set_mode(0o755);
            std::fs::set_permissions(&helper, permissions).unwrap();
        }
        Self { root, helper }
    }

    /// Hermetic child environment: our helper only, Wine host effects off,
    /// every user-directed path rooted at the per-test temp dir.
    fn apply_env(&self, command: &mut Command) {
        command
            .env("WHISKY_BRIDGE_HELPER", &self.helper)
            .env("WHISKY_BRIDGE_NO_WINE", "1")
            .env("WHISKY_REGISTRY", self.root.join("registry"))
            .env("MOCK_BRIDGE_ENTRIES", fixture_dir().join("library-entries.json"))
            .env("HOME", &self.root)
            .env("XDG_CACHE_HOME", self.root.join("xdg-cache"))
            .env("XDG_CONFIG_HOME", self.root.join("xdg-config"))
            .env("XDG_DATA_HOME", self.root.join("xdg-data"))
            .env_remove("DISPLAY")
            .env_remove("WAYLAND_DISPLAY")
            .env_remove("WHISKY_GPUI_DEMO_DATA")
            .env_remove("WHISKY_WINE_RUNTIME");
    }

    /// Run the CLI under the fixture environment. A child that outlives the
    /// timeout is killed and reaped before the test panics — only the process
    /// this test spawned is touched.
    fn run(&self, arguments: &[&str], extra_env: &[(&str, &str)], timeout: Duration) -> Output {
        let mut command = Command::new(env!("CARGO_BIN_EXE_whisky-gpui"));
        command
            .args(arguments)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        self.apply_env(&mut command);
        for (key, value) in extra_env {
            command.env(key, value);
        }
        let mut child = command.spawn().expect("spawn whisky-gpui");
        let deadline = Instant::now() + timeout;
        loop {
            match child.try_wait().expect("try_wait on whisky-gpui") {
                Some(_) => return child.wait_with_output().expect("collect output"),
                None if Instant::now() >= deadline => {
                    let _ = child.kill();
                    let _ = child.wait();
                    panic!("whisky-gpui {arguments:?} exceeded {timeout:?}");
                }
                None => std::thread::sleep(Duration::from_millis(20)),
            }
        }
    }
}

impl Drop for CliFixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn test_cli_print_bridge_status_against_fixture_helper() {
    let fixture = CliFixture::new("status");
    let output = fixture.run(&["--print-bridge-status"], &[], Duration::from_secs(30));
    assert!(
        output.status.success(),
        "--print-bridge-status must exit 0 against the fixture helper, got {:?}: {}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains(&*fixture.helper.to_string_lossy()),
        "the fixture helper must be the one answering, stderr: {stderr}"
    );

    let describe: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("status prints a JSON describe payload");
    assert_eq!(describe["protocolVersion"], json!(1));
    assert_eq!(describe["platform"], json!("fixture"));
    assert_eq!(describe["maximumFrameBytes"], json!(1_048_576));
    assert_eq!(describe["dateUnit"], json!("unix_seconds"));
    assert_eq!(describe["pathFormat"], json!("absolute_native"));
    let methods = describe["methods"].as_array().expect("methods list");
    for required in [
        "bridge.describe",
        "bridge.shutdown",
        "workspace.recover",
        "workspace.containers",
        "library.entries",
    ] {
        assert!(
            methods.iter().any(|method| method == required),
            "describe must advertise {required}: {methods:?}"
        );
    }
}

#[test]
fn test_cli_print_library_against_fixture_helper() {
    let fixture = CliFixture::new("library");
    let output = fixture.run(&["--print-library", "--all"], &[], Duration::from_secs(30));
    assert!(
        output.status.success(),
        "--print-library --all must exit 0 against the fixture helper, got {:?}: {}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    let expected_entries = {
        let entries: serde_json::Value =
            serde_json::from_str(include_str!("fixtures/library-entries.json")).unwrap();
        entries.as_array().expect("entries fixture is a JSON array").len()
    };

    let summary: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("library prints a JSON summary");
    let containers = summary["containers"].as_array().expect("containers array");
    assert_eq!(containers.len(), 1);
    assert_eq!(containers[0]["name"], json!("Fixture Bottle"));
    assert_eq!(containers[0]["path"], json!("/virtual/fixture-bottle"));
    assert_eq!(containers[0]["available"], json!(true));
    assert_eq!(containers[0]["entryCount"], json!(expected_entries));
    let sample = containers[0]["sample"].as_array().expect("sample names");
    assert_eq!(sample.len(), expected_entries.min(5));
    assert_eq!(summary["all"]["total"], json!(expected_entries));
    let per_bottle = summary["all"]["perBottle"]
        .as_array()
        .expect("per-bottle counts");
    assert_eq!(per_bottle.len(), 1);
    assert_eq!(per_bottle[0]["name"], json!("Fixture Bottle"));
    assert_eq!(per_bottle[0]["entries"], json!(expected_entries));
}

#[test]
fn test_cli_missing_helper_exits_one_even_with_demo_data() {
    let fixture = CliFixture::new("missing-helper");
    let missing = fixture.root.join("definitely-nonexistent-helper");
    let missing = missing.to_str().expect("temp root is UTF-8");
    let output = fixture.run(
        &["--print-bridge-status"],
        &[
            ("WHISKY_BRIDGE_HELPER", missing),
            ("WHISKY_GPUI_DEMO_DATA", "1"),
        ],
        Duration::from_secs(30),
    );
    assert_eq!(
        output.status.code(),
        Some(1),
        "a missing helper must exit 1 even with demo data set, got {:?}: {}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("WHISKY_BRIDGE_HELPER does not name a file"),
        "stderr must name the missing-helper cause: {stderr}"
    );
}

#[test]
fn test_integration_remote_error_wire_shape() {
    // The helper reports the Linux picker timeout as a retryable remote
    // error. The wire shape is the Rust-side contract; the supervisor's
    // picker ceiling and the helper's own timeout budget are covered by the
    // supervisor tests and the Swift LinuxFilePicker tests respectively.
    let frame = json!({
        "version": 1,
        "id": "7",
        "error": {
            "code": "host_timeout",
            "message": "File selection timed out; open the picker again",
            "retryable": true,
        }
    });
    let error: whisky_bridge::RemoteError =
        serde_json::from_value(frame["error"].clone()).expect("wire error decodes");
    assert_eq!(error.code, "host_timeout");
    assert_eq!(error.message, "File selection timed out; open the picker again");
    assert!(error.retryable);
    let encoded = serde_json::to_value(&error).expect("error re-encodes to the wire shape");
    assert_eq!(encoded["code"], json!("host_timeout"));
    assert_eq!(encoded["retryable"], json!(true));
}

#[test]
fn test_integration_fixtures_validation() {
    let entries_raw = include_str!("fixtures/library-entries.json");
    let parsed: serde_json::Value = serde_json::from_str(entries_raw).expect("Valid JSON fixture");
    let arr = parsed.as_array().expect("Array of entries");
    assert!(!arr.is_empty(), "Fixture library entries must not be empty");

    let schema_raw = include_str!("fixtures/configuration-schema.json");
    let schema: serde_json::Value = serde_json::from_str(schema_raw).expect("Valid schema JSON");
    assert!(schema.is_array(), "Configuration schema must be an array of field definitions");
    assert!(!schema.as_array().unwrap().is_empty());
}
