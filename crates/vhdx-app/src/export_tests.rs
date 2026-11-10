//! PERF-01 regressions. Native cases use the generated, non-private read fixture.
use super::*;
use sha2::{Digest, Sha256};
use std::{
    io::Read,
    sync::atomic::AtomicBool,
    time::{Duration, Instant},
};

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "vhdx-export-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn submit(worker: &Worker, context: u64, value: Value) -> mpsc::Receiver<Value> {
    let (reply, receive) = mpsc::sync_channel(1);
    if let Err(error) = worker.enqueue(
        context,
        serde_json::from_value(value).unwrap(),
        reply.clone(),
    ) {
        reply.send(error).unwrap();
    }
    receive
}
fn receive(reply: mpsc::Receiver<Value>) -> Value {
    reply
        .recv_timeout(Duration::from_secs(10))
        .expect("reader did not respond")
}
fn call(worker: &Worker, context: u64, value: Value) -> Value {
    let result = receive(submit(worker, context, value));
    assert_eq!(result["ok"], true, "{result}");
    result
}
fn open(worker: &Worker, context: u64) -> u64 {
    let image = std::env::var("VHDX_READ_FIXTURE").expect("VHDX_READ_FIXTURE");
    let opened = call(worker, context, json!({"op":"open","path":image}));
    let session = opened["session"].as_u64().unwrap();
    call(
        worker,
        context,
        json!({"op":"unlock","session":session,"partition":1,"mode":"none"}),
    );
    session
}
fn export_request(session: u64, output: &Path) -> Value {
    json!({"op":"export","session":session,"path":"/payload.bin","output":output})
}
fn expected_digest() -> Vec<u8> {
    let mut digest = Sha256::new();
    for i in 0..512 {
        digest.update(vec![(i % 251) as u8; 65536]);
    }
    digest.finalize().to_vec()
}
fn assert_payload(path: &Path) {
    let mut input = std::fs::File::open(path).unwrap();
    assert_eq!(input.metadata().unwrap().len(), 32 * 1024 * 1024);
    let mut digest = Sha256::new();
    let mut bytes = Zeroizing::new(vec![0; 65536]);
    loop {
        let n = input.read(&mut bytes).unwrap();
        if n == 0 {
            break;
        }
        digest.update(&bytes[..n]);
    }
    assert_eq!(digest.finalize().to_vec(), expected_digest());
}

#[test]
fn cancellation_tracks_yielded_export_without_cancelling_another_context() {
    let export = Cancellation::default();
    let foreground = Cancellation::default();
    let active = ActiveWork {
        current: Some((2, foreground.clone())),
        exports: HashMap::from([(1, export.clone())]),
        ..ActiveWork::default()
    };
    active.cancel(1);
    assert!(export.check().is_err());
    assert!(foreground.check().is_ok());
    active.cancel(99);
    assert!(foreground.check().is_ok());
}

#[test]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn export_finishes_under_foreground_load_and_preserves_hash_and_existing_files() {
    let worker = Worker::start().unwrap();
    let session = open(&worker, 101);
    open(&worker, 102);
    let scratch = Scratch::new();
    let output = scratch.0.join("payload.bin");
    let stop = Arc::new(AtomicBool::new(false));
    let count = Arc::new(AtomicU64::new(0));
    thread::scope(|scope| {
        // Keep enough commands queued to exercise the foreground burst limit.
        for _ in 0..6 {
            let stop = stop.clone();
            let count = count.clone();
            let worker = &worker;
            scope.spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    call(worker, 102, json!({"op":"disk_cache_status"}));
                    count.fetch_add(1, Ordering::Relaxed);
                }
            });
        }
        let start = Instant::now();
        let result = submit(&worker, 101, export_request(session, &output))
            .recv_timeout(Duration::from_secs(10));
        stop.store(true, Ordering::Relaxed);
        assert_eq!(result.unwrap()["ok"], true);
        eprintln!(
            "export under foreground load: {:?}, {} commands",
            start.elapsed(),
            count.load(Ordering::Relaxed)
        );
    });
    assert!(count.load(Ordering::Relaxed) > 4);
    assert_payload(&output);
    let result = receive(submit(&worker, 101, export_request(session, &output)));
    assert_eq!(result["error"]["code"], "exists");
    assert_payload(&output);
    let small = scratch.0.join("small.txt");
    let result = call(
        &worker,
        101,
        json!({"op":"export","session":session,"path":"/file-0000.txt","output":small}),
    );
    assert_eq!(result["data"]["size"], 25);
    assert_eq!(std::fs::read(small).unwrap(), b"Read performance fixture\n");
}

