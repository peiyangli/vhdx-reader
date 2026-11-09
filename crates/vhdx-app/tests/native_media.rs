use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::{ffi::CString, path::PathBuf, ptr};
use vhdx_app::{request_context, vhdx_context_create, vhdx_mpv_open, MpvStreamInfo};
fn call(context: u64, value: Value) -> Value {
    let reply = request_context(context, value.to_string().as_bytes());
    assert_eq!(reply["ok"], true, "{reply}");
    reply
}
struct Stream(MpvStreamInfo);
impl Stream {
    fn open(url: &str) -> Self {
        let uri = CString::new(url).unwrap();
        let mut info = MpvStreamInfo::default();
        assert_eq!(
            unsafe { vhdx_mpv_open(ptr::null_mut(), uri.as_ptr().cast_mut(), &mut info) },
            0
        );
        Self(info)
    }
    fn read(&self, length: usize) -> Vec<u8> {
        let mut bytes = vec![0; length];
        let n = unsafe {
            self.0.read_fn.unwrap()(self.0.cookie, bytes.as_mut_ptr().cast(), length as u64)
        };
        assert!(n >= 0);
        bytes.truncate(n as usize);
        bytes
    }
    fn seek(&self, offset: i64) -> i64 {
        unsafe { self.0.seek_fn.unwrap()(self.0.cookie, offset) }
    }
    fn revoked(&self) {
        assert_eq!(
            unsafe { self.0.read_fn.unwrap()(self.0.cookie, [0u8; 1].as_mut_ptr().cast(), 1) },
            -1
        );
        assert!(self.seek(0) < 0);
    }
}
impl Drop for Stream {
    fn drop(&mut self) {
        unsafe { self.0.close_fn.unwrap()(self.0.cookie) }
    }
}
#[test]
#[ignore = "requires private examples and native libraries"]
fn native_callback_bytes_seek_cancel_close_lock() {
    let root = PathBuf::from(std::env::var_os("VHDX_SAMPLE_DIR").expect("VHDX_SAMPLE_DIR"));
    for (image, encrypted, path) in [
        ("basicvhdx.vhdx", false, "/$LogFile"),
        ("bitlockervhdx.vhdx", true, "/video/avi.avi"),
    ] {
        let context = vhdx_context_create();
        let session = call(context, json!({"op":"open","path":root.join(image)}))["session"]
            .as_u64()
            .unwrap();
        let mut unlock = json!({"op":"unlock","session":session,"partition":1,"mode":"none"});
        if encrypted {
            unlock["mode"] = json!("password");
            unlock["credential_file"] = json!(root.join("password.txt"));
        }
        call(context, unlock);
        let opened = call(
            context,
            json!({"op":"media_open","session":session,"path":path,"transport":"native"}),
        );
        let data = &opened["data"];
        let url = data["url"].as_str().unwrap();
        let a = Stream::open(url);
        let b = Stream::open(url);
        let reference = call(
            context,
            json!({"op":"file_open","session":session,"path":path}),
        );
        let size = data["size"].as_u64().unwrap();
        for offset in [0, 65530, 262139, size - 13, size, size + 17] {
            assert_eq!(a.seek(offset as i64), offset as i64);
            let bytes = a.read(512 * 1024);
            assert!(bytes.len() <= 256 * 1024);
            let reply = call(
                context,
                json!({"op":"file_read","session":session,"file":reference["data"]["file"],"offset":offset,"length":256*1024}),
            );
            let expected = STANDARD
                .decode(reply["data"]["bytes"].as_str().unwrap())
                .unwrap();
            assert!(bytes == expected, "media bytes differ at offset {offset}");
        }
        assert!(!b.read(16).is_empty());
        unsafe { a.0.cancel_fn.unwrap()(a.0.cookie) };
        a.revoked();
        let reopened = Stream::open(url); // Cancellation affects only one open.
        assert!(!reopened.read(16).is_empty());
        call(
            context,
            json!({"op":"media_close","session":session,"file":data["file"]}),
        );
        b.revoked();
        reopened.revoked();
        let uri = CString::new(url).unwrap();
        assert!(
            unsafe {
                vhdx_mpv_open(
                    ptr::null_mut(),
                    uri.as_ptr().cast_mut(),
                    &mut MpvStreamInfo::default(),
                )
            } < 0
        );
        let other = call(
            context,
            json!({"op":"media_open","session":session,"path":path,"transport":"native"}),
        );
        let other = Stream::open(other["data"]["url"].as_str().unwrap());
        call(context, json!({"op":"lock","session":session}));
        other.revoked();
        call(context, json!({"op":"dispose"}));
        // Late callback close remains safe after reader context destruction.
        drop((a, b, reopened, other));
    }
}

#[test]
#[ignore = "requires private examples and native libraries"]
fn disposed_reader_rejects_late_native_callbacks() {
    let root = PathBuf::from(std::env::var_os("VHDX_SAMPLE_DIR").unwrap());
    let context = vhdx_context_create();
    let session = call(
        context,
        json!({"op":"open","path":root.join("basicvhdx.vhdx")}),
    )["session"]
        .as_u64()
        .unwrap();
    call(
        context,
        json!({"op":"unlock","session":session,"partition":1,"mode":"none"}),
    );
    let data = call(
        context,
        json!({"op":"media_open","session":session,"path":"/can.txt","transport":"native"}),
    );
    let stream = Stream::open(data["data"]["url"].as_str().unwrap());
    assert_eq!(stream.read(100).len(), 7);
    // Engine retirement uses the same State drop, tested separately with an
    // isolated worker so global watermarks cannot race parallel test cases.
    call(context, json!({"op":"dispose"}));
    stream.revoked();
}

#[cfg(unix)]
#[test]
#[ignore = "requires private examples and native libraries; truncates only a private temporary copy"]
fn storage_failure_returns_error_and_revokes_other_cursors() {
    let root = PathBuf::from(std::env::var_os("VHDX_SAMPLE_DIR").unwrap());
    let context = vhdx_context_create();
    let path = std::env::temp_dir().join(format!(
        "vhdx-media-fault-{}-{context}.vhdx",
        std::process::id()
    ));
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let _cleanup = Cleanup(path.clone());
    // Never mutate the source fixture. Windows prevents simultaneous writers;
    // Unix lets this test simulate a provider losing its backing storage.
    let mut output = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .unwrap();
    std::io::copy(
        &mut std::fs::File::open(root.join("basicvhdx.vhdx")).unwrap(),
        &mut output,
    )
    .unwrap();
    let session = call(context, json!({"op":"open","path":path}))["session"]
        .as_u64()
        .unwrap();
    call(
        context,
        json!({"op":"unlock","session":session,"partition":1,"mode":"none"}),
    );
    let data = call(
        context,
        json!({"op":"media_open","session":session,"path":"/$LogFile","transport":"native"}),
    );
    let url = data["data"]["url"].as_str().unwrap();
    let a = Stream::open(url);
    let b = Stream::open(url);
    output.set_len(0).unwrap();
    assert_eq!(a.seek(1024 * 1024), 1024 * 1024);
    assert_eq!(
        unsafe { a.0.read_fn.unwrap()(a.0.cookie, [0u8; 16].as_mut_ptr().cast(), 16) },
        -1
    );
    b.revoked();
    let uri = CString::new(url).unwrap();
    assert!(
        unsafe {
            vhdx_mpv_open(
                ptr::null_mut(),
                uri.as_ptr().cast_mut(),
                &mut MpvStreamInfo::default(),
            )
        } < 0
    );
    call(context, json!({"op":"dispose"}));
}
