//! Desktop ABI. Requests run on a dedicated Rust worker that owns all native handles.
//! Dart calls the blocking ABI from a helper isolate; the Flutter UI never waits in FFI.
mod media;
mod vault;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
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
    ciphertext_mib: usize,
}
impl Default for CacheSettings {
    fn default() -> Self {
        Self {
            plaintext_mib: 16,
            ciphertext_mib: 1,
        }
    }
}
impl CacheSettings {
    fn validate(&self) -> Result<()> {
        if ![16, 32, 64, 128, 256].contains(&self.plaintext_mib)
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
    ) -> Result<Volume> {
        self.validate()?;
        image.unlock_with_caches(
            partition,
            credential,
            self.plaintext_mib * 1024 * 1024,
            self.ciphertext_mib * 1024 * 1024,
        )
    }
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
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
    MediaOpen {
        session: u64,
        path: String,
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
            | Self::VaultClear => None,
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
        }
    }
}
struct State {
    context: u64,
    media: HashMap<u64, media::Stream>,
    runtime: Option<Rc<Runtime>>,
    image: Option<Image>,
    volume: Option<Volume>,
    generation: u64,
    files: HashMap<u64, File>,
    next_file: u64,
}
impl State {
    fn new() -> Self {
        Self {
            context: 0,
            media: HashMap::new(),
            runtime: None,
            image: None,
            volume: None,
            generation: 0,
            files: HashMap::new(),
            next_file: 1,
        }
    }
    fn clear(&mut self) {
        self.media.clear();
        self.files.clear();
        self.volume = None;
        self.image = None;
        self.generation += 1;
    }
    fn apply(&mut self, request: &Request, cancel: &Cancellation) -> Result<Value> {
        cancel.check()?;
        if request.session().is_some_and(|id| id != self.generation) {
            return Err(Error::Invalid("stale_session".into()));
        }
        match request {
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
                self.media.clear();
                self.files.clear();
                self.volume = None;
                let volume = cache.unlock(image, *partition, Some(&credential))?;
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
                let image = if let Some(fd) = fd {
                    Image::from_source(
                        runtime,
                        Rc::new(LocalFile::from_file(duplicate_file_descriptor(*fd)?)?),
                    )?
                } else {
                    Image::open(runtime, Path::new(path))?
                };
                cancel.check()?;
                let data = serde_json::to_value(&image.info)
                    .map_err(|_| Error::Invalid("image info".into()))?;
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
            Request::MediaOpen { path, .. } => {
                if self.media.len() >= 4 || self.files.len() >= 16 {
                    return Err(Error::Invalid("too many open media files".into()));
                }
                let file = self.volume.as_ref().ok_or(Error::Locked)?.open_file(path)?;
                let id = self.next_file;
                self.next_file = self
                    .next_file
                    .checked_add(1)
                    .ok_or_else(|| Error::Invalid("file identifier exhausted".into()))?;
                let size = file.len();
                let stream = media::Stream::start(self.context, self.generation, id, size)?;
                let result = json!({"file":id,"size":size,"url":stream.url});
                self.files.insert(id, file);
                self.media.insert(id, stream);
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
            let mut retired_before = 0;
            while let Ok(item) = receiver.recv() {
                let job = match item {
                    WorkItem::Retire { before, reply } => {
                        retired_before = retired_before.max(before);
                        states.retain(|id, _| *id >= retired_before);
                        let _ = reply.send(());
                        continue;
                    }
                    WorkItem::Command(job) => job,
                    WorkItem::Read(job) => {
                        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<Zeroizing<Vec<u8>>> {
                            let state = states.get(&job.context).ok_or(Error::Locked)?;
                            if state.generation != job.session || !state.media.contains_key(&job.file) { return Err(Error::Locked); }
                            let file = state.files.get(&job.file).ok_or(Error::Locked)?;
                            if job.length > 256 * 1024 { return Err(Error::Invalid("media chunk too large".into())); }
                            let mut bytes = Zeroizing::new(vec![0; job.length]);
                            let cancel = Cancellation::default();
                            let mut done = 0;
                            while done < job.length {
                                let n = file.read_at(job.offset.checked_add(done as u64).ok_or_else(|| Error::Invalid("offset overflow".into()))?, &mut bytes[done..], &cancel)?;
                                if n == 0 { break; }
                                done += n;
                            }
                            bytes.truncate(done);
                            Ok(bytes)
                        })).unwrap_or_else(|_| Err(Error::Invalid("media reader panicked".into())));
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
                    states.remove(&job.context);
                    let _ = job.reply.send(json!({"ok":true,"data":{}}));
                    continue;
                }
                let token = Cancellation::default();
                if let Ok(mut active) = shared.lock() {
                    *active = Some((job.context, token.clone()));
                }
                let state = states.entry(job.context).or_insert_with(State::new);
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
    7
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
        }))
        .map_err(|_| Error::Invalid("media queue busy".into()))?;
    response
        .recv_timeout(std::time::Duration::from_secs(10))
        .map_err(|_| {
            Error::Io(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "media read timeout",
            ))
        })?
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
            for (plain, cipher) in [(64, 4), (256, 16)] {
                value["cache"] = json!({"plaintext_mib":plain,"ciphertext_mib":cipher});
                let request: Request = serde_json::from_value(value.clone()).unwrap();
                let settings = match &request {
                    Request::Unlock { cache, .. } | Request::UnlockSaved { cache, .. } => cache,
                    _ => unreachable!(),
                };
                assert!(settings.validate().is_ok());
                assert_eq!(settings.plaintext_mib, plain);
            }
            for cache in [
                json!({"plaintext_mib":0}),
                json!({"plaintext_mib":1024}),
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
