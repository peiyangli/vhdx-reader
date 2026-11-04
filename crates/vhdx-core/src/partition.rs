use crate::{source::ReadAt, Error, Result};
use serde::Serialize;

pub(crate) fn u32le(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}
pub(crate) fn u64le(b: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(b[at..at + 8].try_into().unwrap())
}
pub(crate) fn crc(bytes: &[u8], polynomial: u32) -> u32 {
    let mut value = !0u32;
    for &byte in bytes {
        value ^= byte as u32;
        for _ in 0..8 {
            value = (value >> 1) ^ (polynomial & 0u32.wrapping_sub(value & 1));
        }
    }
    !value
}

/// Refuse dirty logs before letting native code read regions or payloads.
pub fn check_vhdx(source: &dyn ReadAt) -> Result<()> {
    let mut signature = [0; 8];
    source.read_exact_at(0, &mut signature)?;
    if &signature != b"vhdxfile" {
        return Err(Error::Invalid("not a VHDX file".into()));
    }
    let mut valid = Vec::new();
    for offset in [65536, 131072] {
        let mut header = vec![0; 4096];
        source.read_exact_at(offset, &mut header)?;
        if &header[..4] != b"head" {
            continue;
        }
        let expected = u32le(&header, 4);
        header[4..8].fill(0);
        if crc(&header, 0x82f63b78) == expected {
            valid.push(header);
        }
    }
    valid.sort_by_key(|h| u64le(h, 8));
    // The pinned libvhdi selects by sequence without validating header CRCs.
    // Until we supply an overlay for a recovered header, refuse a degraded pair
    // rather than letting it select a header our preflight has rejected.
    if valid.len() != 2 {
        return Err(Error::Invalid(
            "VHDX requires two intact headers in this version; recover a copy first".into(),
        ));
    }
    let selected = valid
        .last()
        .ok_or_else(|| Error::Invalid("neither VHDX header has a valid CRC32C".into()))?;
    if valid.len() == 2 && u64le(&valid[0], 8) == u64le(&valid[1], 8) && valid[0] != valid[1] {
        return Err(Error::Invalid(
            "conflicting VHDX headers with equal sequence numbers".into(),
        ));
    }
    if selected[66..68] != [1, 0] || selected[64..66] != [0, 0] {
        return Err(Error::Unsupported("VHDX header/log version".into()));
    }
    if selected[48..64].iter().any(|v| *v != 0) {
        return Err(Error::Unsupported(
            "VHDX log replay required; recover a copy using Windows before opening read-only"
                .into(),
        ));
    }
    let mut first_regions = None;
    for offset in [192 * 1024, 256 * 1024] {
        let mut table = vec![0; 65536];
        source.read_exact_at(offset, &mut table)?;
        if &table[..4] != b"regi" {
            return Err(Error::Invalid("missing VHDX region table".into()));
        }
        let checksum = u32le(&table, 4);
        table[4..8].fill(0);
        if crc(&table, 0x82f63b78) != checksum {
            return Err(Error::Invalid("VHDX region table CRC32C mismatch".into()));
        }
        let count = u32le(&table, 8) as usize;
        if count == 0 || count > 2047 {
            return Err(Error::Invalid("VHDX region count".into()));
        }
        let mut ranges = Vec::new();
        for i in 0..count {
            let at = 16 + i * 32;
            let start = u64le(&table, at + 16);
            let size = u32le(&table, at + 24) as u64;
            if start < 1024 * 1024
                || start % (1024 * 1024) != 0
                || size == 0
                || size % (1024 * 1024) != 0
                || start.checked_add(size).is_none_or(|end| end > source.len())
            {
                return Err(Error::Invalid("VHDX region bounds/alignment".into()));
            }
            ranges.push((start, start + size));
        }
        ranges.sort_unstable();
        if ranges.windows(2).any(|p| p[0].1 > p[1].0) {
            return Err(Error::Invalid("overlapping VHDX regions".into()));
        }
        // Both copies must describe the same regions for this first reader.
        let contents = table[8..16 + count * 32].to_vec();
        if let Some(previous) = &first_regions {
            if *previous != contents {
                return Err(Error::Invalid("conflicting VHDX region tables".into()));
            }
        } else {
            first_regions = Some(contents);
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize)]
pub struct Partition {
    /// Original table slot, 1-based (stable even when GPT has unused entries).
    pub index: u32,
    pub scheme: String,
    pub name: String,
    pub offset: u64,
    pub length: u64,
    pub kind: VolumeKind,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum VolumeKind {
    Ntfs,
    BitLocker,
    Unknown,
}
pub fn detect_volume(source: &dyn ReadAt, offset: u64) -> Result<VolumeKind> {
    let mut boot = [0; 512];
    source.read_exact_at(offset, &mut boot)?;
    Ok(match &boot[3..11] {
        b"NTFS    " => VolumeKind::Ntfs,
        b"-FVE-FS-" => VolumeKind::BitLocker,
        _ => VolumeKind::Unknown,
    })
}

pub fn partitions(disk: &dyn ReadAt, sector: u32) -> Result<Vec<Partition>> {
    if ![512, 4096].contains(&sector) {
        return Err(Error::Unsupported(format!("logical sector size {sector}")));
    }
    let sector = sector as u64;
    if disk.len() % sector != 0 {
        return Err(Error::Invalid("disk size is not sector-aligned".into()));
    }
    let mut mbr = [0; 512];
    disk.read_exact_at(0, &mut mbr)?;
    if mbr[510..512] != [0x55, 0xaa] {
        return Err(Error::Invalid("missing MBR signature".into()));
    }
    let gpt = (0..4).any(|i| mbr[446 + i * 16 + 4] == 0xee);
    let mut result = Vec::new();
    if gpt {
        let mut header = vec![0; sector as usize];
        disk.read_exact_at(sector, &mut header)?;
        if &header[..8] != b"EFI PART" {
            return Err(Error::Invalid("protective MBR without primary GPT".into()));
        }
        let size = u32le(&header, 12) as usize;
        if !(92..=header.len()).contains(&size)
            || u32le(&header, 8) != 0x10000
            || u32le(&header, 20) != 0
        {
            return Err(Error::Unsupported("GPT revision or header size".into()));
        }
        let expected = u32le(&header, 16);
        header[16..20].fill(0);
        if crc(&header[..size], 0xedb88320) != expected {
            return Err(Error::Invalid("GPT header checksum mismatch".into()));
        }
        let first = u64le(&header, 40);
        let last = u64le(&header, 48);
        if u64le(&header, 24) != 1
            || u64le(&header, 32) != disk.len() / sector - 1
            || first > last
            || last >= disk.len() / sector - 1
        {
            return Err(Error::Invalid("GPT header LBA bounds".into()));
        }
        let entry_size = u32le(&header, 84) as usize;
        let count = u32le(&header, 80) as usize;
        if count == 0 || entry_size < 128 || entry_size % 128 != 0 || !entry_size.is_power_of_two()
        {
            return Err(Error::Invalid("GPT entry dimensions".into()));
        }
        let length = count
            .checked_mul(entry_size)
            .filter(|v| *v <= 16 * 1024 * 1024)
            .ok_or_else(|| Error::Unsupported("GPT entry array exceeds 16 MiB limit".into()))?;
        let table_lba = u64le(&header, 72);
        if table_lba < 2
            || table_lba
                .checked_mul(sector)
                .and_then(|v| v.checked_add(length as u64))
                .is_none_or(|end| end > first * sector)
        {
            return Err(Error::Invalid("GPT table overlaps usable sectors".into()));
        }
        let mut entries = vec![0; length];
        disk.read_exact_at(table_lba * sector, &mut entries)?;
        if crc(&entries, 0xedb88320) != u32le(&header, 88) {
            return Err(Error::Invalid("GPT entry checksum mismatch".into()));
        }
        for (i, e) in entries.chunks_exact(entry_size).enumerate() {
            if e[..16].iter().all(|v| *v == 0) {
                continue;
            }
            let start = u64le(e, 32);
            let end = u64le(e, 40);
            if start < first || end > last || start > end {
                return Err(Error::Invalid(
                    "GPT partition outside usable sectors".into(),
                ));
            }
            let name = String::from_utf16_lossy(
                &e[56..128]
                    .chunks_exact(2)
                    .map(|p| u16::from_le_bytes([p[0], p[1]]))
                    .take_while(|v| *v != 0)
                    .collect::<Vec<_>>(),
            );
            result.push(Partition {
                index: (i + 1) as u32,
                scheme: "GPT".into(),
                name,
                offset: start * sector,
                length: (end - start + 1) * sector,
                kind: detect_volume(disk, start * sector)?,
            });
        }
    } else {
        for i in 0..4 {
            let e = &mbr[446 + i * 16..462 + i * 16];
            if e[4] == 0 {
                continue;
            }
            if [0x05, 0x0f, 0x85].contains(&e[4]) {
                return Err(Error::Unsupported("extended MBR partitions".into()));
            }
            let start = u32le(e, 8) as u64 * sector;
            let length = u32le(e, 12) as u64 * sector;
            if start < sector
                || length == 0
                || start.checked_add(length).is_none_or(|v| v > disk.len())
            {
                return Err(Error::Invalid("MBR partition bounds".into()));
            }
            result.push(Partition {
                index: (i + 1) as u32,
                scheme: "MBR".into(),
                name: String::new(),
                offset: start,
                length,
                kind: detect_volume(disk, start)?,
            });
        }
    }
    let mut ranges = result
        .iter()
        .map(|p| (p.offset, p.offset + p.length))
        .collect::<Vec<_>>();
    ranges.sort_unstable();
    if ranges.windows(2).any(|w| w[0].1 > w[1].0) {
        return Err(Error::Invalid("overlapping partitions".into()));
    }
    if result.is_empty() {
        return Err(Error::Unsupported(
            "no supported partition table entries".into(),
        ));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::tests::Memory;
    #[test]
    fn checksum_vectors() {
        assert_eq!(crc(b"123456789", 0xedb88320), 0xcbf43926);
        assert_eq!(crc(b"123456789", 0x82f63b78), 0xe3069283);
    }
    fn image(log: bool) -> Memory {
        let mut data = vec![0; 2 * 1024 * 1024];
        data[..8].copy_from_slice(b"vhdxfile");
        for (seq, start) in [(1u64, 65536), (2u64, 131072)] {
            let h = &mut data[start..start + 4096];
            h[..4].copy_from_slice(b"head");
            h[8..16].copy_from_slice(&seq.to_le_bytes());
            h[66] = 1;
            if log && seq == 2 {
                h[48] = 1;
            }
            let checksum = crc(h, 0x82f63b78);
            h[4..8].copy_from_slice(&checksum.to_le_bytes());
        }
        for start in [192 * 1024, 256 * 1024] {
            let r = &mut data[start..start + 65536];
            r[..4].copy_from_slice(b"regi");
            r[8..12].copy_from_slice(&1u32.to_le_bytes());
            r[32..40].copy_from_slice(&1048576u64.to_le_bytes());
            r[40..44].copy_from_slice(&1048576u32.to_le_bytes());
            let checksum = crc(r, 0x82f63b78);
            r[4..8].copy_from_slice(&checksum.to_le_bytes());
        }
        Memory(data)
    }
    #[test]
    fn header_selection_and_dirty_log() {
        assert!(check_vhdx(&image(false)).is_ok());
        assert!(matches!(
            check_vhdx(&image(true)),
            Err(Error::Unsupported(_))
        ));
        let mut i = image(false);
        i.0[65536 + 100] ^= 1;
        assert!(check_vhdx(&i).is_err());
        i.0[131072 + 100] ^= 1;
        assert!(check_vhdx(&i).is_err());
    }
    #[test]
    fn rejects_mbr_overlap_and_overflow() {
        let mut disk = Memory(vec![0; 4096]);
        disk.0[510..512].copy_from_slice(&[0x55, 0xaa]);
        for i in 0..2 {
            let e = &mut disk.0[446 + i * 16..462 + i * 16];
            e[4] = 7;
            e[8..12].copy_from_slice(&1u32.to_le_bytes());
            e[12..16].copy_from_slice(&2u32.to_le_bytes());
        }
        assert!(partitions(&disk, 512).is_err());
        disk.0[462 + 4] = 0;
        assert_eq!(partitions(&disk, 512).unwrap().len(), 1);
        disk.0[446 + 12..446 + 16].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(partitions(&disk, 512).is_err());
    }
}
