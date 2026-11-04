//! Narrow FFI boundary to pinned libyal libraries. All ownership stays on one thread.
//! Native callback state uses Rc, so none of these objects is Send or Sync.
use crate::{source::ReadAt, Error, Result};
use libloading::Library;
use std::{
    cell::RefCell,
    ffi::{c_char, c_int, c_void, CStr},
    panic::{catch_unwind, AssertUnwindSafe},
    path::Path,
    ptr,
    rc::Rc,
};

type P = *mut c_void;
type E = *mut P;
type Init = unsafe extern "C" fn(*mut P, E) -> c_int;
type Free = unsafe extern "C" fn(*mut P, E) -> c_int;
type Unary = unsafe extern "C" fn(P, E) -> c_int;
type Open = unsafe extern "C" fn(P, P, c_int, E) -> c_int;
type Read = unsafe extern "C" fn(P, *mut u8, usize, i64, E) -> isize;
type Size = unsafe extern "C" fn(P, *mut u64, E) -> c_int;
type Get32 = unsafe extern "C" fn(P, *mut u32, E) -> c_int;
type ErrorFree = unsafe extern "C" fn(E);
type ErrorString = unsafe extern "C" fn(P, *mut c_char, usize) -> c_int;

pub(crate) struct Api {
    library: Library,
    prefix: &'static str,
    error_free: ErrorFree,
    error_string: ErrorString,
}
impl Api {
    fn load(directory: &Path, prefix: &'static str) -> Result<Rc<Self>> {
        let filename = if cfg!(windows) {
            format!("{prefix}.dll")
        } else if cfg!(target_os = "ios") {
            format!("{prefix}.framework/{prefix}")
        } else if cfg!(target_os = "macos") {
            format!("{prefix}.dylib")
        } else {
            format!("{prefix}.so")
        };
        let path = directory.join(filename).canonicalize()?;
        // SAFETY: load only an explicitly selected, trusted native library directory.
        let library = unsafe {
            #[cfg(windows)]
            {
                Library::from(
                    libloading::os::windows::Library::load_with_flags(&path, 0x100 | 0x1000)
                        .map_err(|e| Error::Native(e.to_string()))?,
                )
            }
            #[cfg(not(windows))]
            {
                Library::new(&path).map_err(|e| Error::Native(e.to_string()))?
            }
        };
        unsafe {
            let error_free = *library
                .get::<ErrorFree>(format!("{prefix}_error_free\0").as_bytes())
                .map_err(|e| Error::Native(e.to_string()))?;
            let error_string = *library
                .get::<ErrorString>(format!("{prefix}_error_backtrace_sprint\0").as_bytes())
                .map_err(|e| Error::Native(e.to_string()))?;
            Ok(Rc::new(Self {
                library,
                prefix,
                error_free,
                error_string,
            }))
        }
    }
    /// Each call site supplies a signature audited against the pinned C header.
    unsafe fn symbol<T: Copy>(&self, suffix: &str) -> Result<T> {
        self.library
            .get::<T>(format!("{}_{}\0", self.prefix, suffix).as_bytes())
            .map(|s| *s)
            .map_err(|e| Error::Native(e.to_string()))
    }
    fn error(&self, mut raw: P, operation: &str) -> Error {
        if raw.is_null() {
            return Error::Native(format!("{}: {operation}", self.prefix));
        }
        let mut buffer = vec![0u8; 8192];
        unsafe {
            (self.error_string)(raw, buffer.as_mut_ptr().cast(), buffer.len());
            (self.error_free)(&mut raw);
        }
        buffer.truncate(buffer.iter().position(|v| *v == 0).unwrap_or(buffer.len()));
        Error::Native(format!(
            "{} {operation}: {}",
            self.prefix,
            String::from_utf8_lossy(&buffer)
        ))
    }
    fn check(&self, result: c_int, mut error: P, operation: &str) -> Result<c_int> {
        if result < 0 {
            return Err(self.error(error, operation));
        }
        if !error.is_null() {
            unsafe {
                (self.error_free)(&mut error);
            }
        }
        Ok(result)
    }
    fn version(&self) -> Result<String> {
        unsafe {
            let f = self.symbol::<unsafe extern "C" fn() -> *const c_char>("get_version")?;
            let p = f();
            if p.is_null() {
                return Err(Error::Native("missing version".into()));
            }
            Ok(CStr::from_ptr(p).to_string_lossy().into_owned())
        }
    }
}

