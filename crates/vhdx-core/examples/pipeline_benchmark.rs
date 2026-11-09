//! Layered read benchmark: source I/O timing, cold session reads, warm reads and
//! cross-sector random reads. RAM mode excludes storage; it is NOT USB throughput.
use sha2::{Digest, Sha256};
use std::{cell::Cell, path::Path, rc::Rc, time::Instant};
use vhdx_core::{
    native::Runtime,
    session::{Cancellation, Image},
    source::{LocalFile, ReadAt},
    Result,
};
use zeroize::Zeroizing;
struct Ram(Vec<u8>);
impl ReadAt for Ram {
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
struct Counted {
    source: Rc<dyn ReadAt>,
    calls: Cell<u64>,
    bytes: Cell<u64>,
    nanos: Cell<u128>,
}
impl ReadAt for Counted {
    fn len(&self) -> u64 {
        self.source.len()
    }
    fn read_at(&self, offset: u64, out: &mut [u8]) -> Result<usize> {
        let start = Instant::now();
        let result = self.source.read_at(offset, out);
        self.nanos
            .set(self.nanos.get() + start.elapsed().as_nanos());
        self.calls.set(self.calls.get() + 1);
        if let Ok(n) = result {
            self.bytes.set(self.bytes.get() + n as u64);
        }
        result
    }
}
impl Counted {
    fn reset(&self) {
        self.calls.set(0);
        self.bytes.set(0);
        self.nanos.set(0);
    }
    fn report(&self, source: &str, stage: &str, round: usize, start: Instant, bytes: u64) {
        let ms = start.elapsed().as_secs_f64() * 1000.;
        println!(
            "{source},{stage},{round},{ms:.3},{bytes},{},{},{:.3}",
            self.calls.get(),
            self.bytes.get(),
            self.nanos.get() as f64 / 1e6
        );
    }
}
fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    assert!(
        args.len() == 4,
        "pipeline_benchmark <image> <file in image> <file|ram>"
    );
    let mode = args[3].as_str();
    assert!(matches!(mode, "file" | "ram"));
    let source: Rc<dyn ReadAt> = if mode == "ram" {
        Rc::new(Ram(std::fs::read(&args[1])?))
    } else {
        Rc::new(LocalFile::open(Path::new(&args[1]))?)
    };
    let source = Rc::new(Counted {
        source,
        calls: Cell::new(0),
        bytes: Cell::new(0),
        nanos: Cell::new(0),
    });
    let native = std::env::var("VHDX_NATIVE_DIR").expect("set VHDX_NATIVE_DIR");
    let runtime = Runtime::load(Path::new(&native))?;
    let credential = std::env::var_os("VHDX_BENCH_PASSWORD_FILE")
        .map(|p| vhdx_core::credentials::from_file(Path::new(&p), false))
        .transpose()?;
    let rounds = std::env::var("VHDX_BENCH_ROUNDS")
        .map(|s| s.parse::<usize>().unwrap())
        .unwrap_or(5);
    assert!((1..=100).contains(&rounds));
    let cancel = Cancellation::default();
    let mut expected = None;
    println!("source,stage,round,ms,logical_bytes,source_calls,source_bytes,source_ms");
    for round in 0..rounds {
        // Reopen every round: neither plaintext nor ciphertext cache is inherited.
        let image = Image::from_source(runtime.clone(), source.clone())?;
        let volume = image.unlock(1, credential.as_ref(), 16 * 1024 * 1024)?;
        let file = volume.open_file(&args[2])?;
        assert!(
            !file.is_empty() && file.len() <= 256 * 1024 * 1024,
            "benchmark file must be 1 byte..256 MiB"
        );
        if round == 0 {
            println!(
                "# encryption_method={:?},bytes={}",
                volume.encryption_method,
                file.len()
            );
        }
        let mut out = Zeroizing::new(vec![0; file.len() as usize]);
        for stage in ["session_cold_sequential", "warm_sequential"] {
            source.reset();
            let start = Instant::now();
            let mut offset = 0;
            while offset < out.len() {
                let end = (offset + 256 * 1024).min(out.len());
                let n = file.read_at(offset as u64, &mut out[offset..end], &cancel)?;
                assert!(n > 0);
                offset += n;
            }
            source.report(mode, stage, round, start, offset as u64);
            // Hash outside timed region. Compare across rounds; compare output
            // hashes across backends using the benchmark runner.
            let digest = format!("{:x}", Sha256::digest(&*out));
            if let Some(expected) = &expected {
                assert_eq!(&digest, expected);
            } else {
                println!("# sha256={digest}");
                expected = Some(digest);
            }
        }
        let mut small = Zeroizing::new(vec![0; 4096]);
        let mut state = 1u64;
        let mut bytes = 0u64;
        source.reset();
        let start = Instant::now();
        for _ in 0..2000 {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
            let offset = ((state >> 32) % file.len()) as usize;
            let n = file.read_at(offset as u64, &mut small, &cancel)?;
            assert_eq!(&small[..n], &out[offset..offset + n]);
            assert_eq!(n, 4096.min(out.len() - offset));
            bytes += n as u64;
        }
        source.report(mode, "warm_seek_4k_verified", round, start, bytes);
        assert_eq!(file.read_at(file.len(), &mut small, &cancel)?, 0);
    }
    Ok(())
}
