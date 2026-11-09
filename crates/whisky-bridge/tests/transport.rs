#![cfg(unix)]
use serde_json::json;
use std::{
    fs,
    path::PathBuf,
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use whisky_bridge::{Client, Error};

static SERIALIZE: Mutex<()> = Mutex::new(());
static SCRIPT_COUNTER: AtomicU64 = AtomicU64::new(0);

fn python_binary() -> PathBuf {
    if let Ok(path) = std::env::var("WHISKY_TEST_PYTHON") {
        let p = PathBuf::from(path);
        if p.is_file() {
            return p;
        }
    }
    for candidate in ["/usr/bin/python3", "/usr/local/bin/python3"] {
        let p = PathBuf::from(candidate);
        if p.is_file() {
            return p;
        }
    }
    PathBuf::from("/usr/bin/python3")
}

struct Script(PathBuf);
impl Script {
    fn new() -> Self {
        let id = SCRIPT_COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "whisky-transport-{}-{}-{}.py",
            std::process::id(),
            id,
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, r#"import sys,json,time
mode=sys.argv[1]
for line in sys.stdin:
    request=json.loads(line)
    if request['method']=='bridge.describe':
        if mode=='stderr':
            sys.stderr.write('x'*100000);sys.stderr.flush()
        result={'protocolVersion':1,'platform':'fixture','methods':['bridge.describe','bridge.shutdown','probe'],'maximumFrameBytes':1048576,'registry':'/tmp/fixture','dateUnit':'unix_seconds','pathFormat':'absolute_native'}
        print(json.dumps({'version':1,'id':request['id'],'result':result}),flush=True)
    elif mode=='shutdown-error' and request['method']=='bridge.shutdown':
        print(json.dumps({'version':1,'id':request['id'],'error':{'code':'operation_failed','message':'process termination failed','retryable':True}}),flush=True)
    elif mode=='timeout': time.sleep(30)
    elif mode=='exit': sys.exit(3)
    elif mode=='oversize': print('x'*1048577,flush=True)
    elif mode=='wrong-id': print(json.dumps({'version':1,'id':'foreign','result':{}}),flush=True)
    elif mode=='wrong-version': print(json.dumps({'version':2,'id':request['id'],'result':{}}),flush=True)
    elif mode=='both': print(json.dumps({'version':1,'id':request['id'],'result':{},'error':{'code':'e','message':'failure','retryable':False}}),flush=True)
    else: print(json.dumps({'version':1,'id':request['id'],'result':None}),flush=True)
"#).unwrap();
        Self(path)
    }
    fn client(&self, mode: &str) -> Client {
        Client::spawn(
            &python_binary(),
            &["-u".into(), self.0.to_string_lossy().into(), mode.into()],
            Duration::from_secs(10),
        )
        .unwrap()
    }
}
impl Drop for Script {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

#[test]
fn protocol_failures_close_the_session() {
    let _guard = SERIALIZE.lock().unwrap_or_else(|e| e.into_inner());
    let script = Script::new();
    for mode in ["wrong-id", "wrong-version", "oversize", "both", "exit"] {
        let mut client = script.client(mode);
        assert!(client.call("probe", json!({})).is_err(), "{mode}");
        assert!(
            matches!(client.call("probe", json!({})), Err(Error::Closed)),
            "{mode}"
        );
    }
}
#[test]
fn stderr_is_drained_and_bounded_while_null_results_remain_valid() {
    let _guard = SERIALIZE.lock().unwrap_or_else(|e| e.into_inner());
    let script = Script::new();
    let mut client = script.client("stderr");
    assert_eq!(
        client.call("probe", json!({})).unwrap(),
        serde_json::Value::Null
    );
    assert!(client.stderr_tail().len() <= 8192);
    assert!(!client.stderr_tail().is_empty());
}
#[test]
fn timeout_marks_unknown_mutation_outcome_and_closes_session() {
    let _guard = SERIALIZE.lock().unwrap_or_else(|e| e.into_inner());
    let script = Script::new();
    let mut client = script.client("timeout");
    assert!(matches!(
        client.call("probe", json!({})),
        Err(Error::Timeout {
            outcome_unknown: true
        })
    ));
    assert!(matches!(
        client.call("probe", json!({})),
        Err(Error::Closed)
    ));
}

#[test]
fn failed_exit_policy_keeps_the_helper_available_for_retry() {
    let _guard = SERIALIZE.lock().unwrap_or_else(|e| e.into_inner());
    let script = Script::new();
    let mut client = script.client("shutdown-error");
    assert!(matches!(client.shutdown(true), Err(Error::Remote(_))));
    assert!(client.call("probe", json!({})).is_ok());
}
