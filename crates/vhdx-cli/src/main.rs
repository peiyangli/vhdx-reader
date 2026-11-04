use clap::{Args, Parser, Subcommand};
use sha2::{Digest, Sha256};
use std::{
    io::Write,
    path::{Path, PathBuf},
    rc::Rc,
};
use vhdx_core::{
    native::{Credential, Runtime},
    session::{Cancellation, Image},
    Error, Result,
};
use zeroize::Zeroizing;

#[derive(Parser)]
#[command(
    name = "vhdx",
    version,
    about = "Read-only VHDX / BitLocker / NTFS explorer"
)]
struct Cli {
    /// Directory containing the four pinned native libraries.
    #[arg(long, global = true)]
    native_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Print loaded native library versions.
    Doctor,
    /// Inspect image geometry and partitions without unlocking volumes.
    Inspect { image: PathBuf },
    /// List one page of a directory as JSON.
    Ls {
        #[command(flatten)]
        volume: VolumeArgs,
        #[arg(default_value = "/")]
        path: String,
        #[arg(long, default_value_t = 0)]
        start: u32,
        #[arg(long, default_value_t = 200)]
        limit: u32,
    },
    /// Read a bounded byte range to stdout (binary). Useful for text and integration tests.
    Read {
        #[command(flatten)]
        volume: VolumeArgs,
        path: String,
        #[arg(long, default_value_t = 0)]
        offset: u64,
        #[arg(long, default_value_t = 65536)]
        length: usize,
    },
    /// Stream a file to a new destination; refuses to overwrite existing files.
    Export {
        #[command(flatten)]
        volume: VolumeArgs,
        path: String,
        output: PathBuf,
    },
    /// Hash one file without creating a plaintext copy.
    Hash {
        #[command(flatten)]
        volume: VolumeArgs,
        path: String,
    },
}
#[derive(Args)]
struct VolumeArgs {
    image: PathBuf,
    #[arg(long, default_value_t = 1)]
    partition: u32,
    /// UTF-8 password file; only a final CRLF/LF is removed. Never pass passwords on the command line.
    #[arg(long, conflicts_with = "recovery_key_file")]
    password_file: Option<PathBuf>,
    /// Windows recovery-key TXT (UTF-8/UTF-16) or a file containing only the 48-digit recovery password.
    #[arg(long, conflicts_with = "password_file")]
    recovery_key_file: Option<PathBuf>,
    #[arg(long,default_value_t=16,value_parser=clap::value_parser!(u16).range(1..=256))]
    cache_mib: u16,
}
fn credential(args: &VolumeArgs) -> Result<Option<Credential>> {
    if let Some(path) = &args.password_file {
        Ok(Some(vhdx_core::credentials::from_file(path, false)?))
    } else if let Some(path) = &args.recovery_key_file {
        Ok(Some(vhdx_core::credentials::from_file(path, true)?))
    } else {
        Ok(None)
    }
}

fn open(runtime: Rc<Runtime>, args: &VolumeArgs) -> Result<vhdx_core::session::Volume> {
    let credential = credential(args)?;
    let image = Image::open(runtime, &args.image)?;
    let volume = image.unlock(
        args.partition,
        credential.as_ref(),
        args.cache_mib as usize * 1024 * 1024,
    )?;
    Ok(volume)
}
fn native_directory(explicit: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(p) = explicit.or_else(|| std::env::var_os("VHDX_NATIVE_DIR").map(PathBuf::from)) {
        return Ok(p);
    }
    let exe = std::env::current_exe()?;
    let sibling = exe.parent().unwrap_or(Path::new(".")).join("native");
    if sibling.is_dir() {
        return Ok(sibling);
    }
    Err(Error::Invalid("set VHDX_NATIVE_DIR or pass --native-dir (directory with libbfio/libvhdi/libbde/libfsntfs)".into()))
}
fn run() -> Result<()> {
    let cli = Cli::parse();
    let runtime = Runtime::load(&native_directory(cli.native_dir)?)?;
    let cancel = Cancellation::default();
    match cli.command {
        Command::Doctor => println!(
            "{}",
            serde_json::to_string_pretty(&runtime.versions()?).unwrap()
        ),
        Command::Inspect { image } => println!(
            "{}",
            serde_json::to_string_pretty(&Image::open(runtime, &image)?.info).unwrap()
        ),
        Command::Ls {
            volume,
            path,
            start,
            limit,
        } => println!(
            "{}",
            serde_json::to_string_pretty(
                &open(runtime, &volume)?.list(&path, start, limit, &cancel)?
            )
            .unwrap()
        ),
        Command::Read {
            volume,
            path,
            offset,
            length,
        } => {
            if length > 4 * 1024 * 1024 {
                return Err(Error::Invalid("read length must be at most 4 MiB".into()));
            }
            let file = open(runtime, &volume)?.open_file(&path)?;
            let mut bytes = Zeroizing::new(vec![0; length]);
            let mut done = 0;
            while done < length {
                let n = file.read_at(
                    offset
                        .checked_add(done as u64)
                        .ok_or_else(|| Error::Invalid("offset overflow".into()))?,
                    &mut bytes[done..],
                    &cancel,
                )?;
                if n == 0 {
                    break;
                }
                done += n;
            }
            std::io::stdout().lock().write_all(&bytes[..done])?;
        }
        Command::Export {
            volume,
            path,
            output,
        } => {
            let file = open(runtime, &volume)?.open_file(&path)?;
            let mut destination = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&output)?;
            match stream(&file, Some(&mut destination), &cancel) {
                Ok(hash) => {
                    destination.sync_all()?;
                    println!("{hash}");
                }
                Err(e) => {
                    drop(destination);
                    let _ = std::fs::remove_file(&output);
                    return Err(e);
                }
            }
        }
        Command::Hash { volume, path } => {
            let file = open(runtime, &volume)?.open_file(&path)?;
            println!("{}", stream(&file, None, &cancel)?);
        }
    }
    Ok(())
}
fn stream(
    file: &vhdx_core::session::File,
    mut output: Option<&mut std::fs::File>,
    cancel: &Cancellation,
) -> Result<String> {
    let mut bytes = Zeroizing::new(vec![0; 1024 * 1024]);
    let mut offset = 0;
    let mut digest = Sha256::new();
    while offset < file.len() {
        let n = file.read_at(offset, &mut bytes, cancel)?;
        if n == 0 {
            return Err(Error::Invalid(
                "file data ended before declared size".into(),
            ));
        }
        if let Some(out) = output.as_deref_mut() {
            out.write_all(&bytes[..n])?;
        }
        digest.update(&bytes[..n]);
        offset += n as u64;
    }
    Ok(format!("{:x}", digest.finalize()))
}
fn main() {
    if let Err(e) = run() {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}
