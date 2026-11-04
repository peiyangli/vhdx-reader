use super::*;
use std::{ffi::c_void, os::windows::ffi::OsStrExt, path::PathBuf, ptr};
#[repr(C)]
struct Blob {
    size: u32,
    data: *mut u8,
}
#[link(name = "crypt32")]
extern "system" {
    fn CryptProtectData(
        input: *const Blob,
        description: *const u16,
        entropy: *const Blob,
        reserved: *mut c_void,
        prompt: *mut c_void,
        flags: u32,
        output: *mut Blob,
    ) -> i32;
    fn CryptUnprotectData(
        input: *const Blob,
        description: *mut *mut u16,
        entropy: *const Blob,
        reserved: *mut c_void,
        prompt: *mut c_void,
        flags: u32,
        output: *mut Blob,
    ) -> i32;
}
#[link(name = "kernel32")]
extern "system" {
    fn LocalFree(ptr: *mut c_void) -> *mut c_void;
    fn MoveFileExW(from: *const u16, to: *const u16, flags: u32) -> i32;
}
fn path() -> Result<PathBuf> {
    Ok(
        PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or(error("vault_unavailable"))?)
            .join("VHDX Reader")
            .join("credentials-v1.dpapi"),
    )
}
fn crypt(bytes: &[u8], protect: bool) -> Result<Zeroizing<Vec<u8>>> {
    let mut output = Blob {
        size: 0,
        data: ptr::null_mut(),
    };
    let input = Blob {
        size: bytes.len() as u32,
        data: bytes.as_ptr() as *mut u8,
    };
    unsafe {
        let result = if protect {
            CryptProtectData(
                &input,
                ptr::null(),
                ptr::null(),
                ptr::null_mut(),
                ptr::null_mut(),
                1,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &input,
                ptr::null_mut(),
                ptr::null(),
                ptr::null_mut(),
                ptr::null_mut(),
                1,
                &mut output,
            )
        };
        if result == 0 {
            return Err(error("vault_unavailable"));
        }
        let data = std::slice::from_raw_parts_mut(output.data, output.size as usize);
        let copy = Zeroizing::new(data.to_vec());
        data.zeroize();
        LocalFree(output.data.cast());
        Ok(copy)
    }
}
pub fn load() -> Result<Option<Zeroizing<Vec<u8>>>> {
    let path = path()?;
    match std::fs::metadata(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Ok(info) if info.len() <= (MAX_BYTES + 65536) as u64 => (),
        _ => return Err(error("vault_corrupt")),
    }
    let bytes = std::fs::read(path).map_err(|_| error("vault_unavailable"))?;
    Ok(Some(crypt(&bytes, false)?))
}
pub fn save(bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let path = path()?;
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|_| error("vault_unavailable"))?;
    let encrypted = crypt(bytes, true)?;
    let mut random = [0; 16];
    getrandom::fill(&mut random).map_err(|_| error("vault_unavailable"))?;
    let tmp = path.with_extension(format!("{:x}.tmp", u128::from_le_bytes(random)));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
            .map_err(|_| error("vault_unavailable"))?;
        file.write_all(&encrypted)
            .and_then(|_| file.sync_all())
            .map_err(|_| error("vault_unavailable"))?;
        drop(file);
        let from: Vec<u16> = tmp.as_os_str().encode_wide().chain(Some(0)).collect();
        let to: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), 1 | 8) } == 0 {
            return Err(error("vault_unavailable"));
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(tmp);
    }
    result
}
pub fn clear() -> Result<()> {
    match std::fs::remove_file(path()?) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        _ => Err(error("vault_unavailable")),
    }
}