pub struct Runtime {
    bfio: Rc<Api>,
    vhdi: Rc<Api>,
    bde: Rc<Api>,
    ntfs: Rc<Api>,
}
impl Runtime {
    pub fn load(directory: &Path) -> Result<Rc<Self>> {
        Ok(Rc::new(Self {
            bfio: Api::load(directory, "libbfio")?,
            vhdi: Api::load(directory, "libvhdi")?,
            bde: Api::load(directory, "libbde")?,
            ntfs: Api::load(directory, "libfsntfs")?,
        }))
    }
    pub fn versions(&self) -> Result<Vec<(String, String)>> {
        [&self.bfio, &self.vhdi, &self.bde, &self.ntfs]
            .into_iter()
            .map(|a| Ok((a.prefix.into(), a.version()?)))
            .collect()
    }
}

struct CallbackState {
    source: Rc<dyn ReadAt>,
    position: u64,
    opened: bool,
    last_error: Rc<RefCell<Option<String>>>,
}
// C must never observe a Rust panic. No callback reenters the same layer.
unsafe fn callback<T: Copy>(p: P, failed: T, f: impl FnOnce(&mut CallbackState) -> Result<T>) -> T {
    if p.is_null() {
        return failed;
    }
    let state = &mut *p.cast::<CallbackState>();
    match catch_unwind(AssertUnwindSafe(|| f(state))) {
        Ok(Ok(value)) => value,
        Ok(Err(e)) => {
            *state.last_error.borrow_mut() = Some(e.to_string());
            failed
        }
        Err(_) => {
            *state.last_error.borrow_mut() = Some("panic inside I/O callback".into());
            failed
        }
    }
}
unsafe extern "C" fn cb_free(p: *mut P, _: E) -> c_int {
    if p.is_null() {
        return -1;
    }
    if !(*p).is_null() {
        // Library owns one Box per callback handle; clone creates a separate cursor.
        let owned = Box::from_raw((*p).cast::<CallbackState>());
        *p = ptr::null_mut();
        if catch_unwind(AssertUnwindSafe(|| drop(owned))).is_err() {
            return -1;
        }
    }
    1
}
unsafe extern "C" fn cb_clone(out: *mut P, p: P, _: E) -> c_int {
    if out.is_null() || !(*out).is_null() {
        return -1;
    }
    callback(p, -1, |s| {
        *out = Box::into_raw(Box::new(CallbackState {
            source: s.source.clone(),
            position: s.position,
            opened: s.opened,
            last_error: s.last_error.clone(),
        }))
        .cast();
        Ok(1)
    })
}
unsafe extern "C" fn cb_open(p: P, flags: c_int, _: E) -> c_int {
    callback(p, -1, |s| {
        if flags != 1 {
            return Err(Error::Unsupported("write access is disabled".into()));
        }
        s.opened = true;
        Ok(1)
    })
}
unsafe extern "C" fn cb_close(p: P, _: E) -> c_int {
    callback(p, -1, |s| {
        s.opened = false;
        Ok(0)
    })
}
unsafe extern "C" fn cb_read(p: P, buffer: *mut u8, size: usize, _: E) -> isize {
    if size == 0 {
        return 0;
    }
    if buffer.is_null() || size > isize::MAX as usize {
        return -1;
    }
    callback(p, -1, |s| {
        if !s.opened {
            return Err(Error::Invalid("read from closed source".into()));
        }
        let n = s
            .source
            .read_at(s.position, std::slice::from_raw_parts_mut(buffer, size))?;
        if n > size {
            return Err(Error::Invalid("source returned oversized read".into()));
        }
        s.position = s
            .position
            .checked_add(n as u64)
            .ok_or_else(|| Error::Invalid("cursor overflow".into()))?;
        Ok(n as isize)
    })
}
unsafe extern "C" fn cb_write(_: P, _: *const u8, _: usize, _: E) -> isize {
    -1
}
unsafe extern "C" fn cb_seek(p: P, offset: i64, whence: c_int, _: E) -> i64 {
    callback(p, -1, |s| {
        let base = match whence {
            0 => 0,
            1 => s.position,
            2 => s.source.len(),
            _ => return Err(Error::Invalid("seek origin".into())),
        };
        let position = base as i128 + offset as i128;
        if position < 0 || position > i64::MAX as i128 {
            return Err(Error::Invalid("seek overflow".into()));
        }
        s.position = position as u64;
        Ok(position as i64)
    })
}
unsafe extern "C" fn cb_exists(_: P, _: E) -> c_int {
    1
}
unsafe extern "C" fn cb_is_open(p: P, _: E) -> c_int {
    callback(p, -1, |s| Ok(s.opened as c_int))
}
unsafe extern "C" fn cb_size(p: P, out: *mut u64, _: E) -> c_int {
    if out.is_null() {
        return -1;
    }
    callback(p, -1, |s| {
        *out = s.source.len();
        Ok(1)
    })
}
type BfioInit = unsafe extern "C" fn(
    *mut P,
    P,
    unsafe extern "C" fn(*mut P, E) -> c_int,
    unsafe extern "C" fn(*mut P, P, E) -> c_int,
    unsafe extern "C" fn(P, c_int, E) -> c_int,
    unsafe extern "C" fn(P, E) -> c_int,
    unsafe extern "C" fn(P, *mut u8, usize, E) -> isize,
    unsafe extern "C" fn(P, *const u8, usize, E) -> isize,
    unsafe extern "C" fn(P, i64, c_int, E) -> i64,
    unsafe extern "C" fn(P, E) -> c_int,
    unsafe extern "C" fn(P, E) -> c_int,
    unsafe extern "C" fn(P, *mut u64, E) -> c_int,
    u8,
    E,
) -> c_int;

