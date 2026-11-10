//! Synthetic managed cache files; metadata/maintenance benchmark, not disk read throughput.
use serde_json::{json, Value};
use std::{
    fs::{self, File, FileTimes},
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant, UNIX_EPOCH},
};
use vhdx_app::{request_context, vhdx_context_create};

fn call(id: u64, value: Value) -> Value {
    let result = request_context(id, value.to_string().as_bytes());
    assert_eq!(result["ok"], true, "{result}");
    result
}
fn config(root: &Path, max: u64, days: u32, enabled: bool) -> Value {
    json!({"op":"disk_cache_configure","directory":root,"cache_enabled":true,"enabled":enabled,"max_gib":max,"retention_days":days})
}
fn seed(root: &Path, count: usize) {
    fs::create_dir(root).unwrap();
    for i in 0..count {
        let file = File::create(root.join(format!("{i:064x}.block"))).unwrap();
        // No cache read is attempted: only real directory/metadata/deletion costs
        // matter here. Only logical length is set; physical allocation depends on the host filesystem.
        file.set_len(65536 + 40).unwrap();
        file.set_times(FileTimes::new().set_modified(UNIX_EPOCH))
            .unwrap();
    }
    fs::write(root.join("keep.txt"), b"unmanaged").unwrap();
    fs::write(root.join(format!("{}.tmp", "f".repeat(64))), b"interrupted").unwrap();
}
fn percentile(values: &mut [f64], p: f64) -> f64 {
    if values.is_empty() {
        return 0.;
    }
    values.sort_by(f64::total_cmp);
    values[((values.len() as f64 * p).ceil() as usize).saturating_sub(1)]
}
fn memory() -> Value {
    #[cfg(target_os = "linux")]
    {
        let status = fs::read_to_string("/proc/self/status").unwrap();
        let bytes = |name: &str| {
            status
                .lines()
                .find(|s| s.starts_with(name))
                .unwrap()
                .split_whitespace()
                .nth(1)
                .unwrap()
                .parse::<u64>()
                .unwrap()
                * 1024
        };
        json!({"rss_bytes":bytes("VmRSS:"),"peak_rss_bytes":bytes("VmHWM:")})
    }
    #[cfg(windows)]
    {
        use std::ffi::c_void;
        #[repr(C)]
        #[derive(Default)]
        struct Counters {
            cb: u32,
            faults: u32,
            peak: usize,
            working: usize,
            peak_paged: usize,
            paged: usize,
            peak_nonpaged: usize,
            nonpaged: usize,
            pagefile: usize,
            peak_pagefile: usize,
        }
        #[link(name = "kernel32")]
        extern "system" {
            fn GetCurrentProcess() -> *mut c_void;
        }
        #[link(name = "psapi")]
        extern "system" {
            fn GetProcessMemoryInfo(
                process: *mut c_void,
                counters: *mut Counters,
                size: u32,
            ) -> i32;
        }
        let mut counters = Counters {
            cb: std::mem::size_of::<Counters>() as u32,
            ..Counters::default()
        };
        let success = unsafe {
            GetProcessMemoryInfo(
                GetCurrentProcess(),
                &mut counters,
                std::mem::size_of::<Counters>() as u32,
            )
        };
        assert_ne!(success, 0);
        json!({"rss_bytes":counters.working,"peak_rss_bytes":counters.peak})
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        Value::Null
    }
}

