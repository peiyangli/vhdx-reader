//! Optional, shared plaintext disk cache. All access belongs to the reader worker.
//! Cache failures fall back to the source; cache data is never authoritative.
use crate::{
    source::{CacheControl, ReadAt},
    Result,
};
use sha2::{Digest, Sha256};
use std::{
    cell::RefCell,
    collections::{BTreeSet, HashMap, VecDeque},
    fs::{self, File, FileTimes, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    rc::{Rc, Weak},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use zeroize::{Zeroize, Zeroizing};

// A byte quota alone permits millions of tiny files. Both limits apply.
pub const MAX_ENTRIES: usize = 65_536;
pub const MAINTENANCE_BATCH: usize = 64;
const MAINTENANCE_SLICE: Duration = Duration::from_millis(2);
pub const MAX_PENDING_WRITES: usize = 32;
pub const MAX_PENDING_BYTES: usize = 8 * 1024 * 1024;
const TOUCH_INTERVAL: u128 = 60 * 1_000_000_000;
const HEADER: u64 = 40;
const MAGIC: &[u8; 8] = b"VHDXC001";
const MAX_PAGE: u64 = 4 * 1024 * 1024;

/// Logical cache operations, not OS syscalls or physical device I/O.
#[derive(Default, Clone, Copy, serde::Serialize)]
pub struct DiskCacheIo {
    pub read_opens: u64,
    pub metadata_checks: u64,
    pub timestamp_updates: u64,
    pub write_attempts: u64,
    pub write_commits: u64,
    pub payload_bytes_written: u64,
    pub page_allocations: u64,
    pub page_copies: u64,
    pub direct_pages: u64,
    pub buffer_hits: u64,
    pub buffer_copies: u64,
    pub buffer_dropped: u64,
}

#[derive(Clone)]
struct Entry {
    bytes: u64,
    used: u128,
    last_touch: u128,
}

struct PendingWrite {
    key: String,
    bytes: Zeroizing<Vec<u8>>,
    // Queued plaintext must not keep a closed volume/file reader alive.
    reader: Weak<()>,
}

#[derive(Default)]
struct WriteBuffer {
    enabled: bool,
    queue: VecDeque<PendingWrite>,
    bytes: usize,
}
impl WriteBuffer {
    fn empty(enabled: bool) -> Self {
        Self {
            enabled,
            ..Self::default()
        }
    }
}

#[derive(Default)]
pub struct DiskCache {
    pub control: CacheControl,
    root: Option<PathBuf>,
    // An OS lock is released automatically even when the process crashes.
    _lock: Option<File>,
    enabled: bool,
    limit: u64,
    retention: u128,
    bytes: u64,
    entries: HashMap<String, Entry>,
    order: BTreeSet<(u128, String)>,
    last_sweep: u128,
    last_used: u128,
    hits: u64,
    misses: u64,
    errors: u64,
    maintenance: Option<Maintenance>,
    io: DiskCacheIo,
    write_buffer: WriteBuffer,
}

#[derive(serde::Serialize)]
pub struct DiskCacheStatus {
    pub cache_enabled: bool,
    pub enabled: bool,
    pub bytes: u64,
    pub entries: usize,
    pub limit_bytes: u64,
    pub limit_entries: usize,
    pub maintenance_pending: bool,
    pub hits: u64,
    pub misses: u64,
    pub errors: u64,
    pub io: DiskCacheIo,
    pub pending_writes: usize,
    pub pending_write_bytes: usize,
}

enum Maintenance {
    Scan {
        candidate: Box<DiskCache>,
        directory: fs::ReadDir,
        exhausted: bool,
    },
    Trim,
    Clear {
        directory: Option<fs::ReadDir>,
        indexed: bool,
    },
}

fn now() -> u128 {
    stamp(SystemTime::now())
}
fn stamp(time: SystemTime) -> u128 {
    time.duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}
fn owned_name(name: &str, suffix: &str) -> bool {
    name.strip_suffix(suffix).is_some_and(|key| {
        key.len() == 64
            && key
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}
fn lock_directory(root: &Path) -> io::Result<File> {
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(root.join("cache.lock"))?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    #[cfg(windows)]
    {
        use std::{ffi::c_void, os::windows::io::AsRawHandle};
        #[repr(C)]
        struct Overlapped {
            internal: usize,
            internal_high: usize,
            offset: u32,
            offset_high: u32,
            event: *mut c_void,
        }
        #[link(name = "kernel32")]
        extern "system" {
            fn LockFileEx(
                file: *mut c_void,
                flags: u32,
                reserved: u32,
                low: u32,
                high: u32,
                overlapped: *mut Overlapped,
            ) -> i32;
        }
        let mut overlapped = Overlapped {
            internal: 0,
            internal_high: 0,
            offset: 0,
            offset_high: 0,
            event: std::ptr::null_mut(),
        };
        if unsafe { LockFileEx(file.as_raw_handle(), 3, 0, 1, 0, &mut overlapped) } == 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(file)
}

impl DiskCache {
    pub fn status(&self) -> DiskCacheStatus {
        DiskCacheStatus {
            cache_enabled: self.control.enabled(),
            enabled: self.enabled,
            bytes: self.bytes,
            entries: self.entries.len(),
            limit_bytes: self.limit,
            limit_entries: MAX_ENTRIES,
            maintenance_pending: self.maintenance_pending(),
            hits: self.hits,
            misses: self.misses,
            errors: self.errors,
            io: self.io,
            pending_writes: self.write_buffer.queue.len(),
            pending_write_bytes: self.write_buffer.bytes,
        }
    }

    /// Synchronous convenience API. The app worker uses begin/step instead.
    pub fn configure(
        &mut self,
        root: &Path,
        enabled: bool,
        limit: u64,
        retention_days: u32,
    ) -> io::Result<()> {
        self.begin_configure(root, enabled, limit, retention_days)?;
        self.finish_maintenance()
    }

    pub fn maintenance_pending(&self) -> bool {
        self.maintenance.is_some()
    }

    pub fn cancel_maintenance(&mut self) {
        self.maintenance = None;
    }

    fn idle(&self) -> io::Result<()> {
        if self.maintenance_pending() {
            Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "cache maintenance in progress",
            ))
        } else {
            Ok(())
        }
    }

    pub fn begin_configure(
        &mut self,
        root: &Path,
        enabled: bool,
        limit: u64,
        retention_days: u32,
    ) -> io::Result<()> {
        self.idle()?;
        if !root.is_absolute() || limit == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid disk cache configuration",
            ));
        }
        self.discard_pending_writes();
        let retention = u128::from(retention_days) * 86400 * 1_000_000_000;
        if self.root.as_deref() != Some(root) {
            if !enabled && !root.exists() {
                *self = Self {
                    control: self.control.clone(),
                    write_buffer: WriteBuffer::empty(self.write_buffer.enabled),
                    limit,
                    retention,
                    ..Self::default()
                };
                return Ok(());
            }
            fs::create_dir_all(root)?;
            if !fs::symlink_metadata(root)?.is_dir() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "cache directory required",
                ));
            }
            let lock = lock_directory(root)?;
            let directory = fs::read_dir(root)?;
            // Keep the previous manager/lock until the candidate has finished.
            let candidate = Box::new(Self {
                control: self.control.clone(),
                write_buffer: WriteBuffer::empty(self.write_buffer.enabled),
                root: Some(root.to_path_buf()),
                _lock: Some(lock),
                enabled,
                limit,
                retention,
                ..Self::default()
            });
            self.maintenance = Some(Maintenance::Scan {
                candidate,
                directory,
                exhausted: false,
            });
        } else {
            self.enabled = enabled;
            self.limit = limit;
            self.retention = retention;
            self.maintenance = Some(Maintenance::Trim);
        }
        Ok(())
    }

    pub fn begin_clear(&mut self) -> io::Result<()> {
        self.idle()?;
        self.discard_pending_writes();
        self.maintenance = Some(Maintenance::Clear {
            directory: None,
            indexed: true,
        });
        Ok(())
    }

    /// Schedule expiry without doing filesystem work in the read/write path.
    pub fn begin_due_maintenance(&mut self) {
        if !self.maintenance_pending()
            && self.root.is_some()
            && self.retention != 0
            && now().saturating_sub(self.last_sweep) >= 60 * 1_000_000_000
        {
            self.maintenance = Some(Maintenance::Trim);
        }
    }

    /// At most 64 records or 2 ms between filesystem calls. A single blocking
    /// filesystem operation cannot be preempted. True means no work remains.
    pub fn step_maintenance(&mut self) -> io::Result<bool> {
        let Some(mut task) = self.maintenance.take() else {
            return Ok(true);
        };
        let started = Instant::now();
        let result = (|| -> io::Result<bool> {
            for _ in 0..MAINTENANCE_BATCH {
                match &mut task {
                    Maintenance::Scan {
                        candidate,
                        directory,
                        exhausted,
                    } => {
                        if candidate.cleanup_one()? { /* trim before admitting more entries */
                        } else if *exhausted {
                            candidate.last_sweep = now();
                            return Ok(true);
                        } else if let Some(entry) = directory.next() {
                            candidate.scan_entry(entry?)?;
                        } else {
                            *exhausted = true;
                        }
                    }
                    Maintenance::Trim => {
                        if !self.cleanup_one()? {
                            return Ok(true);
                        }
                    }
                    Maintenance::Clear { directory, indexed } => {
                        if *indexed {
                            if let Some((_, key)) = self.order.first().cloned() {
                                self.remove(&key)?;
                            } else {
                                *directory = self.root.as_ref().map(fs::read_dir).transpose()?;
                                *indexed = false;
                            }
                        } else if let Some(entry) = directory.as_mut().and_then(Iterator::next) {
                            let entry = entry?;
                            let name = entry.file_name();
                            let name = name.to_string_lossy();
                            if entry.file_type()?.is_file()
                                && (owned_name(&name, ".tmp") || owned_name(&name, ".block"))
                            {
                                fs::remove_file(entry.path())?;
                            }
                        } else {
                            return Ok(true);
                        }
                    }
                }
                if started.elapsed() >= MAINTENANCE_SLICE {
                    break;
                }
            }
            Ok(false)
        })();
        match result {
            Ok(true) => {
                if let Maintenance::Scan { candidate, .. } = task {
                    *self = *candidate;
                }
                self.last_sweep = now();
                Ok(true)
            }
            Ok(false) => {
                self.maintenance = Some(task);
                Ok(false)
            }
            Err(error) => {
                self.errors += 1;
                self.last_sweep = now(); // retry on a later maintenance interval
                Err(error)
            }
        }
    }

    fn finish_maintenance(&mut self) -> io::Result<()> {
        while !self.step_maintenance()? {}
        Ok(())
    }

    fn scan_entry(&mut self, entry: fs::DirEntry) -> io::Result<()> {
        if !entry.file_type()?.is_file() {
            return Ok(());
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if owned_name(&name, ".tmp") {
            fs::remove_file(entry.path())?;
        } else if owned_name(&name, ".block") {
            let meta = entry.metadata()?;
            let used = stamp(meta.modified()?);
            if meta.len() <= HEADER
                || meta.len() > MAX_PAGE + HEADER
                || meta.len() > self.limit
                || (self.retention != 0 && now().saturating_sub(used) >= self.retention)
            {
                fs::remove_file(entry.path())?;
                return Ok(());
            }
            let key = name[..64].to_owned();
            if self.entries.len() >= MAX_ENTRIES {
                let oldest = self.order.first().cloned().unwrap();
                if (used, &key) <= (oldest.0, &oldest.1) {
                    fs::remove_file(entry.path())?;
                    return Ok(());
                }
                self.remove(&oldest.1)?;
            }
            self.insert(
                key,
                Entry {
                    bytes: meta.len(),
                    used,
                    last_touch: used,
                },
            );
        }
        Ok(())
    }

    fn cleanup_one(&mut self) -> io::Result<bool> {
        if let Some((used, key)) = self.order.first().cloned() {
            if self.bytes > self.limit
                || self.entries.len() > MAX_ENTRIES
                || (self.retention != 0 && now().saturating_sub(used) >= self.retention)
            {
                self.remove(&key)?;
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn recent(&mut self) -> u128 {
        self.last_used = now().max(self.last_used.saturating_add(1));
        self.last_used
    }

    fn insert(&mut self, key: String, entry: Entry) {
        self.last_used = self.last_used.max(entry.used);
        self.forget(&key);
        self.bytes += entry.bytes;
        self.order.insert((entry.used, key.clone()));
        self.entries.insert(key, entry);
    }
    fn forget(&mut self, key: &str) {
        if let Some(entry) = self.entries.remove(key) {
            self.bytes -= entry.bytes;
            self.order.remove(&(entry.used, key.to_owned()));
        }
    }
    fn path(&self, key: &str, suffix: &str) -> PathBuf {
        self.root.as_ref().unwrap().join(format!("{key}{suffix}"))
    }
    fn remove(&mut self, key: &str) -> io::Result<()> {
        match fs::remove_file(self.path(key, ".block")) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        self.forget(key);
        Ok(())
    }
    fn trim(&mut self, incoming: u64) -> io::Result<bool> {
        // A large incoming page may displace many tiny pages. Bound this path;
        // skip caching if this turn cannot make enough room. Source reads win.
        let started = Instant::now();
        for _ in 0..MAINTENANCE_BATCH {
            if self.bytes.saturating_add(incoming) <= self.limit && self.entries.len() < MAX_ENTRIES
            {
                return Ok(true);
            }
            let Some((_, key)) = self.order.first().cloned() else {
                break;
            };
            self.remove(&key)?;
            if started.elapsed() >= MAINTENANCE_SLICE {
                break;
            }
        }
        Ok(self.bytes.saturating_add(incoming) <= self.limit && self.entries.len() < MAX_ENTRIES)
    }
    pub fn maintain(&mut self) -> io::Result<()> {
        self.idle()?;
        self.maintenance = Some(Maintenance::Trim);
        self.finish_maintenance()
    }
    /// Failed deletion preserves accounting and returns an error.
    pub fn clear(&mut self) -> io::Result<u64> {
        let before = self.bytes;
        self.begin_clear()?;
        self.finish_maintenance()?;
        Ok(before.saturating_sub(self.bytes))
    }
    fn read_block(&mut self, key: &str, out: &mut [u8]) -> bool {
        if let Some(index) =
            self.write_buffer.queue.iter().position(|p| {
                p.key == key && p.reader.strong_count() > 0 && p.bytes.len() == out.len()
            })
        {
            let pending = self.write_buffer.queue.remove(index).unwrap();
            out.copy_from_slice(&pending.bytes);
            // Preserve access order when buffered pages are later committed.
            self.write_buffer.queue.push_back(pending);
            self.io.buffer_hits += 1;
            return true;
        }
        let Some(mut entry) = self.entries.get(key).cloned() else {
            self.misses += 1;
            return false;
        };
        if entry.bytes != out.len() as u64 + HEADER
            || (self.retention != 0 && now().saturating_sub(entry.used) >= self.retention)
        {
            if self.remove(key).is_err() {
                self.errors += 1;
            }
            self.misses += 1;
            return false;
        }
        let result = (|| -> io::Result<()> {
            self.io.read_opens += 1;
            let mut file = File::open(self.path(key, ".block"))?;
            self.io.metadata_checks += 1;
            if file.metadata()?.len() != entry.bytes {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "cache length changed",
                ));
            }
            let mut header = [0; HEADER as usize];
            file.read_exact(&mut header)?;
            file.read_exact(out)?;
            if &header[..8] != MAGIC || header[8..] != Sha256::digest(&*out)[..] {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "cache checksum"));
            }
            // In-process LRU still changes on every hit. Persist at most once
            // per minute, including failed attempts, without requiring write
            // access to serve verified cached bytes.
            let time = now();
            if time.saturating_sub(entry.last_touch) >= TOUCH_INTERVAL {
                entry.last_touch = time;
                self.io.timestamp_updates += 1;
                if OpenOptions::new()
                    .write(true)
                    .open(self.path(key, ".block"))
                    .and_then(|file| {
                        file.set_times(FileTimes::new().set_modified(SystemTime::now()))
                    })
                    .is_err()
                {
                    self.errors += 1;
                }
            }
            Ok(())
        })();
        if result.is_err() {
            self.errors += 1;
            let _ = self.remove(key);
            self.misses += 1;
            return false;
        }
        let used = self.recent();
        self.insert(key.to_owned(), Entry { used, ..entry });
        self.hits += 1;
        true
    }
    /// The app enables cooperative write-back; standalone callers keep the
    /// synchronous default unless they can regularly advance this queue.
    pub fn set_write_buffering(&mut self, enabled: bool) {
        self.discard_pending_writes();
        self.write_buffer.enabled = enabled;
    }

    fn discard_pending_writes(&mut self) {
        self.io.buffer_dropped += self.write_buffer.queue.len() as u64;
        self.write_buffer.queue.clear(); // Zeroizing clears every copied page.
        self.write_buffer.bytes = 0;
    }

    fn store_page(&mut self, key: &str, bytes: &[u8], reader: &Rc<()>) {
        if !self.write_buffer.enabled {
            if self.write_block(key, bytes).is_err() {
                self.errors += 1;
            }
            return;
        }
        if self
            .write_buffer
            .queue
            .iter()
            .any(|p| p.key == key && p.reader.strong_count() > 0)
        {
            return;
        }
        if bytes.is_empty()
            || bytes.len() as u64 > MAX_PAGE
            || bytes.len() as u64 + HEADER > self.limit
            || self.write_buffer.queue.len() >= MAX_PENDING_WRITES
            || self.write_buffer.bytes.saturating_add(bytes.len()) > MAX_PENDING_BYTES
        {
            self.io.buffer_dropped += 1;
            return;
        }
        self.io.buffer_copies += 1;
        self.write_buffer.queue.push_back(PendingWrite {
            key: key.to_owned(),
            bytes: Zeroizing::new(bytes.to_vec()),
            reader: Rc::downgrade(reader),
        });
        self.write_buffer.bytes += bytes.len();
    }

    /// Called only between foreground jobs on the same worker. No source or
    /// volume handle is transferred, and no write can race clear/configure.
    pub fn advance_write_buffer(&mut self) -> bool {
        if self.maintenance_pending() {
            return false;
        }
        let started = Instant::now();
        let mut progressed = false;
        for _ in 0..MAX_PENDING_WRITES {
            let Some(pending) = self.write_buffer.queue.pop_front() else {
                break;
            };
            self.write_buffer.bytes -= pending.bytes.len();
            progressed = true;
            if !self.enabled || !self.control.enabled() || pending.reader.strong_count() == 0 {
                self.io.buffer_dropped += 1;
            } else if self.write_block(&pending.key, &pending.bytes).is_err() {
                self.errors += 1;
            }
            // A single blocking filesystem call cannot be preempted.
            if started.elapsed() >= MAINTENANCE_SLICE {
                break;
            }
        }
        progressed
    }

    fn write_block(&mut self, key: &str, bytes: &[u8]) -> io::Result<()> {
        let size = bytes.len() as u64 + HEADER;
        if size > self.limit || bytes.is_empty() || bytes.len() as u64 > MAX_PAGE {
            return Ok(());
        }
        if self.entries.contains_key(key) {
            self.remove(key)?;
        }
        if !self.trim(size)? {
            return Ok(());
        }
        self.io.write_attempts += 1;
        let temporary = self.path(key, ".tmp");
        let result = (|| -> io::Result<()> {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)?;
            let mut header = [0; HEADER as usize];
            header[..8].copy_from_slice(MAGIC);
            header[8..].copy_from_slice(&Sha256::digest(bytes));
            file.write_all(&header)?;
            file.write_all(bytes)?;
            file.flush()?;
            drop(file);
            fs::rename(&temporary, self.path(key, ".block"))?;
            self.io.write_commits += 1;
            self.io.payload_bytes_written += bytes.len() as u64;
            let used = self.recent();
            self.insert(
                key.to_owned(),
                Entry {
                    bytes: size,
                    used,
                    last_touch: now(),
                },
            );
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result
    }
}

