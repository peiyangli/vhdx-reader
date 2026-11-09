use serde_json::{json, Value};
use std::{
    ffi::CString,
    io::{Read, Write},
    net::TcpStream,
    path::PathBuf,
    ptr,
    time::Duration,
};
use vhdx_app::{request_context, vhdx_context_create, vhdx_mpv_open, MpvStreamInfo};
fn request(context: u64, value: Value) -> Value {
    request_context(context, value.to_string().as_bytes())
}
fn call(context: u64, value: Value) -> Value {
    let result = request(context, value);
    assert_eq!(result["ok"], true, "{result}");
    result
}
fn setup() -> (u64, u64) {
    let context = vhdx_context_create();
    let path = PathBuf::from(std::env::var_os("VHDX_READ_FIXTURE").unwrap());
    let session = call(context, json!({"op":"open","path":path}))["session"]
        .as_u64()
        .unwrap();
    call(
        context,
        json!({"op":"unlock","session":session,"partition":1,"mode":"none"}),
    );
    (context, session)
}
struct Native(MpvStreamInfo);
impl Native {
    fn open(url: &str) -> Self {
        let url = CString::new(url).unwrap();
        let mut info = MpvStreamInfo::default();
        assert_eq!(
            unsafe { vhdx_mpv_open(ptr::null_mut(), url.as_ptr().cast_mut(), &mut info) },
            0
        );
        Self(info)
    }
    fn read(&self) -> i64 {
        let mut buffer = vec![0; 256 * 1024];
        unsafe {
            assert_eq!(self.0.seek_fn.unwrap()(self.0.cookie, 0), 0);
            self.0.read_fn.unwrap()(
                self.0.cookie,
                buffer.as_mut_ptr().cast(),
                buffer.len() as u64,
            )
        }
    }
}
impl Drop for Native {
    fn drop(&mut self) {
        unsafe { self.0.close_fn.unwrap()(self.0.cookie) }
    }
}
fn http(url: &str) -> usize {
    let (host, path) = url
        .strip_prefix("http://")
        .unwrap()
        .split_once('/')
        .unwrap();
    let Ok(mut socket) = TcpStream::connect(host) else {
        return 0;
    };
    socket
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    if write!(
        socket,
        "GET /{path} HTTP/1.1\r\nHost: {host}\r\nRange: bytes=0-262143\r\n\r\n"
    )
    .is_err()
    {
        return 0;
    }
    let mut data = Vec::new();
    let _ = socket.read_to_end(&mut data);
    let Some(end) = data.windows(4).position(|b| b == b"\r\n\r\n") else {
        return 0;
    };
    if !data.starts_with(b"HTTP/1.1 206 ") {
        return 0;
    }
    data.len() - end - 4
}
#[test]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn repeated_ranges_and_reopens_share_budget_for_both_transports() {
    for transport in ["http", "native"] {
        let (context, session) = setup();
        let task = call(
            context,
            json!({"op":"thumbnail_begin","session":session,"trace":true}),
        )["data"]["task"]
            .clone();
        for _ in 0..2 {
            let opened = call(
                context,
                json!({"op":"media_open","session":session,"path":"/payload.bin","transport":transport,"thumbnail_task":task}),
            );
            let url = opened["data"]["url"].as_str().unwrap();
            let native = (transport == "native").then(|| Native::open(url));
            for _ in 0..64 {
                assert_eq!(
                    if let Some(native) = &native {
                        native.read() as usize
                    } else {
                        http(url)
                    },
                    256 * 1024
                );
            }
            call(
                context,
                json!({"op":"media_close","session":session,"file":opened["data"]["file"]}),
            );
        }
        let opened = call(
            context,
            json!({"op":"media_open","session":session,"path":"/payload.bin","transport":transport,"thumbnail_task":task}),
        );
        let url = opened["data"]["url"].as_str().unwrap();
        if transport == "native" {
            assert_eq!(Native::open(url).read(), -1);
        } else {
            assert_eq!(http(url), 0);
        }
        let stats = call(context, json!({"op":"thumbnail_finish","task":task}));
        assert_eq!(stats["data"]["file_reserved"], 32 * 1024 * 1024);
        assert_eq!(stats["data"]["file_bytes"], 32 * 1024 * 1024);
        assert!(stats["data"]["source_reserved"].as_u64().unwrap() <= 64 * 1024 * 1024);
        assert_eq!(stats["data"]["reason"], "read_budget");
        assert_eq!(stats["data"]["opens"], 3);
        assert!(stats["data"]["trace"].as_array().unwrap().len() <= 256);
        let normal = call(
            context,
            json!({"op":"media_open","session":session,"path":"/payload.bin","transport":"native"}),
        );
        assert_eq!(
            Native::open(normal["data"]["url"].as_str().unwrap()).read(),
            256 * 1024
        );
        call(context, json!({"op":"dispose"}));
    }
}
#[test]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn cancelled_or_expired_task_cannot_open_and_does_not_lock_volume() {
    let (context, session) = setup();
    let task =
        call(context, json!({"op":"thumbnail_begin","session":session}))["data"]["task"].clone();
    call(context, json!({"op":"thumbnail_cancel","task":task}));
    let result = request(
        context,
        json!({"op":"media_open","session":session,"path":"/payload.bin","thumbnail_task":task}),
    );
    assert_eq!(result["error"]["code"], "thumbnail_cancelled");
    assert_eq!(result["invalidated"], false);
    call(context, json!({"op":"thumbnail_finish","task":task}));
    let task =
        call(context, json!({"op":"thumbnail_begin","session":session}))["data"]["task"].clone();
    std::thread::sleep(Duration::from_millis(8100));
    let result = request(
        context,
        json!({"op":"media_open","session":session,"path":"/payload.bin","thumbnail_task":task}),
    );
    assert_eq!(result["error"]["code"], "thumbnail_deadline");
    assert_eq!(result["invalidated"], false);
    call(
        context,
        json!({"op":"read","session":session,"path":"/payload.bin","offset":0,"length":16}),
    );
    call(context, json!({"op":"dispose"}));
}

#[test]
#[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
fn cancelled_tasks_do_not_leak_slots_when_media_close_was_not_delivered() {
    let (context, session) = setup();
    for _ in 0..8 {
        let task = call(context, json!({"op":"thumbnail_begin","session":session}))["data"]["task"]
            .clone();
        call(
            context,
            json!({"op":"media_open","session":session,"path":"/payload.bin","transport":"native","thumbnail_task":task}),
        );
        call(context, json!({"op":"thumbnail_cancel","task":task}));
        call(context, json!({"op":"thumbnail_finish","task":task}));
        // Deliberately omit media_close, simulating a full Dart command queue.
    }
    call(context, json!({"op":"dispose"}));
}
