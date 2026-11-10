//! PERF-04 native NTFS/BitLocker cache-path benchmark. Uses real sources,
//! verifies every returned byte, and includes draining write-back in total time.
use serde_json::{json, Value};
use std::{
    cell::{Cell, RefCell},
    fs,
    path::Path,
    rc::Rc,
    time::Instant,
};
use vhdx_core::{
    disk_cache::DiskCache,
    native::Runtime,
    session::{Cancellation, Image},
    source::{LocalFile, ReadAt},
};
use zeroize::Zeroizing;

struct Counted {
    source: LocalFile,
    calls: Cell<u64>,
    bytes: Cell<u64>,
}
impl ReadAt for Counted {
    fn len(&self) -> u64 {
        self.source.len()
    }
    fn read_at(&self, offset: u64, out: &mut [u8]) -> vhdx_core::Result<usize> {
        let n = self.source.read_at(offset, out)?;
        self.calls.set(self.calls.get() + 1);
        self.bytes.set(self.bytes.get() + n as u64);
        Ok(n)
    }
}
fn drain(cache: &Rc<RefCell<DiskCache>>) {
    while cache.borrow_mut().advance_write_buffer() {}
}
fn percentile(values: &mut [f64], p: f64) -> f64 {
    values.sort_by(f64::total_cmp);
    values[((values.len() as f64 * p).ceil() as usize).saturating_sub(1)]
}
fn resources() -> Value {
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
        #[repr(C)]
        #[derive(Default)]
        struct Time {
            low: u32,
            high: u32,
        }
        impl Time {
            fn ms(&self) -> f64 {
                ((u64::from(self.high) << 32) | u64::from(self.low)) as f64 / 10000.
            }
        }
        #[link(name = "kernel32")]
        extern "system" {
            fn GetCurrentProcess() -> *mut c_void;
            fn GetProcessTimes(
                process: *mut c_void,
                created: *mut Time,
                exit: *mut Time,
                kernel: *mut Time,
                user: *mut Time,
            ) -> i32;
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
        let (mut created, mut exit, mut kernel, mut user) = (
            Time::default(),
            Time::default(),
            Time::default(),
            Time::default(),
        );
        unsafe {
            assert_ne!(
                GetProcessMemoryInfo(
                    GetCurrentProcess(),
                    &mut counters,
                    std::mem::size_of::<Counters>() as u32
                ),
                0
            );
            assert_ne!(
                GetProcessTimes(
                    GetCurrentProcess(),
                    &mut created,
                    &mut exit,
                    &mut kernel,
                    &mut user
                ),
                0
            );
        }
        json!({"rss_bytes":counters.working,"peak_rss_bytes":counters.peak,"cpu_ms":kernel.ms()+user.ms()})
    }
    #[cfg(target_os = "linux")]
    {
        static TICKS: std::sync::OnceLock<f64> = std::sync::OnceLock::new();
        let hz = *TICKS.get_or_init(|| {
            String::from_utf8(
                std::process::Command::new("getconf")
                    .arg("CLK_TCK")
                    .output()
                    .unwrap()
                    .stdout,
            )
            .unwrap()
            .trim()
            .parse()
            .unwrap()
        });
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
        let stat = fs::read_to_string("/proc/self/stat").unwrap();
        let fields: Vec<_> = stat
            .rsplit_once(") ")
            .unwrap()
            .1
            .split_whitespace()
            .collect();
        let cpu =
            (fields[11].parse::<f64>().unwrap() + fields[12].parse::<f64>().unwrap()) / hz * 1000.;
        json!({"rss_bytes":bytes("VmRSS:"),"peak_rss_bytes":bytes("VmHWM:"),"cpu_ms":cpu})
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        json!({"cpu_ms":0})
    }
}
fn main() {
    let args: Vec<_> = std::env::args().collect();
    assert!((7..=8).contains(&args.len()),"cache_io_benchmark <image> <file> <new absolute scratch> <off|cold|disk|memory> <sequential|random> <round> [credential_file]");
    let mode = args[4].as_str();
    let pattern = args[5].as_str();
    assert!(["off", "cold", "disk", "memory"].contains(&mode));
    assert!(["sequential", "random"].contains(&pattern));
    let root = Path::new(&args[3]);
    assert!(root.is_absolute());
    fs::create_dir(root).unwrap();
    let runtime = Runtime::load(Path::new(&std::env::var("VHDX_NATIVE_DIR").unwrap())).unwrap();
    let credential = args
        .get(7)
        .map(|path| vhdx_core::credentials::from_file(Path::new(path), false).unwrap());
    let cancel = Cancellation::default();
    let expected = {
        let image = Image::from_source(
            runtime.clone(),
            Rc::new(LocalFile::open(Path::new(&args[1])).unwrap()),
        )
        .unwrap();
        let volume = image.unlock(1, credential.as_ref(), 64 << 20).unwrap();
        let file = volume.open_file(&args[2]).unwrap();
        let mut bytes = Zeroizing::new(vec![0; file.len() as usize]);
        for (index, chunk) in bytes.chunks_mut(256 * 1024).enumerate() {
            assert_eq!(
                file.read_at((index * 256 * 1024) as u64, chunk, &cancel)
                    .unwrap(),
                chunk.len()
            );
        }
        bytes
    };
    assert!(expected.len() >= 65536);
    let source = Rc::new(Counted {
        source: LocalFile::open(Path::new(&args[1])).unwrap(),
        calls: Cell::new(0),
        bytes: Cell::new(0),
    });
    let image = Image::from_source(runtime, source.clone()).unwrap();
    let mut manager = DiskCache::default();
    manager.set_write_buffering(true);
    manager
        .configure(&root.join("cache"), mode != "off", 1 << 30, 0)
        .unwrap();
    manager.control.set_enabled(mode != "off");
    let cache = Rc::new(RefCell::new(manager));
    let volume = image
        .unlock_with_disk_cache(
            1,
            credential.as_ref(),
            if mode == "memory" { 64 << 20 } else { 65536 },
            1 << 20,
            65536,
            Some((cache.clone(), "perf04-source".into())),
        )
        .unwrap();
    let file = volume.open_file(&args[2]).unwrap();
    drain(&cache);
    let mut out = Zeroizing::new(vec![0; 65536]);
    if ["disk", "memory"].contains(&mode) {
        for offset in (0..expected.len()).step_by(65536) {
            let n = (expected.len() - offset).min(out.len());
            assert_eq!(
                file.read_at(offset as u64, &mut out[..n], &cancel).unwrap(),
                n
            );
            assert_eq!(&out[..n], &expected[offset..offset + n]);
            drain(&cache);
        }
    } else if mode == "cold" {
        cache.borrow_mut().clear().unwrap();
    }
    source.calls.set(0);
    source.bytes.set(0);
    let before = serde_json::to_value(cache.borrow().status()).unwrap();
    let resources_before = resources();
    let mut timings = Vec::new();
    let mut bytes = 0u64;
    let mut max_queued = 0u64;
    let operations = if pattern == "sequential" {
        expected.len().div_ceil(65536)
    } else {
        2048
    };
    let mut random = 20261110u64;
    let clock = Instant::now();
    for i in 0..operations {
        random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
        let offset = if pattern == "sequential" {
            i * 65536
        } else {
            ((random >> 32) as usize % (expected.len() / 4096)) * 4096
        };
        let n = if pattern == "sequential" {
            (expected.len() - offset).min(65536)
        } else {
            4096
        };
        let start = Instant::now();
        assert_eq!(
            file.read_at(offset as u64, &mut out[..n], &cancel).unwrap(),
            n
        );
        timings.push(start.elapsed().as_secs_f64() * 1000.);
        assert_eq!(&out[..n], &expected[offset..offset + n]);
        bytes += n as u64;
        max_queued = max_queued.max(cache.borrow().status().pending_write_bytes as u64);
        // Match the app's sustained foreground burst: a write-back quantum
        // after every four operations, plus a final drain counted in elapsed.
        if i % 4 == 3 {
            cache.borrow_mut().advance_write_buffer();
        }
    }
    let foreground_ms = clock.elapsed().as_secs_f64() * 1000.;
    drain(&cache);
    let elapsed = clock.elapsed().as_secs_f64() * 1000.;
    let after = serde_json::to_value(cache.borrow().status()).unwrap();
    let mut io = serde_json::Map::new();
    for (key, value) in after["io"].as_object().unwrap() {
        io.insert(
            key.clone(),
            json!(value
                .as_u64()
                .unwrap()
                .saturating_sub(before["io"][key].as_u64().unwrap_or(0))),
        );
    }
    let resource = resources();
    println!(
        "{}",
        json!({"round":args[6].parse::<u32>().unwrap(),"mode":mode,"pattern":pattern,"file_bytes":expected.len(),"bytes_read":bytes,"elapsed_ms":elapsed,"before_final_drain_ms":foreground_ms,"mib_per_second":bytes as f64/1048576./(elapsed/1000.),"read_p50_ms":percentile(&mut timings,0.5),"read_p95_ms":percentile(&mut timings,0.95),"read_max_ms":percentile(&mut timings,1.),"source_calls":source.calls.get(),"source_bytes":source.bytes.get(),"io":io,"max_pending_bytes":max_queued,"resources":resource,"cpu_ms":resource["cpu_ms"].as_f64().unwrap()-resources_before["cpu_ms"].as_f64().unwrap()})
    );
    drop(file);
    drop(volume);
    drop(image);
    drop(cache);
    fs::remove_dir_all(root).unwrap();
}
