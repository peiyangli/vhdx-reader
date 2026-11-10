use super::*;
use std::{fs, time::Duration};

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "vhdx-cache-jobs-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        for i in 0..2048 {
            fs::write(root.join(format!("{i:064x}.block")), [0; 104]).unwrap();
        }
        Self(root)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn submit(worker: &Worker, id: u64, request: Value) -> mpsc::Receiver<Value> {
    let (reply, result) = mpsc::sync_channel(1);
    if let Err(e) = worker.enqueue(id, serde_json::from_value(request).unwrap(), reply.clone()) {
        reply.send(e).unwrap();
    }
    result
}
fn receive(reply: mpsc::Receiver<Value>) -> Value {
    reply.recv_timeout(Duration::from_secs(15)).unwrap()
}
fn configure(root: &Path) -> Value {
    json!({"op":"disk_cache_configure","directory":root,"cache_enabled":true,"enabled":true,"max_gib":128,"retention_days":0})
}
fn status(worker: &Worker) -> Value {
    receive(submit(worker, 2, json!({"op":"disk_cache_status"})))["data"].clone()
}
fn release_cache(worker: &Worker, root: &Path) {
    let mut value = configure(&root.join("unused"));
    value["enabled"] = false.into();
    assert_eq!(receive(submit(worker, 2, value))["ok"], true);
}

#[test]
fn scan_and_clear_yield_to_foreground_and_cancel_between_batches() {
    let root = Scratch::new();
    let worker = Worker::start().unwrap();
    let scan = submit(&worker, 1, configure(&root.0));
    assert_eq!(
        receive(submit(&worker, 3, configure(&root.0)))["error"]["code"],
        "busy"
    );
    assert_eq!(status(&worker)["maintenance_pending"], true);
    assert!(matches!(scan.try_recv(), Err(mpsc::TryRecvError::Empty)));
    worker.active.lock().unwrap().cancel(1);
    assert_eq!(receive(scan)["error"]["code"], "cancelled");
    assert_eq!(status(&worker)["maintenance_pending"], false);
    let scan = submit(&worker, 1, configure(&root.0));
    let mut probes = 0;
    let result = loop {
        if let Ok(result) = scan.try_recv() {
            break result;
        }
        status(&worker);
        probes += 1;
        assert!(probes < 100_000);
    };
    assert_eq!(result["ok"], true);
    assert!(
        probes > 4,
        "foreground must make progress while scan is pending"
    );
    assert_eq!(status(&worker)["entries"], 2048);
    assert_eq!(status(&worker)["limit_entries"], 65536);
    let clear = submit(&worker, 1, json!({"op":"disk_cache_clear"}));
    assert_eq!(status(&worker)["maintenance_pending"], true);
    worker.active.lock().unwrap().cancel(1);
    assert_eq!(receive(clear)["error"]["code"], "cancelled");
    assert!(status(&worker)["entries"].as_u64().unwrap() > 0);
    assert_eq!(
        receive(submit(&worker, 1, json!({"op":"disk_cache_clear"})))["ok"],
        true
    );
    assert_eq!(status(&worker)["entries"], 0);
    release_cache(&worker, &root.0);
}

#[test]
fn dispose_and_engine_retirement_close_yielded_cache_jobs() {
    for retire in [false, true] {
        let root = Scratch::new();
        let worker = Worker::start().unwrap();
        let scan = submit(&worker, 1, configure(&root.0));
        assert_eq!(status(&worker)["maintenance_pending"], true);
        if retire {
            let (reply, done) = mpsc::sync_channel(1);
            worker
                .sender
                .send(WorkItem::Retire { before: 2, reply })
                .unwrap();
            done.recv_timeout(Duration::from_secs(5)).unwrap();
        } else {
            assert_eq!(
                receive(submit(&worker, 1, json!({"op":"dispose"})))["ok"],
                true
            );
        }
        assert_eq!(receive(scan)["error"]["code"], "closed");
        assert_eq!(status(&worker)["maintenance_pending"], false);
        assert_eq!(receive(submit(&worker, 2, configure(&root.0)))["ok"], true);
        release_cache(&worker, &root.0);
    }
}

#[test]
fn queued_cache_cancel_and_full_queue_release_admission() {
    let (sender, _receiver) = mpsc::sync_channel(1);
    let worker = Worker {
        sender: Arc::new(sender),
        active: Arc::new(Mutex::new(ActiveWork::default())),
    };
    let (reply, _result) = mpsc::sync_channel(1);
    worker
        .enqueue(7, Request::DiskCacheClear, reply.clone())
        .unwrap();
    let token = worker
        .active
        .lock()
        .unwrap()
        .cache_maintenance
        .as_ref()
        .unwrap()
        .1
        .clone();
    worker.active.lock().unwrap().cancel(7);
    assert!(token.check().is_err());
    // Simulate dispatch completion, then verify a failed queue admission leaves no reservation.
    worker.active.lock().unwrap().cache_maintenance = None;
    assert!(worker.enqueue(8, Request::DiskCacheClear, reply).is_err());
    assert!(worker.active.lock().unwrap().cache_maintenance.is_none());
}

#[test]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn native_directory_and_file_reads_progress_during_cache_scan_and_clear() {
    let root = Scratch::new();
    let worker = Worker::start().unwrap();
    let image = std::env::var("VHDX_READ_FIXTURE").unwrap();
    let opened = receive(submit(&worker, 9, json!({"op":"open","path":image})));
    assert_eq!(opened["ok"], true);
    let session = opened["session"].clone();
    assert_eq!(
        receive(submit(
            &worker,
            9,
            json!({"op":"unlock","session":session,"partition":1,"mode":"none"})
        ))["ok"],
        true
    );
    for request in [configure(&root.0), json!({"op":"disk_cache_clear"})] {
        let job = submit(&worker, 1, request);
        let list = receive(submit(
            &worker,
            9,
            json!({"op":"list","session":session,"path":"/","start":0,"limit":200,"show_system":false}),
        ));
        assert_eq!(list["ok"], true, "{list}");
        let read = receive(submit(
            &worker,
            9,
            json!({"op":"read","session":session,"path":"/file-0000.txt","offset":0,"length":100}),
        ));
        assert_eq!(read["ok"], true, "{read}");
        assert_eq!(
            read["data"]["bytes"],
            STANDARD.encode(b"Read performance fixture\n")
        );
        assert!(matches!(job.try_recv(), Err(mpsc::TryRecvError::Empty)));
        assert_eq!(receive(job)["ok"], true);
    }
    receive(submit(&worker, 9, json!({"op":"dispose"})));
    release_cache(&worker, &root.0);
}
