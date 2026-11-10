use super::*;
use std::ffi::CStr;

fn call(context: u64, value: Value) -> Value {
    let result = request_context(context, value.to_string().as_bytes());
    assert_eq!(result["ok"], true, "{result}");
    result
}
fn binary(context: u64, session: u64, file: u64, offset: u64, length: usize) -> (Value, Vec<u8>) {
    let mut out = vec![0xa5; length + 1];
    let metadata =
        unsafe { vhdx_file_read(context, session, file, offset, length, out.as_mut_ptr()) };
    assert!(!metadata.is_null());
    let response: Value =
        unsafe { serde_json::from_slice(CStr::from_ptr(metadata).to_bytes()).unwrap() };
    unsafe { vhdx_response_free(metadata) };
    assert_eq!(out.pop(), Some(0xa5), "must not write beyond capacity");
    (response, out)
}

#[test]
fn rejects_invalid_ranges_and_zeroes_valid_error_buffers() {
    let (status, bytes) = binary(u64::MAX, 0, 0, u64::MAX, 2);
    assert_eq!(status["error"]["code"], "invalid");
    assert_eq!(bytes, [0, 0]);
    let (status, bytes) = binary(u64::MAX, 0, 0, 0, MAX_READ + 1);
    assert_eq!(status["ok"], false);
    assert!(bytes.iter().all(|b| *b == 0xa5));
    for length in [0, 1] {
        let ptr = unsafe { vhdx_file_read(u64::MAX, 0, 0, 0, length, ptr::null_mut()) };
        assert!(!ptr.is_null());
        let value: Value =
            unsafe { serde_json::from_slice(CStr::from_ptr(ptr).to_bytes()).unwrap() };
        assert_eq!(value["ok"], false);
        unsafe { vhdx_response_free(ptr) };
    }
}

#[test]
fn queued_binary_reads_are_bounded_and_context_cancellable() {
    let (sender, inbox) = mpsc::sync_channel(8);
    let worker = Worker {
        sender: Arc::new(sender),
        active: Arc::new(Mutex::new(ActiveWork::default())),
    };
    let mut responses = Vec::new();
    for context in 1..=8 {
        responses.push(
            enqueue(
                &worker,
                context,
                Request::FileRead {
                    session: 0,
                    file: 1,
                    offset: 0,
                    length: 1,
                },
                Cancellation::default(),
            )
            .unwrap(),
        );
    }
    assert!(enqueue(
        &worker,
        9,
        Request::FileRead {
            session: 0,
            file: 1,
            offset: 0,
            length: 1
        },
        Cancellation::default()
    )
    .is_err());
    worker.active.lock().unwrap().cancel(1);
    for (context, token) in worker.active.lock().unwrap().previews.values() {
        assert_eq!(token.check().is_err(), *context == 1);
    }
    let mut states: HashMap<_, _> = (1..=8).map(|id| (id, State::new())).collect();
    for response in responses {
        let WorkItem::Preview(job) = inbox.recv().unwrap() else {
            panic!()
        };
        let context = job.context;
        run(job, &mut states, &worker.active, 0);
        let (value, bytes) = response.recv().unwrap();
        assert_eq!(
            value["error"]["code"],
            if context == 1 { "cancelled" } else { "locked" }
        );
        assert!(bytes.is_empty());
    }
    assert!(worker.active.lock().unwrap().previews.is_empty());
}

#[test]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn native_binary_matches_json_and_preserves_eof_close_session_and_context() {
    let context = vhdx_context_create();
    let opened = call(
        context,
        json!({"op":"open","path":std::env::var("VHDX_READ_FIXTURE").unwrap()}),
    );
    let session = opened["session"].as_u64().unwrap();
    call(
        context,
        json!({"op":"unlock","session":session,"partition":1,"mode":"none"}),
    );
    let opened = call(
        context,
        json!({"op":"file_open","session":session,"path":"/payload.bin"}),
    );
    let file = opened["data"]["file"].as_u64().unwrap();
    let size = opened["data"]["size"].as_u64().unwrap();
    for (offset, length) in [
        (0, MAX_READ),
        (65521, 80003),
        (size - 19, 123),
        (size, 42),
        (size + 20, 32),
        (0, 0),
    ] {
        let legacy = call(
            context,
            json!({"op":"file_read","session":session,"file":file,"offset":offset,"length":length}),
        );
        let expected = STANDARD
            .decode(legacy["data"]["bytes"].as_str().unwrap())
            .unwrap();
        let (status, bytes) = binary(context, session, file, offset, length);
        assert_eq!(status["ok"], true, "{status}");
        assert_eq!(status["data"]["length"], expected.len());
        assert!(status["data"].get("bytes").is_none());
        assert_eq!(&bytes[..expected.len()], expected);
        assert!(bytes[expected.len()..].iter().all(|b| *b == 0));
    }
    let other = vhdx_context_create();
    assert_eq!(binary(other, session, file, 0, 10).0["ok"], false);
    call(
        context,
        json!({"op":"file_close","session":session,"file":file}),
    );
    let (status, bytes) = binary(context, session, file, 0, 10);
    assert_eq!(status["error"]["code"], "locked");
    assert_eq!(bytes, vec![0; 10]);
    let opened = call(
        context,
        json!({"op":"file_open","session":session,"path":"/payload.bin"}),
    );
    let file = opened["data"]["file"].as_u64().unwrap();
    call(context, json!({"op":"lock","session":session}));
    assert_eq!(
        binary(context, session, file, 0, 10).0["error"]["code"],
        "stale_session"
    );
    call(context, json!({"op":"dispose"}));
    assert_eq!(
        binary(context, session, file, 0, 10).0["error"]["code"],
        "closed"
    );
}

#[test]
#[cfg(unix)]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn failed_source_zeroes_binary_output_and_invalidates_session() {
    let context = vhdx_context_create();
    let path = std::env::temp_dir().join(format!(
        "vhdx-preview-failure-{}-{context}.vhdx",
        std::process::id()
    ));
    std::fs::copy(std::env::var("VHDX_READ_FIXTURE").unwrap(), &path).unwrap();
    let opened = call(context, json!({"op":"open","path":path}));
    let session = opened["session"].as_u64().unwrap();
    call(
        context,
        json!({"op":"unlock","session":session,"partition":1,"mode":"none"}),
    );
    let opened = call(
        context,
        json!({"op":"file_open","session":session,"path":"/payload.bin"}),
    );
    let file = opened["data"]["file"].as_u64().unwrap();
    std::fs::File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_len(0)
        .unwrap();
    let (status, bytes) = binary(context, session, file, 24 * 1024 * 1024, MAX_READ);
    assert_eq!(status["ok"], false, "{status}");
    assert_eq!(status["invalidated"], true, "{status}");
    assert!(bytes.iter().all(|b| *b == 0));
    assert_ne!(status["session"], session);
    call(context, json!({"op":"dispose"}));
    std::fs::remove_file(path).unwrap();
}
