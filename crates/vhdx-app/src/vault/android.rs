use super::*;
use jni::{
    objects::{GlobalRef, JByteArray, JObject, JValue},
    JNIEnv, JavaVM,
};
use std::sync::OnceLock;
static BRIDGE: OnceLock<(JavaVM, GlobalRef)> = OnceLock::new();
#[no_mangle]
pub extern "system" fn Java_org_vhdxreader_vhdx_1reader_MainActivity_installVault(
    env: JNIEnv,
    _: JObject,
    bridge: JObject,
) {
    if let (Ok(vm), Ok(object)) = (env.get_java_vm(), env.new_global_ref(bridge)) {
        let _ = BRIDGE.set((vm, object));
    }
    let _ = env.exception_clear();
}
fn with_env<T>(f: impl FnOnce(&mut JNIEnv, &JObject) -> jni::errors::Result<T>) -> Result<T> {
    let (vm, object) = BRIDGE.get().ok_or(error("vault_unavailable"))?;
    let mut env = vm
        .attach_current_thread()
        .map_err(|_| error("vault_unavailable"))?;
    match env
        .call_method(object.as_obj(), "isUnlocked", "()Z", &[])
        .and_then(|v| v.z())
    {
        Ok(true) => (),
        Ok(false) => return Err(error("vault_locked")),
        Err(_) => {
            let _ = env.exception_clear();
            return Err(error("vault_unavailable"));
        }
    }
    let result = f(&mut env, object.as_obj());
    if result.is_err() {
        let _ = env.exception_clear();
    }
    result.map_err(|_| error("vault_unavailable"))
}
pub fn load() -> Result<Option<Zeroizing<Vec<u8>>>> {
    with_env(|env, object| {
        let raw = env.call_method(object, "load", "()[B", &[])?.l()?;
        if raw.is_null() {
            return Ok(None);
        }
        let array = JByteArray::from(raw);
        let bytes = env.convert_byte_array(&array)?;
        env.set_byte_array_region(&array, 0, &vec![0i8; bytes.len()])?;
        Ok(Some(Zeroizing::new(bytes)))
    })
}
pub fn save(bytes: &[u8]) -> Result<()> {
    with_env(|env, object| {
        let array = env.byte_array_from_slice(bytes)?;
        let result = env.call_method(object, "save", "([B)V", &[JValue::Object(array.as_ref())]);
        if result.is_err() {
            let _ = env.exception_clear();
        }
        let _ = env.set_byte_array_region(&array, 0, &vec![0i8; bytes.len()]);
        result.map(|_| ())
    })
}
pub fn clear() -> Result<()> {
    with_env(|env, object| env.call_method(object, "clear", "()V", &[]).map(|_| ()))
}
