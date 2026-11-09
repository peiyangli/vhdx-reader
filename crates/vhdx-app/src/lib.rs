//! Desktop ABI. Requests run on a dedicated Rust worker that owns all native handles.
//! Dart calls the blocking ABI from a helper isolate; the Flutter UI never waits in FFI.
mod media;
mod native_media;
mod thumbnail;
pub use native_media::{vhdx_mpv_open, MpvStreamInfo};
mod vault;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    cell::RefCell,
    collections::HashMap,
    ffi::{c_char, CString},
    io::Write,
    path::{Path, PathBuf},
    ptr,
    rc::Rc,
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc, Arc, Mutex, OnceLock,
    },
    thread,
};
use vhdx_core::{
    credentials,
    disk_cache::DiskCache,
    native::Runtime,
    session::{Cancellation, File, Image, Volume},
    source::{duplicate_file_descriptor, LocalFile},
    Error, Result,
};
use zeroize::{Zeroize, Zeroizing};

#[derive(Clone, Copy, Deserialize, serde::Serialize)]
#[serde(default, deny_unknown_fields)]
struct CacheSettings {
    plaintext_mib: usize,
    plaintext_page_kib: usize,
    ciphertext_mib: usize,
}
impl Default for CacheSettings {
    fn default() -> Self {
        Self {
            plaintext_mib: 16,
            plaintext_page_kib: 64,
            ciphertext_mib: 1,
        }
    }
}
impl CacheSettings {
    fn validate(&self) -> Result<()> {
        if ![16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384].contains(&self.plaintext_mib)
            || ![64, 128, 256, 512, 1024, 2048, 4096].contains(&self.plaintext_page_kib)
            || self.plaintext_mib.checked_mul(1024 * 1024).is_none()
            || ![1, 2, 4, 8, 16].contains(&self.ciphertext_mib)
        {
            return Err(Error::Invalid("unsupported cache size".into()));
        }
        Ok(())
    }
    fn unlock(
        &self,
        image: &Image,
        partition: u32,
        credential: Option<&vhdx_core::native::Credential>,
        disk_cache: Rc<RefCell<DiskCache>>,
        identity: String,
    ) -> Result<Volume> {
        self.validate()?;
        image.unlock_with_disk_cache(
            partition,
            credential,
            self.plaintext_mib * 1024 * 1024,
            self.ciphertext_mib * 1024 * 1024,
            self.plaintext_page_kib * 1024,
            Some((disk_cache, identity)),
        )
    }
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    DiskCacheConfigure {
        cache_enabled: bool,
        directory: String,
        enabled: bool,
        max_gib: u64,
        retention_days: u32,
    },
    DiskCacheClear,
    DiskCacheStatus,
    Dispose,
    VaultStatus {
        session: u64,
        partition: u32,
    },
    VaultList,
    VaultRemove {
        id: String,
    },
    VaultClear,
    UnlockSaved {
        session: u64,
        partition: u32,
        #[serde(default)]
        cache: CacheSettings,
    },
    ThumbnailBegin {
        session: u64,
        #[serde(default)]
        trace: bool,
    },
    ThumbnailCancel {
        task: u64,
    },
    ThumbnailFinish {
        task: u64,
    },
    MediaOpen {
        session: u64,
        path: String,
        #[serde(default)]
        transport: MediaTransport,
        #[serde(default)]
        thumbnail_task: Option<u64>,
    },
    MediaClose {
        session: u64,
        file: u64,
    },
    MediaStatus {
        session: u64,
        file: u64,
    },
    FileOpen {
        session: u64,
        path: String,
    },
    FileRead {
        session: u64,
        file: u64,
        offset: u64,
        length: usize,
    },
    FileClose {
        session: u64,
        file: u64,
    },
    Open {
        path: String,
        #[serde(default)]
        fd: Option<i32>,
        #[serde(default)]
        native_directory: Option<String>,
    },
    Unlock {
        session: u64,
        partition: u32,
        mode: String,
        #[serde(default)]
        cache: CacheSettings,
        #[serde(default)]
        secret: Option<String>,
        #[serde(default)]
        credential_file: Option<String>,
        #[serde(default)]
        credential_fd: Option<i32>,
        #[serde(default)]
        remember: bool,
        #[serde(default)]
        label: String,
    },
    List {
        session: u64,
        path: String,
        start: u32,
        limit: u32,
        #[serde(default)]
        show_system: bool,
    },
    Read {
        session: u64,
        path: String,
        offset: u64,
        length: usize,
    },
    Export {
        session: u64,
        path: String,
        output: String,
        #[serde(default)]
        output_fd: Option<i32>,
    },
    Lock {
        session: u64,
    },
    Close {
        session: u64,
    },
}
impl Drop for Request {
    fn drop(&mut self) {
        if let Self::Unlock {
            secret: Some(secret),
            ..
        } = self
        {
            secret.zeroize();
        }
    }
}
impl Request {
    fn session(&self) -> Option<u64> {
        match self {
            Self::Open { .. }
            | Self::Dispose
            | Self::VaultList
            | Self::VaultRemove { .. }
            | Self::VaultClear
            | Self::DiskCacheConfigure { .. }
            | Self::DiskCacheClear
            | Self::DiskCacheStatus => None,
            Self::VaultStatus { session, .. } | Self::UnlockSaved { session, .. } => Some(*session),
            Self::Unlock { session, .. }
            | Self::List { session, .. }
            | Self::Read { session, .. }
            | Self::Export { session, .. }
            | Self::Lock { session }
            | Self::Close { session }
            | Self::FileOpen { session, .. }
            | Self::FileRead { session, .. }
            | Self::FileClose { session, .. }
            | Self::MediaOpen { session, .. }
            | Self::MediaClose { session, .. }
            | Self::MediaStatus { session, .. } => Some(*session),
            Self::ThumbnailBegin { .. }
            | Self::ThumbnailCancel { .. }
            | Self::ThumbnailFinish { .. } => None,
        }
    }
}
#[derive(Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum MediaTransport {
    #[default]
    Http,
    Native,
}
enum MediaEndpoint {
    Http(media::Stream),
    Native(native_media::Stream),
}
struct MediaSource {
    endpoint: MediaEndpoint,
    task: Option<Arc<thumbnail::Task>>,
    read_calls: u64,
    read_bytes: u64,
    read_ns: u64,
}
impl MediaSource {
    fn stats(&self) -> Value {
        let (mut stats, transport) = match &self.endpoint {
            MediaEndpoint::Http(stream) => (stream.stats(), "http"),
            MediaEndpoint::Native(stream) => (stream.stats(), "native"),
        };
        if let Some(task) = &self.task {
            stats["thumbnail"] = task.stats();
        }
        stats["transport"] = json!(transport);
        stats["worker_read_calls"] = json!(self.read_calls);
        stats["worker_read_bytes"] = json!(self.read_bytes);
        stats["worker_read_ns"] = json!(self.read_ns);
        stats
    }
}
struct State {
    disk_cache: Rc<RefCell<DiskCache>>,
    source_identity: String,
    context: u64,
    media: HashMap<u64, MediaSource>,
    source_scope: thumbnail::SourceScope,
    runtime: Option<Rc<Runtime>>,
    image: Option<Image>,
    volume: Option<Volume>,
    generation: u64,
    files: HashMap<u64, File>,
    next_file: u64,
}
impl State {
    #[cfg(test)]
    fn new() -> Self {
        Self::with_disk_cache(Rc::new(RefCell::new(DiskCache::default())))
    }
    fn with_disk_cache(disk_cache: Rc<RefCell<DiskCache>>) -> Self {
        Self {
            disk_cache,
            source_identity: String::new(),
            context: 0,
            media: HashMap::new(),
            source_scope: thumbnail::SourceScope::default(),
            runtime: None,
            image: None,
            volume: None,
            generation: 0,
            files: HashMap::new(),
            next_file: 1,
        }
    }
    fn clear(&mut self) {
        thumbnail::revoke(self.context);
        self.media.clear();
        self.files.clear();
        self.volume = None;
        self.image = None;
        self.source_identity.clear();
        self.generation += 1;
    }
    fn reap_thumbnails(&mut self) {
        // A busy command queue can reject media_close. Expired/cancelled jobs
        // must not retain the four media slots and block subsequent thumbnails.
        let stale: Vec<_> = self
            .media
            .iter()
            .filter_map(|(id, stream)| {
                stream
                    .task
                    .as_ref()
                    .filter(|task| task.check().is_err())
                    .map(|_| *id)
            })
            .collect();
        for id in stale {
            self.media.remove(&id);
            self.files.remove(&id);
        }
    }
    fn apply(&mut self, request: &Request, cancel: &Cancellation) -> Result<Value> {
        cancel.check()?;
        if request.session().is_some_and(|id| id != self.generation) {
            return Err(Error::Invalid("stale_session".into()));
        }
        match request {
            Request::DiskCacheConfigure {
                cache_enabled,
                directory,
                enabled,
                max_gib,
                retention_days,
            } => {
                if ![1, 2, 4, 8, 16, 32, 64, 128].contains(max_gib)
                    || ![0, 1, 7, 30].contains(retention_days)
                {
                    return Err(Error::Invalid("disk_cache_settings".into()));
                }
                self.disk_cache
                    .borrow_mut()
                    .configure(
                        Path::new(directory),
                        *enabled,
                        max_gib * 1024 * 1024 * 1024,
                        *retention_days,
                    )
                    .map_err(|_| Error::Invalid("disk_cache_unavailable".into()))?;
                self.disk_cache.borrow().control.set_enabled(*cache_enabled);
                Ok(serde_json::to_value(self.disk_cache.borrow().status()).unwrap())
            }
            Request::DiskCacheClear => {
                let removed = self
                    .disk_cache
                    .borrow_mut()
                    .clear()
                    .map_err(|_| Error::Invalid("disk_cache_clear_failed".into()))?;
                Ok(
                    json!({"removed_bytes":removed,"remaining_bytes":self.disk_cache.borrow().status().bytes}),
                )
            }
            Request::DiskCacheStatus => {
                self.disk_cache
                    .borrow_mut()
                    .maintain()
                    .map_err(|_| Error::Invalid("disk_cache_cleanup_failed".into()))?;
                Ok(serde_json::to_value(self.disk_cache.borrow().status()).unwrap())
            }
            Request::ThumbnailBegin { .. }
            | Request::ThumbnailCancel { .. }
            | Request::ThumbnailFinish { .. } => Err(Error::Invalid(
                "thumbnail control must bypass worker".into(),
            )),
            Request::VaultList => {
                if vault::available() {
                    vault::list()
                } else {
                    Ok(json!({"available":false,"entries":[]}))
                }
            }
            Request::VaultRemove { id } => {
                vault::remove(id)?;
                Ok(json!({}))
            }
            Request::VaultClear => {
                vault::clear()?;
                Ok(json!({}))
            }
            Request::VaultStatus { partition, .. } => {
                if !vault::available() {
                    return Ok(json!({"available":false,"saved":false}));
                }
                let id = match self
                    .image
                    .as_ref()
                    .ok_or(Error::Locked)?
                    .credential_id(*partition)
                {
                    Ok(id) => id,
                    Err(_) => {
                        return Ok(
                            json!({"available":false,"saved":false,"reason":"无法可靠识别此卷，暂不支持记住解锁信息。"}),
                        )
                    }
                };
                let saved = vault::contains(&id)?;
                Ok(
                    json!({"available":true,"saved":saved,"id":id,"authentication_required":vault::authentication::required()}),
                )
            }
            Request::UnlockSaved {
                partition, cache, ..
            } => {
                cache.validate()?;
                let image = self.image.as_ref().ok_or(Error::Locked)?;
                let id = image.credential_id(*partition)?;
                let saved = vault::get(&id)?;
                let credential = saved.credential()?;
                cancel.check()?;
                thumbnail::revoke(self.context);
                self.media.clear();
                self.files.clear();
                self.volume = None;
                let volume = cache.unlock(
                    image,
                    *partition,
                    Some(&credential),
                    self.disk_cache.clone(),
                    self.source_identity.clone(),
                )?;
                cancel.check()?;
                let method = volume.encryption_method;
                self.volume = Some(volume);
                Ok(json!({"encryption_method":method,"automatic":true,"cache":cache}))
            }
            Request::Open {
                path,
                fd,
                native_directory,
            } => {
                self.clear();
                if self.runtime.is_none() {
                    #[cfg(any(target_os = "android", target_os = "ios"))]
                    let directory = PathBuf::from(
                        native_directory
                            .as_ref()
                            .ok_or_else(|| Error::Invalid("native directory required".into()))?,
                    );
                    #[cfg(not(any(target_os = "android", target_os = "ios")))]
                    let _ = native_directory;
                    #[cfg(not(any(target_os = "android", target_os = "ios")))]
                    let directory = if let Some(path) = std::env::var_os("VHDX_NATIVE_DIR") {
                        PathBuf::from(path)
                    } else {
                        let executable = std::env::current_exe()?;
                        let parent = executable
                            .parent()
                            .ok_or_else(|| Error::Invalid("executable directory".into()))?;
                        if cfg!(target_os = "macos") {
                            parent
                                .parent()
                                .ok_or_else(|| Error::Invalid("app bundle directory".into()))?
                                .join("Frameworks/vhdx")
                        } else {
                            parent.join("native")
                        }
                    };
                    self.runtime = Some(Runtime::load(&directory)?);
                }
                let runtime = self.runtime.as_ref().unwrap().clone();
                let source = Rc::new(if let Some(fd) = fd {
                    LocalFile::from_file(duplicate_file_descriptor(*fd)?)?
                } else {
                    LocalFile::open(Path::new(path))?
                });
                let revision = source.cache_revision();
                let version = revision.clone().unwrap_or_else(|| {
                    format!(
                        "open-{}-{}-{}",
                        self.context,
                        self.generation,
                        std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_nanos()
                    )
                });
                self.source_identity = serde_json::to_string(&(path, version)).unwrap();
                let image = Image::from_source(runtime, self.source_scope.wrap(source))?;
                cancel.check()?;
                let mut data = serde_json::to_value(&image.info)
                    .map_err(|_| Error::Invalid("image info".into()))?;
                if let Some(revision) = revision {
                    data["source_revision"] = Value::String(revision);
                }
                self.image = Some(image);
                Ok(data)
            }
            Request::Unlock {
                partition,
                mode,
                secret,
                credential_file,
                credential_fd,
                remember,
                label,
                cache,
                ..
            } => {
                cache.validate()?;
                if [
                    secret.is_some(),
                    credential_file.is_some(),
                    credential_fd.is_some(),
                ]
                .iter()
                .filter(|present| **present)
                .count()
                    > 1
                {
                    return Err(Error::Invalid("choose one credential source".into()));
                }
                if !["none", "password", "recovery"].contains(&mode.as_str()) {
                    return Err(Error::Invalid("credential mode".into()));
                }
                thumbnail::revoke(self.context);
                self.media.clear();
                self.files.clear();
                // Drop previous plaintext context before any attempt to switch/reunlock a volume.
                self.volume = None;
                let credential = if mode == "none" {
                    None
                } else if let Some(fd) = credential_fd {
                    Some(credentials::from_reader(
                        duplicate_file_descriptor(*fd)?,
                        mode == "recovery",
                    )?)
                } else if let Some(path) = credential_file {
                    Some(credentials::from_file(Path::new(path), mode == "recovery")?)
                } else {
                    Some(credentials::from_bytes(
                        secret.as_deref().unwrap_or("").as_bytes(),
                        mode == "recovery",
                        false,
                    )?)
                };
                let volume = cache.unlock(
                    self.image.as_ref().ok_or(Error::Locked)?,
                    *partition,
                    credential.as_ref(),
                    self.disk_cache.clone(),
                    self.source_identity.clone(),
                )?;
                cancel.check()?;
                let method = volume.encryption_method;
                self.volume = Some(volume);
                let mut remember_error = None;
                let saved = if *remember {
                    let result = (|| {
                        let id = self
                            .image
                            .as_ref()
                            .ok_or(Error::Locked)?
                            .credential_id(*partition)?;
                        cancel.check()?;
                        vault::save(&id, label, credential.as_ref().ok_or(Error::Locked)?)
                    })();
                    if let Err(error) = &result {
                        remember_error = Some(match error {
                            Error::Invalid(code) if code.starts_with("vault_") => code.clone(),
                            _ => "vault_unavailable".to_owned(),
                        });
                    }
                    Some(result.is_ok())
                } else {
                    None
                };
                Ok(
                    json!({"encryption_method":method,"remembered":saved,"remember_error":remember_error,"cache":cache}),
                )
            }
            Request::List {
                path,
                start,
                limit,
                show_system,
                ..
            } => {
                // Pagination refers to raw NTFS entries. Each request scans at most 2000 records.
                if *limit == 0 || *limit > 500 {
                    return Err(Error::Invalid("directory page limit".into()));
                }
                let volume = self.volume.as_ref().ok_or(Error::Locked)?;
                let mut index = *start;
                let mut entries = Vec::new();
                let mut total = 0;
                let mut scanned = 0;
                while entries.len() < *limit as usize && scanned < 2000 {
                    let batch = volume.list(
                        path,
                        index,
                        (*limit - entries.len() as u32).min(200),
                        cancel,
                    )?;
                    total = batch.total_entries;
                    index += batch.entries.len() as u32;
                    scanned += batch.entries.len();
                    entries.extend(batch.entries.into_iter().filter(|f| {
                        *show_system || (f.attributes & 6 == 0 && !f.name.starts_with('$'))
                    }));
                    if index >= total {
                        break;
                    }
                }
                Ok(
                    json!({"entries":entries,"total_entries":total,"next_index":if index<total{Some(index)}else{None}}),
                )
            }
            Request::MediaOpen {
                path,
                transport,
                thumbnail_task,
                ..
            } => {
                self.reap_thumbnails();
                let task = thumbnail_task
                    .map(|id| thumbnail::get(self.context, self.generation, id))
                    .transpose()?;
                if let Some(task) = &task {
                    task.open()?;
                }
                let _scope = self.source_scope.enter(task.clone());
                if self.media.len() >= 4 || self.files.len() >= 16 {
                    return Err(Error::Invalid("too many open media files".into()));
                }
                let result = self.volume.as_ref().ok_or(Error::Locked)?.open_file(path);
                if let Some(task) = &task {
                    task.check()?;
                }
                let file = result?;
                let id = self.next_file;
                self.next_file = self
                    .next_file
                    .checked_add(1)
                    .ok_or_else(|| Error::Invalid("file identifier exhausted".into()))?;
                let size = file.len();
                let (endpoint, url) = match transport {
                    MediaTransport::Http => {
                        let stream = media::Stream::start_task(
                            self.context,
                            self.generation,
                            id,
                            size,
                            task.clone(),
                        )?;
                        let url = stream.url.clone();
                        (MediaEndpoint::Http(stream), url)
                    }
                    MediaTransport::Native => {
                        let stream = native_media::Stream::start_task(
                            self.context,
                            self.generation,
                            id,
                            size,
                            task.clone(),
                        )?;
                        let url = stream.url.clone();
                        (MediaEndpoint::Native(stream), url)
                    }
                };
                let result = json!({"file":id,"size":size,"url":url});
                self.files.insert(id, file);
                self.media.insert(
                    id,
                    MediaSource {
                        endpoint,
                        task,
                        read_calls: 0,
                        read_bytes: 0,
                        read_ns: 0,
                    },
                );
                Ok(result)
            }
            Request::MediaClose { file, .. } => {
                self.media.remove(file);
                self.files.remove(file);
                Ok(json!({}))
            }
            Request::MediaStatus { file, .. } => {
                Ok(self.media.get(file).ok_or(Error::Locked)?.stats())
            }
            Request::FileOpen { path, .. } => {
                self.reap_thumbnails();
                if self.files.len() >= 16 {
                    return Err(Error::Invalid("too many open preview files".into()));
                }
                let file = self.volume.as_ref().ok_or(Error::Locked)?.open_file(path)?;
                let id = self.next_file;
                self.next_file = self
                    .next_file
                    .checked_add(1)
                    .ok_or_else(|| Error::Invalid("file identifier exhausted".into()))?;
                let size = file.len();
                self.files.insert(id, file);
                Ok(json!({"file":id,"size":size}))
            }
            Request::FileClose { file, .. } => {
                self.media.remove(file);
                self.files.remove(file);
                Ok(json!({}))
            }
            Request::FileRead {
                file,
                offset,
                length,
                ..
            } => {
                let file = self.files.get(file).ok_or(Error::Locked)?;
                Self::read_file(file, *offset, *length, cancel)
            }
            Request::Read {
                path,
                offset,
                length,
                ..
            } => {
                let file = self.volume.as_ref().ok_or(Error::Locked)?.open_file(path)?;
                Self::read_file(&file, *offset, *length, cancel)
            }

            Request::Export {
                path,
                output,
                output_fd,
                ..
            } => {
                let file = self.volume.as_ref().ok_or(Error::Locked)?.open_file(path)?;
                let mut destination = if let Some(fd) = output_fd {
                    duplicate_file_descriptor(*fd)?
                } else {
                    std::fs::OpenOptions::new()
                        .create_new(true)
                        .write(true)
                        .open(output)?
                };
                let result = (|| {
                    let mut bytes = Zeroizing::new(vec![0; 1024 * 1024]);
                    let mut position = 0;
                    while position < file.len() {
                        let n = file.read_at(position, &mut bytes, cancel)?;
                        if n == 0 {
                            return Err(Error::Invalid("unexpected file EOF".into()));
                        }
                        destination.write_all(&bytes[..n])?;
                        position += n as u64;
                    }
                    cancel.check()?;
                    destination.sync_all()?;
                    Ok(json!({"size":position}))
                })();
                if result.is_err() {
                    drop(destination);
                    if output_fd.is_none() {
                        let _ = std::fs::remove_file(output);
                    }
                }
                result
            }
            Request::Lock { .. } => {
                thumbnail::revoke(self.context);
                self.media.clear();
                self.files.clear();
                self.volume = None;
                self.generation += 1;
                Ok(json!({}))
            }
            Request::Close { .. } | Request::Dispose => {
                self.clear();
                Ok(json!({}))
            }
        }
    }
    fn read_file(file: &File, offset: u64, length: usize, cancel: &Cancellation) -> Result<Value> {
        if length > 1024 * 1024 {
            return Err(Error::Invalid("preview chunk exceeds 1 MiB".into()));
        }
        let mut bytes = Zeroizing::new(vec![0; length]);
        let mut done = 0;
        while done < length {
            let at = offset
                .checked_add(done as u64)
                .ok_or_else(|| Error::Invalid("offset overflow".into()))?;
            let n = file.read_at(at, &mut bytes[done..], cancel)?;
            if n == 0 {
                break;
            }
            done += n;
        }
        Ok(json!({"bytes":STANDARD.encode(&bytes[..done]),"size":file.len(),"offset":offset}))
    }
    fn handle(&mut self, request: &Request, cancel: &Cancellation) -> Value {
        match self.apply(request, cancel) {
            Ok(data) => json!({"ok":true,"session":self.generation,"data":data}),
            Err(error) => {
                let invalidated = matches!(error, Error::Native(_) | Error::Io(_))
                    && !matches!(
                        request,
                        Request::Unlock { .. }
                            | Request::UnlockSaved { .. }
                            | Request::Export { .. }
                    );
                if invalidated {
                    self.clear();
                }
                let (code, message) = match &error {
                    Error::WrongCredential => (
                        "wrong_credential",
                        "密码或恢复密钥不正确，请重试。".to_owned(),
                    ),
                    Error::Locked => ("locked", "请先解锁分区。".to_owned()),
                    Error::Cancelled => ("cancelled", "操作已取消。".to_owned()),
                    Error::NotFound(_) => ("not_found", "找不到指定文件或分区。".to_owned()),
                    Error::Io(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                        ("exists", "目标文件已存在，请选择另一个文件名。".to_owned())
                    }
                    Error::Io(_) => (
                        "io",
                        "无法访问文件。请检查存储设备、权限和目标路径。".to_owned(),
                    ),
                    Error::Native(_) => (
                        "native",
                        "读取失败。请检查镜像完整性、设备连接及依赖文件。".to_owned(),
                    ),
                    Error::Unsupported(detail) => ("unsupported", format!("暂不支持：{detail}")),
                    Error::Invalid(detail) if detail == "stale_session" => {
                        ("stale_session", "此镜像会话已关闭，请重新打开。".to_owned())
                    }
                    Error::Invalid(code) if code.starts_with("thumbnail_") => (code.as_str(), "缩略图已达到读取或时间限制。".to_owned()),
                    Error::Invalid(code) if code.starts_with("vault_") => (
                        code.as_str(),
                        match code.as_str() {
                            "vault_locked" => {
                                "设备安全存储已锁定，请解锁设备后重试，或手动输入密码。"
                            }
                            "vault_auth_cancelled" => "身份验证未完成，可重试或手动输入 BitLocker 密码。",
                            "vault_auth_unavailable" => "无法进行系统身份验证，请检查系统登录验证设置，或手动输入 BitLocker 密码。",
                            "vault_auth_busy" => "其他解锁操作正在验证身份，请完成后重试。",
                            "vault_missing" => "此卷没有已保存的解锁信息，请手动输入。",
                            "vault_corrupt" => {
                                "保存的解锁信息无法读取；可以手动解锁，或在管理页清除后重新保存。"
                            }
                            "vault_full" => {
                                "已保存的解锁信息达到容量限制，请先删除不再使用的记录。"
                            }
                            _ => "设备安全存储暂不可用，请手动解锁；原有记录未删除。",
                        }
                        .to_owned(),
                    ),
                    Error::Invalid(_) => (
                        "invalid",
                        "文件格式或输入无效，请检查镜像和解锁信息。".to_owned(),
                    ),
                };
                json!({"ok":false,"session":self.generation,"invalidated":invalidated,"error":{"code":code,"message":message}})
            }
        }
    }
}
struct Job {
    context: u64,
    request: Request,
    reply: mpsc::SyncSender<Value>,
}
struct MediaRead {
    context: u64,
    session: u64,
    file: u64,
    offset: u64,
    length: usize,
    reply: mpsc::SyncSender<Result<Zeroizing<Vec<u8>>>>,
    cancel: Cancellation,
    revoked: Cancellation,
    task: Option<Arc<thumbnail::Task>>,
}
enum WorkItem {
    Command(Job),
    Read(MediaRead),
    Retire {
        before: u64,
        reply: mpsc::SyncSender<()>,
    },
}
struct Worker {
    sender: mpsc::SyncSender<WorkItem>,
    active: Arc<Mutex<Option<(u64, Cancellation)>>>,
}
impl Worker {
    fn start() -> std::result::Result<Self, String> {
        let (sender, receiver) = mpsc::sync_channel::<WorkItem>(8);
        let active = Arc::new(Mutex::new(None));
        let shared = active.clone();
        thread::Builder::new().name("vhdx-reader".into()).spawn(move || {
            let mut states = HashMap::<u64, State>::new();
            let disk_cache = Rc::new(RefCell::new(DiskCache::default()));
            let mut retired_before = 0;
            while let Ok(item) = receiver.recv() {
                let job = match item {
                    WorkItem::Retire { before, reply } => {
                        retired_before = retired_before.max(before);
                        thumbnail::retire(retired_before);
                        states.retain(|id, _| *id >= retired_before);
                        let _ = reply.send(());
                        continue;
                    }
                    WorkItem::Command(job) => job,
                    WorkItem::Read(job) => {
                        let started = std::time::Instant::now();
                        if let Ok(mut active) = shared.lock() { *active = Some((job.context, job.cancel.clone())); }
                        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<Zeroizing<Vec<u8>>> {
                            let state = states.get(&job.context).ok_or(Error::Locked)?;
                            if state.generation != job.session || !state.media.contains_key(&job.file) { return Err(Error::Locked); }
                            let file = state.files.get(&job.file).ok_or(Error::Locked)?;
                            let _scope = state.source_scope.enter(job.task.clone());
                            if let Some(task) = &job.task { task.reserve(false, job.length.min(file.len().saturating_sub(job.offset) as usize))?; }
                            if job.length > 256 * 1024 { return Err(Error::Invalid("media chunk too large".into())); }
                            let mut bytes = Zeroizing::new(vec![0; job.length]);
                            let mut done = 0;
                            while done < job.length {
                                job.cancel.check()?;
                                job.revoked.check()?;
                                let result = file.read_at(job.offset.checked_add(done as u64).ok_or_else(|| Error::Invalid("offset overflow".into()))?, &mut bytes[done..], &job.cancel);
                                if let Some(task) = &job.task { task.check()?; }
                                let n = result?;
                                if n == 0 { break; }
                                done += n;
                            }
                            bytes.truncate(done);
                            Ok(bytes)
                        })).unwrap_or_else(|_| Err(Error::Invalid("media reader panicked".into())));
                        if let Ok(mut active) = shared.lock() { *active = None; }
                        if let Some(task) = &job.task { task.record(false, job.offset, job.length, result.as_ref().map(|b|b.len()).unwrap_or(0), started.elapsed()); }
                        if let Some(stream) = states.get_mut(&job.context).and_then(|s| s.media.get_mut(&job.file)) {
                            stream.read_calls += 1;
                            stream.read_ns = stream.read_ns.saturating_add(started.elapsed().as_nanos().min(u64::MAX as u128) as u64);
                            if let Ok(bytes) = &result { stream.read_bytes += bytes.len() as u64; }
                        }
                        if matches!(&result, Err(Error::Io(_) | Error::Native(_))) {
                            if let Some(state) = states.get_mut(&job.context) { state.clear(); }
                        }
                        let _ = job.reply.send(result);
                        continue;
                    }
                };
                if job.context < retired_before {
                    let _ = job.reply.send(failure("closed", "读取会话已关闭。"));
                    continue;
                }
                if matches!(job.request, Request::Dispose) {
                    thumbnail::revoke(job.context);
                    states.remove(&job.context);
                    let _ = job.reply.send(json!({"ok":true,"data":{}}));
                    continue;
                }
                let token = Cancellation::default();
                if let Ok(mut active) = shared.lock() {
                    *active = Some((job.context, token.clone()));
                }
                let state = states.entry(job.context).or_insert_with(|| State::with_disk_cache(disk_cache.clone()));
                state.context = job.context;
                let response = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| state.handle(&job.request, &token))) {
                    Ok(response) => response,
                    Err(_) => {
                        state.clear();
                        json!({"ok":false,"session":state.generation,"invalidated":true,"error":{"code":"internal","message":"读取会话意外结束，请重新打开镜像。"}})
                    }
                };
                if let Ok(mut active) = shared.lock() { *active = None; }
                let _ = job.reply.send(response);
            }
        }).map_err(|e| e.to_string())?;
        Ok(Self { sender, active })
    }
}
static WORKER: OnceLock<std::result::Result<Worker, String>> = OnceLock::new();
static NEXT_CONTEXT: AtomicU64 = AtomicU64::new(1);
// Android engine teardown also happens when Dart cannot run widget.dispose.
// Retire only older IDs: a newly created Flutter engine must remain unaffected.
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_org_vhdxreader_vhdx_1reader_MainActivity_contextWatermark(
    _env: *mut std::ffi::c_void,
    _this: *mut std::ffi::c_void,
) -> i64 {
    NEXT_CONTEXT.load(Ordering::SeqCst) as i64
}
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_org_vhdxreader_vhdx_1reader_MainActivity_retireContextsBefore(
    _env: *mut std::ffi::c_void,
    _this: *mut std::ffi::c_void,
    before: i64,
) -> u8 {
    vhdx_retire_contexts_before(before as u64)
}
/// Engine hosts use this boundary to retire their readers before releasing file grants.
#[no_mangle]
pub extern "C" fn vhdx_context_watermark() -> u64 {
    NEXT_CONTEXT.load(Ordering::SeqCst)
}
#[no_mangle]
pub extern "C" fn vhdx_retire_contexts_before(before: u64) -> u8 {
    let result = std::panic::catch_unwind(|| {
        let Ok(worker) = WORKER.get_or_init(Worker::start) else {
            return false;
        };
        let (reply, receive) = mpsc::sync_channel(1);
        worker
            .sender
            .send(WorkItem::Retire { before, reply })
            .is_ok()
            && receive
                .recv_timeout(std::time::Duration::from_secs(30))
                .is_ok()
    });
    u8::from(result.unwrap_or(false))
}
#[no_mangle]
pub extern "C" fn vhdx_context_create() -> u64 {
    NEXT_CONTEXT.fetch_add(1, Ordering::Relaxed)
}
#[no_mangle]
pub extern "C" fn vhdx_api_version() -> u32 {
    9
}
fn failure(code: &str, message: &str) -> Value {
    json!({"ok":false,"error":{"code":code,"message":message}})
}

