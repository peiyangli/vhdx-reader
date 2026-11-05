use crate::{Error, Result};
use std::{cell::RefCell, collections::HashMap, fs::File, path::Path, rc::Rc};

/// Synchronous random access. A session owns this on one worker thread.
pub trait ReadAt {
    fn len(&self) -> u64;
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
    /// Short reads at EOF are allowed; errors must never be turned into zero-filled data.
    fn read_at(&self, offset: u64, buffer: &mut [u8]) -> Result<usize>;
    fn read_exact_at(&self, mut offset: u64, mut buffer: &mut [u8]) -> Result<()> {
        checked_range(offset, buffer.len(), self.len())?;
        while !buffer.is_empty() {
            let n = self.read_at(offset, buffer)?;
            if n == 0 || n > buffer.len() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "source was truncated or disconnected",
                )
                .into());
            }
            offset += n as u64;
            buffer = &mut buffer[n..];
        }
        Ok(())
    }
}

pub(crate) fn checked_range(offset: u64, size: usize, len: u64) -> Result<()> {
    if offset.checked_add(size as u64).is_none_or(|end| end > len) {
        return Err(Error::Invalid("read exceeds source bounds".into()));
    }
    Ok(())
}

pub struct LocalFile {
    file: File,
    len: u64,
}
/// Borrow a platform-owned descriptor only long enough to duplicate it. The caller
/// keeps the original alive until this returns; our File owns only the duplicate.
pub fn duplicate_file_descriptor(fd: i32) -> Result<File> {
    #[cfg(unix)]
    {
        use std::os::fd::FromRawFd;
        // fcntl validates invalid integers without constructing a borrowed Rust FD.
        let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
        if copy < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(unsafe { File::from_raw_fd(copy) })
    }
    #[cfg(not(unix))]
    {
        let _ = fd;
        Err(Error::Unsupported(
            "file descriptors on this platform".into(),
        ))
    }
}
impl LocalFile {
    pub fn open(path: &Path) -> Result<Self> {
        let mut options = std::fs::OpenOptions::new();
        options.read(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.share_mode(1); // FILE_SHARE_READ: deny concurrent writers and deletion.
        }
        let file = options.open(path)?;
        Self::from_file(file)
    }
    pub fn from_file(file: File) -> Result<Self> {
        let metadata = file.metadata()?;
        if !metadata.is_file() {
            return Err(Error::Unsupported("expected a regular image file".into()));
        }
        let source = Self {
            file,
            len: metadata.len(),
        };
        // Reject pipe-like providers and incorrect random-access implementations.
        if source.len > 0 {
            source.read_exact_at(source.len - 1, &mut [0])?;
        }
        Ok(source)
    }
}
impl ReadAt for LocalFile {
    fn len(&self) -> u64 {
        self.len
    }
    fn read_at(&self, offset: u64, buffer: &mut [u8]) -> Result<usize> {
        if offset >= self.len || buffer.is_empty() {
            return Ok(0);
        }
        let n = buffer
            .len()
            .min((self.len - offset).min(usize::MAX as u64) as usize);
        #[cfg(unix)]
        {
            use std::os::unix::fs::FileExt;
            Ok(self.file.read_at(&mut buffer[..n], offset)?)
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::FileExt;
            Ok(self.file.seek_read(&mut buffer[..n], offset)?)
        }
    }
}

pub struct Slice {
    source: Rc<dyn ReadAt>,
    offset: u64,
    len: u64,
}
impl Slice {
    pub fn new(source: Rc<dyn ReadAt>, offset: u64, len: u64) -> Result<Self> {
        if offset.checked_add(len).is_none_or(|end| end > source.len()) {
            return Err(Error::Invalid("partition exceeds disk bounds".into()));
        }
        Ok(Self {
            source,
            offset,
            len,
        })
    }
}
impl ReadAt for Slice {
    fn len(&self) -> u64 {
        self.len
    }
    fn read_at(&self, offset: u64, buffer: &mut [u8]) -> Result<usize> {
        if offset >= self.len {
            return Ok(0);
        }
        let n = buffer
            .len()
            .min((self.len - offset).min(usize::MAX as u64) as usize);
        self.source.read_at(self.offset + offset, &mut buffer[..n])
    }
}

