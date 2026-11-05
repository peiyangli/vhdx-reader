//! Repeatable read-only benchmark. See docs/read-performance.md for usage and limits.
use std::{cell::Cell, hint::black_box, path::Path, rc::Rc, time::Instant};
use vhdx_core::{
    native::Runtime,
    session::{Cancellation, Image},
    source::{CachedReader, LocalFile, ReadAt},
    Result,
};

struct Counted {
    source: Rc<dyn ReadAt>,
    calls: Cell<u64>,
    bytes: Cell<u64>,
}
impl Counted {
    fn new(source: Rc<dyn ReadAt>) -> Rc<Self> {
        Rc::new(Self {
            source,
            calls: Cell::new(0),
            bytes: Cell::new(0),
        })
    }
    fn measure(&self, label: &str, run: impl FnOnce() -> Result<u64>) -> Result<()> {
        self.calls.set(0);
        self.bytes.set(0);
        let start = Instant::now();
        let units = run()?;
        println!(
            "{label},{:.3},{units},{},{}",
            start.elapsed().as_secs_f64() * 1000.0,
            self.calls.get(),
            self.bytes.get()
        );
        Ok(())
    }
}
impl ReadAt for Counted {
    fn len(&self) -> u64 {
        self.source.len()
    }
    fn read_at(&self, offset: u64, out: &mut [u8]) -> Result<usize> {
        let n = self.source.read_at(offset, out)?;
        self.calls.set(self.calls.get() + 1);
        self.bytes.set(self.bytes.get() + n as u64);
        Ok(n)
    }
}
struct Generated;
impl ReadAt for Generated {
    fn len(&self) -> u64 {
        1024 * 1024 * 1024
    }
    fn read_at(&self, offset: u64, out: &mut [u8]) -> Result<usize> {
        let n = out.len().min(self.len().saturating_sub(offset) as usize);
        out[..n].fill((offset / 65536) as u8);
        Ok(n)
    }
}
fn main() -> Result<()> {
    println!("workload,ms,logical_bytes_or_entries,source_calls,source_bytes");
    let args = std::env::args().collect::<Vec<_>>();
    if args.len() == 1 {
        for _ in 0..5 {
            let source = Counted::new(Rc::new(Generated));
            let cache = CachedReader::new(source.clone(), 65536, 16 * 1024 * 1024)?;
            let mut out = vec![0; 4096];
            source.measure("cache_sequential", || {
                for offset in (0..512 * 1024 * 1024).step_by(out.len()) {
                    cache.read_exact_at(offset, &mut out)?;
                    black_box(&out);
                }
                Ok(512 * 1024 * 1024)
            })?;
            source.measure("cache_random", || {
                let mut state = 1u64;
                for _ in 0..10000 {
                    state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
                    cache.read_exact_at((state >> 32) % 16384 * 65536, &mut out)?;
                    black_box(&out);
                }
                Ok(10000 * out.len() as u64)
            })?;
        }
        return Ok(());
    }
    let native = std::env::var("VHDX_NATIVE_DIR").expect("set VHDX_NATIVE_DIR");
    let runtime = Runtime::load(Path::new(&native))?;
    let credential = std::env::var_os("VHDX_BENCH_PASSWORD_FILE")
        .map(|p| vhdx_core::credentials::from_file(Path::new(&p), false))
        .transpose()?;
    let page_size = std::env::var("VHDX_BENCH_PAGE_SIZE")
        .map(|s| s.parse::<u32>().expect("invalid page size"))
        .unwrap_or(200);
    let plaintext_mib = std::env::var("VHDX_BENCH_PLAINTEXT_MIB")
        .map(|s| s.parse::<usize>().expect("invalid cache size"))
        .unwrap_or(16);
    let ciphertext_mib = std::env::var("VHDX_BENCH_CIPHERTEXT_MIB")
        .map(|s| s.parse::<usize>().expect("invalid cache size"))
        .unwrap_or(1);
    assert!((1..=256).contains(&plaintext_mib) && (1..=16).contains(&ciphertext_mib));
    for _ in 0..5 {
        let source = Counted::new(Rc::new(LocalFile::open(Path::new(&args[1]))?));
        let image = Image::from_source(runtime.clone(), source.clone())?;
        let volume = image.unlock_with_caches(
            1,
            credential.as_ref(),
            plaintext_mib * 1024 * 1024,
            ciphertext_mib * 1024 * 1024,
        )?;
        let cancel = Cancellation::default();
        source.measure(&format!("directory_pages_{page_size}"), || {
            let mut start = 0;
            loop {
                let page = volume.list("/", start, page_size, &cancel)?;
                black_box(&page.entries);
                match page.next_index {
                    Some(next) => start = next,
                    None => return Ok(page.total_entries as u64),
                }
            }
        })?;
        if let Some(path) = args.get(2) {
            let file = volume.open_file(path)?;
            let mut out = vec![0; 256 * 1024];
            source.measure("file_sequential", || {
                let mut offset = 0;
                while offset < file.len() {
                    let n = file.read_at(offset, &mut out, &cancel)?;
                    assert!(n > 0);
                    black_box(&out[..n]);
                    offset += n as u64;
                }
                Ok(offset)
            })?;
            source.measure("file_seek_4k", || {
                let mut state = 1u64;
                for _ in 0..2000 {
                    state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
                    let offset = (state >> 32) % file.len().max(1);
                    black_box(file.read_at(offset, &mut out[..4096], &cancel)?);
                }
                Ok(2000 * 4096)
            })?;
        }
    }
    Ok(())
}