/// Wrap only after validating credentials; the surrounding memory cache remains
/// independent and can keep its existing budget and page size.
pub struct DiskCachedReader {
    source: Rc<dyn ReadAt>,
    cache: Rc<RefCell<DiskCache>>,
    identity: String,
    page_size: usize,
    write_lease: Rc<()>,
}
impl DiskCachedReader {
    pub fn new(
        source: Rc<dyn ReadAt>,
        cache: Rc<RefCell<DiskCache>>,
        identity: String,
        page_size: usize,
    ) -> Self {
        Self {
            source,
            cache,
            identity,
            page_size,
            write_lease: Rc::new(()),
        }
    }
    fn fill_page(&self, key: &str, start: u64, out: &mut [u8]) -> Result<()> {
        if !self.cache.borrow_mut().read_block(key, out) {
            if let Err(error) = self.source.read_exact_at(start, out) {
                out.zeroize();
                return Err(error);
            }
            self.cache
                .borrow_mut()
                .store_page(key, out, &self.write_lease);
        }
        Ok(())
    }
    fn key(&self, offset: u64) -> String {
        let mut hash = Sha256::new();
        hash.update(b"vhdx-file-cache-v1\0");
        hash.update(self.identity.as_bytes());
        hash.update(self.len().to_le_bytes());
        hash.update((self.page_size as u64).to_le_bytes());
        hash.update(offset.to_le_bytes());
        format!("{:x}", hash.finalize())
    }
}
impl Drop for DiskCachedReader {
    fn drop(&mut self) {
        // Ordinary close/lock wipes this reader's queued plaintext immediately.
        // If a caller holds a cache borrow, expired weak leases still prevent
        // commit and the next worker quantum wipes those pages.
        if let Ok(mut cache) = self.cache.try_borrow_mut() {
            let lease = Rc::downgrade(&self.write_lease);
            let mut removed_bytes = 0;
            let mut removed = 0;
            cache.write_buffer.queue.retain(|pending| {
                if pending.reader.ptr_eq(&lease) {
                    removed_bytes += pending.bytes.len();
                    removed += 1;
                    false
                } else {
                    true
                }
            });
            cache.write_buffer.bytes -= removed_bytes;
            cache.io.buffer_dropped += removed;
        }
    }
}