struct Bfio {
    raw: P,
    api: Rc<Api>,
    last_error: Rc<RefCell<Option<String>>>,
}
impl Bfio {
    fn new(api: Rc<Api>, source: Rc<dyn ReadAt>) -> Result<Self> {
        unsafe {
            let initialize = api.symbol::<BfioInit>("handle_initialize")?;
            let last_error = Rc::new(RefCell::new(None));
            let state = Box::into_raw(Box::new(CallbackState {
                source,
                position: 0,
                opened: false,
                last_error: last_error.clone(),
            }))
            .cast();
            let mut raw = ptr::null_mut();
            let mut error = ptr::null_mut();
            let r = initialize(
                &mut raw, state, cb_free, cb_clone, cb_open, cb_close, cb_read, cb_write, cb_seek,
                cb_exists, cb_is_open, cb_size, 1, &mut error,
            );
            if r != 1 {
                if raw.is_null() {
                    drop(Box::from_raw(state.cast::<CallbackState>()));
                } else {
                    let free = api.symbol::<Free>("handle_free")?;
                    let mut ignored = ptr::null_mut();
                    free(&mut raw, &mut ignored);
                    if !ignored.is_null() {
                        (api.error_free)(&mut ignored);
                    }
                }
                return Err(api.error(error, "initialize callback I/O"));
            }
            Ok(Self {
                raw,
                api,
                last_error,
            })
        }
    }
}
impl Drop for Bfio {
    fn drop(&mut self) {
        unsafe {
            if let Ok(f) = self.api.symbol::<Free>("handle_free") {
                let mut error = ptr::null_mut();
                f(&mut self.raw, &mut error);
                if !error.is_null() {
                    (self.api.error_free)(&mut error);
                }
            }
        }
    }
}

