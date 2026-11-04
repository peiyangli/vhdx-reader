//! Opt-in tests: VHDX_NATIVE_DIR=/path/to/libs cargo test -p vhdx-core --test native -- --ignored
use std::{path::PathBuf, rc::Rc};
use vhdx_core::{
    native::{Disk, Runtime},
    source::ReadAt,
    Result,
};

struct Bytes(Vec<u8>);
impl ReadAt for Bytes {
    fn len(&self) -> u64 {
        self.0.len() as u64
    }
    fn read_at(&self, offset: u64, out: &mut [u8]) -> Result<usize> {
        let start = usize::try_from(offset)
            .unwrap_or(usize::MAX)
            .min(self.0.len());
        let n = out.len().min(self.0.len() - start);
        out[..n].copy_from_slice(&self.0[start..start + n]);
        Ok(n)
    }
}
fn crc32c(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0x82f63b78 & 0u32.wrapping_sub(crc & 1));
        }
    }
    !crc
}
fn put32(data: &mut [u8], at: usize, value: u32) {
    data[at..at + 4].copy_from_slice(&value.to_le_bytes());
}
fn put64(data: &mut [u8], at: usize, value: u64) {
    data[at..at + 8].copy_from_slice(&value.to_le_bytes());
}
fn guid(s: &str) -> [u8; 16] {
    let hex = s.replace('-', "");
    let mut b = [0; 16];
    for (i, v) in b.iter_mut().enumerate() {
        *v = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap();
    }
    b[..4].reverse();
    b[4..6].reverse();
    b[6..8].reverse();
    b
}
const MIB: usize = 1024 * 1024;
fn expected(offset: usize) -> u8 {
    if (2 * MIB..4 * MIB).contains(&offset) {
        0
    } else {
        ((offset.wrapping_mul(13) + offset / 512) % 251) as u8
    }
}
/// Independent fixture writer, no production mapping code. Middle block is explicitly ZERO.
fn fixture() -> Bytes {
    let mut d = vec![0; 8 * MIB];
    d[..8].copy_from_slice(b"vhdxfile");
    for (seq, start) in [(1, 65536), (2, 131072)] {
        let h = &mut d[start..start + 4096];
        h[..4].copy_from_slice(b"head");
        put64(h, 8, seq);
        h[66] = 1;
        put32(h, 68, MIB as u32);
        put64(h, 72, (3 * MIB) as u64);
        let crc = crc32c(h);
        put32(h, 4, crc);
    }
    for start in [192 * 1024, 256 * 1024] {
        let r = &mut d[start..start + 65536];
        r[..4].copy_from_slice(b"regi");
        put32(r, 8, 2);
        for (i, id, offset) in [
            (0, "8b7ca206-4790-4b9a-b8fe-575f050f886e", MIB),
            (1, "2dc27766-f623-4200-9d64-115e9bfd4a08", 2 * MIB),
        ] {
            let at = 16 + i * 32;
            r[at..at + 16].copy_from_slice(&guid(id));
            put64(r, at + 16, offset as u64);
            put32(r, at + 24, MIB as u32);
            put32(r, at + 28, 1);
        }
        let crc = crc32c(r);
        put32(r, 4, crc);
    }
    let m = &mut d[MIB..2 * MIB];
    m[..8].copy_from_slice(b"metadata");
    m[10] = 5;
    let items = [
        (
            "caa16737-fa36-4d43-b3b6-33f0aa44e76b",
            [(2 * MIB) as u32, 0]
                .into_iter()
                .flat_map(u32::to_le_bytes)
                .collect::<Vec<_>>(),
            4,
        ),
        (
            "2fa54224-cd1b-4876-b211-5dbed83bf4b8",
            (6 * MIB as u64).to_le_bytes().to_vec(),
            6,
        ),
        (
            "8141bf1d-a96f-4709-ba47-f233a8faab5f",
            512u32.to_le_bytes().to_vec(),
            6,
        ),
        (
            "cda348c7-445d-4471-9cc9-e9885251c556",
            4096u32.to_le_bytes().to_vec(),
            6,
        ),
        ("beca12ab-b2e6-4523-93ef-c309e000c746", vec![1; 16], 6),
    ];
    for (i, (id, value, flags)) in items.iter().enumerate() {
        let at = 32 + i * 32;
        let offset = 65536 + i * 64;
        m[at..at + 16].copy_from_slice(&guid(id));
        put32(m, at + 16, offset as u32);
        put32(m, at + 20, value.len() as u32);
        put32(m, at + 24, *flags);
        m[offset..offset + value.len()].copy_from_slice(value);
    }
    put64(&mut d, 2 * MIB, (4 * MIB) as u64 | 6);
    put64(&mut d, 2 * MIB + 8, 2);
    put64(&mut d, 2 * MIB + 16, (6 * MIB) as u64 | 6);
    for i in 0..2 * MIB {
        d[4 * MIB + i] = expected(i);
        d[6 * MIB + i] = expected(4 * MIB + i);
    }
    Bytes(d)
}
fn runtime() -> Rc<Runtime> {
    Runtime::load(&PathBuf::from(
        std::env::var_os("VHDX_NATIVE_DIR").expect("set VHDX_NATIVE_DIR"),
    ))
    .unwrap()
}
#[test]
#[ignore = "requires pinned native libraries"]
fn dynamic_disk_random_reads_cross_blocks_and_zero_holes() {
    let runtime = runtime();
    let mut offsets = vec![
        0,
        511,
        4093,
        2 * MIB - 17,
        2 * MIB,
        4 * MIB - 31,
        4 * MIB,
        6 * MIB - 65,
    ];
    let mut random = 17u64;
    for _ in 0..128 {
        random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
        offsets.push((random % (6 * MIB as u64)) as usize);
    }
    for state in [0, 2] {
        // NOT_PRESENT and ZERO in an independent dynamic disk.
        let mut data = fixture();
        put64(&mut data.0, 2 * MIB + 8, state);
        let disk = Disk::open(&runtime, Rc::new(data)).unwrap();
        assert_eq!(disk.len(), 6 * MIB as u64);
        for &offset in &offsets {
            let mut out = vec![0; 65539];
            let n = disk.read_at(offset as u64, &mut out).unwrap();
            assert_eq!(n, out.len().min(6 * MIB - offset));
            for (i, b) in out[..n].iter().enumerate() {
                assert_eq!(*b, expected(offset + i), "logical offset {}", offset + i);
            }
        }
        assert_eq!(disk.read_at(disk.len(), &mut [0; 8]).unwrap(), 0);
    }
}
#[test]
#[ignore = "requires pinned native libraries"]
fn truncated_payload_is_an_error_not_zero_filled_success() {
    let runtime = runtime();
    let mut data = fixture();
    data.0.truncate(7 * MIB);
    if let Ok(disk) = Disk::open(&runtime, Rc::new(data)) {
        assert!(disk
            .read_exact_at((5 * MIB) as u64, &mut [0; 4096])
            .is_err());
    }
}
