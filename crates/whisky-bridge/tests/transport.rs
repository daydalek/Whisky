#![cfg(unix)]
use serde_json::json;
use std::{
    fs,
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use whisky_bridge::{Client, Error};

struct Script(PathBuf);
impl Script {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "whisky-transport-{}-{}.py",
            std::process::id(),
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
        result={'protocolVersion':1,'platform':'fixture','methods':['bridge.describe','probe'],'maximumFrameBytes':1048576,'registry':'/tmp/fixture','dateUnit':'unix_seconds','pathFormat':'absolute_native'}
        print(json.dumps({'version':1,'id':request['id'],'result':result}),flush=True)
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
            &PathBuf::from("/usr/bin/python3"),
            &[self.0.to_string_lossy().into(), mode.into()],
            Duration::from_secs(2),
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
