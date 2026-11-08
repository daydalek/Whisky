//! UI-independent client for the bundled Swift application service.
//! Call it from GPUI's background executor. A timeout terminates this session;
//! mutations then require state readback before a user retries them.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::Duration,
};

pub mod mock;
pub use mock::{BridgeFault, MockBridgeServer, MockBridgeState, MockResponse};

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct RemoteError {
    pub code: String,
    pub message: String,
    pub retryable: bool,
}
#[derive(Debug)]
pub enum Error {
    Transport(String),
    Protocol(String),
    Remote(RemoteError),
    Timeout { outcome_unknown: bool },
    Closed,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Transport(s) | Self::Protocol(s) => f.write_str(s),
            Self::Remote(e) => write!(f, "{}: {}", e.code, e.message),
            Self::Timeout { .. } => {
                f.write_str("Bridge timed out; reload state before retrying a mutation")
            }
            Self::Closed => f.write_str("Bridge session is closed"),
        }
    }
}
impl std::error::Error for Error {}

#[derive(Debug, Deserialize)]
struct Response {
    version: u32,
    id: Option<String>,
    #[serde(default, deserialize_with = "present_result")]
    result: Option<Value>,
    error: Option<RemoteError>,
}
fn present_result<'de, D: serde::Deserializer<'de>>(decoder: D) -> Result<Option<Value>, D::Error> {
    Value::deserialize(decoder).map(Some)
}
#[derive(Serialize)]
struct Request<'a> {
    version: u32,
    id: &'a str,
    method: &'a str,
    params: Value,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub protocol_version: u32,
    pub platform: String,
    pub methods: Vec<String>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    pub maximum_frame_bytes: usize,
    pub registry: String,
    pub date_unit: String,
    pub path_format: String,
}

/// An in-memory reader that streams byte chunks received from a channel.
/// Feeds the standard NDJSON framing reader without physical subprocess I/O.
struct ChannelReader {
    receiver: mpsc::Receiver<Vec<u8>>,
    current: std::io::Cursor<Vec<u8>>,
}

impl ChannelReader {
    fn new(receiver: mpsc::Receiver<Vec<u8>>) -> Self {
        Self {
            receiver,
            current: std::io::Cursor::new(Vec::new()),
        }
    }
}

impl Read for ChannelReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        loop {
            let n = self.current.read(buf)?;
            if n > 0 {
                return Ok(n);
            }
            match self.receiver.recv() {
                Ok(chunk) if !chunk.is_empty() => {
                    self.current = std::io::Cursor::new(chunk);
                }
                Ok(_) => continue,
                Err(_) => return Ok(0),
            }
        }
    }
}

/// Internal execution backend for the bridge client.
pub enum ClientBackend {
    Process {
        child: Child,
        input: Option<ChildStdin>,
    },
    Mock {
        server: Arc<MockBridgeServer>,
        closed: Arc<AtomicBool>,
        response_tx: Option<mpsc::Sender<Vec<u8>>>,
    },
}

