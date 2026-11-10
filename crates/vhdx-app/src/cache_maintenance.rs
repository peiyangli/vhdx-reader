//! Cooperative cache administration; only the reader worker owns this state.
use super::*;

pub(super) struct Pending {
    job: Job,
    before: u64,
}

pub(super) fn is_admin(request: &Request) -> bool {
    matches!(
        request,
        Request::DiskCacheConfigure { .. } | Request::DiskCacheClear
    )
}

fn release(active: &Arc<Mutex<ActiveWork>>) {
    if let Ok(mut active) = active.lock() {
        active.cache_maintenance = None;
    }
}

pub(super) fn start(
    job: Job,
    state: &mut State,
    cache: &Rc<RefCell<DiskCache>>,
    pending: &mut Option<Pending>,
    active: &Arc<Mutex<ActiveWork>>,
) {
    let before = cache.borrow().status().bytes;
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<()> {
        job.cancel.check()?;
        // Admission reserves the single explicit maintenance slot at enqueue.
        // A background expiry sweep can be superseded by an explicit command.
        cache.borrow_mut().cancel_maintenance();
        match &job.request {
            Request::DiskCacheConfigure {
                directory,
                enabled,
                max_gib,
                retention_days,
                ..
            } => {
                if ![1, 2, 4, 8, 16, 32, 64, 128].contains(max_gib)
                    || ![0, 1, 7, 30].contains(retention_days)
                {
                    return Err(Error::Invalid("disk_cache_settings".into()));
                }
                cache
                    .borrow_mut()
                    .begin_configure(
                        Path::new(directory),
                        *enabled,
                        max_gib * 1024 * 1024 * 1024,
                        *retention_days,
                    )
                    .map_err(|_| Error::Invalid("disk_cache_unavailable".into()))?;
            }
            Request::DiskCacheClear => cache
                .borrow_mut()
                .begin_clear()
                .map_err(|_| Error::Invalid("disk_cache_clear_failed".into()))?,
            _ => unreachable!(),
        }
        Ok(())
    }))
    .unwrap_or_else(|_| {
        cache.borrow_mut().cancel_maintenance();
        Err(Error::Invalid("disk_cache_unavailable".into()))
    });
    if let Ok(mut active) = active.lock() {
        active.current = None;
    }
    match result {
        Ok(()) => *pending = Some(Pending { job, before }),
        Err(error) => {
            release(active);
            let _ = job.reply.send(state.response(&job.request, Err(error)));
        }
    }
}

/// Advance one bounded quantum even under a continuously busy foreground queue.
pub(super) fn advance(
    pending: &mut Option<Pending>,
    cache: &Rc<RefCell<DiskCache>>,
    states: &mut HashMap<u64, State>,
    active: &Arc<Mutex<ActiveWork>>,
) -> bool {
    if pending.is_none() {
        cache.borrow_mut().begin_due_maintenance();
    }
    if pending.is_none() && !cache.borrow().maintenance_pending() {
        return false;
    }
    let result = if pending
        .as_ref()
        .is_some_and(|p| p.job.cancel.check().is_err())
    {
        cache.borrow_mut().cancel_maintenance();
        Err(Error::Cancelled)
    } else {
        let step = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            cache.borrow_mut().step_maintenance()
        }))
        .unwrap_or_else(|_| {
            cache.borrow_mut().cancel_maintenance();
            Err(std::io::Error::other("cache maintenance panicked"))
        });
        step.map_err(|_| {
            Error::Invalid(
                if pending
                    .as_ref()
                    .is_some_and(|p| matches!(p.job.request, Request::DiskCacheClear))
                {
                    "disk_cache_clear_failed"
                } else {
                    "disk_cache_unavailable"
                }
                .into(),
            )
        })
    };
    if matches!(result, Ok(false)) {
        return true;
    }
    if let Some(pending) = pending.take() {
        let job = pending.job;
        let response = if let Some(state) = states.get_mut(&job.context) {
            let result = result.map(|_| {
                let cache = cache.borrow();
                if let Request::DiskCacheConfigure { cache_enabled, .. } = job.request {
                    cache.control.set_enabled(cache_enabled);
                }
                if matches!(job.request, Request::DiskCacheClear) {
                    json!({"removed_bytes":pending.before.saturating_sub(cache.status().bytes),"remaining_bytes":cache.status().bytes})
                } else { serde_json::to_value(cache.status()).unwrap() }
            });
            state.response(&job.request, result)
        } else {
            failure("closed", "读取会话已关闭。")
        };
        release(active);
        let _ = job.reply.send(response);
    }
    true
}

pub(super) fn close(
    pending: &mut Option<Pending>,
    cache: &Rc<RefCell<DiskCache>>,
    active: &Arc<Mutex<ActiveWork>>,
    closed: impl Fn(u64) -> bool,
) {
    if pending.as_ref().is_some_and(|p| closed(p.job.context)) {
        let pending = pending.take().unwrap();
        cache.borrow_mut().cancel_maintenance();
        release(active);
        let _ = pending
            .job
            .reply
            .send(failure("closed", "读取会话已关闭。"));
    }
}
