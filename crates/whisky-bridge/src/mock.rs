//! Mock bridge server and fault injection engine for IPC testing.
//!
//! Provides an in-memory double of the Swift `whisky-bridge` helper service
//! capable of simulating process crashes, malformed NDJSON lines, payload overruns,
//! timeouts, and capability mismatches without spawning external processes.

use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use crate::{MAX_FRAME_BYTES, PROTOCOL_VERSION, RemoteError};

/// Fault scenarios that can be injected into the mock bridge server.
#[derive(Debug, Clone, PartialEq)]
pub enum BridgeFault {
    /// No fault; requests are processed normally.
    None,
    /// Simulates helper process death / broken pipe after the specified number of calls.
    ProcessCrashAfter(u32),
    /// Emits a malformed NDJSON line that fails JSON deserialization.
    MalformedNdjsonFrame,
    /// Emits an oversized payload exceeding the 1 MiB framing limit.
    OversizedPayload(usize),
    /// Incurs a delay before responding, exercising timeout circuits.
    SlowResponse(Duration),
    /// Fails the specified method with a `method_unavailable` error or omits it from describe.
    MethodNotFound(String),
}

/// Actions the mock server backend takes upon handling a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MockFaultAction {
    /// Drop channel / terminate connection immediately to simulate process crash or EOF.
    Crash,
    /// Do not respond; wait for the client's timeout to expire.
    Hang,
}

/// Wire responses emitted by the mock server.
#[derive(Debug, Clone)]
pub enum MockResponse {
    /// Deliver byte chunks immediately to the reader channel.
    Immediate(Vec<Vec<u8>>),
    /// Deliver byte chunks after the specified delay in a background thread.
    Delayed(Vec<Vec<u8>>, Duration),
}

/// Internal mutable state of the mock bridge server.
pub struct MockBridgeState {
    pub fault: BridgeFault,
    pub call_count: u32,
    pub containers: Vec<Value>,
    pub methods: Vec<String>,
    pub responses: HashMap<String, Value>,
    /// Per-method wire errors: recorded like any other call, answered with
    /// the registered error instead of the canned success, and the method
    /// stays advertised in `bridge.describe`.
    pub errors: HashMap<String, RemoteError>,
    pub recorded_calls: Vec<(String, Value)>,
    pub closed: bool,
}

impl Default for MockBridgeState {
    fn default() -> Self {
        Self {
            fault: BridgeFault::None,
            call_count: 0,
            containers: vec![json!({
                "name": "Default Bottle",
                "path": "/virtual/bottles/Default",
                "available": true
            })],
            methods: vec![
                "bridge.describe".into(),
                "bridge.shutdown".into(),
                "workspace.recover".into(),
                "workspace.containers".into(),
                "library.entries".into(),
                "programs.list".into(),
                "processes.list".into(),
                "preferences.schema".into(),
                "preferences.read".into(),
                "preferences.write".into(),
                "system.info".into(),
                "system.terminals".into(),
                "system.desktop.status".into(),
                "setup.status".into(),
                "setup.gptk.status".into(),
                "bottle.create".into(),
                "jobs.get".into(),
                "probe".into(),
            ],
            responses: HashMap::new(),
            errors: HashMap::new(),
            recorded_calls: Vec::new(),
            closed: false,
        }
    }
}

/// Thread-safe in-memory mock bridge server.
#[derive(Clone)]
pub struct MockBridgeServer {
    state: Arc<Mutex<MockBridgeState>>,
}

impl Default for MockBridgeServer {
    fn default() -> Self {
        Self::new()
    }
}

impl MockBridgeServer {
    /// Creates a new mock bridge server with default state.
    pub fn new() -> Self {
        Self {
            state: Arc::new(Mutex::new(MockBridgeState::default())),
        }
    }

    /// Creates a new mock bridge server wrapped in an `Arc`.
    pub fn new_arc() -> Arc<Self> {
        Arc::new(Self::new())
    }

    /// Creates a mock bridge server with custom initial state.
    pub fn with_state(state: MockBridgeState) -> Self {
        Self {
            state: Arc::new(Mutex::new(state)),
        }
    }

    /// Injects a fault into the mock server.
    pub fn inject_fault(&self, fault: BridgeFault) {
        let mut state = self.state.lock().unwrap();
        state.fault = fault;
    }

    /// Simulates an immediate process crash on the next request.
    pub fn crash_now(&self) {
        let count = self.call_count();
        self.inject_fault(BridgeFault::ProcessCrashAfter(count));
    }

    /// Sets the containers returned by `workspace.containers`.
    pub fn set_containers(&self, containers: Vec<Value>) {
        let mut state = self.state.lock().unwrap();
        state.containers = containers;
    }

    /// Sets the advertised method list returned by `bridge.describe`.
    pub fn set_methods(&self, methods: Vec<String>) {
        let mut state = self.state.lock().unwrap();
        state.methods = methods;
    }

    /// Sets a canned result response for a specific method.
    pub fn set_response(&self, method: impl Into<String>, response: Value) {
        let mut state = self.state.lock().unwrap();
        state.responses.insert(method.into(), response);
    }

    /// Registers a wire error returned for `method` requests. The call is
    /// still recorded and the method stays advertised — unlike
    /// `BridgeFault::MethodNotFound`, which removes it from `bridge.describe`.
    pub fn set_error(&self, method: impl Into<String>, error: RemoteError) {
        let mut state = self.state.lock().unwrap();
        state.errors.insert(method.into(), error);
    }

    /// Returns the total number of requests handled or attempted so far.
    pub fn call_count(&self) -> u32 {
        self.state.lock().unwrap().call_count
    }