pub(crate) struct Object {
    raw: P,
    api: Rc<Api>,
    kind: &'static str,
    opened: bool,
    io: Option<Bfio>,
}
impl Object {
    fn new(api: Rc<Api>, kind: &'static str) -> Result<Self> {
        unsafe {
            let f = api.symbol::<Init>(&format!("{kind}_initialize"))?;
            let mut raw = ptr::null_mut();
            let mut error = ptr::null_mut();
            api.check(f(&mut raw, &mut error), error, "initialize")?;
            if raw.is_null() {
                return Err(Error::Native("initialize returned a null object".into()));
            }
            Ok(Self {
                raw,
                api,
                kind,
                opened: false,
                io: None,
            })
        }
    }
    fn open(&mut self, bfio: Rc<Api>, source: Rc<dyn ReadAt>) -> Result<()> {
        self.io = Some(Bfio::new(bfio, source)?);
        unsafe {
            let f = self
                .api
                .symbol::<Open>(&format!("{}_open_file_io_handle", self.kind))?;
            let mut error = ptr::null_mut();
            let r = f(self.raw, self.io.as_ref().unwrap().raw, 1, &mut error);
            self.api.check(r, error, "open read-only")?;
            self.opened = true;
            Ok(())
        }
    }
    fn u64(&self, suffix: &str) -> Result<u64> {
        unsafe {
            let f = self.api.symbol::<Size>(suffix)?;
            let mut value = 0;
            let mut error = ptr::null_mut();
            self.api
                .check(f(self.raw, &mut value, &mut error), error, suffix)?;
            Ok(value)
        }
    }
    fn u32(&self, suffix: &str) -> Result<u32> {
        unsafe {
            let f = self.api.symbol::<Get32>(suffix)?;
            let mut value = 0;
            let mut error = ptr::null_mut();
            self.api
                .check(f(self.raw, &mut value, &mut error), error, suffix)?;
            Ok(value)
        }
    }
    fn read(&self, f: Read, offset: u64, buffer: &mut [u8]) -> Result<usize> {
        unsafe {
            let offset = i64::try_from(offset)
                .map_err(|_| Error::Invalid("offset exceeds native signed 64-bit range".into()))?;
            if let Some(io) = &self.io {
                *io.last_error.borrow_mut() = None;
            }
            let mut error = ptr::null_mut();
            let r = f(
                self.raw,
                buffer.as_mut_ptr(),
                buffer.len(),
                offset,
                &mut error,
            );
            if r < 0 {
                let native = self.api.error(error, "read");
                if let Some(detail) = self
                    .io
                    .as_ref()
                    .and_then(|io| io.last_error.borrow_mut().take())
                {
                    return Err(Error::Native(format!("{detail}; {native}")));
                }
                return Err(native);
            }
            if !error.is_null() {
                (self.api.error_free)(&mut error);
            }
            if r as usize > buffer.len() {
                return Err(Error::Native("oversized read result".into()));
            }
            Ok(r as usize)
        }
    }
}
impl Drop for Object {
    fn drop(&mut self) {
        unsafe {
            let mut error = ptr::null_mut();
            if self.opened {
                if let Ok(f) = self.api.symbol::<Unary>(&format!("{}_close", self.kind)) {
                    f(self.raw, &mut error);
                    if !error.is_null() {
                        (self.api.error_free)(&mut error);
                    }
                }
            }
            if let Ok(f) = self.api.symbol::<Free>(&format!("{}_free", self.kind)) {
                f(&mut self.raw, &mut error);
                if !error.is_null() {
                    (self.api.error_free)(&mut error);
                }
            }
        }
    }
}

pub struct Disk {
    object: Object,
    len: u64,
    read: Read,
    pub sector_size: u32,
    pub disk_type: u32,
}
impl Disk {
    pub fn open(runtime: &Runtime, source: Rc<dyn ReadAt>) -> Result<Rc<Self>> {
        crate::partition::check_vhdx(source.as_ref())?;
        let mut object = Object::new(runtime.vhdi.clone(), "file")?;
        object.open(runtime.bfio.clone(), source)?;
        let len = object.u64("file_get_media_size")?;
        let sector_size = object.u32("file_get_bytes_per_sector")?;
        let disk_type = object.u32("file_get_disk_type")?;
        if disk_type != 2 && disk_type != 3 {
            return Err(Error::Unsupported(format!(
                "VHDX disk type {disk_type}; only independent fixed/dynamic disks are supported"
            )));
        }
        let read = unsafe { object.api.symbol::<Read>("file_read_buffer_at_offset")? };
        Ok(Rc::new(Self {
            object,
            len,
            read,
            sector_size,
            disk_type,
        }))
    }
}
impl ReadAt for Disk {
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
        self.object.read(self.read, offset, &mut buffer[..n])
    }
}