fn state_for(image: &Path) -> State {
    let mut state = State::new();
    let cancel = Cancellation::default();
    let opened = state.handle(
        &serde_json::from_value(json!({"op":"open","path":image})).unwrap(),
        &cancel,
    );
    assert_eq!(opened["ok"], true, "{opened}");
    let unlocked = state.handle(
        &serde_json::from_value(json!({
            "op":"unlock","session":state.generation,"partition":1,"mode":"none"
        }))
        .unwrap(),
        &cancel,
    );
    assert_eq!(unlocked["ok"], true, "{unlocked}");
    state
}
fn finish(transfer: &mut export::Transfer, wakes: &mpsc::Receiver<WorkItem>) -> Result<Value> {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        assert!(Instant::now() < deadline, "export cleanup stalled");
        match transfer.step() {
            export::Step::Finished(result) => return result,
            export::Step::Progress => {}
            export::Step::Waiting => {
                let _ = wakes.recv_timeout(Duration::from_millis(10));
            }
        }
    }
}
#[test]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn cancelled_export_cleans_partial_path_before_response_and_allows_retry() {
    let image = PathBuf::from(std::env::var("VHDX_READ_FIXTURE").unwrap());
    let state = state_for(&image);
    let scratch = Scratch::new();
    let output = scratch.0.join("cancelled.bin");
    for after_read in [false, true] {
        let request = serde_json::from_value(export_request(state.generation, &output)).unwrap();
        let (wake, wakes) = mpsc::sync_channel(8);
        let token = Cancellation::default();
        let mut transfer = export::Transfer::start(&state, &request, token.clone(), wake).unwrap();
        if after_read {
            assert!(matches!(transfer.step(), export::Step::Progress));
        }
        token.cancel();
        assert!(matches!(
            finish(&mut transfer, &wakes),
            Err(Error::Cancelled)
        ));
        assert!(!output.exists());
        assert!(state.volume.is_some());
    }
}
#[test]
#[cfg(unix)]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn source_failure_removes_partial_export_without_touching_original_image() {
    let scratch = Scratch::new();
    let copy = scratch.0.join("source.vhdx");
    std::fs::copy(std::env::var("VHDX_READ_FIXTURE").unwrap(), &copy).unwrap();
    let state = state_for(&copy);
    let output = scratch.0.join("partial.bin");
    let request = serde_json::from_value(export_request(state.generation, &output)).unwrap();
    let (wake, wakes) = mpsc::sync_channel(8);
    let mut transfer =
        export::Transfer::start(&state, &request, Cancellation::default(), wake).unwrap();
    assert!(matches!(transfer.step(), export::Step::Progress));
    // Unix permits truncating an open source; Windows deliberately denies writers.
    #[cfg(unix)]
    {
        std::fs::File::options()
            .write(true)
            .open(copy)
            .unwrap()
            .set_len(0)
            .unwrap();
        assert!(finish(&mut transfer, &wakes).is_err());
        assert!(!output.exists());
    }
}

