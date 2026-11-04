use super::*;
use std::{ffi::c_void, ptr};
type CF = *const c_void;
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(value: CF);
    fn CFStringCreateWithBytes(
        allocator: CF,
        bytes: *const u8,
        size: isize,
        encoding: u32,
        external: bool,
    ) -> CF;
    fn CFDictionaryCreateMutable(allocator: CF, capacity: isize, keys: CF, values: CF) -> CF;
    fn CFDictionarySetValue(dictionary: CF, key: CF, value: CF);
    fn CFDataCreate(allocator: CF, bytes: *const u8, size: isize) -> CF;
    fn CFDataGetLength(data: CF) -> isize;
    fn CFDataGetBytePtr(data: CF) -> *const u8;
    static kCFBooleanTrue: CF;
    static kCFBooleanFalse: CF;
}
#[link(name = "Security", kind = "framework")]
extern "C" {
    fn SecItemCopyMatching(query: CF, result: *mut CF) -> i32;
    fn SecItemAdd(query: CF, result: *mut CF) -> i32;
    fn SecItemUpdate(query: CF, attributes: CF) -> i32;
    fn SecItemDelete(query: CF) -> i32;
    static kSecClass: CF;
    static kSecClassGenericPassword: CF;
    static kSecAttrService: CF;
    static kSecAttrAccount: CF;
    static kSecAttrSynchronizable: CF;
    #[cfg(target_os = "ios")]
    static kSecAttrAccessible: CF;
    #[cfg(target_os = "ios")]
    static kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CF;
    static kSecValueData: CF;
    static kSecReturnData: CF;
    static kSecUseAuthenticationUI: CF;
    static kSecUseAuthenticationUIFail: CF;
}
struct Owned(CF);
impl Drop for Owned {
    fn drop(&mut self) {
        unsafe {
            if !self.0.is_null() {
                CFRelease(self.0);
            }
        }
    }
}
struct Query {
    dictionary: Owned,
    values: Vec<Owned>,
}
impl Query {
    unsafe fn new() -> Self {
        Self {
            dictionary: Owned(CFDictionaryCreateMutable(
                ptr::null(),
                0,
                ptr::null(),
                ptr::null(),
            )),
            values: Vec::new(),
        }
    }
    unsafe fn set(&self, key: CF, value: CF) {
        CFDictionarySetValue(self.dictionary.0, key, value);
    }
    unsafe fn string(&mut self, key: CF, value: &str) {
        let v = Owned(CFStringCreateWithBytes(
            ptr::null(),
            value.as_ptr(),
            value.len() as isize,
            0x08000100,
            false,
        ));
        self.set(key, v.0);
        self.values.push(v);
    }
    unsafe fn data(&mut self, bytes: &[u8]) {
        let v = Owned(CFDataCreate(
            ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
        ));
        self.set(kSecValueData, v.0);
        self.values.push(v);
    }
    unsafe fn base() -> Self {
        let mut q = Self::new();
        q.set(kSecClass, kSecClassGenericPassword);
        q.string(kSecAttrService, "org.vhdxreader.bitlocker.vault.v1");
        q.string(kSecAttrAccount, "local-credentials");
        q.set(kSecAttrSynchronizable, kCFBooleanFalse);
        q.set(kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
        q
    }
}
fn status(code: i32) -> Result<()> {
    match code {
        0 => Ok(()),
        -25308 | -25293 | -128 => Err(error("vault_locked")),
        _ => Err(error(&format!("vault_os_{code}"))),
    }
}
pub fn load() -> Result<Option<Zeroizing<Vec<u8>>>> {
    unsafe {
        let q = Query::base();
        q.set(kSecReturnData, kCFBooleanTrue);
        let mut data = ptr::null();
        let code = SecItemCopyMatching(q.dictionary.0, &mut data);
        if code == -25300 {
            return Ok(None);
        }
        status(code)?;
        let data = Owned(data);
        if data.0.is_null() {
            return Err(error("vault_corrupt"));
        }
        let size = CFDataGetLength(data.0);
        if size <= 0 || size as usize > MAX_BYTES {
            return Err(error("vault_corrupt"));
        }
        Ok(Some(Zeroizing::new(
            std::slice::from_raw_parts(CFDataGetBytePtr(data.0), size as usize).to_vec(),
        )))
    }
}
pub fn save(bytes: &[u8]) -> Result<()> {
    unsafe {
        let mut q = Query::base();
        let mut attributes = Query::new();
        attributes.data(bytes);
        #[cfg(target_os = "ios")]
        attributes.set(
            kSecAttrAccessible,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        );
        let code = SecItemUpdate(q.dictionary.0, attributes.dictionary.0);
        if code != -25300 {
            return status(code);
        }
        q.data(bytes);
        #[cfg(target_os = "ios")]
        q.set(
            kSecAttrAccessible,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        );
        status(SecItemAdd(q.dictionary.0, ptr::null_mut()))
    }
}
pub fn clear() -> Result<()> {
    unsafe {
        let q = Query::base();
        let code = SecItemDelete(q.dictionary.0);
        if code == -25300 {
            Ok(())
        } else {
            status(code)
        }
    }
}
