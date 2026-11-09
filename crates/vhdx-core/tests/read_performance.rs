//! Correctness regression for the generated large-directory/eviction fixture.
use std::{cell::Cell, path::Path, rc::Rc};
use vhdx_core::{
    native::Runtime,
    session::{Cancellation, Image},
    source::{LocalFile, ReadAt},
};

#[test]
#[ignore = "requires private VHDX_SAMPLE_DIR and VHDX_NATIVE_DIR"]
fn bitlocker_sector_reads_are_coalesced_and_plaintext_is_reused() {
    struct Counted {
        source: LocalFile,
        calls: Cell<u64>,
        bytes: Cell<u64>,
    }
    impl ReadAt for Counted {
        fn len(&self) -> u64 {
            self.source.len()
        }
        fn read_at(&self, offset: u64, out: &mut [u8]) -> vhdx_core::Result<usize> {
            let n = self.source.read_at(offset, out)?;
            self.calls.set(self.calls.get() + 1);
            self.bytes.set(self.bytes.get() + n as u64);
            Ok(n)
        }
    }
    let root = std::env::var("VHDX_SAMPLE_DIR").unwrap();
    let native = std::env::var("VHDX_NATIVE_DIR").unwrap();
    let runtime = Runtime::load(Path::new(&native)).unwrap();
    let source = Rc::new(Counted {
        source: LocalFile::open(&Path::new(&root).join("bitlockervhdx.vhdx")).unwrap(),
        calls: Cell::new(0),
        bytes: Cell::new(0),
    });
    let image = Image::from_source(runtime, source.clone()).unwrap();
    let credential =
        vhdx_core::credentials::from_file(&Path::new(&root).join("password.txt"), false).unwrap();
    let volume = image
        .unlock(1, Some(&credential), 16 * 1024 * 1024)
        .unwrap();
    let file = volume.open_file("/$LogFile").unwrap();
    assert_eq!(file.len(), 2 * 1024 * 1024);
    let cancel = Cancellation::default();
    source.calls.set(0);
    source.bytes.set(0);
    let mut first = zeroize::Zeroizing::new(vec![0; file.len() as usize]);
    assert_eq!(file.read_at(0, &mut first, &cancel).unwrap(), first.len());
    // Allow mapping/metadata reads, but reject a return to thousands of 512-byte reads.
    assert!(source.calls.get() > 0 && source.calls.get() < 128);
    assert!(source.bytes.get() <= 3 * 1024 * 1024);
    source.calls.set(0);
    let mut out = [0; 4096];
    for offset in [65535, 0, 1048573, 2097135, 511] {
        let n = file.read_at(offset, &mut out, &cancel).unwrap();
        assert_eq!(&out[..n], &first[offset as usize..offset as usize + n]);
    }
    assert_eq!(source.calls.get(), 0);
}

#[test]
#[ignore = "requires VHDX_READ_FIXTURE and VHDX_NATIVE_DIR"]
fn paged_directory_and_reads_survive_eviction_refresh_and_errors() {
    let root = std::env::var("VHDX_READ_FIXTURE").unwrap();
    let native = std::env::var("VHDX_NATIVE_DIR").unwrap();
    let runtime = Runtime::load(Path::new(&native)).unwrap();
    let image =
        Image::from_source(runtime, Rc::new(LocalFile::open(Path::new(&root)).unwrap())).unwrap();
    let volume = image.unlock(1, None, 16 * 1024 * 1024).unwrap();
    let cancel = Cancellation::default();
    let expected = volume.list("/", 0, 10000, &cancel).unwrap();
    assert!(expected.total_entries >= 2001);
    let names = |entries: &[vhdx_core::session::FileInfo]| {
        entries
            .iter()
            .map(|e| {
                (
                    e.name.clone(),
                    e.directory,
                    e.size,
                    e.attributes,
                    e.modified_unix_ms,
                )
            })
            .collect::<Vec<_>>()
    };
    for limit in [1, 32, 200, 500] {
        let mut index = 0;
        let mut entries = Vec::new();
        loop {
            let page = volume.list("/", index, limit, &cancel).unwrap();
            entries.extend(page.entries);
            match page.next_index {
                Some(next) => index = next,
                None => break,
            }
        }
        assert_eq!(names(&entries), names(&expected.entries));
    }
    volume.list("/", 0, 1, &cancel).unwrap();
    assert!(volume.list("/does-not-exist", 1, 1, &cancel).is_err());
    assert_eq!(
        names(&volume.list("/", 5, 10, &cancel).unwrap().entries),
        names(&expected.entries[5..15])
    );
    let cancelled = Cancellation::default();
    cancelled.cancel();
    assert!(volume.list("/", 15, 10, &cancelled).is_err());
    assert_eq!(
        names(&volume.list("/", 0, 10, &cancel).unwrap().entries),
        names(&expected.entries[..10])
    );
    assert!(volume.list("/", u32::MAX, 1, &cancel).is_err());

    let file = volume.open_file("/payload.bin").unwrap();
    assert_eq!(file.len(), 32 * 1024 * 1024);
    let mut out = vec![0; 256 * 1024];
    let verify = |offset: u64, bytes: &[u8]| {
        assert!(bytes
            .iter()
            .enumerate()
            .all(|(i, b)| *b == (((offset + i as u64) / 65536) % 251) as u8));
    };
    for offset in (0..file.len()).step_by(out.len()) {
        let n = file.read_at(offset, &mut out, &cancel).unwrap();
        assert_eq!(n, out.len());
        verify(offset, &out[..n]);
    }
    for offset in [0, 511, 65535, 16777213, file.len() - 100, 65537, 4095] {
        let n = file.read_at(offset, &mut out[..4096], &cancel).unwrap();
        assert_eq!(n, (file.len() - offset).min(4096) as usize);
        verify(offset, &out[..n]);
    }
    assert_eq!(file.read_at(file.len(), &mut out, &cancel).unwrap(), 0);
}

