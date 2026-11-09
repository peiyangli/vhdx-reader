//! Per-attempt limits shared by every reopen/range and both media transports.
//! Registry operations are metadata-only and may run independently of the reader.
use serde_json::{json, Value};
use std::{
    cell::RefCell,
    collections::HashMap,
    rc::Rc,
    sync::{
        atomic::{AtomicU64, AtomicU8, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::{Duration, Instant},
};
use vhdx_core::{session::Cancellation, source::ReadAt, Error, Result};
const FILE_LIMIT: u64 = 32 * 1024 * 1024;
const SOURCE_LIMIT: u64 = 64 * 1024 * 1024;
const TIME_LIMIT: Duration = Duration::from_secs(8);
static NEXT: AtomicU64 = AtomicU64::new(1);
static TASKS: OnceLock<Mutex<HashMap<u64, Arc<Task>>>> = OnceLock::new();
fn tasks() -> &'static Mutex<HashMap<u64, Arc<Task>>> {
    TASKS.get_or_init(Default::default)
}
#[derive(Default)]
struct Metrics {
    file_reserved: u64,
    source_reserved: u64,
    file_bytes: u64,
    source_bytes: u64,
    file_calls: u64,
    source_calls: u64,
    source_in_flight: u64,
    opens: u64,
    trace: Vec<Value>,
    trace_dropped: u64,
}
pub(crate) struct Task {
    pub id: u64,
    context: u64,
    session: u64,
    started: Instant,
    deadline: Duration,
    file_limit: u64,
    source_limit: u64,
    reason: AtomicU8,
    pub cancel: Cancellation,
    trace: bool,
    metrics: Mutex<Metrics>,
}
impl Task {
    fn new(
        context: u64,
        session: u64,
        trace: bool,
        deadline: Duration,
        file_limit: u64,
        source_limit: u64,
    ) -> Self {
        Self {
            id: NEXT.fetch_add(1, Ordering::Relaxed),
            context,
            session,
            started: Instant::now(),
            deadline,
            file_limit,
            source_limit,
            reason: AtomicU8::new(0),
            cancel: Cancellation::default(),
            trace,
            metrics: Mutex::new(Metrics::default()),
        }
    }
    fn stop(&self, reason: u8) {
        let _ = self
            .reason
            .compare_exchange(0, reason, Ordering::AcqRel, Ordering::Acquire);
        self.cancel.cancel();
    }
    pub fn check(&self) -> Result<()> {
        if self.started.elapsed() >= self.deadline {
            self.stop(2);
        }
        let code = match self.reason.load(Ordering::Acquire) {
            0 => return Ok(()),
            1 => "thumbnail_cancelled",
            2 => "thumbnail_deadline",
            _ => "thumbnail_read_budget",
        };
        Err(Error::Invalid(code.into()))
    }
    pub fn open(&self) -> Result<()> {
        self.check()?;
        self.metrics.lock().unwrap().opens += 1;
        Ok(())
    }
    pub fn reserve(&self, source: bool, count: usize) -> Result<()> {
        self.check()?;
        let mut metrics = self.metrics.lock().unwrap();
        let (used, limit) = if source {
            (&mut metrics.source_reserved, self.source_limit)
        } else {
            (&mut metrics.file_reserved, self.file_limit)
        };
        if count as u64 > limit.saturating_sub(*used) {
            self.stop(3);
            return self.check();
        }
        *used += count as u64;
        if source {
            metrics.source_calls += 1;
            metrics.source_in_flight += 1;
        } else {
            metrics.file_calls += 1;
        }
        Ok(())
    }
    pub fn record(
        &self,
        source: bool,
        offset: u64,
        wanted: usize,
        returned: usize,
        elapsed: Duration,
    ) {
        let mut metrics = self.metrics.lock().unwrap();
        if source {
            metrics.source_bytes += returned as u64;
            metrics.source_in_flight -= 1;
        } else {
            metrics.file_bytes += returned as u64;
        }
        if self.trace {
            if metrics.trace.len() < 256 {
                metrics.trace.push(json!({"layer":if source {"source"} else {"file"},"offset":offset,"length":wanted,"returned":returned,"us":elapsed.as_micros().min(u64::MAX as u128) as u64}));
            } else {
                metrics.trace_dropped += 1;
            }
        }
    }
    pub fn stats(&self) -> Value {
        let _ = self.check();
        let m = self.metrics.lock().unwrap();
        json!({"task":self.id,"reason":match self.reason.load(Ordering::Acquire) {0=>"active",1=>"cancelled",2=>"deadline",_=>"read_budget"},
            "elapsed_ms":self.started.elapsed().as_millis().min(u64::MAX as u128) as u64,
            "file_limit":self.file_limit,"source_limit":self.source_limit,"deadline_ms":self.deadline.as_millis() as u64,
            "file_reserved":m.file_reserved,"source_reserved":m.source_reserved,"file_bytes":m.file_bytes,"source_bytes":m.source_bytes,
            "file_calls":m.file_calls,"source_calls":m.source_calls,"source_in_flight":m.source_in_flight,"opens":m.opens,
            "trace":m.trace,"trace_dropped":m.trace_dropped})
    }
}
pub fn begin(context: u64, session: u64, trace: bool) -> Result<Value> {
    let mut tasks = tasks().lock().unwrap();
    tasks.retain(|_, task| task.started.elapsed() < task.deadline + Duration::from_secs(30));
    if tasks.len() >= 128
        || tasks
            .values()
            .filter(|t| t.context == context && t.check().is_ok())
            .count()
            >= 4
    {
        return Err(Error::Invalid("thumbnail_busy".into()));
    }
    let task = Arc::new(Task::new(
        context,
        session,
        trace,
        TIME_LIMIT,
        FILE_LIMIT,
        SOURCE_LIMIT,
    ));
    let result = task.stats();
    tasks.insert(task.id, task);
    Ok(result)
}
pub fn get(context: u64, session: u64, id: u64) -> Result<Arc<Task>> {
    let task = tasks()
        .lock()
        .unwrap()
        .get(&id)
        .cloned()
        .ok_or_else(|| Error::Invalid("thumbnail_cancelled".into()))?;
    if task.context != context || task.session != session {
        return Err(Error::Invalid("thumbnail_cancelled".into()));
    }
    Ok(task)
}
pub fn end(context: u64, id: u64, finish: bool) -> Result<Value> {
    let mut tasks = tasks().lock().unwrap();
    let task = tasks
        .get(&id)
        .filter(|t| t.context == context)
        .ok_or_else(|| Error::Invalid("thumbnail_cancelled".into()))?;
    let stats = task.stats();
    task.stop(1);
    if finish {
        tasks.remove(&id);
    }
    Ok(stats)
}
pub fn revoke(context: u64) {
    if let Ok(mut tasks) = tasks().lock() {
        tasks.retain(|_, t| {
            if t.context == context {
                t.stop(1);
                false
            } else {
                true
            }
        });
    }
}
pub fn retire(before: u64) {
    if let Ok(mut tasks) = tasks().lock() {
        tasks.retain(|_, t| {
            if t.context < before {
                t.stop(1);
                false
            } else {
                true
            }
        });
    }
}
/// A worker-local guard scopes raw image-file measurements/limits to this job.
/// No Rc or native handle ever leaves the reader thread.
#[derive(Default)]
pub struct SourceScope(Rc<RefCell<Option<Arc<Task>>>>);
impl SourceScope {
    pub fn enter(&self, task: Option<Arc<Task>>) -> SourceGuard {
        let previous = self.0.replace(task);
        SourceGuard(self.0.clone(), previous)
    }
    pub fn wrap(&self, source: Rc<dyn ReadAt>) -> Rc<dyn ReadAt> {
        Rc::new(ObservedSource {
            source,
            current: self.0.clone(),
        })
    }
}
pub struct SourceGuard(Rc<RefCell<Option<Arc<Task>>>>, Option<Arc<Task>>);
impl Drop for SourceGuard {
    fn drop(&mut self) {
        self.0.replace(self.1.take());
    }
}
struct ObservedSource {
    source: Rc<dyn ReadAt>,
    current: Rc<RefCell<Option<Arc<Task>>>>,
}
impl ReadAt for ObservedSource {
    fn len(&self) -> u64 {
        self.source.len()
    }
    fn read_at(&self, offset: u64, out: &mut [u8]) -> Result<usize> {
        let task = self.current.borrow().clone();
        let Some(task) = task else {
            return self.source.read_at(offset, out);
        };
        task.reserve(true, out.len())?;
        let started = Instant::now();
        let result = self.source.read_at(offset, out);
        task.record(
            true,
            offset,
            out.len(),
            result.as_ref().copied().unwrap_or(0),
            started.elapsed(),
        );
        task.check()?;
        result
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn limits_survive_reopens_and_repeated_offsets() {
        let task = Task::new(0, 0, true, Duration::from_secs(8), 32, 64);
        for _ in 0..4 {
            task.open().unwrap();
            task.reserve(false, 8).unwrap();
        }
        assert!(task.reserve(false, 1).is_err());
        assert!(task.open().is_err());
        assert_eq!(task.stats()["file_reserved"], 32);
        assert_eq!(task.stats()["reason"], "read_budget");
    }
    #[test]
    fn source_limits_and_deadlines_do_not_depend_on_dart_polling() {
        let task = Task::new(0, 0, false, Duration::from_secs(8), 32, 64);
        task.reserve(true, 64).unwrap();
        assert!(task.reserve(true, 1).is_err());
        let expired = Task::new(0, 0, false, Duration::ZERO, 32, 64);
        assert!(expired.open().is_err());
        assert_eq!(expired.stats()["reason"], "deadline");
    }
    #[test]
    fn scoped_source_leaves_normal_reads_unrestricted() {
        struct Source;
        impl ReadAt for Source {
            fn len(&self) -> u64 {
                100
            }
            fn read_at(&self, _: u64, out: &mut [u8]) -> Result<usize> {
                out.fill(1);
                Ok(out.len())
            }
        }
        let scope = SourceScope::default();
        let source = scope.wrap(Rc::new(Source));
        let task = Arc::new(Task::new(0, 0, true, Duration::from_secs(8), 32, 8));
        {
            let _guard = scope.enter(Some(task.clone()));
            assert_eq!(source.read_at(0, &mut [0; 8]).unwrap(), 8);
            assert!(source.read_at(0, &mut [0; 1]).is_err());
        }
        assert_eq!(source.read_at(0, &mut [0; 16]).unwrap(), 16);
        assert_eq!(task.stats()["source_bytes"], 8);
    }
    #[test]
    #[ignore = "requires generated VHDX_READ_FIXTURE and native libraries"]
    fn native_source_budget_failure_preserves_healthy_volume() {
        let context = crate::vhdx_context_create();
        let call = |value: Value| crate::request_context(context, value.to_string().as_bytes());
        let image = std::env::var("VHDX_READ_FIXTURE").unwrap();
        let opened = call(json!({"op":"open","path":image}));
        assert_eq!(opened["ok"], true);
        let session = opened["session"].as_u64().unwrap();
        assert_eq!(
            call(json!({"op":"unlock","session":session,"partition":1,"mode":"none"}))["ok"],
            true
        );
        let task = Arc::new(Task::new(context, session, true, TIME_LIMIT, FILE_LIMIT, 1));
        tasks().lock().unwrap().insert(task.id, task.clone());
        let opened = call(
            json!({"op":"media_open","session":session,"path":"/payload.bin","transport":"native","thumbnail_task":task.id}),
        );
        if opened["ok"] == true {
            let file = opened["data"]["file"].as_u64().unwrap();
            assert!(crate::read_media_task(
                context,
                session,
                file,
                0,
                256 * 1024,
                &task.cancel,
                &task.cancel,
                Some(&task)
            )
            .is_err());
        } else {
            assert_eq!(opened["error"]["code"], "thumbnail_read_budget");
            assert_eq!(opened["invalidated"], false);
        }
        assert_eq!(task.stats()["reason"], "read_budget");
        assert!(task.stats()["source_reserved"].as_u64().unwrap() <= 1);
        let healthy = call(
            json!({"op":"read","session":session,"path":"/payload.bin","offset":0,"length":16}),
        );
        assert_eq!(healthy["ok"], true, "{healthy}");
        assert_eq!(call(json!({"op":"dispose"}))["ok"], true);
    }
}
