//! Generated 32 MiB fixture: export throughput and concurrent directory/PDF/media
//! data latency. No GUI, PDF rendering or media decoding is included.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    ffi::CString,
    io::Read,
    path::Path,
    ptr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};
use vhdx_app::{request_context, vhdx_context_create, vhdx_mpv_open, MpvStreamInfo};
use zeroize::Zeroizing;

fn call(context: u64, value: Value) -> Value {
    let reply = request_context(context, value.to_string().as_bytes());
    assert_eq!(reply["ok"], true, "{reply}");
    reply
}
fn open(image: &str) -> (u64, u64) {
    let context = vhdx_context_create();
    let session = call(context, json!({"op":"open","path":image}))["session"]
        .as_u64()
        .unwrap();
    call(
        context,
        json!({"op":"unlock","session":session,"partition":1,"mode":"none"}),
    );
    (context, session)
}
struct Stream(MpvStreamInfo);
impl Drop for Stream {
    fn drop(&mut self) {
        unsafe { self.0.close_fn.unwrap()(self.0.cookie) }
    }
}
fn percentile(samples: &mut [f64], p: f64) -> f64 {
    samples.sort_by(f64::total_cmp);
    if samples.is_empty() {
        0.0
    } else {
        samples[((samples.len() as f64 * p).ceil() as usize).saturating_sub(1)]
    }
}
fn digest(path: &Path) -> Vec<u8> {
    let mut file = std::fs::File::open(path).unwrap();
    let mut bytes = Zeroizing::new(vec![0u8; 65536]);
    let mut hash = Sha256::new();
    loop {
        let n = file.read(&mut bytes).unwrap();
        if n == 0 {
            break;
        }
        hash.update(&bytes[..n]);
    }
    hash.finalize().to_vec()
}
fn main() {
    let args: Vec<_> = std::env::args().collect();
    assert_eq!(
        args.len(),
        4,
        "export_benchmark <generated read fixture> <output directory> <isolated|mixed>"
    );
    let mixed = match args[3].as_str() {
        "mixed" => true,
        "isolated" => false,
        _ => panic!("invalid mode"),
    };
    let rounds: usize = std::env::var("VHDX_BENCH_ROUNDS")
        .unwrap_or("5".into())
        .parse()
        .unwrap();
    assert!((1..=100).contains(&rounds));
    std::fs::create_dir_all(&args[2]).unwrap();
    let mut expected = Sha256::new();
    for i in 0..512 {
        expected.update(vec![(i % 251) as u8; 65536]);
    }
    let expected = expected.finalize().to_vec();
    println!("round,mode,export_ms,mib_s,probe_count,directory_p50_ms,directory_p95_ms,pdf_read_p50_ms,pdf_read_p95_ms,media_read_p50_ms,media_read_p95_ms,directory_first_ms");
    for round in 0..rounds {
        let (exporter, session) = open(&args[1]);
        let (browser, browser_session) = open(&args[1]);
        let file = call(
            browser,
            json!({"op":"file_open","session":browser_session,"path":"/payload.bin"}),
        )["data"]["file"]
            .clone();
        let media = call(
            browser,
            json!({"op":"media_open","session":browser_session,"path":"/payload.bin","transport":"native"}),
        );
        let uri = CString::new(media["data"]["url"].as_str().unwrap()).unwrap();
        let mut info = MpvStreamInfo::default();
        assert_eq!(
            unsafe { vhdx_mpv_open(ptr::null_mut(), uri.as_ptr().cast_mut(), &mut info) },
            0
        );
        let stream = Stream(info);
        let output = Path::new(&args[2]).join(format!("export-{}-{round}.bin", std::process::id()));
        assert!(!output.exists());
        let done = Arc::new(AtomicBool::new(false));
        let finished = done.clone();
        let target = output.clone();
        let start = Instant::now();
        let export = thread::spawn(move || {
            let response = call(
                exporter,
                json!({"op":"export","session":session,"path":"/payload.bin","output":target}),
            );
            assert_eq!(response["data"]["size"], 32 * 1024 * 1024);
            let elapsed = start.elapsed().as_secs_f64();
            finished.store(true, Ordering::Release);
            elapsed
        });
        let mut directory = Vec::new();
        let mut pdf = Vec::new();
        let mut media_times = Vec::new();
        if mixed {
            // Start probes after real target progress, never before export begins.
            while !done.load(Ordering::Acquire) && !output.metadata().is_ok_and(|m| m.len() > 0) {
                assert!(start.elapsed() < Duration::from_secs(30));
                thread::sleep(Duration::from_micros(100));
            }
            let mut bytes = Zeroizing::new(vec![0u8; 65536]);
            loop {
                let t = Instant::now();
                call(
                    browser,
                    json!({"op":"list","session":browser_session,"path":"/","start":0,"limit":20}),
                );
                directory.push(t.elapsed().as_secs_f64() * 1000.0);
                let t = Instant::now();
                call(
                    browser,
                    json!({"op":"file_read","session":browser_session,"file":file,"offset":65536,"length":65536}),
                );
                pdf.push(t.elapsed().as_secs_f64() * 1000.0);
                let t = Instant::now();
                assert_eq!(
                    unsafe { stream.0.seek_fn.unwrap()(stream.0.cookie, 131072) },
                    131072
                );
                assert_eq!(
                    unsafe {
                        stream.0.read_fn.unwrap()(stream.0.cookie, bytes.as_mut_ptr().cast(), 65536)
                    },
                    65536
                );
                assert!(bytes.iter().all(|b| *b == 2));
                media_times.push(t.elapsed().as_secs_f64() * 1000.0);
                if done.load(Ordering::Acquire) {
                    break;
                }
            }
        }
        let elapsed = export.join().unwrap();
        assert_eq!(digest(&output), expected);
        let first_directory_ms = directory.first().copied().unwrap_or(0.0);
        println!(
            "{round},{},{:.3},{:.3},{},{:.3},{:.3},{:.3},{:.3},{:.3},{:.3},{:.3}",
            args[3],
            elapsed * 1000.0,
            32.0 / elapsed,
            directory.len(),
            percentile(&mut directory, 0.5),
            percentile(&mut directory, 0.95),
            percentile(&mut pdf, 0.5),
            percentile(&mut pdf, 0.95),
            percentile(&mut media_times, 0.5),
            percentile(&mut media_times, 0.95),
            first_directory_ms
        );
        drop(stream);
        call(browser, json!({"op":"dispose"}));
        call(exporter, json!({"op":"dispose"}));
        std::fs::remove_file(output).unwrap();
    }
}
