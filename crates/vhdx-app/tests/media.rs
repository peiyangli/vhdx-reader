use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    net::TcpStream,
    path::PathBuf,
    time::Duration,
};
use vhdx_app::{request_context, vhdx_context_create};

fn call(context: u64, value: Value) -> Value {
    request_context(context, value.to_string().as_bytes())
}
fn http(url: &str, method: &str, headers: &str, wrong_token: bool) -> (u16, String, Vec<u8>) {
    let (host, path) = url
        .strip_prefix("http://")
        .unwrap()
        .split_once('/')
        .unwrap();
    let mut socket = TcpStream::connect(host).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let target = if wrong_token {
        "wrong-token/stream"
    } else {
        path
    };
    write!(
        socket,
        "{method} /{target} HTTP/1.1\r\nHost: {host}\r\n{headers}\r\n"
    )
    .unwrap();
    let mut bytes = Vec::new();
    socket.read_to_end(&mut bytes).unwrap();
    let end = bytes.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
    let head = String::from_utf8(bytes[..end].to_vec()).unwrap();
    (
        head.split_whitespace().nth(1).unwrap().parse().unwrap(),
        head,
        bytes[end..].to_vec(),
    )
}
#[test]
#[ignore = "requires private examples and native libraries"]
fn loopback_ranges_authentication_and_isolated_revocation() {
    let root = PathBuf::from(std::env::var_os("VHDX_SAMPLE_DIR").expect("VHDX_SAMPLE_DIR"));
    let a = vhdx_context_create();
    let b = vhdx_context_create();
    let open = |context, image, encrypted| {
        let info = call(context, json!({"op":"open","path":root.join(image)}));
        let session = info["session"].as_u64().unwrap();
        let mut unlock = json!({"op":"unlock","session":session,"partition":1,"mode":"none"});
        if encrypted {
            unlock["mode"] = json!("password");
            unlock["credential_file"] = json!(root.join("password.txt"));
        }
        assert_eq!(call(context, unlock)["ok"], true);
        session
    };
    let sa = open(a, "basicvhdx.vhdx", false);
    let sb = open(b, "bitlockervhdx.vhdx", true);
    let start = |context, session, path| {
        call(
            context,
            json!({"op":"media_open","session":session,"path":path}),
        )
    };
    let first = start(a, sa, "/can.txt");
    let second = start(b, sb, "/hello.txt");
    assert_eq!(
        first["ok"], true,
        "loopback server requires permission to bind local sockets"
    );
    assert_eq!(second["ok"], true);
    let url = first["data"]["url"].as_str().unwrap();
    let other = second["data"]["url"].as_str().unwrap();
    assert_ne!(url, other);
    let (status, _, full) = http(url, "GET", "", false);
    assert_eq!(status, 200);
    assert_eq!(full.len(), 7);
    let (status, head, body) = http(url, "HEAD", "Range: bytes=2-3\r\n", false);
    assert_eq!(status, 200);
    assert!(head.contains("Content-Length: 7\r\n"));
    assert!(body.is_empty());
    for (range, expected) in [
        ("bytes=1-3", &full[1..4]),
        ("bytes=2-", &full[2..]),
        ("bytes=-2", &full[5..]),
        ("bytes=4-999", &full[4..]),
    ] {
        let (status, header, bytes) = http(url, "GET", &format!("Range: {range}\r\n"), false);
        assert_eq!(status, 206);
        assert!(header.contains("Content-Range: bytes "));
        assert_eq!(bytes, expected);
    }
    let (status, header, _) = http(url, "GET", "Range: bytes=100-\r\n", false);
    assert_eq!(status, 416);
    assert!(header.contains("Content-Range: bytes */7\r\n"));
    assert_eq!(http(url, "GET", "Range: bytes=0-1,4-5\r\n", false).0, 200);
    assert_eq!(http(url, "GET", "", true).0, 404);
    assert_eq!(
        http(url, "GET", "Origin: https://example.invalid\r\n", false).0,
        404
    );
    assert_eq!(http(url, "POST", "", false).0, 405);
    // Cross-boundary reads over nonresident NTFS data (not JSON/Base64 transport).
    let large = start(a, sa, "/$LogFile");
    let (status, _, bytes) = http(
        large["data"]["url"].as_str().unwrap(),
        "GET",
        "Range: bytes=65530-524310\r\n",
        false,
    );
    assert_eq!(status, 206);
    assert_eq!(bytes.len(), 524310 - 65530 + 1);
    assert_eq!(http(other, "GET", "Range: bytes=1-\r\n", false).2.len(), 4);
    assert_eq!(call(a, json!({"op":"lock","session":sa}))["ok"], true);
    std::thread::sleep(Duration::from_millis(80));
    let host = url
        .strip_prefix("http://")
        .unwrap()
        .split('/')
        .next()
        .unwrap();
    assert!(
        TcpStream::connect(host).is_err(),
        "locked image listener must close"
    );
    assert_eq!(http(other, "GET", "", false).2.len(), 5);
    assert_eq!(
        call(
            b,
            json!({"op":"media_close","session":sb,"file":second["data"]["file"]})
        )["ok"],
        true
    );
    std::thread::sleep(Duration::from_millis(80));
    assert!(TcpStream::connect(
        other
            .strip_prefix("http://")
            .unwrap()
            .split('/')
            .next()
            .unwrap()
    )
    .is_err());
    for context in [a, b] {
        assert_eq!(call(context, json!({"op":"dispose"}))["ok"], true);
    }
}