fn measure(
    id: u64,
    probe: u64,
    request: Value,
    name: &str,
    count: usize,
    round: usize,
    mixed: bool,
) -> Value {
    let done = Arc::new(AtomicBool::new(false));
    let started = Arc::new(AtomicBool::new(false));
    let mut delays = Vec::new();
    let result = thread::scope(|scope| {
        let finished = done.clone();
        let entered = started.clone();
        let admin = scope.spawn(move || {
            let clock = Instant::now();
            entered.store(true, Ordering::Release);
            let response = call(id, request);
            let ms = clock.elapsed().as_secs_f64() * 1000.;
            finished.store(true, Ordering::Release);
            (ms, response)
        });
        while !started.load(Ordering::Acquire) {
            thread::yield_now();
        }
        // Begin probes after giving the admin thread a chance to enter the queue.
        thread::sleep(Duration::from_millis(1));
        if mixed {
            while !done.load(Ordering::Acquire) {
                let clock = Instant::now();
                call(probe, json!({"op":"disk_cache_status"}));
                delays.push(clock.elapsed().as_secs_f64() * 1000.);
                thread::sleep(Duration::from_micros(200));
            }
        }
        admin.join().unwrap()
    });
    let status = call(probe, json!({"op":"disk_cache_status"}))["data"].clone();
    let first = delays.first().copied().unwrap_or(0.);
    let probes = delays.len();
    println!(
        "{}",
        json!({"round":round,"input_entries":count,"operation":name,"mode":if mixed {"mixed"} else {"isolated"},"elapsed_ms":result.0,"first_probe_ms":first,"probe_p95_ms":percentile(&mut delays,0.95),"probe_max_ms":percentile(&mut delays,1.),"probes":probes,"status":status,"memory":memory()})
    );
    status
}
fn main() {
    let args: Vec<_> = std::env::args().collect();
    assert_eq!(
        args.len(),
        5,
        "disk_cache_benchmark <new scratch path> <count> <round> <mixed|isolated>"
    );
    let root = Path::new(&args[1]);
    fs::create_dir(root).unwrap();
    let count: usize = args[2].parse().unwrap();
    let round: usize = args[3].parse().unwrap();
    let mixed = args[4] == "mixed";
    let id = vhdx_context_create();
    let probe = vhdx_context_create();
    let cache = root.join("cache");
    seed(&cache, count);
    let scanned = measure(
        id,
        probe,
        config(&cache, 128, 0, true),
        "scan",
        count,
        round,
        mixed,
    );
    assert!(!cache.join(format!("{}.tmp", "f".repeat(64))).exists());
    let files = fs::read_dir(&cache)
        .unwrap()
        .filter(|e| {
            e.as_ref()
                .unwrap()
                .path()
                .extension()
                .is_some_and(|x| x == "block")
        })
        .count();
    assert_eq!(scanned["entries"].as_u64().unwrap(), files as u64);
    if let Some(limit) = scanned["limit_entries"].as_u64() {
        assert!(files as u64 <= limit);
    }
    // Reopen the same physical blocks with a fresh manager/lock, checking restart accounting.
    call(id, config(&root.join("unused"), 8, 0, false));
    let reopened = measure(
        id,
        probe,
        config(&cache, 128, 0, true),
        "reopen",
        count,
        round,
        mixed,
    );
    assert_eq!(scanned["entries"], reopened["entries"]);
    assert_eq!(scanned["bytes"], reopened["bytes"]);
    let small = measure(
        id,
        probe,
        config(&cache, 1, 0, true),
        "shrink",
        count,
        round,
        mixed,
    );
    assert!(small["bytes"].as_u64().unwrap() <= 1 << 30);
    let expired = measure(
        id,
        probe,
        config(&cache, 1, 1, true),
        "expire",
        count,
        round,
        mixed,
    );
    assert_eq!(expired["entries"], 0);
    call(id, config(&root.join("unused"), 8, 0, false));
    let clear = root.join("clear");
    seed(&clear, count);
    call(id, config(&clear, 128, 0, true));
    let cleared = measure(
        id,
        probe,
        json!({"op":"disk_cache_clear"}),
        "clear",
        count,
        round,
        mixed,
    );
    assert_eq!(cleared["bytes"], 0);
    assert!(clear.join("keep.txt").exists());
    call(id, config(&root.join("unused"), 8, 0, false));
    call(id, json!({"op":"dispose"}));
    call(probe, json!({"op":"dispose"}));
    fs::remove_dir_all(root).unwrap();
}
