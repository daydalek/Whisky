use std::sync::{Arc, Mutex};
use serde_json::json;
use whisky_bridge::{
    BridgeFault, Client, Error, MAX_FRAME_BYTES, MockBridgeServer,
    PROTOCOL_VERSION,
};

/// 1. EMPIRICAL VERIFICATION: Framing Limits (1,048,576 vs 1,048,577 bytes)
#[test]
fn test_exact_1mb_boundary_payload_succeeds_in_client() {
    let server = MockBridgeServer::new_arc();
    let mut client = Client::new_mock(server.clone()).expect("spawn mock client");

    // Construct a valid response whose wire bytes before newline is EXACTLY 1,048,576 bytes.
    // Response format: {"id":"1","result":{"blob":"<PADDING>"},"version":1}\n
    let base_json = json!({
        "version": PROTOCOL_VERSION,
        "id": "1",
        "result": { "blob": "" }
    });
    let base_len = serde_json::to_vec(&base_json).unwrap().len();
    let padding_len = MAX_FRAME_BYTES - base_len;
    let padding = "x".repeat(padding_len);

    let exact_1mb_json = json!({
        "version": PROTOCOL_VERSION,
        "id": "1",
        "result": { "blob": padding }
    });
    let exact_1mb_bytes = serde_json::to_vec(&exact_1mb_json).unwrap();
    assert_eq!(
        exact_1mb_bytes.len(),
        MAX_FRAME_BYTES,
        "Payload must be exactly 1,048,576 bytes"
    );

    // Configure mock server to emit this exact 1MB response for "probe"
    server.set_response("probe", exact_1mb_json["result"].clone());

    let res = client.call("probe", json!({})).expect("exact 1MB frame must succeed");
    assert_eq!(res["blob"].as_str().unwrap().len(), padding_len);
    assert!(!client.is_closed());
}

#[test]
fn test_exact_1mb_plus_1_byte_response_rejected_by_framing() {
    let server = MockBridgeServer::new_arc();
    let mut client = Client::new_mock(server.clone()).expect("spawn mock client");

    // Inject fault: response payload of exactly MAX_FRAME_BYTES + 1 (1,048,577 bytes)
    server.inject_fault(BridgeFault::OversizedPayload(MAX_FRAME_BYTES + 1));

    let err = client.call("probe", json!({})).unwrap_err();
    match &err {
        Error::Protocol(msg) => {
            assert!(
                msg.contains("Bridge output exceeds frame budget"),
                "Expected frame budget error, got: {msg}"
            );
        }
        other => panic!("Expected Error::Protocol, got: {other:?}"),
    }
    assert!(client.is_closed(), "Client must be closed on framing violation");
}

#[test]
fn test_request_payload_exactly_1mb_vs_1mb_plus_1() {
    let server = MockBridgeServer::new_arc();
    let mut client = Client::new_mock(server.clone()).expect("spawn mock client");

    // Base request overhead:
    // {"version":1,"id":"1","method":"probe","params":{"data":""}}
    let base_req = json!({
        "version": PROTOCOL_VERSION,
        "id": "1",
        "method": "probe",
        "params": { "data": "" }
    });
    let base_len = serde_json::to_vec(&base_req).unwrap().len();
    let padding_len = MAX_FRAME_BYTES - base_len;

    // 1. Exactly 1,048,576 bytes request
    let exact_req_params = json!({
        "data": "a".repeat(padding_len)
    });
    let res = client.call("probe", exact_req_params);
    assert!(res.is_ok(), "Request of exactly 1MB should be accepted by exchange");

    // 2. Exactly 1,048,577 bytes request (1MB + 1 byte)
    let oversize_req_params = json!({
        "data": "a".repeat(padding_len + 1)
    });
    let err = client.call("probe", oversize_req_params).unwrap_err();
    match &err {
        Error::Protocol(msg) => {
            assert!(
                msg.contains("Request exceeds frame budget"),
                "Expected Request exceeds frame budget, got: {msg}"
            );
        }
        other => panic!("Expected Error::Protocol, got: {other:?}"),
    }
}

/// 2. EMPIRICAL VERIFICATION: Malformed NDJSON, Truncated UTF-8, Partial JSON, Abrupt Closure
#[test]
fn test_malformed_ndjson_arbitrary_garbage_rejects_and_closes() {
    let server = MockBridgeServer::new_arc();
    let mut client = Client::new_mock(server.clone()).expect("spawn mock client");

    server.inject_fault(BridgeFault::MalformedNdjsonFrame);
    let err = client.call("probe", json!({})).unwrap_err();
    assert!(matches!(err, Error::Protocol(ref m) if m.contains("Invalid bridge JSON")));
    assert!(client.is_closed());

    // Subsequent calls fail immediately with Closed
    let second_err = client.call("probe", json!({})).unwrap_err();
    assert!(matches!(second_err, Error::Closed));
}