pub enum Credential {
    Password(zeroize::Zeroizing<Vec<u8>>),
    RecoveryPassword(zeroize::Zeroizing<Vec<u8>>),
}
pub struct Decrypted {
    object: Object,
    len: u64,
    read: Read,
    pub encryption_method: u16,
}
impl Decrypted {
    /// Read public BitLocker identifiers without supplying a credential. Bounded
    /// metadata reads only; neither paths nor mutable VHDX write GUIDs identify a vault entry.
    pub fn identity(runtime: &Runtime, source: Rc<dyn ReadAt>) -> Result<Vec<u8>> {
        let mut object = Object::new(runtime.bde.clone(), "volume")?;
        object.open(runtime.bfio.clone(), source)?;
        unsafe {
            type Guid = unsafe extern "C" fn(P, *mut u8, usize, E) -> c_int;
            let guid = object.api.symbol::<Guid>("volume_get_volume_identifier")?;
            let mut bytes = [0u8; 16];
            let mut error = ptr::null_mut();
            if object.api.check(
                guid(object.raw, bytes.as_mut_ptr(), 16, &mut error),
                error,
                "volume identity",
            )? != 1
                || bytes == [0; 16]
            {
                return Err(Error::Unsupported("missing BitLocker identity".into()));
            }
            let count_fn = object
                .api
                .symbol::<unsafe extern "C" fn(P, *mut c_int, E) -> c_int>(
                    "volume_get_number_of_key_protectors",
                )?;
            let get = object
                .api
                .symbol::<unsafe extern "C" fn(P, c_int, *mut P, E) -> c_int>(
                    "volume_get_key_protector_by_index",
                )?;
            let id = object.api.symbol::<Guid>("key_protector_get_identifier")?;
            let free = object
                .api
                .symbol::<unsafe extern "C" fn(*mut P, E) -> c_int>("key_protector_free")?;
            let mut count = 0;
            object.api.check(
                count_fn(object.raw, &mut count, &mut error),
                error,
                "protector count",
            )?;
            if !(1..=128).contains(&count) {
                return Err(Error::Unsupported("BitLocker protector identity".into()));
            }
            let mut ids = Vec::new();
            for index in 0..count {
                let mut protector = ptr::null_mut();
                object.api.check(
                    get(object.raw, index, &mut protector, &mut error),
                    error,
                    "protector",
                )?;
                if protector.is_null() {
                    return Err(Error::Invalid("null protector".into()));
                }
                let mut value = [0u8; 16];
                let read = object.api.check(
                    id(protector, value.as_mut_ptr(), 16, &mut error),
                    error,
                    "protector identity",
                );
                let release =
                    object
                        .api
                        .check(free(&mut protector, &mut error), error, "release protector");
                if read? != 1 || value == [0; 16] {
                    return Err(Error::Unsupported("missing protector identity".into()));
                }
                release?;
                ids.push(value);
            }
            ids.sort_unstable();
            let mut result = bytes.to_vec();
            for id in ids {
                result.extend_from_slice(&id);
            }
            Ok(result)
        }
    }