pub struct Client {
    backend: ClientBackend,
    responses: mpsc::Receiver<Result<Response, String>>,
    stderr: Arc<Mutex<VecDeque<u8>>>,
    next_id: u64,
    timeout: Duration,
    capabilities: Capabilities,
}
impl Client {
    pub fn bundled_helper(executable: &Path) -> Result<PathBuf, Error> {
        let bin_dir = executable
            .parent()
            .ok_or_else(|| Error::Transport("Cannot resolve the application bundle".into()))?;
        let mut candidates = Vec::new();
        if let Some(prefix) = bin_dir.parent() {
            candidates.push(prefix.join("Resources/whisky-bridge"));
            candidates.push(prefix.join("lib/whisky/whisky-bridge"));
            candidates.push(prefix.join("libexec/whisky-bridge"));
        }
        candidates.push(bin_dir.join("whisky-bridge"));
        for candidate in candidates {
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
        // Fallback: look up `whisky-bridge` along $PATH.
        if let Some(path_var) = std::env::var_os("PATH") {
            for dir in std::env::split_paths(&path_var) {
                let candidate = dir.join("whisky-bridge");
                if candidate.is_file() {
                    return Ok(candidate);
                }
            }
        }
        Err(Error::Transport("Bundled whisky-bridge is missing".into()))
    }
    pub fn spawn(helper: &Path, arguments: &[String], timeout: Duration) -> Result<Self, Error> {
        if !helper.is_absolute() || timeout.is_zero() {
            return Err(Error::Transport(
                "An absolute helper path and positive timeout are required".into(),
            ));
        }
        let mut child = Command::new(helper)
            .args(arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| Error::Transport(e.to_string()))?;
        let input = child.stdin.take();
        let output = child.stdout.take().expect("piped stdout");
        let mut errors = child.stderr.take().expect("piped stderr");
        let stderr = Arc::new(Mutex::new(VecDeque::with_capacity(8192)));
        let tail = stderr.clone();
        std::thread::spawn(move || {
            let mut bytes = [0; 1024];
            while let Ok(count) = errors.read(&mut bytes) {
                if count == 0 {
                    break;
                }
                let mut tail = tail.lock().unwrap_or_else(|e| e.into_inner());
                for byte in &bytes[..count] {
                    if tail.len() == 8192 {
                        tail.pop_front();
                    }
                    tail.push_back(*byte);
                }
            }
        });
        let (sender, responses) = mpsc::sync_channel(64);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(output);
            loop {
                let frame = read_frame(&mut reader);
                let terminal = frame.is_err();
                let response = frame.and_then(|data| {
                    serde_json::from_slice(&data).map_err(|e| format!("Invalid bridge JSON: {e}"))
                });
                if sender.send(response).is_err() || terminal {
                    break;
                }
            }
        });
        let mut client = Self {
            backend: ClientBackend::Process { child, input },
            responses,
            stderr,
            next_id: 0,
            timeout,
            capabilities: Capabilities {
                protocol_version: 1,
                platform: String::new(),
                methods: Vec::new(),
                capabilities: Vec::new(),
                maximum_frame_bytes: MAX_FRAME_BYTES,
                registry: String::new(),
                date_unit: String::new(),
                path_format: String::new(),
            },
        };
        let payload = client.exchange("bridge.describe", json!({}), timeout)?;
        let capabilities: Capabilities =
            serde_json::from_value(payload).map_err(|e| Error::Protocol(e.to_string()))?;
        if capabilities.protocol_version != PROTOCOL_VERSION
            || capabilities.maximum_frame_bytes != MAX_FRAME_BYTES
            || capabilities.date_unit != "unix_seconds"
            || capabilities.path_format != "absolute_native"
        {
            return Err(Error::Protocol("Unsupported bridge contract".into()));
        }
        client.capabilities = capabilities;
        Ok(client)
    }

    /// Spawns an in-memory client using a mock bridge server.
    pub fn new_mock(server: Arc<MockBridgeServer>) -> Result<Self, Error> {
        Self::new_mock_with_timeout(server, Duration::from_secs(5))
    }

    /// Spawns an in-memory client using a mock bridge server and custom timeout.
    pub fn new_mock_with_timeout(
        server: Arc<MockBridgeServer>,
        timeout: Duration,
    ) -> Result<Self, Error> {
        if timeout.is_zero() {
            return Err(Error::Transport("Call timeout must be positive".into()));
        }
        let (mock_tx, mock_rx) = mpsc::channel();
        let channel_reader = ChannelReader::new(mock_rx);
        let (sender, responses) = mpsc::sync_channel(64);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(channel_reader);
            loop {
                let frame = read_frame(&mut reader);
                let terminal = frame.is_err();
                let response = frame.and_then(|data| {
                    serde_json::from_slice(&data).map_err(|e| format!("Invalid bridge JSON: {e}"))
                });
                if sender.send(response).is_err() || terminal {
                    break;
                }
            }
        });

        let stderr = Arc::new(Mutex::new(VecDeque::with_capacity(8192)));
        let closed = Arc::new(AtomicBool::new(false));

        let mut client = Self {
            backend: ClientBackend::Mock {
                server,
                closed,
                response_tx: Some(mock_tx),
            },
            responses,
            stderr,
            next_id: 0,
            timeout,
            capabilities: Capabilities {
                protocol_version: 1,
                platform: "mock".into(),
                methods: Vec::new(),
                capabilities: Vec::new(),
                maximum_frame_bytes: MAX_FRAME_BYTES,
                registry: String::new(),
                date_unit: String::new(),
                path_format: String::new(),
            },
        };

        let payload = client.exchange("bridge.describe", json!({}), timeout)?;
        let capabilities: Capabilities =
            serde_json::from_value(payload).map_err(|e| Error::Protocol(e.to_string()))?;
        if capabilities.protocol_version != PROTOCOL_VERSION
            || capabilities.maximum_frame_bytes != MAX_FRAME_BYTES
            || capabilities.date_unit != "unix_seconds"
            || capabilities.path_format != "absolute_native"
        {
            return Err(Error::Protocol("Unsupported bridge contract".into()));
        }
        client.capabilities = capabilities;
        Ok(client)
    }

    pub fn backend(&self) -> &ClientBackend {
        &self.backend
    }

    pub fn is_closed(&self) -> bool {
        match &self.backend {
            ClientBackend::Process { input, .. } => input.is_none(),
            ClientBackend::Mock {
                closed,
                response_tx,
                ..
            } => closed.load(Ordering::SeqCst) || response_tx.is_none(),
        }
    }

    pub fn capabilities(&self) -> &Capabilities {
        &self.capabilities
    }
    pub fn stderr_tail(&self) -> String {
        let tail = self.stderr.lock().unwrap_or_else(|e| e.into_inner());
        String::from_utf8_lossy(&tail.iter().copied().collect::<Vec<_>>()).into_owned()
    }
    pub fn call(&mut self, method: &str, params: Value) -> Result<Value, Error> {
        self.call_with_timeout(method, params, self.timeout)
    }
    pub fn call_with_timeout(
        &mut self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, Error> {
        if timeout.is_zero() {
            return Err(Error::Protocol("Call timeout must be positive".into()));
        }
        if !self.capabilities.methods.iter().any(|m| m == method) {
            return Err(Error::Remote(RemoteError {
                code: "method_unavailable".into(),
                message: format!("Method is unavailable: {method}"),
                retryable: false,
            }));
        }
        self.exchange(method, params, timeout)
    }
    fn exchange(&mut self, method: &str, params: Value, timeout: Duration) -> Result<Value, Error> {
        match &mut self.backend {
            ClientBackend::Process { input, .. } => {
                if input.is_none() {
                    return Err(Error::Closed);
                }
            }
            ClientBackend::Mock {
                closed,
                response_tx,
                ..
            } => {
                if closed.load(Ordering::SeqCst) || response_tx.is_none() {
                    return Err(Error::Closed);
                }
            }
        }
        if !params.is_object() {
            return Err(Error::Protocol("Request params must be an object".into()));
        }
        self.next_id = self
            .next_id
            .checked_add(1)
            .ok_or_else(|| Error::Protocol("Request ID space exhausted".into()))?;
        let id = self.next_id.to_string();
        let mut bytes = serde_json::to_vec(&Request {
            version: PROTOCOL_VERSION,
            id: &id,
            method,
            params,
        })
        .map_err(|e| Error::Protocol(e.to_string()))?;
        if bytes.len() > MAX_FRAME_BYTES {
            return Err(Error::Protocol("Request exceeds frame budget".into()));
        }
        bytes.push(b'\n');

        match &mut self.backend {
            ClientBackend::Process { input, .. } => {
                if let Err(e) = input.as_mut().unwrap().write_all(&bytes) {
                    self.close();
                    return Err(Error::Transport(e.to_string()));
                }
            }
            ClientBackend::Mock {
                server,
                closed,
                response_tx,
            } => match server.process_request(&bytes) {
                Ok(MockResponse::Immediate(chunks)) => {
                    if let Some(tx) = response_tx {
                        for chunk in chunks {
                            if let Err(e) = tx.send(chunk) {
                                self.close();
                                return Err(Error::Transport(e.to_string()));
                            }
                        }
                    } else {
                        self.close();
                        return Err(Error::Closed);
                    }
                }
                Ok(MockResponse::Delayed(chunks, delay)) => {
                    if let Some(tx) = response_tx.clone() {
                        std::thread::spawn(move || {
                            std::thread::sleep(delay);
                            for chunk in chunks {
                                let _ = tx.send(chunk);
                            }
                        });
                    } else {
                        self.close();
                        return Err(Error::Closed);
                    }
                }
                Err(mock::MockFaultAction::Crash) => {
                    response_tx.take();
                    closed.store(true, Ordering::SeqCst);
                    server.mark_closed();
                }
                Err(mock::MockFaultAction::Hang) => {}
            },
        }

        let response = match self.responses.recv_timeout(timeout) {
            Ok(Ok(response)) => response,
            Ok(Err(message)) => {
                self.close();
                return Err(Error::Protocol(message));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                self.close();
                return Err(Error::Timeout {
                    outcome_unknown: true,
                });
            }
            Err(e) => {
                self.close();
                return Err(Error::Transport(e.to_string()));
            }
        };
        if response.version != PROTOCOL_VERSION || response.id.as_deref() != Some(&id) {
            self.close();
            return Err(Error::Protocol(
                "Response version or identity mismatch".into(),
            ));
        }
        match (response.result, response.error) {
            (Some(value), None) => Ok(value),
            (None, Some(error)) => Err(Error::Remote(error)),
            _ => {
                self.close();
                Err(Error::Protocol(
                    "Response must carry exactly one result or error".into(),
                ))
            }
        }
    }
    /// Explicit application quit may apply the stored per-container policy.
    /// Transport loss and Drop use passive close, preserving running games.
    pub fn shutdown(&mut self, apply_exit_policy: bool) -> Result<Value, Error> {
        let result = self.call(
            "bridge.shutdown",
            json!({"applyExitPolicy": apply_exit_policy}),
        );
        if result.is_ok() || !apply_exit_policy {
            self.close();
        }
        result
    }
    pub fn close(&mut self) {
        match &mut self.backend {
            ClientBackend::Process { child, input } => {
                input.take();
                for _ in 0..15 {
                    if child.try_wait().ok().flatten().is_some() {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                let _ = child.kill();
                let _ = child.wait();
            }
            ClientBackend::Mock {
                server,
                closed,
                response_tx,
            } => {
                response_tx.take();
                closed.store(true, Ordering::SeqCst);
                server.mark_closed();
            }
        }
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        self.close();
    }
}

fn read_frame(reader: &mut impl BufRead) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    loop {
        let buffer = reader.fill_buf().map_err(|e| e.to_string())?;
        if buffer.is_empty() {
            return Err("Bridge output ended before a complete response".into());
        }
        let newline = buffer.iter().position(|byte| *byte == b'\n');
        let count = newline.unwrap_or(buffer.len());
        if bytes.len() + count > MAX_FRAME_BYTES {
            return Err("Bridge output exceeds frame budget".into());
        }
        bytes.extend_from_slice(&buffer[..count]);
        reader.consume(count + usize::from(newline.is_some()));
        if newline.is_some() {
            return Ok(bytes);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn bounded_framing_rejects_truncation_and_oversize() {
        assert!(read_frame(&mut &b"{\"ok\":true}"[..]).is_err());
        assert!(read_frame(&mut vec![b'a'; MAX_FRAME_BYTES + 1].as_slice()).is_err());
        assert_eq!(
            read_frame(&mut "{\"title\":\"中文\"}\n".as_bytes()).unwrap(),
            "{\"title\":\"中文\"}".as_bytes()
        );
    }

    #[test]
    fn bundled_helper_supports_macos_bundle_and_linux_layouts() {
        let root = std::env::temp_dir().join(format!(
            "whisky-helper-layout-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let bin = root.join("usr/bin");
        let lib = root.join("usr/lib/whisky");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(&lib).unwrap();
        let exe = bin.join("whisky-gpui");
        let helper = lib.join("whisky-bridge");
        std::fs::write(&exe, b"").unwrap();
        std::fs::write(&helper, b"").unwrap();
        assert_eq!(Client::bundled_helper(&exe).unwrap(), helper);

        let sibling = bin.join("whisky-bridge");
        std::fs::remove_file(&helper).unwrap();
        std::fs::write(&sibling, b"").unwrap();
        assert_eq!(Client::bundled_helper(&exe).unwrap(), sibling);
        let _ = std::fs::remove_dir_all(&root);
    }
}
