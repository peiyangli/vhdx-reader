//! HTTP / stream_cb comparison through the same reader worker and native stack.
//! No decoder or renderer: use media_transport_test.dart for first-frame/seek.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    ffi::CString,
    hint::black_box,
    io::{BufRead, BufReader, Read, Write},
    net::TcpStream,
    path::Path,
    ptr,
    time::{Duration, Instant},
};
use vhdx_app::{request_context, vhdx_context_create, vhdx_mpv_open, MpvStreamInfo};
use zeroize::Zeroizing;
fn call(context: u64, value: Value) -> Value {
    let result = request_context(context, value.to_string().as_bytes());
    assert_eq!(result["ok"], true, "{result}");
    result
}
struct Native(MpvStreamInfo);
impl Drop for Native {
    fn drop(&mut self) {
        unsafe { self.0.close_fn.unwrap()(self.0.cookie) }
    }
}
fn transfer(url: &str, size: u64, verify: bool) -> std::io::Result<Option<[u8; 32]>> {
    let mut native = None;
    let mut http = None;
    if let Some(address) = url.strip_prefix("http://") {
        let (host, path) = address.split_once('/').unwrap();
        let mut socket = TcpStream::connect(host)?;
        socket.set_read_timeout(Some(Duration::from_secs(10)))?;
        write!(socket, "GET /{path} HTTP/1.1\r\nHost: {host}\r\n\r\n")?;
        let mut reader = BufReader::new(socket);
        let mut line = String::new();
        reader.read_line(&mut line)?;
        assert!(line.starts_with("HTTP/1.1 200 "), "{line}");
        loop {
            line.clear();
            reader.read_line(&mut line)?;
            if line == "\r\n" {
                break;
            }
            assert!(!line.is_empty());
        }
        http = Some(reader);
    } else {
        let uri = CString::new(url).unwrap();
        let mut info = MpvStreamInfo::default();
        assert_eq!(
            unsafe { vhdx_mpv_open(ptr::null_mut(), uri.as_ptr().cast_mut(), &mut info) },
            0
        );
        native = Some(Native(info));
    }
    let mut buffer = Zeroizing::new(vec![0; 256 * 1024]);
    let mut total = 0;
    let mut digest = Sha256::new();
    loop {
        let n = if let Some(Native(info)) = &native {
            let n = unsafe {
                info.read_fn.unwrap()(info.cookie, buffer.as_mut_ptr().cast(), buffer.len() as u64)
            };
            assert!(n >= 0, "native read failed");
            n as usize
        } else {
            http.as_mut().unwrap().read(&mut buffer)?
        };
        if n == 0 {
            break;
        }
        if verify {
            digest.update(&buffer[..n]);
        } else {
            black_box(&buffer[..n]);
        }
        total += n as u64;
    }
    assert_eq!(total, size);
    Ok(verify.then(|| digest.finalize().into()))
}
#[cfg(windows)]
fn cpu_ms() -> f64 {
    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentProcess() -> *mut std::ffi::c_void;
        fn GetProcessTimes(
            handle: *mut std::ffi::c_void,
            create: *mut u64,
            exit: *mut u64,
            kernel: *mut u64,
            user: *mut u64,
        ) -> i32;
    }
    let (mut create, mut exit, mut kernel, mut user) = (0, 0, 0, 0);
    assert_ne!(
        unsafe {
            GetProcessTimes(
                GetCurrentProcess(),
                &mut create,
                &mut exit,
                &mut kernel,
                &mut user,
            )
        },
        0
    );
    (kernel + user) as f64 / 10000.
}
#[cfg(not(windows))]
fn cpu_ms() -> f64 {
    f64::NAN
}
#[allow(clippy::too_many_arguments)]
fn report(
    context: u64,
    session: u64,
    file: &Value,
    transport: &str,
    phase: &str,
    round: usize,
    start: Instant,
    cpu: f64,
    before: &Value,
    bytes: u64,
) {
    let ms = start.elapsed().as_secs_f64() * 1000.;
    let cpu = cpu_ms() - cpu;
    let after = call(
        context,
        json!({"op":"media_status","session":session,"file":file}),
    );
    let delta =
        |key: &str| after["data"][key].as_u64().unwrap() - before["data"][key].as_u64().unwrap();
    println!(
        "{transport},{phase},{round},{bytes},{ms:.3},{cpu:.3},{:.3},{},{},{}",
        bytes as f64 / 1048576. / (ms / 1000.),
        delta("worker_read_calls"),
        delta("worker_read_bytes"),
        delta("worker_read_ns")
    );
}
fn main() -> std::io::Result<()> {
    let args: Vec<_> = std::env::args().collect();
    assert_eq!(args.len(), 3, "media_benchmark <image> <file in image>");
    let rounds: usize = std::env::var("VHDX_BENCH_ROUNDS")
        .unwrap_or("7".into())
        .parse()
        .unwrap();
    let repeats: u64 = std::env::var("VHDX_BENCH_REPEATS")
        .unwrap_or("16".into())
        .parse()
        .unwrap();
    assert!((1..=100).contains(&rounds) && (1..=100).contains(&repeats));
    let mut expected = None;
    println!(
        "transport,phase,round,bytes,ms,cpu_ms,mib_per_second,worker_calls,worker_bytes,worker_ns"
    );
    for round in 0..rounds {
        let order = if round % 2 == 0 {
            ["http", "native"]
        } else {
            ["native", "http"]
        };
        for transport in order {
            // Recreate volume caches for every transport/round. OS cache is NOT cleared.
            let context = vhdx_context_create();
            let opened = call(context, json!({"op":"open", "path":args[1]}));
            let session = opened["session"].as_u64().unwrap();
            let mut unlock = json!({"op":"unlock","session":session,"partition":1,"mode":"none"});
            if let Some(path) = std::env::var_os("VHDX_BENCH_PASSWORD_FILE") {
                unlock["mode"] = json!("password");
                unlock["credential_file"] = json!(Path::new(&path));
            }
            call(context, unlock);
            let opened = call(
                context,
                json!({"op":"media_open","session":session,"path":args[2],"transport":transport}),
            );
            let url = opened["data"]["url"].as_str().unwrap();
            let file = &opened["data"]["file"];
            let size = opened["data"]["size"].as_u64().unwrap();
            assert!(size > 0);
            let status = || {
                call(
                    context,
                    json!({"op":"media_status","session":session,"file":file}),
                )
            };
            let before = status();
            let cpu = cpu_ms();
            let start = Instant::now();
            transfer(url, size, false)?;
            report(
                context,
                session,
                file,
                transport,
                "fresh_volume",
                round,
                start,
                cpu,
                &before,
                size,
            );
            // Verification / warmup outside the timed interval, bounded memory.
            let digest = transfer(url, size, true)?.unwrap();
            if let Some(expected) = expected {
                assert_eq!(digest, expected);
            } else {
                expected = Some(digest);
            }
            let before = status();
            let cpu = cpu_ms();
            let start = Instant::now();
            for _ in 0..repeats {
                transfer(url, size, false)?;
            }
            report(
                context,
                session,
                file,
                transport,
                "warm",
                round,
                start,
                cpu,
                &before,
                size * repeats,
            );
            call(context, json!({"op":"dispose"}));
        }
    }
    Ok(())
}
