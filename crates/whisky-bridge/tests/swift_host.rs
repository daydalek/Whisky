use serde_json::json;
use std::{
    fs,
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use whisky_bridge::{Client, Error};

#[test]
#[ignore = "requires WHISKY_BRIDGE_HELPER built from current Swift sources"]
fn real_swift_host_preserves_literal_settings_and_persistence() {
    let helper = PathBuf::from(
        std::env::var_os("WHISKY_BRIDGE_HELPER").expect("required built Swift helper"),
    );
    let root = std::env::temp_dir().join(format!(
        "whisky-rust-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&root).unwrap();
    let mut client = Client::spawn(
        &helper,
        &["--container".into(), root.to_string_lossy().into()],
        Duration::from_secs(5),
    )
    .unwrap();
    assert!(
        client
            .capabilities()
            .methods
            .iter()
            .any(|m| m == "environment.set")
    );
    let executable = root.join("中文 test.exe");
    fs::write(&executable, b"MZ").unwrap();
    let params = json!({"container": root, "executable": executable, "key": "GAME_TEXT", "value": "中文 $HOME `literal` 'quote' \\"});
    let result = client.call("environment.set", params.clone()).unwrap();
    assert_eq!(result["GAME_TEXT"], params["value"]);
    client.shutdown(false).unwrap();
    let mut client = Client::spawn(
        &helper,
        &["--container".into(), root.to_string_lossy().into()],
        Duration::from_secs(5),
    )
    .unwrap();
    let read = client
        .call(
            "environment.read",
            json!({"container": root, "executable": executable}),
        )
        .unwrap();
    assert_eq!(read["GAME_TEXT"], params["value"]);
    let error = client.call("configuration.set", json!({"container": root, "executable": executable, "field": "programLocale", "value": "invalid"})).unwrap_err();
    assert!(matches!(error, Error::Remote(_)));
    let after = client
        .call(
            "environment.read",
            json!({"container": root, "executable": executable}),
        )
        .unwrap();
    assert_eq!(after, read);
    // A retained scan completes while the same persistent IPC session accepts polls.
    let started = client
        .call("library.scan", json!({"container": root}))
        .unwrap();
    let mut completed = false;
    for _ in 0..100 {
        let state = client
            .call("jobs.get", json!({"jobID": started["jobID"]}))
            .unwrap();
        if state["status"] == "completed" {
            completed = true;
            break;
        }
        assert!(state["status"] == "queued" || state["status"] == "running");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(completed);
    client.shutdown(false).unwrap();
    fs::remove_dir_all(root).unwrap();
}
