//! End-to-end loopback streaming benchmark (worker + native reads + socket).
//! No decoded video or external device is involved. Do not report as USB speed.
use serde_json::{json, Value};
use std::{
    hint::black_box,
    io::{BufRead, BufReader, Read, Write},
    net::TcpStream,
    path::Path,
    time::{Duration, Instant},
};
use vhdx_app::{request_context, vhdx_context_create};
use zeroize::Zeroizing;
fn call(context: u64, value: Value) -> Value {
    let result = request_context(context, value.to_string().as_bytes());
    assert_eq!(result["ok"], true, "{result}");
    result
}
fn read(url: &str, size: usize) -> std::io::Result<()> {
    let (host, path) = url
        .strip_prefix("http://")
        .unwrap()
        .split_once('/')
        .unwrap();
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
    let mut buffer = Zeroizing::new(vec![0; 64 * 1024]);
    let mut total = 0;
    loop {
        let n = reader.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        black_box(&buffer[..n]);
        total += n;
    }
    assert_eq!(total, size);
    Ok(())
}
fn main() -> std::io::Result<()> {
    let args: Vec<_> = std::env::args().collect();
    assert_eq!(args.len(), 3, "media_benchmark <image> <file in image>");
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
        json!({"op":"media_open","session":session,"path":args[2]}),
    );
    let url = opened["data"]["url"].as_str().unwrap();
    let size = opened["data"]["size"].as_u64().unwrap() as usize;
    assert!(size > 0);
    read(url, size)?;
    println!("round,requests,bytes,ms,mib_per_second");
    for round in 0..7 {
        let start = Instant::now();
        for _ in 0..16 {
            read(url, size)?;
        }
        let secs = start.elapsed().as_secs_f64();
        println!(
            "{round},16,{}, {:.3},{:.3}",
            size * 16,
            secs * 1000.,
            (size * 16) as f64 / 1048576. / secs
        );
    }
    call(context, json!({"op":"dispose"}));
    Ok(())
}
