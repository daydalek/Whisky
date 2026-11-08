use serde_json::json;
use std::time::Duration;
use whisky_bridge::{
    BridgeFault, Client, Error, MAX_FRAME_BYTES, MockBridgeServer, MockBridgeState,
    PROTOCOL_VERSION,
};

#[test]
fn test_mock_client_lifecycle_and_successful_calls() {
    let server = MockBridgeServer::new_arc();
    let mut initial_methods = MockBridgeState::default().methods;
    initial_methods.push("custom.method".into());
    server.set_methods(initial_methods);
    server.set_response("custom.method", json!({"score": 100}));

    let mut client = Client::new_mock(server.clone()).expect("client spawned");

    assert_eq!(client.capabilities().protocol_version, PROTOCOL_VERSION);
    assert_eq!(client.capabilities().maximum_frame_bytes, MAX_FRAME_BYTES);
    assert_eq!(client.capabilities().platform, "mock");
    assert!(!client.is_closed());

    // Call standard methods
    let containers = client.call("workspace.containers", json!({})).unwrap();
    assert!(containers.is_array());
    assert_eq!(containers.as_array().unwrap().len(), 1);

    let probe = client.call("probe", json!({})).unwrap();
    assert_eq!(probe, serde_json::Value::Null);

    // Call custom method
    let res = client.call("custom.method", json!({})).unwrap();
    assert_eq!(res["score"], 100);

    // Recorded calls
    assert!(server.call_count() >= 4);
    let calls = server.recorded_calls();
    assert!(calls.iter().any(|(m, _)| m == "bridge.describe"));
    assert!(calls.iter().any(|(m, _)| m == "workspace.containers"));
    assert!(calls.iter().any(|(m, _)| m == "probe"));
    assert!(calls.iter().any(|(m, _)| m == "custom.method"));

    // Graceful close
    client.close();
    assert!(client.is_closed());
    assert!(matches!(client.call("probe", json!({})), Err(Error::Closed)));
}

#[test]
fn test_oversize_response_payload_rejected_by_framing() {
    let server = MockBridgeServer::new_arc();
    let mut client = Client::new_mock(server.clone()).expect("client spawned");

    // Inject fault: response payload exceeding MAX_FRAME_BYTES (1 MiB + 1 byte)
    server.inject_fault(BridgeFault::OversizedPayload(MAX_FRAME_BYTES + 1));

    let err = client.call("probe", json!({})).unwrap_err();
    assert!(
        matches!(err, Error::Protocol(ref msg) if msg.contains("Bridge output exceeds frame budget")),
        "Expected frame budget protocol error, got: {err:?}"
    );
    assert!(client.is_closed());

    // Subsequent calls are rejected with Closed
    assert!(matches!(client.call("probe", json!({})), Err(Error::Closed)));
}

#[test]
fn test_oversize_response_large_payload_rejected() {
    let server = MockBridgeServer::new_arc();
    let mut client = Client::new_mock(server.clone()).expect("client spawned");

    // Inject fault: response payload of 2 MiB
    server.inject_fault(BridgeFault::OversizedPayload(2 * 1024 * 1024));

    let err = client.call("probe", json!({})).unwrap_err();
    assert!(
        matches!(err, Error::Protocol(ref msg) if msg.contains("Bridge output exceeds frame budget")),
        "Expected frame budget protocol error, got: {err:?}"
    );
    assert!(client.is_closed());
}

#[test]
fn test_oversize_request_payload_rejected_before_send() {
    let server = MockBridgeServer::new_arc();
    let mut client = Client::new_mock(server.clone()).expect("client spawned");

    // Construct request with huge string parameter exceeding 1MB
    let huge_string = "a".repeat(MAX_FRAME_BYTES + 10);
    let err = client
        .call("probe", json!({"huge": huge_string}))
        .unwrap_err();

    assert!(
        matches!(err, Error::Protocol(ref msg) if msg.contains("Request exceeds frame budget")),
        "Expected request frame budget protocol error, got: {err:?}"
    );
}

#[test]
fn test_malformed_ndjson_frame_returns_protocol_error() {
    let server = MockBridgeServer::new_arc();
    let mut client = Client::new_mock(server.clone()).expect("client spawned");

    // Inject malformed NDJSON fault
    server.inject_fault(BridgeFault::MalformedNdjsonFrame);

    let err = client.call("probe", json!({})).unwrap_err();
    assert!(
        matches!(err, Error::Protocol(ref msg) if msg.contains("Invalid bridge JSON")),
        "Expected Invalid bridge JSON error, got: {err:?}"
    );
    assert!(client.is_closed());
}