/// JSON request/response adapter used by the desktop client and native integration tests.
pub fn request_json(input: &[u8]) -> Value {
    request_context(0, input)
}

/// Each context owns an independent image, unlock state and generation.
pub fn request_context(context: u64, input: &[u8]) -> Value {
    if input.len() > 1024 * 1024 {
        return failure("invalid", "请求过大。");
    }
    let request: Request = match serde_json::from_slice(input) {
        Ok(request) => request,
        Err(_) => return failure("invalid", "请求格式无效。"),
    };
    // Metadata-only controls must remain callable while native reads block.
    let control = match &request {
        Request::ThumbnailBegin { session, trace } => {
            Some(thumbnail::begin(context, *session, *trace))
        }
        Request::ThumbnailCancel { task } => Some(thumbnail::end(context, *task, false)),
        Request::ThumbnailFinish { task } => Some(thumbnail::end(context, *task, true)),
        _ => None,
    };
    if let Some(result) = control {
        return match result {
            Ok(data) => json!({"ok":true,"data":data}),
            Err(Error::Invalid(code)) => failure(&code, "缩略图任务已结束或暂不可用。"),
            Err(_) => failure("internal", "缩略图控制失败。"),
        };
    }
    let worker = match WORKER.get_or_init(Worker::start) {
        Ok(worker) => worker,
        Err(_) => return failure("internal", "无法启动读取线程。"),
    };
    let (reply, response) = mpsc::sync_channel(1);
    if let Err(error) = worker.sender.try_send(WorkItem::Command(Job {
        context,
        request,
        reply,
    })) {
        return match error {
            mpsc::TrySendError::Full(_) => failure("busy", "读取队列已满，请稍后重试。"),
            mpsc::TrySendError::Disconnected(_) => failure("internal", "读取线程已结束。"),
        };
    }
    response
        .recv()
        .unwrap_or_else(|_| failure("internal", "读取线程已结束。"))
}