struct Page {
    bytes: zeroize::Zeroizing<Vec<u8>>,
    previous: Option<u64>,
    next: Option<u64>,
}
struct Cache {
    pages: HashMap<u64, Page>,
    oldest: Option<u64>,
    newest: Option<u64>,
}
impl Cache {
    // Intrusive LRU links keep hits and evictions O(1), with no timestamp wrap.
    fn unlink(&mut self, index: u64) {
        let page = &self.pages[&index];
        let (previous, next) = (page.previous, page.next);
        if let Some(previous) = previous {
            self.pages.get_mut(&previous).unwrap().next = next;
        } else {
            self.oldest = next;
        }
        if let Some(next) = next {
            self.pages.get_mut(&next).unwrap().previous = previous;
        } else {
            self.newest = previous;
        }
    }
    fn append(&mut self, index: u64) {
        let page = self.pages.get_mut(&index).unwrap();
        page.previous = self.newest;
        page.next = None;
        if let Some(newest) = self.newest {
            self.pages.get_mut(&newest).unwrap().next = Some(index);
        } else {
            self.oldest = Some(index);
        }
        self.newest = Some(index);
    }
    fn touch(&mut self, index: u64) {
        if self.newest != Some(index) {
            self.unlink(index);
            self.append(index);
        }
    }
}
/// A bounded plaintext page cache. Evicted pages are zeroized before deallocation.
pub struct CachedReader {
    source: Rc<dyn ReadAt>,
    page_size: usize,
    capacity: usize,
    cache: RefCell<Cache>,
}
impl CachedReader {
    pub fn new(source: Rc<dyn ReadAt>, page_size: usize, budget: usize) -> Result<Self> {
        if page_size == 0 || budget < page_size {
            return Err(Error::Invalid(
                "cache budget must contain at least one nonempty page".into(),
            ));
        }
        Ok(Self {
            source,
            page_size,
            capacity: budget / page_size,
            cache: RefCell::new(Cache {
                pages: HashMap::new(),
                oldest: None,
                newest: None,
            }),
        })
    }
}
impl ReadAt for CachedReader {
    fn len(&self) -> u64 {
        self.source.len()
    }
    fn read_at(&self, offset: u64, buffer: &mut [u8]) -> Result<usize> {
        if offset >= self.len() || buffer.is_empty() {
            return Ok(0);
        }
        let total = buffer
            .len()
            .min((self.len() - offset).min(usize::MAX as u64) as usize);
        let mut done = 0;
        let mut cache = self.cache.borrow_mut();
        while done < total {
            let position = offset + done as u64;
            let index = position / self.page_size as u64;
            let within = (position % self.page_size as u64) as usize;
            if !cache.pages.contains_key(&index) {
                let start = index * self.page_size as u64;
                let size = (self.len() - start).min(self.page_size as u64) as usize;
                // Evict before allocating and reuse the allocation. Erase all old
                // plaintext, including the tail when the next page is shorter.
                let mut bytes = if cache.pages.len() == self.capacity {
                    use zeroize::Zeroize;
                    let oldest = cache.oldest.unwrap();
                    cache.unlink(oldest);
                    let mut bytes = cache.pages.remove(&oldest).unwrap().bytes;
                    bytes.as_mut_slice().zeroize();
                    bytes.resize(size, 0);
                    bytes
                } else {
                    zeroize::Zeroizing::new(vec![0; size])
                };
                // A failed/short fill never becomes a cache hit; the temporary
                // buffer is zeroized on error and the remaining LRU stays valid.
                self.source.read_exact_at(start, &mut bytes)?;
                cache.pages.insert(
                    index,
                    Page {
                        bytes,
                        previous: None,
                        next: None,
                    },
                );
                cache.append(index);
            } else {
                cache.touch(index);
            }
            let page = &cache.pages[&index];
            let n = (total - done).min(page.bytes.len() - within);
            buffer[done..done + n].copy_from_slice(&page.bytes[within..within + n]);
            done += n;
        }
        Ok(done)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::cell::Cell;
    pub struct Memory(pub Vec<u8>);
    impl ReadAt for Memory {
        fn len(&self) -> u64 {
            self.0.len() as u64
        }
        fn read_at(&self, offset: u64, buffer: &mut [u8]) -> Result<usize> {
            let start = usize::try_from(offset)
                .unwrap_or(usize::MAX)
                .min(self.0.len());
            let n = buffer.len().min(self.0.len() - start);
            buffer[..n].copy_from_slice(&self.0[start..start + n]);
            Ok(n)
        }
    }
    struct Counting {
        memory: Memory,
        reads: Cell<usize>,
    }
    impl ReadAt for Counting {
        fn len(&self) -> u64 {
            self.memory.len()
        }
        fn read_at(&self, o: u64, b: &mut [u8]) -> Result<usize> {
            self.reads.set(self.reads.get() + 1);
            self.memory.read_at(o, b)
        }
    }
    #[test]
    fn cache_cross_page_eof_hits_and_eviction() {
        let source = Rc::new(Counting {
            memory: Memory((0..250).collect()),
            reads: Cell::new(0),
        });
        let cache = CachedReader::new(source.clone(), 64, 128).unwrap();
        let mut out = [0; 100];
        cache.read_exact_at(50, &mut out).unwrap();
        assert_eq!(&out[..], &(50..150).collect::<Vec<u8>>());
        assert_eq!(source.reads.get(), 3);
        cache.read_exact_at(64, &mut out[..64]).unwrap();
        assert_eq!(source.reads.get(), 3);
        assert_eq!(cache.read_at(240, &mut out).unwrap(), 10);
        cache.read_exact_at(0, &mut out[..1]).unwrap();
        assert_eq!(source.reads.get(), 5);
        assert!(cache.read_exact_at(u64::MAX, &mut out).is_err());
    }
    #[test]
    fn cache_matches_reference_lru_across_capacity_and_partial_pages() {
        use std::collections::VecDeque;
        for capacity in 1..=5 {
            let source = Rc::new(Counting {
                memory: Memory((0..501).map(|n| (n % 251) as u8).collect()),
                reads: Cell::new(0),
            });
            let cache = CachedReader::new(source.clone(), 17, capacity * 17).unwrap();
            let mut recent = VecDeque::new();
            let mut expected_reads = 0;
            let mut state = 1u64;
            for _ in 0..2000 {
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
                let offset = (state >> 32) as usize % 520;
                let length = state as usize % 55;
                let mut out = vec![0xff; length];
                let n = cache.read_at(offset as u64, &mut out).unwrap();
                let expected_len = length.min(501usize.saturating_sub(offset));
                assert_eq!(n, expected_len);
                if n > 0 {
                    assert_eq!(out[..n], source.memory.0[offset..offset + n]);
                    for page in offset / 17..=(offset + n - 1) / 17 {
                        if let Some(at) = recent.iter().position(|p| *p == page) {
                            recent.remove(at);
                        } else {
                            expected_reads += 1;
                            if recent.len() == capacity {
                                recent.pop_front();
                            }
                        }
                        recent.push_back(page);
                    }
                }
                assert_eq!(source.reads.get(), expected_reads);
                assert_eq!(cache.cache.borrow().pages.len(), recent.len());
            }
        }
    }
    #[test]
    fn failed_cache_fill_is_not_retained_and_lru_can_recover() {
        struct Fallible {
            fail: Cell<bool>,
        }
        impl ReadAt for Fallible {
            fn len(&self) -> u64 {
                130
            }
            fn read_at(&self, offset: u64, out: &mut [u8]) -> Result<usize> {
                // Return a partial read, then fail partway through a page fill.
                if self.fail.get() && offset >= 70 {
                    return Err(std::io::Error::other("disconnected").into());
                }
                let n = out.len().min(3).min((130 - offset) as usize);
                out[..n].fill(42);
                Ok(n)
            }
        }
        let source = Rc::new(Fallible {
            fail: Cell::new(true),
        });
        let cache = CachedReader::new(source.clone(), 64, 64).unwrap();
        let mut out = [0; 64];
        cache.read_exact_at(0, &mut out).unwrap();
        assert!(cache.read_exact_at(64, &mut out).is_err());
        assert!(cache.cache.borrow().pages.is_empty());
        assert!(cache.cache.borrow().oldest.is_none());
        assert!(cache.cache.borrow().newest.is_none());
        source.fail.set(false);
        cache.read_exact_at(64, &mut out).unwrap();
        assert_eq!(out, [42; 64]);
        assert_eq!(cache.read_at(128, &mut out).unwrap(), 2);
        cache.read_exact_at(0, &mut out).unwrap();
        assert_eq!(out, [42; 64]);
    }
    #[test]
    fn slice_never_exposes_next_partition() {
        let source = Rc::new(Memory((0..200).collect()));
        let slice = Slice::new(source.clone(), 80, 20).unwrap();
        let mut out = [0; 64];
        assert_eq!(slice.read_at(10, &mut out).unwrap(), 10);
        assert_eq!(&out[..10], &(90..100).collect::<Vec<u8>>());
        assert!(Slice::new(source, 190, 20).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn descriptor_owns_duplicate_reads_above_4gib_and_detects_truncation() {
        use std::os::{fd::AsRawFd, unix::fs::FileExt};
        let path = std::env::temp_dir().join(format!("vhdx-fd-{}", std::process::id()));
        let original = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        let offset = (1u64 << 32) + 17;
        original.set_len(offset + 6).unwrap();
        original.write_all_at(b"offset", offset).unwrap();
        let source =
            LocalFile::from_file(duplicate_file_descriptor(original.as_raw_fd()).unwrap()).unwrap();
        drop(original);
        let mut bytes = [0; 6];
        source.read_exact_at(offset, &mut bytes).unwrap();
        assert_eq!(&bytes, b"offset");
        std::fs::OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(0)
            .unwrap();
        assert!(source.read_exact_at(offset, &mut bytes).is_err());
        drop(source);
        std::fs::remove_file(path).unwrap();
        assert!(duplicate_file_descriptor(-1).is_err());
    }
}