#[test]
fn test_truncated_utf8_sequence_inside_frame() {
    // An invalid/truncated multi-byte UTF-8 sequence inside a JSON string
    let mut bad_utf8 = Vec::new();
    bad_utf8.extend_from_slice(b"{\"version\":1,\"id\":\"1\",\"result\":{\"bad\":\"");
    bad_utf8.push(0xE4);
    bad_utf8.push(0xB8); // Incomplete 3-byte Chinese character
    bad_utf8.extend_from_slice(b"\"}}");

    let parse_res: Result<serde_json::Value, _> = serde_json::from_slice(&bad_utf8);
    assert!(parse_res.is_err(), "Invalid UTF-8 in JSON must fail serde_json parsing");
}

#[test]
fn test_partial_json_token_without_newline_triggers_eof() {
    let server = MockBridgeServer::new_arc();
    // Simulate abrupt EOF by crashing on call 1 before response is completed
    server.inject_fault(BridgeFault::ProcessCrashAfter(1));

    let mut client = Client::new_mock(server.clone()).expect("spawn mock client");
    let err = client.call("probe", json!({})).unwrap_err();

    assert!(
        matches!(err, Error::Protocol(ref m) if m.contains("Bridge output ended before a complete response")),
        "Expected complete response EOF error, got: {err:?}"
    );
    assert!(client.is_closed());
}

#[test]
fn test_abrupt_channel_closure_on_idle_and_inflight() {
    let server = MockBridgeServer::new_arc();
    let mut client = Client::new_mock(server.clone()).expect("spawn mock client");

    // Close server explicitly
    server.mark_closed();
    server.crash_now();

    let err = client.call("probe", json!({})).unwrap_err();
    assert!(
        matches!(err, Error::Protocol(_) | Error::Transport(_) | Error::Closed),
        "Expected error on crashed/closed server, got: {err:?}"
    );
    assert!(client.is_closed());
}

/// 3. EMPIRICAL VERIFICATION: Concurrency & Thread-Safety Stress Harness
#[test]
fn test_mock_server_high_concurrency_stress() {
    let server = MockBridgeServer::new_arc();
    let num_threads = 16;
    let calls_per_thread = 100;
    let mut handles = Vec::new();

    for t in 0..num_threads {
        let s = server.clone();
        handles.push(std::thread::spawn(move || {
            for i in 0..calls_per_thread {
                let req_bytes = format!(
                    "{{\"version\":1,\"id\":\"t{t}-c{i}\",\"method\":\"probe\",\"params\":{{}}}}\n"
                ).into_bytes();

                let resp = s.process_request(&req_bytes).expect("mock request process");
                match resp {
                    whisky_bridge::MockResponse::Immediate(chunks) => {
                        assert_eq!(chunks.len(), 1);
                        let v: serde_json::Value = serde_json::from_slice(&chunks[0]).unwrap();
                        assert_eq!(v["id"], format!("t{t}-c{i}"));
                    }
                    _ => panic!("Expected immediate response"),
                }
            }
        }));
    }

    for h in handles {
        h.join().expect("thread join");
    }

    // Verify all calls were recorded without race conditions
    assert_eq!(server.call_count(), (num_threads * calls_per_thread) as u32);
    let recorded = server.recorded_calls();
    assert_eq!(recorded.len(), num_threads * calls_per_thread);
}

#[test]
fn test_client_under_concurrent_thread_mutex() {
    let server = MockBridgeServer::new_arc();
    let client = Arc::new(Mutex::new(
        Client::new_mock(server.clone()).expect("spawn mock client")
    ));

    let num_threads = 8;
    let calls_per_thread = 25;
    let mut handles = Vec::new();

    for t in 0..num_threads {
        let c = client.clone();
        handles.push(std::thread::spawn(move || {
            for i in 0..calls_per_thread {
                let mut guard = c.lock().unwrap();
                let res = guard.call("probe", json!({"thread": t, "iteration": i}));
                assert!(res.is_ok(), "Concurrent call must succeed");
            }
        }));
    }

    for h in handles {
        h.join().expect("thread join");
    }

    let guard = client.lock().unwrap();
    assert!(!guard.is_closed());
    assert_eq!(server.call_count(), 1 + (num_threads * calls_per_thread) as u32); // 1 describe + 200 calls
}

#[test]
fn test_concurrent_error_propagation_and_circuit_breaking() {
    let server = MockBridgeServer::new_arc();
    let client = Arc::new(Mutex::new(
        Client::new_mock(server.clone()).expect("spawn mock client")
    ));

    let num_threads = 6;
    let mut handles = Vec::new();

    // Trigger crash after 10 calls
    server.inject_fault(BridgeFault::ProcessCrashAfter(10));

    for _ in 0..num_threads {
        let c = client.clone();
        handles.push(std::thread::spawn(move || {
            let mut failed = false;
            for _ in 0..30 {
                let mut guard = c.lock().unwrap();
                let res = guard.call("probe", json!({}));
                if res.is_err() {
                    failed = true;
                }
            }
            failed
        }));
    }

    let mut any_failed = false;
    for h in handles {
        if h.join().expect("thread join") {
            any_failed = true;
        }
    }

    assert!(any_failed, "Crash fault must trigger failure across threads");
    let guard = client.lock().unwrap();
    assert!(guard.is_closed(), "Client must be closed permanently after crash");
}