#[test]
fn test_process_crash_after_n_calls_closes_session() {
    let server = MockBridgeServer::new_arc();
    let mut client = Client::new_mock(server.clone()).expect("client spawned");

    // Describe was call 0. Let's crash on call 2 (after 1 successful post-handshake call)
    server.inject_fault(BridgeFault::ProcessCrashAfter(2));

    // Call 1: succeeds
    assert!(client.call("probe", json!({})).is_ok());

    // Call 2: crashes
    let err = client.call("probe", json!({})).unwrap_err();
    assert!(
        matches!(err, Error::Protocol(ref msg) if msg.contains("Bridge output ended before a complete response")),
        "Expected EOF before complete response error, got: {err:?}"
    );
    assert!(client.is_closed());
    assert!(server.is_closed());

    // Call 3: closed
    assert!(matches!(client.call("probe", json!({})), Err(Error::Closed)));
}

#[test]
fn test_process_crash_on_handshake_fails_spawn() {
    let server = MockBridgeServer::new_arc();
    // Crash on call 0 (the handshake describe call)
    server.inject_fault(BridgeFault::ProcessCrashAfter(0));

    let result = Client::new_mock(server.clone());
    assert!(result.is_err());
    let err = result.err().unwrap();
    assert!(
        matches!(err, Error::Protocol(ref msg) if msg.contains("Bridge output ended before a complete response")),
        "Expected EOF during handshake, got: {err:?}"
    );
    assert!(server.is_closed());
}

#[test]
fn test_crash_now_helper_immediately_terminates_next_call() {
    let server = MockBridgeServer::new_arc();
    let mut client = Client::new_mock(server.clone()).expect("client spawned");

    assert!(client.call("probe", json!({})).is_ok());
    server.crash_now();

    let err = client.call("probe", json!({})).unwrap_err();
    assert!(
        matches!(err, Error::Protocol(ref msg) if msg.contains("Bridge output ended before a complete response")),
        "Expected crash on next call, got: {err:?}"
    );
    assert!(client.is_closed());
}

#[test]
fn test_slow_response_triggers_timeout() {
    let server = MockBridgeServer::new_arc();
    let mut client =
        Client::new_mock_with_timeout(server.clone(), Duration::from_millis(50)).unwrap();

    // Inject slow response exceeding client timeout
    server.inject_fault(BridgeFault::SlowResponse(Duration::from_millis(250)));

    let err = client.call("probe", json!({})).unwrap_err();
    assert!(
        matches!(err, Error::Timeout { outcome_unknown: true }),
        "Expected timeout error, got: {err:?}"
    );
    assert!(client.is_closed());
}

#[test]
fn test_set_error_returns_remote_error_but_records_call() {
    let server = MockBridgeServer::new_arc();
    server.set_error(
        "workspace.containers",
        whisky_bridge::RemoteError {
            code: "host_timeout".into(),
            message: "File selection timed out; open the picker again".into(),
            retryable: true,
        },
    );

    let mut client = Client::new_mock(server.clone()).expect("client spawned");

    // The injected error surfaces as a remote error, not a session error.
    let err = client
        .call("workspace.containers", json!({}))
        .unwrap_err();
    match err {
        Error::Remote(remote) => {
            assert_eq!(remote.code, "host_timeout");
            assert_eq!(remote.message, "File selection timed out; open the picker again");
            assert!(remote.retryable);
        }
        other => panic!("expected remote error, got: {other:?}"),
    }

    // The failed call still traversed the wire and was recorded...
    assert!(
        server
            .recorded_calls()
            .iter()
            .any(|(m, _)| m == "workspace.containers")
    );
    // ...the method stays advertised in describe...
    assert!(
        client
            .capabilities()
            .methods
            .contains(&"workspace.containers".to_string())
    );
    // ...the session stays usable, and canned successes are unaffected.
    let probe = client.call("probe", json!({})).unwrap();
    assert_eq!(probe, serde_json::Value::Null);
    assert!(!client.is_closed());
}

#[test]
fn test_method_not_found_returns_method_unavailable() {
    let server = MockBridgeServer::new_arc();
    // Inject MethodNotFound for a method before spawn
    server.inject_fault(BridgeFault::MethodNotFound("workspace.containers".into()));

    let client = Client::new_mock(server.clone()).expect("spawned");
    assert!(
        !client
            .capabilities()
            .methods
            .contains(&"workspace.containers".to_string()),
        "failing method should not be advertised in describe"
    );
}
