//! Native-only gate for every use of a saved credential. No Dart success flag.
use super::*;
#[cfg(any(target_os = "android", target_os = "ios"))]
static PROMPT: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(target_os = "ios")]
static IOS_AUTHENTICATE: std::sync::OnceLock<extern "C" fn() -> i32> = std::sync::OnceLock::new();

/// Installed by the iOS host before creating the Flutter engine. Absence fails closed.
#[cfg(target_os = "ios")]
#[no_mangle]
pub extern "C" fn vhdx_install_device_authentication(callback: extern "C" fn() -> i32) {
    let _ = IOS_AUTHENTICATE.set(callback);
}

pub fn required() -> bool {
    cfg!(any(target_os = "android", target_os = "ios"))
}

#[cfg(any(target_os = "android", target_os = "ios", test))]
fn outcome(code: i32) -> Result<()> {
    match code {
        0 => Ok(()),
        1 => Err(error("vault_auth_cancelled")),
        _ => Err(error("vault_auth_unavailable")),
    }
}

fn authenticate() -> Result<()> {
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let _prompt = PROMPT.try_lock().map_err(|_| error("vault_auth_busy"))?;
    #[cfg(target_os = "android")]
    return outcome(super::android::authenticate()?);
    #[cfg(target_os = "ios")]
    return outcome(IOS_AUTHENTICATE
        .get()
        .ok_or(error("vault_auth_unavailable"))?());
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
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
        for code in [1, 2, -1, 99] {
            let result: Result<()> =
                after_authentication(|| outcome(code), || panic!("must not read secrets"));
            assert!(result.is_err());
        }
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
