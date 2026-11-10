//! Bounded binary preview transport. Native handles stay on the reader worker;
//! the FFI caller owns its output buffer and receives only metadata as JSON.
use super::*;
pub const MAX_READ: usize = 1024 * 1024;
static NEXT_READ: AtomicU64 = AtomicU64::new(1);
type Reply = (Value, Zeroizing<Vec<u8>>);
pub(super) struct Job {
    id: u64,
    context: u64,
    request: Request,
    cancel: Cancellation,
    reply: mpsc::SyncSender<Reply>,
}

fn read(state: &State, request: &Request, cancel: &Cancellation) -> Result<Zeroizing<Vec<u8>>> {
    cancel.check()?;
    let Request::FileRead {
        session,
        file,
        offset,
        length,
    } = request
    else {
        return Err(Error::Invalid("expected file read".into()));
    };
    if *session != state.generation {
        return Err(Error::Invalid("stale_session".into()));
    }
    if *length > MAX_READ || offset.checked_add(*length as u64).is_none() {
        return Err(Error::Invalid("preview range exceeds limit".into()));
    }
    let file = state.files.get(file).ok_or(Error::Locked)?;
    let wanted = (*length as u64).min(file.len().saturating_sub(*offset)) as usize;
    let mut bytes = Zeroizing::new(vec![0; wanted]);
    let mut done = 0;
    while done < wanted {
        cancel.check()?;
        let n = file.read_at(*offset + done as u64, &mut bytes[done..], cancel)?;
        if n == 0 {
            break;
        }
        done += n;
    }
    cancel.check()?;
    bytes.truncate(done);
    Ok(bytes)
}

pub(super) fn run(
    job: Job,
    states: &mut HashMap<u64, State>,
    active: &Mutex<ActiveWork>,
    retired_before: u64,
) {
    let (metadata, bytes) = if job.context < retired_before || !states.contains_key(&job.context) {
        (
            failure("closed", "读取会话已关闭。"),
            Zeroizing::new(Vec::new()),
        )
    } else {
        let state = states.get_mut(&job.context).unwrap();
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            read(state, &job.request, &job.cancel)
        }));
        match result {
            Ok(Ok(bytes)) => {
                let response = state.response(&job.request, Ok(json!({"length":bytes.len()})));
                (response, bytes)
            }
            Ok(Err(error)) => (
                state.response(&job.request, Err(error)),
                Zeroizing::new(Vec::new()),
            ),
            Err(_) => {
                state.clear();
                (
                    json!({"ok":false,"session":state.generation,"invalidated":true,"error":{"code":"internal","message":"读取会话意外结束。"}}),
                    Zeroizing::new(Vec::new()),
                )
            }
        }
    };
    // Keep the registration through send. A concurrent cancel also reaches the
    // caller's shared token, including after a successful worker read.
    let _ = job.reply.send((metadata, bytes));
    if let Ok(mut active) = active.lock() {
        active.previews.remove(&job.id);
    }
}

fn enqueue(
    worker: &Worker,
    context: u64,
    request: Request,
    cancel: Cancellation,
) -> std::result::Result<mpsc::Receiver<Reply>, Value> {
    let id = NEXT_READ.fetch_add(1, Ordering::Relaxed);
    let (reply, receive) = mpsc::sync_channel(1);
    let mut active = worker
        .active
        .lock()
        .map_err(|_| failure("internal", "读取线程已结束。"))?;
    // Include queued and running calls in the same global admission bound.
    if active.previews.len() >= 8 {
        return Err(failure("busy", "读取队列已满，请稍后重试。"));
    }
    active.previews.insert(id, (context, cancel.clone()));
    if let Err(error) = worker.sender.try_send(WorkItem::Preview(Job {
        id,
        context,
        request,
        cancel,
        reply,
    })) {
        active.previews.remove(&id);
        return Err(match error {
            mpsc::TrySendError::Full(_) => failure("busy", "读取队列已满，请稍后重试。"),
            mpsc::TrySendError::Disconnected(_) => failure("internal", "读取线程已结束。"),
        });
    }
    Ok(receive)
}

fn request(context: u64, session: u64, file: u64, offset: u64, length: usize) -> Reply {
    let empty = || Zeroizing::new(Vec::new());
    if length > MAX_READ || offset.checked_add(length as u64).is_none() {
        return (failure("invalid", "读取范围无效。"), empty());
    }
    let worker = match WORKER.get_or_init(Worker::start) {
        Ok(worker) => worker,
        Err(_) => return (failure("internal", "无法启动读取线程。"), empty()),
    };
    let cancel = Cancellation::default();
    let response = match enqueue(
        worker,
        context,
        Request::FileRead {
            session,
            file,
            offset,
            length,
        },
        cancel.clone(),
    ) {
        Ok(response) => response,
        Err(error) => return (error, empty()),
    };
    let result = response
        .recv()
        .unwrap_or_else(|_| (failure("internal", "读取线程已结束。"), empty()));
    if cancel.check().is_err() {
        return (failure("cancelled", "操作已取消。"), empty());
    }
    result
}

/// Blocking ABI 10 preview read. Returns metadata in the regular JSON envelope.
/// Success data.length is the actual byte count (zero at EOF); no Base64 payload.
/// # Safety
/// For 0 < length <= 1 MiB, output must point to length writable bytes and stay
/// alive until return. Null is accepted only for length=0. Invalid oversized
/// lengths never dereference output. Valid buffers are zeroed before work;
/// errors leave them zero, success writes only data.length bytes. Caller owns,
/// wipes and frees output. Free returned metadata with vhdx_response_free.
#[no_mangle]
pub unsafe extern "C" fn vhdx_file_read(
    context: u64,
    session: u64,
    file: u64,
    offset: u64,
    length: usize,
    output: *mut u8,
) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if length > MAX_READ || (length != 0 && output.is_null()) {
            return CString::new(failure("invalid", "读取缓冲区无效。").to_string())
                .unwrap()
                .into_raw();
        }
        let out = if length == 0 {
            &mut []
        } else {
            std::slice::from_raw_parts_mut(output, length)
        };
        out.zeroize();
        let (metadata, bytes) = request(context, session, file, offset, length);
        // Allocate metadata before exposing plaintext; unwind leaves output zero.
        let response = CString::new(metadata.to_string()).unwrap();
        if metadata["ok"] == true {
            out[..bytes.len()].copy_from_slice(&bytes);
        }
        response.into_raw()
    });
    result.unwrap_or(ptr::null_mut())
}

#[cfg(test)]
#[path = "preview_tests.rs"]
mod tests;