#[cfg(unix)]
struct BlockedExport {
    socket: std::os::unix::net::UnixStream,
    reply: mpsc::Receiver<Value>,
}
#[cfg(unix)]
fn blocked_export(worker: &Worker, context: u64, session: u64) -> BlockedExport {
    use std::os::fd::AsRawFd;
    let (writer, mut socket) = std::os::unix::net::UnixStream::pair().unwrap();
    writer
        .set_write_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let reply = submit(
        worker,
        context,
        json!({
            "op":"export","session":session,"path":"/payload.bin","output":"",
            "output_fd":writer.as_raw_fd()
        }),
    );
    // Receiving real data proves the FD was duplicated and export has started.
    socket.read_exact(&mut [0]).unwrap();
    drop(writer);
    BlockedExport { socket, reply }
}
#[cfg(unix)]
fn drain(mut blocked: BlockedExport) -> Value {
    std::io::copy(&mut blocked.socket, &mut std::io::sink()).unwrap();
    receive(blocked.reply)
}
#[test]
#[cfg(unix)]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn blocked_target_keeps_directory_pdf_media_and_other_export_responsive() {
    let worker = Worker::start().unwrap();
    let a = open(&worker, 201);
    let b = open(&worker, 202);
    let blocked = blocked_export(&worker, 201, a);
    let start = Instant::now();
    call(
        &worker,
        202,
        json!({"op":"list","session":b,"path":"/","start":0,"limit":200}),
    );
    let file = call(
        &worker,
        202,
        json!({"op":"file_open","session":b,"path":"/payload.bin"}),
    );
    let read = call(
        &worker,
        202,
        json!({"op":"file_read","session":b,"file":file["data"]["file"],"offset":65536,"length":65536}),
    );
    assert_eq!(
        STANDARD
            .decode(read["data"]["bytes"].as_str().unwrap())
            .unwrap(),
        vec![1; 65536]
    );
    let media = call(
        &worker,
        202,
        json!({"op":"media_open","session":b,"path":"/payload.bin","transport":"native"}),
    );
    let (reply, result) = mpsc::sync_channel(1);
    worker
        .sender
        .send(WorkItem::Read(MediaRead {
            context: 202,
            session: b,
            file: media["data"]["file"].as_u64().unwrap(),
            offset: 131072,
            length: 65536,
            reply,
            cancel: Cancellation::default(),
            revoked: Cancellation::default(),
            task: None,
        }))
        .unwrap();
    let bytes = result
        .recv_timeout(Duration::from_secs(2))
        .unwrap()
        .unwrap();
    assert_eq!(&*bytes, &vec![2; 65536]);
    assert!(start.elapsed() < Duration::from_secs(2));
    assert!(matches!(
        blocked.reply.try_recv(),
        Err(mpsc::TryRecvError::Empty)
    ));
    let scratch = Scratch::new();
    let output = scratch.0.join("parallel.bin");
    call(&worker, 202, export_request(b, &output));
    assert_payload(&output);
    worker.active.lock().unwrap().cancel(201);
    assert_eq!(drain(blocked)["error"]["code"], "cancelled");
    call(&worker, 202, json!({"op":"dispose"}));
}
#[test]
#[cfg(unix)]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn lock_close_dispose_and_reunlock_revoke_yielded_exports() {
    for operation in ["lock", "close", "dispose", "unlock"] {
        let worker = Worker::start().unwrap();
        let session = open(&worker, 301);
        let blocked = blocked_export(&worker, 301, session);
        let request = if operation == "unlock" {
            json!({"op":operation,"session":session,"partition":1,"mode":"none"})
        } else if operation == "dispose" {
            json!({"op":operation})
        } else {
            json!({"op":operation,"session":session})
        };
        call(&worker, 301, request);
        assert!(worker.active.lock().unwrap().exports[&301].check().is_err());
        let response = drain(blocked);
        assert_eq!(response["ok"], false);
        assert_eq!(
            response["error"]["code"],
            if operation == "dispose" {
                "closed"
            } else {
                "cancelled"
            }
        );
    }
}
#[test]
#[cfg(unix)]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn retirement_waits_for_target_cleanup_but_keeps_new_engine_responsive() {
    let worker = Worker::start().unwrap();
    let old = open(&worker, 401);
    let new = open(&worker, 402);
    let blocked = blocked_export(&worker, 401, old);
    let (reply, retired) = mpsc::sync_channel(1);
    worker
        .sender
        .send(WorkItem::Retire { before: 402, reply })
        .unwrap();
    call(
        &worker,
        402,
        json!({"op":"list","session":new,"path":"/","start":0,"limit":1}),
    );
    assert!(matches!(retired.try_recv(), Err(mpsc::TryRecvError::Empty)));
    assert_eq!(drain(blocked)["error"]["code"], "closed");
    retired.recv_timeout(Duration::from_secs(2)).unwrap();
    assert_eq!(
        receive(submit(&worker, 401, json!({"op":"dispose"})))["error"]["code"],
        "closed"
    );
}
#[test]
#[cfg(unix)]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn export_limit_rejects_extra_tasks_before_creating_destinations() {
    let worker = Worker::start().unwrap();
    let mut blocked = Vec::new();
    for context in 501..=504 {
        let session = open(&worker, context);
        blocked.push((context, session, blocked_export(&worker, context, session)));
    }
    let fifth = open(&worker, 505);
    let scratch = Scratch::new();
    let output = scratch.0.join("not-created.bin");
    for (context, session) in [(501, blocked[0].1), (505, fifth)] {
        assert_eq!(
            receive(submit(&worker, context, export_request(session, &output)))["error"]["code"],
            "busy"
        );
        assert!(!output.exists());
    }
    for (context, _, item) in blocked {
        worker.active.lock().unwrap().cancel(context);
        assert_eq!(drain(item)["error"]["code"], "cancelled");
    }
}