fn read_media(
    context: u64,
    session: u64,
    file: u64,
    offset: u64,
    length: usize,
) -> Result<Zeroizing<Vec<u8>>> {
    read_media_cancellable(
        context,
        session,
        file,
        offset,
        length,
        &Cancellation::default(),
        &Cancellation::default(),
    )
}
fn read_media_cancellable(
    context: u64,
    session: u64,
    file: u64,
    offset: u64,
    length: usize,
    cancel: &Cancellation,
    revoked: &Cancellation,
) -> Result<Zeroizing<Vec<u8>>> {
    read_media_task(
        context, session, file, offset, length, cancel, revoked, None,
    )
}
#[allow(clippy::too_many_arguments)]
fn read_media_task(
    context: u64,
    session: u64,
    file: u64,
    offset: u64,
    length: usize,
    cancel: &Cancellation,
    revoked: &Cancellation,
    task: Option<&Arc<thumbnail::Task>>,
) -> Result<Zeroizing<Vec<u8>>> {
    if let Some(task) = task {
        task.check()?;
    }
    cancel.check()?;
    revoked.check()?;
    let worker = WORKER
        .get()
        .and_then(|worker| worker.as_ref().ok())
        .ok_or(Error::Locked)?;
    let (reply, response) = mpsc::sync_channel(1);
    worker
        .sender
        .try_send(WorkItem::Read(MediaRead {
            context,
            session,
            file,
            offset,
            length,
            reply,
            cancel: cancel.clone(),
            revoked: revoked.clone(),
            task: task.cloned(),
        }))
        .map_err(|_| Error::Invalid("media queue busy".into()))?;
    wait_media_task(response, cancel, revoked, task)
}
#[cfg(test)]
fn wait_media(
    response: mpsc::Receiver<Result<Zeroizing<Vec<u8>>>>,
    cancel: &Cancellation,
    revoked: &Cancellation,
) -> Result<Zeroizing<Vec<u8>>> {
    wait_media_task(response, cancel, revoked, None)
}
fn wait_media_task(
    response: mpsc::Receiver<Result<Zeroizing<Vec<u8>>>>,
    cancel: &Cancellation,
    revoked: &Cancellation,
    task: Option<&Arc<thumbnail::Task>>,
) -> Result<Zeroizing<Vec<u8>>> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        if let Some(task) = task {
            task.check()?;
        }
        cancel.check()?;
        revoked.check()?;
        match response.recv_timeout(std::time::Duration::from_millis(20)) {
            Ok(result) => {
                cancel.check()?;
                revoked.check()?;
                return result;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => return Err(Error::Locked),
            Err(mpsc::RecvTimeoutError::Timeout) if std::time::Instant::now() >= deadline => {
                cancel.cancel();
                return Err(Error::Io(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "media read timeout",
                )));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    }
}