    /// Returns all recorded calls as `(method, params)` pairs.
    pub fn recorded_calls(&self) -> Vec<(String, Value)> {
        self.state.lock().unwrap().recorded_calls.clone()
    }

    /// Returns whether the mock server has been marked closed or crashed.
    pub fn is_closed(&self) -> bool {
        self.state.lock().unwrap().closed
    }

    /// Marks the mock server as closed.
    pub fn mark_closed(&self) {
        let mut state = self.state.lock().unwrap();
        state.closed = true;
    }

    /// Returns a direct handle to the internal state mutex.
    pub fn state(&self) -> Arc<Mutex<MockBridgeState>> {
        self.state.clone()
    }

    /// Processes an incoming wire request and produces byte responses to deliver over the framing reader.
    pub fn process_request(&self, request_bytes: &[u8]) -> Result<MockResponse, MockFaultAction> {
        let mut state = self.state.lock().unwrap();
        let current_count = state.call_count;
        state.call_count = current_count.saturating_add(1);

        // Evaluate active faults prior to dispatch
        let delayed_by = match &state.fault {
            BridgeFault::ProcessCrashAfter(limit) => {
                if current_count >= *limit {
                    state.closed = true;
                    return Err(MockFaultAction::Crash);
                }
                None
            }
            BridgeFault::MalformedNdjsonFrame => {
                // Return a non-JSON line ending in newline
                return Ok(MockResponse::Immediate(vec![b"{not valid ndjson content\n".to_vec()]));
            }
            BridgeFault::OversizedPayload(size) => {
                let mut buf = vec![b'a'; *size];
                buf.push(b'\n');
                return Ok(MockResponse::Immediate(vec![buf]));
            }
            BridgeFault::SlowResponse(delay) => Some(*delay),
            BridgeFault::MethodNotFound(_) | BridgeFault::None => None,
        };

        // Deserialize request JSON
        let request: Value = match serde_json::from_slice(request_bytes) {
            Ok(v) => v,
            Err(e) => {
                let resp = json!({
                    "version": PROTOCOL_VERSION,
                    "id": Value::Null,
                    "error": {
                        "code": "invalid_request",
                        "message": format!("Cannot parse request JSON: {e}"),
                        "retryable": false
                    }
                });
                let mut b = serde_json::to_vec(&resp).unwrap();
                b.push(b'\n');
                return Ok(MockResponse::Immediate(vec![b]));
            }
        };

        let method = request
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let params = request.get("params").cloned().unwrap_or_else(|| json!({}));

        state.recorded_calls.push((method.clone(), params));

        // Registered per-method wire errors: the request was recorded above
        // and the reply is the injected error, not a canned success.
        if let Some(error) = state.errors.get(&method) {
            let resp = json!({
                "version": PROTOCOL_VERSION,
                "id": id,
                "error": error,
            });
            let mut b = serde_json::to_vec(&resp).unwrap();
            b.push(b'\n');
            return Ok(MockResponse::Immediate(vec![b]));
        }

        // MethodNotFound fault check
        if let BridgeFault::MethodNotFound(failing) = &state.fault
            && &method == failing
        {
            let resp = json!({
                "version": PROTOCOL_VERSION,
                "id": id,
                "error": {
                    "code": "method_unavailable",
                    "message": format!("Method is unavailable: {method}"),
                    "retryable": false
                }
            });
            let mut b = serde_json::to_vec(&resp).unwrap();
            b.push(b'\n');
            return Ok(MockResponse::Immediate(vec![b]));
        }

        let result = if let Some(custom) = state.responses.get(&method) {
            custom.clone()
        } else {
            match method.as_str() {
                "bridge.describe" => {
                    let mut methods = state.methods.clone();
                    if let BridgeFault::MethodNotFound(failing) = &state.fault {
                        methods.retain(|m| m != failing);
                    }
                    json!({
                        "protocolVersion": PROTOCOL_VERSION,
                        "platform": "mock",
                        "methods": methods,
                        "capabilities": ["wine", "fast_indexing"],
                        "maximumFrameBytes": MAX_FRAME_BYTES,
                        "registry": "/mock/registry",
                        "dateUnit": "unix_seconds",
                        "pathFormat": "absolute_native"
                    })
                }
                "workspace.containers" => json!(state.containers),
                "workspace.recover" => json!({}),
                "library.entries" => json!({
                    "entries": [],
                    "total": 0,
                    "nextOffset": Value::Null
                }),
                "programs.list" => json!([]),
                "processes.list" => json!([]),
                "preferences.schema" => json!({
                    "booleans": {},
                    "strings": {},
                    "numbers": {},
                    "paths": []
                }),
                "preferences.read" => json!({}),
                "preferences.write" => json!({}),
                "system.info" => json!({
                    "bundleVersion": "1.0.0",
                    "buildNumber": "1",
                    "osVersion": "mock"
                }),
                "system.terminals" => json!([]),
                "system.desktop.status" => json!({"supported": false}),
                "setup.status" => json!({
                    "installed": true,
                    "version": "1.0.0",
                    "rosettaInstalled": true,
                    "appleSilicon": true
                }),
                "setup.gptk.status" => json!({"installed": true}),
                "bridge.shutdown" => json!({}),
                "probe" => Value::Null,
                _ => json!({}),
            }
        };

        let response = json!({
            "version": PROTOCOL_VERSION,
            "id": id,
            "result": result
        });
        let mut response_bytes = serde_json::to_vec(&response).unwrap();
        response_bytes.push(b'\n');
        if let Some(delay) = delayed_by {
            Ok(MockResponse::Delayed(vec![response_bytes], delay))
        } else {
            Ok(MockResponse::Immediate(vec![response_bytes]))
        }
    }
}