impl ReadAt for DiskCachedReader {
    fn len(&self) -> u64 {
        self.source.len()
    }
    fn read_at(&self, offset: u64, out: &mut [u8]) -> Result<usize> {
        if !self.cache.borrow().enabled
            || !self.cache.borrow().control.enabled()
            || self.cache.borrow().maintenance_pending()
        {
            return self.source.read_at(offset, out);
        }
        if offset >= self.len() || out.is_empty() {
            return Ok(0);
        }
        let length = out
            .len()
            .min((self.len() - offset).min(usize::MAX as u64) as usize);
        let mut done = 0;
        while done < length {
            let position = offset + done as u64;
            let start = position / self.page_size as u64 * self.page_size as u64;
            let size = (self.len() - start).min(self.page_size as u64) as usize;
            let key = self.key(start);
            let within = (position - start) as usize;
            let n = (length - done).min(size - within);
            if within == 0 && n == size {
                self.cache.borrow_mut().io.direct_pages += 1;
                self.fill_page(&key, start, &mut out[done..done + n])?;
            } else {
                self.cache.borrow_mut().io.page_allocations += 1;
                let mut bytes = Zeroizing::new(vec![0; size]);
                self.fill_page(&key, start, &mut bytes)?;
                self.cache.borrow_mut().io.page_copies += 1;
                out[done..done + n].copy_from_slice(&bytes[within..within + n]);
            }
            done += n;
        }
        Ok(done)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        cell::Cell,
        sync::atomic::{AtomicU64, Ordering},
    };
    static SCRATCH_ID: AtomicU64 = AtomicU64::new(0);
    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "vhdx-disk-cache-{}-{}-{}",
                std::process::id(),
                now(),
                SCRATCH_ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&root).unwrap();
            Self(root)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    struct Source {
        calls: Cell<usize>,
        fail: Cell<bool>,
    }
    impl Source {
        fn new() -> Rc<Self> {
            Rc::new(Self {
                calls: Cell::new(0),
                fail: Cell::new(false),
            })
        }
    }
    impl ReadAt for Source {
        fn len(&self) -> u64 {
            1024 + 17
        }
        fn read_at(&self, offset: u64, out: &mut [u8]) -> Result<usize> {
            self.calls.set(self.calls.get() + 1);
            if self.fail.get() {
                return Err(io::Error::other("test source unavailable").into());
            }
            let n = out.len().min(self.len().saturating_sub(offset) as usize);
            for (i, b) in out[..n].iter_mut().enumerate() {
                *b = ((offset + i as u64) % 251) as u8;
            }
            Ok(n)
        }
    }
    fn cache(root: &Path, limit: u64) -> Rc<RefCell<DiskCache>> {
        let mut cache = DiskCache::default();
        cache.configure(root, true, limit, 0).unwrap();
        Rc::new(RefCell::new(cache))
    }
    #[test]
    fn disk_pages_persist_validate_namespace_and_handle_short_tail() {
        let tmp = Scratch::new();
        let source = Source::new();
        let shared = cache(&tmp.0, 4096);
        let reader = DiskCachedReader::new(
            source.clone(),
            shared.clone(),
            "image-a-revision1-volume1".into(),
            64,
        );
        let mut out = [0; 80];
        reader.read_exact_at(60, &mut out).unwrap();
        assert_eq!(out, std::array::from_fn(|i| ((60 + i) % 251) as u8));
        assert_eq!(source.calls.get(), 3);
        source.fail.set(true);
        reader.read_exact_at(60, &mut out).unwrap();
        assert_eq!(source.calls.get(), 3);
        drop(reader);
        drop(shared);
        let shared = cache(&tmp.0, 4096);
        let reader = DiskCachedReader::new(
            source.clone(),
            shared.clone(),
            "image-a-revision1-volume1".into(),
            64,
        );
        reader.read_exact_at(60, &mut out).unwrap();
        assert_eq!(source.calls.get(), 3);
        let changed = DiskCachedReader::new(
            source.clone(),
            shared.clone(),
            "image-a-revision2-volume1".into(),
            64,
        );
        assert!(changed.read_exact_at(60, &mut out).is_err());
        source.fail.set(false);
        assert_eq!(reader.read_at(1039, &mut out).unwrap(), 2);
        assert_eq!(&out[..2], &[((1039) % 251) as u8, ((1040) % 251) as u8]);
        assert_eq!(reader.read_at(1041, &mut out).unwrap(), 0);
    }
    #[test]
    fn global_quota_lru_disable_master_and_clear_apply_to_live_readers() {
        let tmp = Scratch::new();
        let shared = cache(&tmp.0, 2 * (64 + HEADER));
        let source = Source::new();
        let a = DiskCachedReader::new(source.clone(), shared.clone(), "a".into(), 64);
        let b = DiskCachedReader::new(source.clone(), shared.clone(), "b".into(), 64);
        let mut out = [0; 4];
        a.read_exact_at(0, &mut out).unwrap();
        b.read_exact_at(0, &mut out).unwrap();
        a.read_exact_at(0, &mut out).unwrap();
        a.read_exact_at(64, &mut out).unwrap();
        assert!(!shared.borrow().entries.contains_key(&b.key(0)));
        assert_eq!(shared.borrow().bytes, 2 * (64 + HEADER));
        shared
            .borrow_mut()
            .configure(&tmp.0, true, 64 + HEADER, 0)
            .unwrap();
        assert_eq!(shared.borrow().entries.len(), 1);
        shared.borrow().control.set_enabled(false);
        let hits = shared.borrow().hits;
        let calls = source.calls.get();
        a.read_exact_at(64, &mut out).unwrap();
        a.read_exact_at(64, &mut out).unwrap();
        assert_eq!(source.calls.get(), calls + 2);
        assert_eq!(shared.borrow().hits, hits);
        shared.borrow().control.set_enabled(true);
        a.read_exact_at(64, &mut out).unwrap();
        assert_eq!(shared.borrow().hits, hits + 1);
        shared
            .borrow_mut()
            .configure(&tmp.0, false, 64 + HEADER, 0)
            .unwrap();
        let calls = source.calls.get();
        a.read_exact_at(64, &mut out).unwrap();
        assert_eq!(source.calls.get(), calls + 1);
        assert_eq!(shared.borrow_mut().clear().unwrap(), 64 + HEADER);
        assert_eq!(shared.borrow().bytes, 0);
        fs::write(tmp.0.join("unrelated.txt"), b"keep").unwrap();
        shared.borrow_mut().clear().unwrap();
        assert!(tmp.0.join("unrelated.txt").exists());
    }
    #[test]
    fn corrupt_blocks_and_failed_writes_fall_back_without_breaking_source_reads() {
        let tmp = Scratch::new();
        let shared = cache(&tmp.0, 4096);
        let source = Source::new();
        let reader = DiskCachedReader::new(source.clone(), shared.clone(), "a".into(), 64);
        let mut out = [0; 4];
        reader.read_exact_at(0, &mut out).unwrap();
        fs::write(shared.borrow().path(&reader.key(0), ".block"), vec![0; 104]).unwrap();
        reader.read_exact_at(0, &mut out).unwrap();
        assert_eq!(out, [0, 1, 2, 3]);
        assert_eq!(source.calls.get(), 2);
        fs::create_dir(shared.borrow().path(&reader.key(64), ".tmp")).unwrap();
        reader.read_exact_at(64, &mut out).unwrap();
        assert_eq!(out, [64, 65, 66, 67]);
        assert!(!shared.borrow().entries.contains_key(&reader.key(64)));
        assert!(shared.borrow().errors >= 2);
        source.fail.set(true);
        assert!(reader.read_exact_at(128, &mut out).is_err());
        assert!(!shared.borrow().entries.contains_key(&reader.key(128)));
    }
    #[test]
    fn permanent_retention_survives_restart_and_expiry_removes_old_blocks() {
        let tmp = Scratch::new();
        let shared = cache(&tmp.0, 4096);
        let source = Source::new();
        let reader = DiskCachedReader::new(source.clone(), shared.clone(), "a".into(), 64);
        let mut out = [0; 4];
        reader.read_exact_at(0, &mut out).unwrap();
        let path = shared.borrow().path(&reader.key(0), ".block");
        OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(FileTimes::new().set_modified(UNIX_EPOCH))
            .unwrap();
        drop(reader);
        drop(shared);
        let shared = cache(&tmp.0, 4096);
        assert_eq!(shared.borrow().entries.len(), 1);
        shared
            .borrow_mut()
            .configure(&tmp.0, true, 4096, 1)
            .unwrap();
        assert!(shared.borrow().entries.is_empty());
        assert!(!path.exists());
    }
    #[test]
    fn directory_lock_and_interrupted_write_cleanup_are_bounded() {
        let tmp = Scratch::new();
        let key = "a".repeat(64);
        fs::write(tmp.0.join(format!("{key}.tmp")), b"partial").unwrap();
        let shared = cache(&tmp.0, 128u64 << 30);
        assert_eq!(shared.borrow().bytes, 0);
        assert!(!tmp.0.join(format!("{key}.tmp")).exists());
        let mut other = DiskCache::default();
        assert!(other.configure(&tmp.0, true, 4096, 0).is_err());
        drop(shared);
        other.configure(&tmp.0, true, 4096, 0).unwrap();
    }
    #[test]
    fn clear_reports_failed_deletion_instead_of_forgetting_bytes() {
        let tmp = Scratch::new();
        let shared = cache(&tmp.0, 4096);
        let source = Source::new();
        let reader = DiskCachedReader::new(source, shared.clone(), "a".into(), 64);
        let mut out = [0; 4];
        reader.read_exact_at(0, &mut out).unwrap();
        let path = shared.borrow().path(&reader.key(0), ".block");
        fs::remove_file(&path).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(shared.borrow_mut().clear().is_err());
        assert_eq!(shared.borrow().bytes, 104);
    }
    fn blocks(root: &Path, count: usize) {
        for i in 0..count {
            fs::write(root.join(format!("{i:064x}.block")), vec![0; 104]).unwrap();
        }
    }

    #[test]
    fn scan_clear_and_expiry_yield_and_reads_bypass_pending_maintenance() {
        let tmp = Scratch::new();
        blocks(&tmp.0, 513);
        fs::write(tmp.0.join("unrelated.txt"), b"keep").unwrap();
        let mut manager = DiskCache::default();
        manager.begin_configure(&tmp.0, true, 1 << 20, 0).unwrap();
        assert!(manager.maintenance_pending());
        assert!(!manager.step_maintenance().unwrap());
        assert_eq!(manager.status().entries, 0); // candidate is not published early
        let mut turns = 1;
        while !manager.step_maintenance().unwrap() {
            turns += 1;
        }
        assert!(turns >= 513 / MAINTENANCE_BATCH);
        assert_eq!(manager.status().entries, 513);
        let shared = Rc::new(RefCell::new(manager));
        let source = Source::new();
        let reader = DiskCachedReader::new(source.clone(), shared.clone(), "new".into(), 64);
        shared.borrow_mut().begin_clear().unwrap();
        assert!(!shared.borrow_mut().step_maintenance().unwrap());
        let remaining = shared.borrow().status().entries;
        assert!((1..513).contains(&remaining));
        let mut out = [0; 4];
        reader.read_exact_at(0, &mut out).unwrap();
        assert_eq!(out, [0, 1, 2, 3]);
        assert_eq!(shared.borrow().status().entries, remaining);
        shared.borrow_mut().cancel_maintenance();
        assert!(!shared.borrow().maintenance_pending());
        // A later clear completes and never deletes unrelated files.
        shared.borrow_mut().clear().unwrap();
        assert_eq!(shared.borrow().status().entries, 0);
        assert!(tmp.0.join("unrelated.txt").exists());
        reader.read_exact_at(0, &mut out).unwrap();
        let key = reader.key(0);
        let bytes = shared.borrow().entries[&key].bytes;
        shared.borrow_mut().insert(
            key,
            Entry {
                bytes,
                used: 0,
                last_touch: 0,
            },
        );
        shared.borrow_mut().retention = 1;
        shared.borrow_mut().last_sweep = 0;
        shared.borrow_mut().begin_due_maintenance();
        shared.borrow_mut().finish_maintenance().unwrap();
        assert_eq!(shared.borrow().status().entries, 0);
    }

    #[test]
    fn scan_cancel_releases_candidate_lock_and_preserves_old_cache() {
        let old = Scratch::new();
        let new = Scratch::new();
        let mut cache = DiskCache::default();
        cache.configure(&old.0, true, 4096, 0).unwrap();
        cache.write_block(&"a".repeat(64), &[7; 64]).unwrap();
        blocks(&new.0, 200);
        cache.begin_configure(&new.0, true, 1 << 20, 0).unwrap();
        assert!(lock_directory(&old.0).is_err());
        assert!(lock_directory(&new.0).is_err());
        assert!(!cache.step_maintenance().unwrap());
        cache.cancel_maintenance();
        assert!(lock_directory(&new.0).is_ok());
        assert!(lock_directory(&old.0).is_err());
        assert_eq!(cache.root.as_ref(), Some(&old.0));
        assert_eq!(cache.status().entries, 1);
        assert!(cache.read_block(&"a".repeat(64), &mut [0; 64]));
    }

    #[test]
    fn entry_ceiling_is_independent_of_byte_quota_and_indexes_stay_in_sync() {
        let tmp = Scratch::new();
        let mut cache = DiskCache::default();
        cache.configure(&tmp.0, true, 128 << 30, 0).unwrap();
        // Metadata-only setup isolates the index ceiling; absent eviction files
        // are treated exactly like files externally removed from a cache.
        for i in 0..MAX_ENTRIES {
            cache.insert(
                format!("{i:064x}"),
                Entry {
                    bytes: 104,
                    used: i as u128,
                    last_touch: i as u128,
                },
            );
        }
        cache
            .write_block(&format!("{:064x}", MAX_ENTRIES), &[8; 64])
            .unwrap();
        assert_eq!(cache.status().entries, MAX_ENTRIES);
        assert_eq!(cache.order.len(), MAX_ENTRIES);
        assert!(!cache.entries.contains_key(&format!("{:064x}", 0)));
        assert_eq!(cache.status().bytes, MAX_ENTRIES as u64 * 104);
        assert_eq!(cache.status().limit_entries, MAX_ENTRIES);
        cache.begin_configure(&tmp.0, true, 104, 0).unwrap();
        assert!(!cache.step_maintenance().unwrap());
        assert!(cache.status().entries > 1);
        cache.finish_maintenance().unwrap();
        assert_eq!(cache.status().entries, 1);
        assert_eq!(cache.status().bytes, 104);
    }

    #[test]
    fn clear_failure_ends_task_and_preserves_bytes_for_retry() {
        let tmp = Scratch::new();
        let mut cache = DiskCache::default();
        cache.configure(&tmp.0, true, 4096, 0).unwrap();
        let key = "f".repeat(64);
        cache.write_block(&key, &[1; 64]).unwrap();
        let path = cache.path(&key, ".block");
        fs::remove_file(&path).unwrap();
        fs::create_dir(&path).unwrap();
        cache.begin_clear().unwrap();
        assert!(cache.step_maintenance().is_err());
        assert!(!cache.maintenance_pending());
        assert_eq!(cache.status().bytes, 104);
        assert_eq!(cache.status().errors, 1);
        fs::remove_dir(&path).unwrap();
        assert_eq!(cache.clear().unwrap(), 104);
    }
    #[test]
    fn hits_touch_lru_each_time_but_persist_timestamps_at_most_once_per_interval() {
        let tmp = Scratch::new();
        let shared = cache(&tmp.0, 4096);
        let source = Source::new();
        let reader = DiskCachedReader::new(source, shared.clone(), "time".into(), 64);
        let mut out = [0; 64];
        reader.read_exact_at(0, &mut out).unwrap();
        let key = reader.key(0);
        let path = shared.borrow().path(&key, ".block");
        let initial = fs::metadata(&path).unwrap().modified().unwrap();
        let used = shared.borrow().entries[&key].used;
        for _ in 0..100 {
            reader.read_exact_at(0, &mut out).unwrap();
        }
        assert_eq!(shared.borrow().io.timestamp_updates, 0);
        assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), initial);
        assert!(shared.borrow().entries[&key].used > used);
        OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(FileTimes::new().set_modified(UNIX_EPOCH))
            .unwrap();
        shared
            .borrow_mut()
            .entries
            .get_mut(&key)
            .unwrap()
            .last_touch = 0;
        for _ in 0..100 {
            reader.read_exact_at(0, &mut out).unwrap();
        }
        assert_eq!(shared.borrow().io.timestamp_updates, 1);
        assert!(fs::metadata(&path).unwrap().modified().unwrap() > UNIX_EPOCH);
        assert_eq!(shared.borrow().io.page_allocations, 0);
        assert_eq!(shared.borrow().io.page_copies, 0);
        assert_eq!(shared.borrow().io.direct_pages, 201);
    }

    #[test]
    fn direct_fill_clears_failed_page_and_preserves_partial_and_short_tail_reads() {
        let tmp = Scratch::new();
        let shared = cache(&tmp.0, 4096);
        let source = Source::new();
        let reader = DiskCachedReader::new(source.clone(), shared.clone(), "direct".into(), 64);
        let mut out = [0; 64];
        reader.read_exact_at(0, &mut out).unwrap();
        fs::write(shared.borrow().path(&reader.key(0), ".block"), [0; 104]).unwrap();
        source.fail.set(true);
        out.fill(99);
        assert!(reader.read_exact_at(0, &mut out).is_err());
        assert_eq!(out, [0; 64]);
        assert!(!shared.borrow().entries.contains_key(&reader.key(0)));
        source.fail.set(false);
        reader.read_exact_at(61, &mut out).unwrap();
        assert_eq!(out, std::array::from_fn(|i| ((61 + i) % 251) as u8));
        let mut tail = [0; 17];
        reader.read_exact_at(1024, &mut tail).unwrap();
        assert_eq!(tail, std::array::from_fn(|i| ((1024 + i) % 251) as u8));
        assert_eq!(shared.borrow().io.page_allocations, 2);
        assert_eq!(shared.borrow().io.page_copies, 2);
    }

    #[test]
    fn buffered_pages_are_deduplicated_bounded_and_do_not_survive_clear_or_reader_close() {
        let tmp = Scratch::new();
        let shared = cache(&tmp.0, 32 << 20);
        shared.borrow_mut().set_write_buffering(true);
        let source = Source::new();
        let reader = DiskCachedReader::new(source.clone(), shared.clone(), "buffer".into(), 64);
        let mut out = [0; 64];
        reader.read_exact_at(0, &mut out).unwrap();
        assert_eq!(shared.borrow().status().entries, 0);
        assert_eq!(shared.borrow().status().pending_writes, 1);
        source.fail.set(true);
        reader.read_exact_at(0, &mut out).unwrap();
        assert_eq!(shared.borrow().status().pending_writes, 1);
        assert_eq!(shared.borrow().io.buffer_hits, 1);
        assert_eq!(shared.borrow().io.write_attempts, 0);
        assert!(shared.borrow_mut().advance_write_buffer());
        assert_eq!(shared.borrow().status().entries, 1);
        source.fail.set(false);
        reader.read_exact_at(64, &mut out).unwrap();
        shared.borrow_mut().begin_clear().unwrap();
        assert_eq!(shared.borrow().status().pending_writes, 0);
        shared.borrow_mut().finish_maintenance().unwrap();
        assert!(!shared.borrow_mut().advance_write_buffer());
        assert_eq!(shared.borrow().status().entries, 0);
        reader.read_exact_at(128, &mut out).unwrap();
        drop(reader);
        shared.borrow_mut().advance_write_buffer();
        assert_eq!(shared.borrow().status().entries, 0);
        let lease = Rc::new(());
        let page = Zeroizing::new(vec![7; MAX_PAGE as usize]);
        for i in 0..3 {
            shared
                .borrow_mut()
                .store_page(&format!("{i:064x}"), &page, &lease);
        }
        assert_eq!(
            shared.borrow().status().pending_write_bytes,
            MAX_PENDING_BYTES
        );
        assert_eq!(shared.borrow().status().pending_writes, 2);
        shared.borrow_mut().discard_pending_writes();
        for i in 0..40 {
            shared
                .borrow_mut()
                .store_page(&format!("{i:064x}"), &[9; 64], &lease);
        }
        assert_eq!(shared.borrow().status().pending_writes, MAX_PENDING_WRITES);
        shared.borrow_mut().control.set_enabled(false);
        while shared.borrow_mut().advance_write_buffer() {}
        assert_eq!(shared.borrow().status().entries, 0);
        assert_eq!(shared.borrow().status().pending_write_bytes, 0);
    }

    #[test]
    fn configure_discards_buffer_and_write_failure_preserves_source_data() {
        let tmp = Scratch::new();
        let new = Scratch::new();
        let shared = cache(&tmp.0, 4096);
        shared.borrow_mut().set_write_buffering(true);
        let reader = DiskCachedReader::new(Source::new(), shared.clone(), "buffer".into(), 64);
        let mut out = [0; 64];
        reader.read_exact_at(0, &mut out).unwrap();
        shared
            .borrow_mut()
            .configure(&new.0, true, 4096, 0)
            .unwrap();
        assert_eq!(shared.borrow().status().pending_writes, 0);
        assert!(shared.borrow().write_buffer.enabled);
        assert!(!shared.borrow_mut().advance_write_buffer());
        reader.read_exact_at(64, &mut out).unwrap();
        fs::create_dir(shared.borrow().path(&reader.key(64), ".tmp")).unwrap();
        shared.borrow_mut().advance_write_buffer();
        assert!(shared.borrow().status().errors > 0);
        assert_eq!(shared.borrow().status().entries, 0);
        reader.read_exact_at(64, &mut out).unwrap();
        assert_eq!(out, std::array::from_fn(|i| (64 + i) as u8));
        shared
            .borrow_mut()
            .configure(&new.0, false, 4096, 0)
            .unwrap();
        assert!(!shared.borrow_mut().advance_write_buffer());
    }
    #[test]
    fn buffered_hits_keep_access_order_and_commits_obey_disk_quota() {
        let tmp = Scratch::new();
        let shared = cache(&tmp.0, 208);
        shared.borrow_mut().set_write_buffering(true);
        let source = Source::new();
        let reader = DiskCachedReader::new(source.clone(), shared.clone(), "lru-buffer".into(), 64);
        let mut out = [0; 64];
        for offset in [0, 64, 128, 0] {
            reader.read_exact_at(offset, &mut out).unwrap();
        }
        while shared.borrow_mut().advance_write_buffer() {}
        assert_eq!(shared.borrow().status().entries, 2);
        assert_eq!(shared.borrow().status().bytes, 208);
        assert!(shared.borrow().entries.contains_key(&reader.key(0)));
        assert!(!shared.borrow().entries.contains_key(&reader.key(64)));
        source.fail.set(true);
        reader.read_exact_at(0, &mut out).unwrap();
        assert_eq!(out, std::array::from_fn(|i| i as u8));
    }

    #[cfg(windows)]
    #[test]
    fn readonly_timestamp_failure_serves_verified_data_and_backs_off() {
        let tmp = Scratch::new();
        let shared = cache(&tmp.0, 4096);
        let source = Source::new();
        let reader = DiskCachedReader::new(source.clone(), shared.clone(), "readonly".into(), 64);
        let mut out = [0; 64];
        reader.read_exact_at(0, &mut out).unwrap();
        let key = reader.key(0);
        let path = shared.borrow().path(&key, ".block");
        let original = fs::metadata(&path).unwrap().permissions();
        let mut readonly = original.clone();
        readonly.set_readonly(true);
        fs::set_permissions(&path, readonly).unwrap();
        shared
            .borrow_mut()
            .entries
            .get_mut(&key)
            .unwrap()
            .last_touch = 0;
        source.fail.set(true);
        for _ in 0..10 {
            reader.read_exact_at(0, &mut out).unwrap();
        }
        fs::set_permissions(&path, original).unwrap();
        assert_eq!(shared.borrow().io.timestamp_updates, 1);
        assert_eq!(shared.borrow().errors, 1);
        assert_eq!(shared.borrow().hits, 10);
        assert_eq!(shared.borrow().status().entries, 1);
    }
}