/// # Safety
/// `input` must point to `length` readable bytes for the duration of this call.
/// The returned pointer must be released exactly once using vhdx_response_free.
#[no_mangle]
pub unsafe extern "C" fn vhdx_request(
    context: u64,
    input: *const u8,
    length: usize,
) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        let response = if input.is_null() || length > 1024 * 1024 {
            failure("invalid", "请求格式无效。")
        } else {
            let copy = Zeroizing::new(std::slice::from_raw_parts(input, length).to_vec());
            request_context(context, &copy)
        };
        CString::new(response.to_string())
            .map(CString::into_raw)
            .unwrap_or(ptr::null_mut())
    });
    result.unwrap_or(ptr::null_mut())
}
/// # Safety
/// `response` is null or a live pointer returned by vhdx_request, never freed before.
#[no_mangle]
pub unsafe extern "C" fn vhdx_response_free(response: *mut c_char) {
    if !response.is_null() {
        let mut bytes = CString::from_raw(response).into_bytes_with_nul();
        bytes.zeroize();
    }
}
#[no_mangle]
pub extern "C" fn vhdx_cancel(context: u64) {
    if let Some(Ok(worker)) = WORKER.get() {
        if let Ok(active) = worker.active.lock() {
            if let Some((owner, token)) = active.as_ref() {
                if *owner == context {
                    token.cancel();
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancelled_media_wait_does_not_wait_for_blocked_native_io() {
        for revoke in [false, true] {
            let cancel = Cancellation::default();
            let revoked = Cancellation::default();
            let signal = if revoke {
                revoked.clone()
            } else {
                cancel.clone()
            };
            let (reply, receive) = mpsc::sync_channel(1);
            let started = std::time::Instant::now();
            let waiter = thread::spawn(move || wait_media(receive, &cancel, &revoked));
            // Keep sender alive, simulating an in-flight native read that cannot
            // be interrupted. The waiting callback must still return promptly.
            signal.cancel();
            assert!(matches!(waiter.join().unwrap(), Err(Error::Cancelled)));
            assert!(started.elapsed() < std::time::Duration::from_secs(1));
            assert!(reply.send(Ok(Zeroizing::new(vec![1, 2, 3]))).is_err());
        }
    }
    #[test]
    fn media_wait_propagates_io_failure_instead_of_eof() {
        let (reply, receive) = mpsc::sync_channel(1);
        reply
            .send(Err(Error::Io(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "disconnected source",
            ))))
            .unwrap();
        assert!(matches!(
            wait_media(receive, &Cancellation::default(), &Cancellation::default()),
            Err(Error::Io(_))
        ));
    }
    #[test]
    fn engine_retirement_rejects_late_jobs_but_preserves_new_engine() {
        let worker = Worker::start().unwrap();
        let (reply, receive) = mpsc::sync_channel(1);
        worker
            .sender
            .send(WorkItem::Retire { before: 10, reply })
            .unwrap();
        receive
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        for (context, accepted) in [(9, false), (10, true), (9, false)] {
            let (reply, receive) = mpsc::sync_channel(1);
            worker
                .sender
                .send(WorkItem::Command(Job {
                    context,
                    request: Request::Dispose,
                    reply,
                }))
                .unwrap();
            let response = receive
                .recv_timeout(std::time::Duration::from_secs(2))
                .unwrap();
            assert_eq!(response["ok"], accepted);
            if !accepted {
                assert_eq!(response["error"]["code"], "closed");
            }
        }
    }
    #[test]
    fn invalid_request_does_not_echo_input() {
        let r = request_json(br#"{"op":"bad-sensitive-input"}"#);
        assert!(!r.to_string().contains("bad-sensitive-input"));
        assert_eq!(r["ok"], false);
    }
    #[test]
    fn cache_settings_default_validate_and_cover_both_unlock_routes() {
        for op in ["unlock", "unlock_saved"] {
            let mut value = json!({"op":op,"session":0,"partition":1});
            if op == "unlock" {
                value["mode"] = json!("none");
            }
            let request: Request = serde_json::from_value(value.clone()).unwrap();
            let settings = match &request {
                Request::Unlock { cache, .. } | Request::UnlockSaved { cache, .. } => cache,
                _ => unreachable!(),
            };
            assert_eq!(settings.plaintext_mib, 16);
            assert_eq!(settings.ciphertext_mib, 1);
            assert_eq!(settings.plaintext_page_kib, 64);
            for (plain, cipher, page) in [
                (64usize, 4, 64),
                (256, 16, 1024),
                (1024, 1, 4096),
                (16384, 4, 1024),
            ] {
                value["cache"] = json!({"plaintext_mib":plain,"ciphertext_mib":cipher,"plaintext_page_kib":page});
                let request: Request = serde_json::from_value(value.clone()).unwrap();
                let settings = match &request {
                    Request::Unlock { cache, .. } | Request::UnlockSaved { cache, .. } => cache,
                    _ => unreachable!(),
                };
                assert_eq!(
                    settings.validate().is_ok(),
                    plain.checked_mul(1024 * 1024).is_some()
                );
                assert_eq!(settings.plaintext_mib, plain);
                assert_eq!(settings.plaintext_page_kib, page);
            }
            for cache in [
                json!({"plaintext_mib":0}),
                json!({"plaintext_mib":32768}),
                json!({"plaintext_page_kib":0}),
                json!({"plaintext_page_kib":96}),
                json!({"plaintext_page_kib":8192}),
                json!({"ciphertext_mib":32}),
            ] {
                value["cache"] = cache;
                let request: Request = serde_json::from_value(value.clone()).unwrap();
                let error = State::new()
                    .apply(&request, &Cancellation::default())
                    .unwrap_err();
                // Validation precedes image/vault access and allocation.
                assert!(matches!(error, Error::Invalid(_)));
            }
        }
    }
    #[test]
    fn stale_session_cannot_access_new_volume() {
        let mut state = State::new();
        state.generation = 2;
        let request = Request::List {
            session: 1,
            path: "/".into(),
            start: 0,
            limit: 10,
            show_system: false,
        };
        assert_eq!(
            state.handle(&request, &Cancellation::default())["error"]["code"],
            "stale_session"
        );
    }
    #[test]
    fn cancelled_request_stops_before_io() {
        let mut state = State::new();
        let token = Cancellation::default();
        token.cancel();
        assert_eq!(
            state.handle(
                &Request::Open {
                    path: "not-opened".into(),
                    fd: None,
                    native_directory: None
                },
                &token
            )["error"]["code"],
            "cancelled"
        );
    }
}
