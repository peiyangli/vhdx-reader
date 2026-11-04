use crate::{
    native::{Credential, Decrypted, Disk, Entry, Ntfs, Runtime},
    partition::{partitions, Partition, VolumeKind},
    source::{CachedReader, LocalFile, ReadAt, Slice},
    Error, Result,
};
use serde::Serialize;
use std::{
    path::Path,
    rc::Rc,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

/// Cancellation is thread-safe; session/native objects deliberately are not.
#[derive(Clone, Default)]
pub struct Cancellation(Arc<AtomicBool>);
impl Cancellation {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }
    pub fn check(&self) -> Result<()> {
        if self.0.load(Ordering::Relaxed) {
            Err(Error::Cancelled)
        } else {
            Ok(())
        }
    }
}
#[derive(Serialize)]
pub struct ImageInfo {
    pub virtual_size: u64,
    pub logical_sector_size: u32,
    pub disk_type: String,
    pub partitions: Vec<Partition>,
}
pub struct Image {
    runtime: Rc<Runtime>,
    disk: Rc<Disk>,
    pub info: ImageInfo,
}
impl Image {
    pub fn credential_id(&self, index: u32) -> Result<String> {
        use sha2::{Digest, Sha256};
        let p = self
            .info
            .partitions
            .iter()
            .find(|p| p.index == index)
            .ok_or(Error::Locked)?;
        if !matches!(p.kind, VolumeKind::BitLocker) {
            return Err(Error::Unsupported("not BitLocker".into()));
        }
        let source = Rc::new(Slice::new(self.disk.clone(), p.offset, p.length)?);
        let identity = Decrypted::identity(&self.runtime, source)?;
        let mut hash = Sha256::new();
        hash.update(b"vhdx-reader:bitlocker-credential:v1\0");
        hash.update(p.offset.to_le_bytes());
        hash.update(p.length.to_le_bytes());
        hash.update(identity);
        Ok(format!("v1-{:x}", hash.finalize()))
    }

    pub fn open(runtime: Rc<Runtime>, path: &Path) -> Result<Self> {
        let source = Rc::new(LocalFile::open(path)?);
        Self::from_source(runtime, source)
    }
    pub fn from_source(runtime: Rc<Runtime>, source: Rc<dyn ReadAt>) -> Result<Self> {
        let disk = Disk::open(&runtime, source)?;
        let info = ImageInfo {
            virtual_size: disk.len(),
            logical_sector_size: disk.sector_size,
            disk_type: if disk.disk_type == 2 {
                "fixed"
            } else {
                "dynamic"
            }
            .into(),
            partitions: partitions(disk.as_ref(), disk.sector_size)?,
        };
        Ok(Self {
            runtime,
            disk,
            info,
        })
    }
    pub fn unlock(
        &self,
        index: u32,
        credential: Option<&Credential>,
        cache_bytes: usize,
    ) -> Result<Volume> {
        let partition = self
            .info
            .partitions
            .iter()
            .find(|p| p.index == index)
            .ok_or_else(|| Error::NotFound(format!("partition {index}")))?;
        let source: Rc<dyn ReadAt> = Rc::new(Slice::new(
            self.disk.clone(),
            partition.offset,
            partition.length,
        )?);
        let (source, encryption_method): (Rc<dyn ReadAt>, Option<u16>) = match partition.kind {
            VolumeKind::Ntfs => (source, None),
            VolumeKind::BitLocker => {
                let decrypted = Decrypted::open(&self.runtime, source, credential)?;
                let method = decrypted.encryption_method;
                (decrypted, Some(method))
            }
            VolumeKind::Unknown => {
                return Err(Error::Unsupported(
                    "partition is neither NTFS nor BitLocker".into(),
                ))
            }
        };
        if crate::partition::detect_volume(source.as_ref(), 0)? != VolumeKind::Ntfs {
            return Err(Error::Unsupported("unlocked filesystem is not NTFS".into()));
        }
        let cached = Rc::new(CachedReader::new(source, 64 * 1024, cache_bytes)?);
        let fs = Ntfs::open(&self.runtime, cached)?;
        Ok(Volume {
            fs,
            encryption_method,
        })
    }
}
pub struct Volume {
    fs: Rc<Ntfs>,
    pub encryption_method: Option<u16>,
}
#[derive(Serialize, Debug)]
pub struct FileInfo {
    pub name: String,
    pub directory: bool,
    pub size: u64,
    pub attributes: u32,
}
#[derive(Serialize)]
pub struct DirectoryPage {
    pub entries: Vec<FileInfo>,
    pub total_entries: u32,
    pub next_index: Option<u32>,
}
impl Volume {
    pub fn list(
        &self,
        path: &str,
        start: u32,
        limit: u32,
        cancel: &Cancellation,
    ) -> Result<DirectoryPage> {
        cancel.check()?;
        if limit == 0 || limit > 10000 {
            return Err(Error::Invalid(
                "directory page size must be 1..10000".into(),
            ));
        }
        let directory = self.fs.entry(path)?;
        let total = directory.child_count()?;
        if start > total {
            return Err(Error::Invalid(
                "directory offset exceeds entry count".into(),
            ));
        }
        let end = start.saturating_add(limit).min(total);
        let mut entries = Vec::with_capacity((end - start) as usize);
        for i in start..end {
            cancel.check()?;
            let entry = directory.child(i)?;
            let directory = entry.is_directory()?;
            entries.push(FileInfo {
                name: entry.name()?,
                directory,
                size: if directory { 0 } else { entry.size()? },
                attributes: entry.flags()?,
            });
        }
        Ok(DirectoryPage {
            entries,
            total_entries: total,
            next_index: if end < total { Some(end) } else { None },
        })
    }
    pub fn open_file(&self, path: &str) -> Result<File> {
        let entry = self.fs.entry(path)?;
        entry.ensure_browsable()?;
        if entry.is_directory()? {
            return Err(Error::Invalid("expected a file".into()));
        }
        let size = entry.size()?;
        Ok(File { entry, size })
    }
}
pub struct File {
    entry: Entry,
    size: u64,
}
impl File {
    pub fn len(&self) -> u64 {
        self.size
    }
    pub fn is_empty(&self) -> bool {
        self.size == 0
    }
    pub fn read_at(&self, offset: u64, buffer: &mut [u8], cancel: &Cancellation) -> Result<usize> {
        cancel.check()?;
        if buffer.len() > 4 * 1024 * 1024 {
            return Err(Error::Invalid(
                "single read exceeds 4 MiB; split into cancellable chunks".into(),
            ));
        }
        let n = self.entry.read_at(offset, buffer)?;
        cancel.check()?;
        Ok(n)
    }
}
