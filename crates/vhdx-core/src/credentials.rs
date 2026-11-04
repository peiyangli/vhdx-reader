//! Credential input shared by the CLI and the desktop adapter. Never log its contents.
use crate::{native::Credential, Error, Result};
use std::{io::Read, path::Path};
use zeroize::Zeroizing;

pub fn from_file(path: &Path, recovery: bool) -> Result<Credential> {
    from_reader(std::fs::File::open(path)?, recovery)
}
pub fn from_reader(reader: impl Read, recovery: bool) -> Result<Credential> {
    let mut bytes = Zeroizing::new(Vec::new());
    reader.take(65537).read_to_end(&mut bytes)?;
    if bytes.len() > 65536 {
        return Err(Error::Invalid("credential file exceeds 64 KiB".into()));
    }
    from_bytes(&bytes, recovery, true)
}
/// File inputs may contain a final newline; explicitly typed passwords are never trimmed.
pub fn from_bytes(bytes: &[u8], recovery: bool, from_file: bool) -> Result<Credential> {
    if bytes.len() > 65536 {
        return Err(Error::Invalid("credential exceeds 64 KiB".into()));
    }
    let mut text = if bytes.starts_with(&[0xff, 0xfe]) || bytes.starts_with(&[0xfe, 0xff]) {
        if bytes.len() % 2 != 0 {
            return Err(Error::Invalid("invalid UTF-16 credential file".into()));
        }
        let little = bytes[0] == 0xff;
        let units = Zeroizing::new(
            bytes[2..]
                .chunks_exact(2)
                .map(|p| {
                    if little {
                        u16::from_le_bytes([p[0], p[1]])
                    } else {
                        u16::from_be_bytes([p[0], p[1]])
                    }
                })
                .collect::<Vec<_>>(),
        );
        Zeroizing::new(
            String::from_utf16(&units)
                .map_err(|_| Error::Invalid("invalid UTF-16 credential file".into()))?,
        )
    } else {
        let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes);
        Zeroizing::new(
            std::str::from_utf8(bytes)
                .map_err(|_| {
                    Error::Invalid("credential must be UTF-8 or BOM-marked UTF-16".into())
                })?
                .to_owned(),
        )
    };
    if !recovery {
        if from_file && text.ends_with('\n') {
            text.pop();
            if text.ends_with('\r') {
                text.pop();
            }
        }
        if text.is_empty() {
            return Err(Error::Invalid("password is empty".into()));
        }
        return Ok(Credential::Password(Zeroizing::new(
            text.as_bytes().to_vec(),
        )));
    }
    let mut candidate = None;
    for token in text.split(|c: char| !c.is_ascii_digit() && c != '-') {
        let parts = token.split('-').collect::<Vec<_>>();
        if parts.len() == 8
            && parts
                .iter()
                .all(|p| p.len() == 6 && p.bytes().all(|b| b.is_ascii_digit()))
        {
            if candidate.is_some() {
                return Err(Error::Invalid(
                    "recovery input contains more than one key".into(),
                ));
            }
            candidate = Some(Zeroizing::new(token.as_bytes().to_vec()));
        }
    }
    candidate
        .map(Credential::RecoveryPassword)
        .ok_or_else(|| Error::Invalid("expected eight groups of six recovery digits".into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn password(c: Credential) -> Zeroizing<Vec<u8>> {
        match c {
            Credential::Password(p) => p,
            _ => panic!("wrong credential type"),
        }
    }
    #[test]
    fn preserves_spaces_and_typed_newlines() {
        assert_eq!(
            &*password(from_bytes(b"  sample  \r\n", false, true).unwrap()),
            b"  sample  "
        );
        assert_eq!(
            &*password(from_bytes(b"sample\n", false, false).unwrap()),
            b"sample\n"
        );
    }
    #[test]
    fn utf16_and_bom() {
        let mut data = vec![0xff, 0xfe];
        data.extend(
            "测试 password\r\n"
                .encode_utf16()
                .flat_map(u16::to_le_bytes),
        );
        assert_eq!(
            &*password(from_bytes(&data, false, true).unwrap()),
            "测试 password".as_bytes()
        );
        assert!(from_bytes(b"", false, false).is_err());
        assert!(from_bytes(&[0xff, 0xfe, 0], false, true).is_err());
    }
}