    pub fn open(
        runtime: &Runtime,
        source: Rc<dyn ReadAt>,
        credential: Option<&Credential>,
    ) -> Result<Rc<Self>> {
        let mut object = Object::new(runtime.bde.clone(), "volume")?;
        if let Some(credential) = credential {
            unsafe {
                let (suffix, bytes) = match credential {
                    Credential::Password(b) => ("volume_set_utf8_password", b),
                    Credential::RecoveryPassword(b) => ("volume_set_utf8_recovery_password", b),
                };
                let set = object
                    .api
                    .symbol::<unsafe extern "C" fn(P, *const u8, usize, E) -> c_int>(suffix)?;
                let mut error = ptr::null_mut();
                let r = object.api.check(
                    set(object.raw, bytes.as_ptr(), bytes.len(), &mut error),
                    error,
                    "set credential",
                )?;
                if r != 1 {
                    return Err(Error::WrongCredential);
                }
            }
        }
        object.open(runtime.bfio.clone(), source)?;
        unsafe {
            let is_locked = object.api.symbol::<Unary>("volume_is_locked")?;
            let mut error = ptr::null_mut();
            if object
                .api
                .check(is_locked(object.raw, &mut error), error, "check lock state")?
                != 0
            {
                return Err(if credential.is_some() {
                    Error::WrongCredential
                } else {
                    Error::Locked
                });
            }
        }
        let len = object.u64("volume_get_size")?;
        let read = unsafe { object.api.symbol::<Read>("volume_read_buffer_at_offset")? };
        let mut encryption_method = 0;
        unsafe {
            let f = object
                .api
                .symbol::<unsafe extern "C" fn(P, *mut u16, E) -> c_int>(
                    "volume_get_encryption_method",
                )?;
            let mut error = ptr::null_mut();
            object.api.check(
                f(object.raw, &mut encryption_method, &mut error),
                error,
                "get encryption method",
            )?;
        }
        Ok(Rc::new(Self {
            object,
            len,
            read,
            encryption_method,
        }))
    }
}
impl ReadAt for Decrypted {
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
        self.object.read(self.read, offset, &mut buffer[..n])
    }
}