#[test]
#[cfg(target_os = "linux")]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn target_write_failure_does_not_lock_source_or_leak_export_slot() {
    use std::os::fd::AsRawFd;
    let worker = Worker::start().unwrap();
    let session = open(&worker, 601);
    let full = std::fs::File::options()
        .write(true)
        .open("/dev/full")
        .unwrap();
    let result = receive(submit(
        &worker,
        601,
        json!({
            "op":"export","session":session,"path":"/payload.bin","output":"","output_fd":full.as_raw_fd()
        }),
    ));
    assert_eq!(result["error"]["code"], "io");
    assert_eq!(result["invalidated"], false);
    assert!(!worker.active.lock().unwrap().exports.contains_key(&601));
    call(
        &worker,
        601,
        json!({"op":"read","session":session,"path":"/file-0000.txt","offset":0,"length":64}),
    );
}

#[test]
fn queued_export_cancellation_and_failed_admission_release_reservations() {
    let (sender, receiver) = mpsc::sync_channel(1);
    let worker = Worker {
        sender: Arc::new(sender),
        active: Arc::new(Mutex::new(ActiveWork::default())),
    };
    let (reply, _) = mpsc::sync_channel(1);
    let request = || serde_json::from_value(export_request(1, Path::new("unused.bin"))).unwrap();
    worker.enqueue(701, request(), reply.clone()).unwrap();
    worker.active.lock().unwrap().cancel(701);
    assert!(worker.enqueue(701, request(), reply.clone()).is_err());
    // The queue is full: a failed enqueue must return its reserved slot.
    assert!(worker.enqueue(702, request(), reply.clone()).is_err());
    assert!(!worker.active.lock().unwrap().exports.contains_key(&702));
    let WorkItem::Command(job) = receiver.recv().unwrap() else {
        panic!("expected command");
    };
    assert!(matches!(job.cancel.check(), Err(Error::Cancelled)));
    assert!(worker.active.lock().unwrap().exports.contains_key(&701));
    drop(receiver);
    assert!(worker.enqueue(703, request(), reply).is_err());
    assert!(!worker.active.lock().unwrap().exports.contains_key(&703));
}
