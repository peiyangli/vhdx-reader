//! libmpv stream_cb ABI (API 1.106+, including cancel_fn).
//! Only IDs and thread-safe cancellation/statistics cross threads. All native
//! filesystem handles remain on the reader worker. No callback invokes mpv.
use std::{
    collections::HashMap,
    ffi::{c_char, c_int, c_void, CStr},
    panic::{catch_unwind, AssertUnwindSafe},
    ptr,
    sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex, OnceLock, Weak,
    },
};
use vhdx_core::{session::Cancellation, Error, Result};

const CHUNK: u64 = 256 * 1024;
const LOADING_FAILED: c_int = -13;
const GENERIC: i64 = -20;
static STREAMS: OnceLock<Mutex<HashMap<String, Weak<Shared>>>> = OnceLock::new();
fn streams() -> &'static Mutex<HashMap<String, Weak<Shared>>> {
    STREAMS.get_or_init(Default::default)
}
struct Shared {
    task: Option<Arc<crate::thumbnail::Task>>,
    context: u64,
    session: u64,
    file: u64,
    size: u64,
    revoked: Cancellation,
    active: AtomicUsize,
    opens: AtomicU64,
    reads: AtomicU64,
    bytes: AtomicU64,
    seeks: AtomicU64,
}
pub(crate) struct Stream {
    pub url: String,
    shared: Arc<Shared>,
}
impl Stream {
    #[cfg(test)]
    pub fn start(context: u64, session: u64, file: u64, size: u64) -> Result<Self> {
        Self::start_task(context, session, file, size, None)
    }
    pub fn start_task(
        context: u64,
        session: u64,
        file: u64,
        size: u64,
        task: Option<Arc<crate::thumbnail::Task>>,
    ) -> Result<Self> {
        if size > i64::MAX as u64 {
            return Err(Error::Invalid("media size exceeds mpv ABI".into()));
        }
        let mut token = [0u8; 32];
        getrandom::fill(&mut token)
            .map_err(|_| Error::Invalid("random token generation failed".into()))?;
        let url = format!(
            "vhdx://{}/stream",
            token.iter().map(|b| format!("{b:02x}")).collect::<String>()
        );
        let shared = Arc::new(Shared {
            task,
            context,
            session,
            file,
            size,
            revoked: Cancellation::default(),
            active: AtomicUsize::new(0),
            opens: AtomicU64::new(0),
            reads: AtomicU64::new(0),
            bytes: AtomicU64::new(0),
            seeks: AtomicU64::new(0),
        });
        streams()
            .lock()
            .map_err(|_| Error::Invalid("media registry poisoned".into()))?
            .insert(url.clone(), Arc::downgrade(&shared));
        Ok(Self { url, shared })
    }
    pub fn stats(&self) -> serde_json::Value {
        serde_json::json!({
            "bytes": self.shared.bytes.load(Ordering::Relaxed),
            "requests": self.shared.opens.load(Ordering::Relaxed),
            "reads": self.shared.reads.load(Ordering::Relaxed),
            "ranges": self.shared.seeks.load(Ordering::Relaxed),
            "active": self.shared.active.load(Ordering::Relaxed),
        })
    }
}
impl Drop for Stream {
    fn drop(&mut self) {
        self.shared.revoked.cancel();
        if let Ok(mut streams) = streams().lock() {
            streams.remove(&self.url);
        }
    }
}
struct Cursor {
    shared: Arc<Shared>,
    // mpv serializes read/seek, but cancel may run concurrently. Never create
    // an exclusive Rust reference to a cookie while cancel can borrow it.
    offset: AtomicU64,
    cancelled: Cancellation,
}
impl Cursor {
    fn check(&self) -> Result<()> {
        if let Some(task) = &self.shared.task {
            task.check()?;
        }
        self.cancelled.check()?;
        self.shared.revoked.check()
    }
}
impl Drop for Cursor {
    fn drop(&mut self) {
        self.shared.active.fetch_sub(1, Ordering::AcqRel);
    }
}
/// Layout from mpv/stream_cb.h. Callers must check mpv_client_api_version before
/// registration: API 1.106+ or compatible API 2.x. Older structs are smaller.
#[repr(C)]
#[derive(Default)]
pub struct MpvStreamInfo {
    pub cookie: *mut c_void,
    pub read_fn: Option<unsafe extern "C" fn(*mut c_void, *mut c_char, u64) -> i64>,
    pub seek_fn: Option<unsafe extern "C" fn(*mut c_void, i64) -> i64>,
    pub size_fn: Option<unsafe extern "C" fn(*mut c_void) -> i64>,
    pub close_fn: Option<unsafe extern "C" fn(*mut c_void)>,
    pub cancel_fn: Option<unsafe extern "C" fn(*mut c_void)>,
}
/// Register this function with mpv_stream_cb_add_ro(ctx, "vhdx", NULL, ...).
/// Registration has no allocated user_data: media_kit defers mpv destruction
/// beyond dispose(). The Rust library must stay loaded until mpv destruction.
///
/// # Safety
/// Called only using the compatible mpv stream_cb ABI. uri is a NUL-terminated
/// string; info is writable for MpvStreamInfo. mpv owns each successful cookie
/// until exactly one close call, after all other callbacks have finished.
#[no_mangle]
pub unsafe extern "C" fn vhdx_mpv_open(
    _user_data: *mut c_void,
    uri: *mut c_char,
    info: *mut MpvStreamInfo,
) -> c_int {
    catch_unwind(AssertUnwindSafe(|| {
        if uri.is_null() || info.is_null() {
            return LOADING_FAILED;
        }
        let Ok(uri) = CStr::from_ptr(uri).to_str() else {
            return LOADING_FAILED;
        };
        let shared = streams()
            .lock()
            .ok()
            .and_then(|s| s.get(uri).and_then(Weak::upgrade));
        let Some(shared) = shared else {
            return LOADING_FAILED;
        };
        if shared.revoked.check().is_err()
            || shared.task.as_ref().is_some_and(|t| t.check().is_err())
        {
            return LOADING_FAILED;
        }
        if shared.active.fetch_add(1, Ordering::AcqRel) >= 4 {
            shared.active.fetch_sub(1, Ordering::AcqRel);
            return LOADING_FAILED;
        }
        shared.opens.fetch_add(1, Ordering::Relaxed);
        let cursor = Box::new(Cursor {
            shared,
            offset: AtomicU64::new(0),
            cancelled: Cancellation::default(),
        });
        ptr::write(
            info,
            MpvStreamInfo {
                cookie: Box::into_raw(cursor).cast(),
                read_fn: Some(read),
                seek_fn: Some(seek),
                size_fn: Some(size),
                close_fn: Some(close),
                cancel_fn: Some(cancel),
            },
        );
        0
    }))
    .unwrap_or(LOADING_FAILED)
}
unsafe extern "C" fn read(cookie: *mut c_void, buffer: *mut c_char, length: u64) -> i64 {
    catch_unwind(AssertUnwindSafe(|| -> Result<i64> {
        let cursor = (cookie as *const Cursor).as_ref().ok_or(Error::Locked)?;
        cursor.check()?;
        if length == 0 {
            return Ok(0);
        }
        if buffer.is_null() {
            return Err(Error::Invalid("null mpv buffer".into()));
        }
        let offset = cursor.offset.load(Ordering::Relaxed);
        let length = length
            .min(CHUNK)
            .min(cursor.shared.size.saturating_sub(offset)) as usize;
        if length == 0 {
            return Ok(0);
        }
        cursor.shared.reads.fetch_add(1, Ordering::Relaxed);
        let bytes = crate::read_media_task(
            cursor.shared.context,
            cursor.shared.session,
            cursor.shared.file,
            offset,
            length,
            &cursor.cancelled,
            &cursor.shared.revoked,
            cursor.shared.task.as_ref(),
        )?;
        cursor.check()?;
        // Owned worker buffer is copied once into mpv's supplied buffer, then
        // zeroized. It never traverses Dart or a socket; this is not zero-copy.
        ptr::copy_nonoverlapping(bytes.as_ptr(), buffer.cast(), bytes.len());
        cursor
            .offset
            .store(offset + bytes.len() as u64, Ordering::Relaxed);
        cursor
            .shared
            .bytes
            .fetch_add(bytes.len() as u64, Ordering::Relaxed);
        Ok(bytes.len() as i64)
    }))
    .ok()
    .and_then(Result::ok)
    .unwrap_or(-1)
}
unsafe extern "C" fn seek(cookie: *mut c_void, offset: i64) -> i64 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(cursor) = (cookie as *const Cursor).as_ref() else {
            return GENERIC;
        };
        if cursor.check().is_err() || offset < 0 {
            return GENERIC;
        }
        // Seeking past EOF is allowed. A subsequent read returns EOF.
        cursor.offset.store(offset as u64, Ordering::Relaxed);
        cursor.shared.seeks.fetch_add(1, Ordering::Relaxed);
        offset
    }))
    .unwrap_or(GENERIC)
}
unsafe extern "C" fn size(cookie: *mut c_void) -> i64 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(cursor) = (cookie as *const Cursor).as_ref() else {
            return GENERIC;
        };
        if cursor.check().is_err() {
            return GENERIC;
        }
        cursor.shared.size as i64
    }))
    .unwrap_or(GENERIC)
}
unsafe extern "C" fn cancel(cookie: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(cursor) = (cookie as *const Cursor).as_ref() {
            cursor.cancelled.cancel();
        }
    }));
}
unsafe extern "C" fn close(cookie: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !cookie.is_null() {
            drop(Box::from_raw(cookie as *mut Cursor));
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    unsafe fn open(stream: &Stream) -> MpvStreamInfo {
        let uri = CString::new(stream.url.clone()).unwrap();
        let mut info = MpvStreamInfo::default();
        assert_eq!(
            vhdx_mpv_open(ptr::null_mut(), uri.as_ptr().cast_mut(), &mut info),
            0
        );
        info
    }
    #[test]
    fn independent_cursors_cancel_revoke_and_late_close() {
        unsafe {
            let stream = Stream::start(0, 0, 0, (1u64 << 33) + 17).unwrap();
            let a = open(&stream);
            let b = open(&stream);
            assert_eq!(a.size_fn.unwrap()(a.cookie), (1i64 << 33) + 17);
            assert_eq!(a.seek_fn.unwrap()(a.cookie, 1i64 << 32), 1i64 << 32);
            assert_eq!(
                (b.cookie as *const Cursor)
                    .as_ref()
                    .unwrap()
                    .offset
                    .load(Ordering::Relaxed),
                0
            );
            assert_eq!(a.seek_fn.unwrap()(a.cookie, -1), GENERIC);
            assert_eq!(a.seek_fn.unwrap()(a.cookie, i64::MAX), i64::MAX);
            let mut out = 0;
            assert_eq!(a.read_fn.unwrap()(a.cookie, &mut out, 1), 0);
            a.cancel_fn.unwrap()(a.cookie);
            assert_eq!(a.read_fn.unwrap()(a.cookie, &mut out, 1), -1);
            assert!(b.size_fn.unwrap()(b.cookie) > 0);
            let uri = CString::new(stream.url.clone()).unwrap();
            drop(stream);
            assert_eq!(b.size_fn.unwrap()(b.cookie), GENERIC);
            assert_eq!(b.read_fn.unwrap()(b.cookie, &mut out, 1), -1);
            assert_eq!(
                vhdx_mpv_open(
                    ptr::null_mut(),
                    uri.as_ptr().cast_mut(),
                    &mut MpvStreamInfo::default()
                ),
                LOADING_FAILED
            );
            a.close_fn.unwrap()(a.cookie);
            b.close_fn.unwrap()(b.cookie);
        }
    }
    #[test]
    fn token_matching_and_open_limit() {
        unsafe {
            let stream = Stream::start(0, 0, 0, 0).unwrap();
            let uri = CString::new(format!("{}?extra", stream.url)).unwrap();
            assert_eq!(
                vhdx_mpv_open(
                    ptr::null_mut(),
                    uri.as_ptr().cast_mut(),
                    &mut MpvStreamInfo::default()
                ),
                LOADING_FAILED
            );
            let cursors: Vec<_> = (0..4).map(|_| open(&stream)).collect();
            let uri = CString::new(stream.url.clone()).unwrap();
            assert_eq!(
                vhdx_mpv_open(
                    ptr::null_mut(),
                    uri.as_ptr().cast_mut(),
                    &mut MpvStreamInfo::default()
                ),
                LOADING_FAILED
            );
            for info in cursors {
                info.close_fn.unwrap()(info.cookie);
            }
            assert_eq!(stream.stats()["active"], 0);
            let info = open(&stream);
            info.close_fn.unwrap()(info.cookie);
        }
    }
}