pub struct Ntfs {
    object: Object,
}
pub struct Entry {
    object: Object,
    _volume: Rc<Ntfs>,
    read: Read,
}
impl Ntfs {
    pub fn open(runtime: &Runtime, source: Rc<dyn ReadAt>) -> Result<Rc<Self>> {
        let mut object = Object::new(runtime.ntfs.clone(), "volume")?;
        object.open(runtime.bfio.clone(), source)?;
        Ok(Rc::new(Self { object }))
    }
    pub fn entry(self: &Rc<Self>, path: &str) -> Result<Entry> {
        let components = path
            .split(['/', '\\'])
            .filter(|p| !p.is_empty())
            .collect::<Vec<_>>();
        if components
            .iter()
            .any(|p| *p == ".." || *p == "." || p.contains('\0'))
        {
            return Err(Error::Invalid("invalid in-volume path".into()));
        }
        let mut current = unsafe {
            let f = self
                .object
                .api
                .symbol::<unsafe extern "C" fn(P, *mut P, E) -> c_int>(
                    "volume_get_root_directory",
                )?;
            let mut raw = ptr::null_mut();
            let mut error = ptr::null_mut();
            self.object
                .api
                .check(f(self.object.raw, &mut raw, &mut error), error, "get root")?;
            self.wrap_entry(raw)?
        };
        // Resolve component by component; never follow NTFS reparse points.
        for component in components {
            current.ensure_browsable()?;
            if !current.is_directory()? {
                return Err(Error::NotFound(path.into()));
            }
            current = unsafe {
                let f =
                    self.object
                        .api
                        .symbol::<unsafe extern "C" fn(P, *const u8, usize, *mut P, E) -> c_int>(
                            "file_entry_get_sub_file_entry_by_utf8_name",
                        )?;
                let mut raw = ptr::null_mut();
                let mut error = ptr::null_mut();
                let r = self.object.api.check(
                    f(
                        current.object.raw,
                        component.as_ptr(),
                        component.len(),
                        &mut raw,
                        &mut error,
                    ),
                    error,
                    "lookup file",
                )?;
                if r == 0 {
                    return Err(Error::NotFound(path.into()));
                }
                self.wrap_entry(raw)?
            };
        }
        Ok(current)
    }
    fn wrap_entry(self: &Rc<Self>, raw: P) -> Result<Entry> {
        if raw.is_null() {
            return Err(Error::Native("null file entry".into()));
        }
        let object = Object {
            raw,
            api: self.object.api.clone(),
            kind: "file_entry",
            opened: false,
            io: None,
        };
        let read = unsafe {
            object
                .api
                .symbol::<Read>("file_entry_read_buffer_at_offset")?
        };
        Ok(Entry {
            object,
            _volume: self.clone(),
            read,
        })
    }
}
impl Entry {
    pub fn flags(&self) -> Result<u32> {
        self.object.u32("file_entry_get_file_attribute_flags")
    }
    pub fn is_directory(&self) -> Result<bool> {
        // NTFS $STANDARD_INFORMATION does not reliably carry Win32's DIRECTORY
        // flag. Use the filesystem's directory index, including for the root.
        unsafe {
            let f = self
                .object
                .api
                .symbol::<Unary>("file_entry_has_directory_entries_index")?;
            let mut error = ptr::null_mut();
            Ok(self
                .object
                .api
                .check(f(self.object.raw, &mut error), error, "directory index")?
                == 1)
        }
    }
    pub fn ensure_browsable(&self) -> Result<()> {
        let flags = self.flags()?;
        if flags & 0x400 != 0 {
            return Err(Error::Unsupported(
                "NTFS reparse points are not followed".into(),
            ));
        }
        if flags & 0x4000 != 0 {
            return Err(Error::Unsupported(
                "NTFS EFS encryption is separate from BitLocker".into(),
            ));
        }
        Ok(())
    }
    pub fn size(&self) -> Result<u64> {
        self.object.u64("file_entry_get_size")
    }
    pub fn name(&self) -> Result<String> {
        unsafe {
            let get_size = self
                .object
                .api
                .symbol::<unsafe extern "C" fn(P, *mut usize, E) -> c_int>(
                    "file_entry_get_utf8_name_size",
                )?;
            let get = self
                .object
                .api
                .symbol::<unsafe extern "C" fn(P, *mut u8, usize, E) -> c_int>(
                    "file_entry_get_utf8_name",
                )?;
            let mut len = 0;
            let mut error = ptr::null_mut();
            self.object.api.check(
                get_size(self.object.raw, &mut len, &mut error),
                error,
                "file name size",
            )?;
            if len == 0 || len > 4096 {
                return Err(Error::Invalid("NTFS file name length".into()));
            }
            let mut bytes = vec![0; len];
            let mut error = ptr::null_mut();
            self.object.api.check(
                get(self.object.raw, bytes.as_mut_ptr(), len, &mut error),
                error,
                "file name",
            )?;
            if bytes.last() == Some(&0) {
                bytes.pop();
            }
            String::from_utf8(bytes).map_err(|_| {
                Error::Unsupported("file name contains unpaired UTF-16 surrogates".into())
            })
        }
    }
    pub fn child_count(&self) -> Result<u32> {
        unsafe {
            self.ensure_browsable()?;
            if !self.is_directory()? {
                return Err(Error::Invalid("expected a directory".into()));
            }
            let f = self
                .object
                .api
                .symbol::<unsafe extern "C" fn(P, *mut c_int, E) -> c_int>(
                    "file_entry_get_number_of_sub_file_entries",
                )?;
            let mut value = 0;
            let mut error = ptr::null_mut();
            self.object.api.check(
                f(self.object.raw, &mut value, &mut error),
                error,
                "child count",
            )?;
            u32::try_from(value).map_err(|_| Error::Invalid("negative child count".into()))
        }
    }
    pub fn child(&self, index: u32) -> Result<Entry> {
        unsafe {
            let f = self
                .object
                .api
                .symbol::<unsafe extern "C" fn(P, c_int, *mut P, E) -> c_int>(
                    "file_entry_get_sub_file_entry_by_index",
                )?;
            let index = c_int::try_from(index)
                .map_err(|_| Error::Invalid("directory index too large".into()))?;
            let mut raw = ptr::null_mut();
            let mut error = ptr::null_mut();
            self.object.api.check(
                f(self.object.raw, index, &mut raw, &mut error),
                error,
                "get child",
            )?;
            self._volume.wrap_entry(raw)
        }
    }
    pub fn read_at(&self, offset: u64, buffer: &mut [u8]) -> Result<usize> {
        self.ensure_browsable()?;
        if self.is_directory()? {
            return Err(Error::Invalid("cannot read directory as a file".into()));
        }
        let size = self.size()?;
        if offset >= size {
            return Ok(0);
        }
        let n = buffer
            .len()
            .min((size - offset).min(usize::MAX as u64) as usize);
        self.object.read(self.read, offset, &mut buffer[..n])
    }
}
