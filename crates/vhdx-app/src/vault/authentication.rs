//! Native-only gate for every use of a saved credential. No Dart success flag.
use super::*;
#[cfg(any(
    target_os = "android",
    target_os = "ios",
    target_os = "windows",
    target_os = "macos"
))]
static PROMPT: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(any(target_os = "ios", target_os = "windows", target_os = "macos"))]
static HOST_AUTHENTICATE: std::sync::OnceLock<extern "C" fn() -> i32> = std::sync::OnceLock::new();

/// Installed by the native host before creating the Flutter engine. Absence fails closed.
#[cfg(any(target_os = "ios", target_os = "windows", target_os = "macos"))]
#[no_mangle]
pub extern "C" fn vhdx_install_device_authentication(callback: extern "C" fn() -> i32) {
    let _ = HOST_AUTHENTICATE.set(callback);
}

pub fn required() -> bool {
    cfg!(any(
        target_os = "android",
        target_os = "ios",
        target_os = "windows",
        target_os = "macos"
    ))
}

#[cfg(any(
    target_os = "android",
    target_os = "ios",
    target_os = "windows",
    target_os = "macos",
    test
))]
fn outcome(code: i32) -> Result<()> {
    match code {
        0 => Ok(()),
        1 => Err(error("vault_auth_cancelled")),
        3 => Err(error("vault_auth_busy")),
        _ => Err(error("vault_auth_unavailable")),
    }
}

fn authenticate() -> Result<()> {
    #[cfg(any(
        target_os = "android",
        target_os = "ios",
        target_os = "windows",
        target_os = "macos"
    ))]
    let _prompt = PROMPT.try_lock().map_err(|_| error("vault_auth_busy"))?;
    #[cfg(target_os = "android")]
    return outcome(super::android::authenticate()?);
    #[cfg(any(target_os = "ios", target_os = "windows", target_os = "macos"))]
    return outcome(HOST_AUTHENTICATE
        .get()
        .ok_or(error("vault_auth_unavailable"))?());
    #[cfg(not(any(
        target_os = "android",
        target_os = "ios",
        target_os = "windows",
        target_os = "macos"
    )))]
    Ok(())
}

pub fn read<T>(load: impl FnOnce() -> Result<T>) -> Result<T> {
    after_authentication(authenticate, load)
}
fn after_authentication<T>(
    verify: impl FnOnce() -> Result<()>,
    load: impl FnOnce() -> Result<T>,
) -> Result<T> {
    verify()?;
    load()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn denied_or_missing_verification_never_reads_credentials() {
        for code in [1, 2, 3, -1, 99] {
            let result: Result<()> =
                after_authentication(|| outcome(code), || panic!("must not read secrets"));
            assert!(result.is_err());
        }
    }
    #[cfg(any(target_os = "ios", target_os = "windows", target_os = "macos"))]
    #[test]
    fn missing_native_host_cannot_read_saved_credentials() {
        assert!(HOST_AUTHENTICATE.get().is_none());
        let result: Result<()> = read(|| panic!("missing host must never read credentials"));
        assert!(result.is_err());
    }
    #[test]
    fn success_is_required_for_each_read() {
        let prompts = std::cell::Cell::new(0);
        for expected in 1..=2 {
            let value = after_authentication(
                || {
                    prompts.set(prompts.get() + 1);
                    outcome(0)
                },
                || {
                    assert_eq!(prompts.get(), expected);
                    Ok(42)
                },
            )
            .unwrap();
            assert_eq!(value, 42);
        }
    }
}