#[test]
#[cfg(target_pointer_width = "64")]
#[ignore = "requires VHDX_SAMPLE_DIR, VHDX_READ_FIXTURE and VHDX_NATIVE_DIR"]
fn configurable_cache_pages_preserve_ntfs_and_bitlocker_reads() {
    let root = std::path::PathBuf::from(std::env::var_os("VHDX_SAMPLE_DIR").unwrap());
    let fixture = std::path::PathBuf::from(std::env::var_os("VHDX_READ_FIXTURE").unwrap());
    let native = std::env::var("VHDX_NATIVE_DIR").unwrap();
    let runtime = Runtime::load(Path::new(&native)).unwrap();
    let credential = vhdx_core::credentials::from_file(&root.join("password.txt"), false).unwrap();
    let cancel = Cancellation::default();
    for (path, file_path, credential) in [
        (fixture, "/payload.bin", None),
        (
            root.join("bitlockervhdx.vhdx"),
            "/$LogFile",
            Some(&credential),
        ),
    ] {
        let image =
            Image::from_source(runtime.clone(), Rc::new(LocalFile::open(&path).unwrap())).unwrap();
        let baseline = image.unlock(1, credential, 16 * 1024 * 1024).unwrap();
        let file = baseline.open_file(file_path).unwrap();
        let mut reference = zeroize::Zeroizing::new(vec![0; file.len() as usize]);
        for (index, chunk) in reference.chunks_mut(256 * 1024).enumerate() {
            assert_eq!(
                file.read_at((index * 256 * 1024) as u64, chunk, &cancel)
                    .unwrap(),
                chunk.len()
            );
        }
        for page in [1024 * 1024, 4 * 1024 * 1024] {
            let volume = image
                .unlock_with_cache_layout(1, credential, 16usize << 30, 1024 * 1024, page)
                .unwrap();
            let file = volume.open_file(file_path).unwrap();
            let mut out = vec![0; 128 * 1024];
            for offset in [
                0,
                511,
                (page as u64 - 1).min(file.len() - 1),
                file.len() / 2,
                file.len() - 17,
            ] {
                let n = file.read_at(offset, &mut out, &cancel).unwrap();
                assert_eq!(n, (file.len() - offset).min(out.len() as u64) as usize);
                assert_eq!(&out[..n], &reference[offset as usize..offset as usize + n]);
            }
            assert_eq!(file.read_at(file.len(), &mut out, &cancel).unwrap(), 0);
        }
        for page in [0, 96 * 1024, 8 * 1024 * 1024] {
            assert!(image
                .unlock_with_cache_layout(1, credential, 16 * 1024 * 1024, 1024 * 1024, page)
                .is_err());
        }
        assert!(image
            .unlock_with_cache_layout(1, credential, 64 * 1024, 1024 * 1024, 1024 * 1024)
            .is_err());
    }
}
