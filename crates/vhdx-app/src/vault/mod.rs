//! OS-protected vault. Only the Rust worker touches credentials; replies contain
//! metadata, never secrets. One atomic encrypted record avoids plaintext indexes.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use vhdx_core::{native::Credential, Error, Result};
use zeroize::{Zeroize, Zeroizing};

#[cfg(any(target_os = "ios", target_os = "macos"))]
mod apple;
#[cfg(any(target_os = "ios", target_os = "macos"))]
use apple as platform;
#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
use windows as platform;
#[cfg(target_os = "android")]
pub mod android;
#[cfg(target_os = "android")]
use android as platform;
#[cfg(not(any(
    target_os = "ios",
    target_os = "macos",
    target_os = "windows",
    target_os = "android"
)))]
mod platform {
    use super::*;
    pub fn load() -> Result<Option<Zeroizing<Vec<u8>>>> {
        Err(error("vault_unavailable"))
    }
    pub fn save(_: &[u8]) -> Result<()> {
        Err(error("vault_unavailable"))
    }
    pub fn clear() -> Result<()> {
        Err(error("vault_unavailable"))
    }
}
pub const MAX_BYTES: usize = 4 * 1024 * 1024;
pub fn available() -> bool {
    cfg!(any(
        target_os = "ios",
        target_os = "macos",
        target_os = "windows",
        target_os = "android"
    ))
}
pub fn error(code: &str) -> Error {
    Error::Invalid(code.into())
}
pub fn valid_id(id: &str) -> bool {
    id.len() == 67 && id.starts_with("v1-") && id[3..].bytes().all(|c| c.is_ascii_hexdigit())
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Saved {
    mode: String,
    secret: String,
    label: String,
    updated: u64,
}
impl Drop for Saved {
    fn drop(&mut self) {
        self.secret.zeroize();
    }
}
impl Saved {
    pub fn credential(&self) -> Result<Credential> {
        vhdx_core::credentials::from_bytes(self.secret.as_bytes(), self.mode == "recovery", false)
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Vault {
    version: u32,
    entries: BTreeMap<String, Saved>,
}
impl Vault {
    fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() > MAX_BYTES {
            return Err(error("vault_corrupt"));
        }
        let value: Self = serde_json::from_slice(bytes).map_err(|_| error("vault_corrupt"))?;
        if value.version != 1
            || value.entries.len() > 256
            || value.entries.iter().any(|(id, s)| {
                !valid_id(id)
                    || !matches!(s.mode.as_str(), "password" | "recovery")
                    || s.secret.is_empty()
                    || s.secret.len() > 65536
                    || s.label.len() > 1024
            })
        {
            return Err(error("vault_corrupt"));
        }
        Ok(value)
    }
    fn load() -> Result<Self> {
        match platform::load()? {
            Some(bytes) => Self::decode(&bytes),
            None => Ok(Self {
                version: 1,
                entries: BTreeMap::new(),
            }),
        }
    }
    fn persist(&self) -> Result<()> {
        let bytes = Zeroizing::new(serde_json::to_vec(self).map_err(|_| error("vault_corrupt"))?);
        if bytes.len() > MAX_BYTES {
            return Err(error("vault_full"));
        }
        platform::save(&bytes)
    }
}
pub fn list() -> Result<Value> {
    let vault = Vault::load()?;
    Ok(
        json!({"available":true,"entries":vault.entries.iter().map(|(id,s)|
        json!({"id":id,"label":s.label,"mode":s.mode,"updated":s.updated})).collect::<Vec<_>>()}),
    )
}
pub fn contains(id: &str) -> Result<bool> {
    Ok(Vault::load()?.entries.contains_key(id))
}
pub fn get(id: &str) -> Result<Saved> {
    Vault::load()?
        .entries
        .remove(id)
        .ok_or(error("vault_missing"))
}
pub fn save(id: &str, label: &str, credential: &Credential) -> Result<()> {
    if !valid_id(id) {
        return Err(error("vault_identity"));
    }
    let mut vault = Vault::load()?; // Never replace corrupt/locked data with an empty vault.
    if vault.entries.len() >= 256 && !vault.entries.contains_key(id) {
        return Err(error("vault_full"));
    }
    let (mode, bytes) = match credential {
        Credential::Password(s) => ("password", s),
        Credential::RecoveryPassword(s) => ("recovery", s),
    };
    let secret = String::from_utf8(bytes.to_vec()).map_err(|_| error("vault_corrupt"))?;
    vault.entries.insert(
        id.into(),
        Saved {
            mode: mode.into(),
            secret,
            label: label
                .chars()
                .filter(|c| !c.is_control())
                .take(200)
                .collect(),
            updated: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
        },
    );
    vault.persist()
}
pub fn remove(id: &str) -> Result<()> {
    let mut vault = Vault::load()?;
    vault.entries.remove(id);
    if vault.entries.is_empty() {
        platform::clear()
    } else {
        vault.persist()
    }
}
pub fn clear() -> Result<()> {
    platform::clear()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_unknown_version_and_bad_ids() {
        assert!(Vault::decode(br#"{"version":2,"entries":{}}"#).is_err());
        assert!(Vault::decode(br#"{"version":1,"entries":{"path":{"mode":"password","secret":"secret","label":"disk","updated":1}}}"#).is_err());
        assert!(Vault::decode(br#"{"version":1,"entries":{}}"#).is_ok());
        assert!(!valid_id("../../password.txt"));
    }
}
