//! Optional, shared plaintext disk cache. All access belongs to the reader worker.
//! Cache failures fall back to the source; cache data is never authoritative.
use crate::{
    source::{CacheControl, ReadAt},
    Result,
};
use sha2::{Digest, Sha256};
use std::{
    cell::RefCell,
    collections::{BTreeSet, HashMap},
    fs::{self, File, FileTimes, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    rc::Rc,
    time::{SystemTime, UNIX_EPOCH},
};
use zeroize::Zeroizing;

const HEADER: u64 = 40;
const MAGIC: &[u8; 8] = b"VHDXC001";
const MAX_PAGE: u64 = 4 * 1024 * 1024;

#[derive(Clone)]
struct Entry {
    bytes: u64,
    used: u128,
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
}

#[derive(serde::Serialize)]
pub struct DiskCacheStatus {
    pub cache_enabled: bool,
    pub enabled: bool,
    pub bytes: u64,
    pub entries: usize,
    pub limit_bytes: u64,
    pub hits: u64,
    pub misses: u64,
    pub errors: u64,
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
            hits: self.hits,
            misses: self.misses,
            errors: self.errors,
        }
    }

    /// Capacity is shared by every volume using this manager. No space is reserved.
    pub fn configure(
        &mut self,
        root: &Path,
        enabled: bool,
        limit: u64,
        retention_days: u32,
    ) -> io::Result<()> {
        if !root.is_absolute() || limit == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid disk cache configuration",
            ));
        }
        if self.root.as_deref() != Some(root) {
            // Do not create a directory merely because a disabled default was loaded.
            if !enabled && !root.exists() {
                *self = Self {
                    control: self.control.clone(),
                    limit,
                    retention: u128::from(retention_days) * 86400 * 1_000_000_000,
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
            let mut candidate = Self {
                control: self.control.clone(),
                root: Some(root.to_path_buf()),
                _lock: Some(lock),
                ..Self::default()
            };
            for entry in fs::read_dir(root)? {
                let entry = entry?;
                if !entry.file_type()?.is_file() {
                    continue;
                }
                let name = entry.file_name().to_string_lossy().into_owned();
                if owned_name(&name, ".tmp") {
                    fs::remove_file(entry.path())?;
                } else if owned_name(&name, ".block") {
                    let meta = entry.metadata()?;
                    if meta.len() <= HEADER || meta.len() > MAX_PAGE + HEADER {
                        fs::remove_file(entry.path())?;
                        continue;
                    }
                    let key = name[..64].to_owned();
                    candidate.insert(
                        key,
                        Entry {
                            bytes: meta.len(),
                            used: stamp(meta.modified()?),
                        },
                    );
                }
            }
            *self = candidate;
        }
        self.enabled = enabled;
        self.limit = limit;
        self.retention = u128::from(retention_days) * 86400 * 1_000_000_000;
        self.maintain()?;
        self.trim(0)
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
    fn trim(&mut self, incoming: u64) -> io::Result<()> {
        while self.bytes.saturating_add(incoming) > self.limit {
            let Some((_, key)) = self.order.first().cloned() else {
                break;
            };
            self.remove(&key)?;
        }
        Ok(())
    }
    pub fn maintain(&mut self) -> io::Result<()> {
        let time = now();
        self.last_sweep = time;
        if self.retention == 0 {
            return Ok(());
        }
        while let Some((used, key)) = self.order.first().cloned() {
            if time.saturating_sub(used) < self.retention {
                break;
            }
            self.remove(&key)?;
        }
        Ok(())
    }
    /// Delete only managed blocks, including any left by an interrupted write.
    /// A failed deletion is reported; it must not claim the space was freed.
    pub fn clear(&mut self) -> io::Result<u64> {
        let before = self.bytes;
        let mut error = None;
        let keys: Vec<_> = self.entries.keys().cloned().collect();
        for key in keys {
            if let Err(e) = self.remove(&key) {
                error = Some(e);
            }
        }
        if let Some(root) = &self.root {
            for entry in fs::read_dir(root)? {
                let entry = entry?;
                if entry.file_type()?.is_file()
                    && owned_name(&entry.file_name().to_string_lossy(), ".tmp")
                {
                    if let Err(e) = fs::remove_file(entry.path()) {
                        error = Some(e);
                    }
                }
            }
        }
        match error {
            Some(e) => Err(e),
            None => Ok(before - self.bytes),
        }
    }
    fn read_block(&mut self, key: &str, out: &mut [u8]) -> bool {
        let Some(entry) = self.entries.get(key).cloned() else {
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
            let mut file = OpenOptions::new()
                .read(true)
                .write(true)
                .open(self.path(key, ".block"))?;
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
            // Persist last use for retention/LRU after restart. Timestamp failure
            // does not invalidate successfully verified data.
            if file
                .set_times(FileTimes::new().set_modified(SystemTime::now()))
                .is_err()
            {
                self.errors += 1;
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
    fn write_block(&mut self, key: &str, bytes: &[u8]) -> io::Result<()> {
        let size = bytes.len() as u64 + HEADER;
        if size > self.limit || bytes.is_empty() || bytes.len() as u64 > MAX_PAGE {
            return Ok(());
        }
        if now().saturating_sub(self.last_sweep) >= 60 * 1_000_000_000 {
            self.maintain()?;
        }
        if self.entries.contains_key(key) {
            self.remove(key)?;
        }
        self.trim(size)?;
        let temporary = self.path(key, ".tmp");
        let result = (|| -> io::Result<()> {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)?;
            file.write_all(MAGIC)?;
            file.write_all(&Sha256::digest(bytes))?;
            file.write_all(bytes)?;
            file.flush()?;
            drop(file);
            fs::rename(&temporary, self.path(key, ".block"))?;
            let used = self.recent();
            self.insert(key.to_owned(), Entry { bytes: size, used });
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
        }
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
impl ReadAt for DiskCachedReader {
    fn len(&self) -> u64 {
        self.source.len()
    }
    fn read_at(&self, offset: u64, out: &mut [u8]) -> Result<usize> {
        if !self.cache.borrow().enabled || !self.cache.borrow().control.enabled() {
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
            let mut bytes = Zeroizing::new(vec![0; size]);
            let key = self.key(start);
            let hit = self.cache.borrow_mut().read_block(&key, &mut bytes);
            if !hit {
                self.source.read_exact_at(start, &mut bytes)?;
                let mut cache = self.cache.borrow_mut();
                if cache.write_block(&key, &bytes).is_err() {
                    cache.errors += 1;
                }
            }
            let within = (position - start) as usize;
            let n = (length - done).min(size - within);
            out[done..done + n].copy_from_slice(&bytes[within..within + n]);
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
}
