//! Private sample smoke tests. Opt in with VHDX_SAMPLE_DIR and VHDX_NATIVE_DIR.
//! Credentials and image bytes never appear in test output or source control.
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Output},
};

fn invoke(arguments: &[&str], success: bool) -> Output {
    let output = Command::new(env!("CARGO_BIN_EXE_vhdx"))
        .args(arguments)
        .output()
        .unwrap();
    assert_eq!(
        output.status.success(),
        success,
        "unexpected CLI status; stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    output
}
fn digest(path: &Path) -> String {
    let mut file = fs::File::open(path).unwrap();
    let mut hash = Sha256::new();
    let mut bytes = vec![0; 1024 * 1024];
    loop {
        let n = file.read(&mut bytes).unwrap();
        if n == 0 {
            break;
        }
        hash.update(&bytes[..n]);
    }
    format!("{:x}", hash.finalize())
}
#[test]
#[ignore = "requires private examples and native libraries"]
fn real_images_unlock_read_export_and_remain_unchanged() {
    let examples = PathBuf::from(std::env::var_os("VHDX_SAMPLE_DIR").expect("set VHDX_SAMPLE_DIR"));
    let keys = fs::read_dir(&examples)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| {
            p.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("BitLocker")
                && p.extension().is_some_and(|e| e.eq_ignore_ascii_case("txt"))
        })
        .collect::<Vec<_>>();
    assert_eq!(keys.len(), 1, "expected one recovery key file");
    let scratch = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../.native")
        .join(format!("sample-test-{}", std::process::id()));
    fs::create_dir(&scratch).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(scratch.clone());
    for (name, file, encrypted) in [
        ("basicvhdx.vhdx", "/can.txt", false),
        ("bitlockervhdx.vhdx", "/hello.txt", true),
    ] {
        let image = examples.join(name);
        let before = digest(&image);
        let image = image.to_str().unwrap();
        let info = invoke(&["inspect", image], true);
        let info: serde_json::Value = serde_json::from_slice(&info.stdout).unwrap();
        assert_eq!(info["virtual_size"], 134217728u64);
        let auth: Vec<&str> = if encrypted {
            vec!["--recovery-key-file", keys[0].to_str().unwrap()]
        } else {
            vec![]
        };
        let call = |args: Vec<&str>, success| {
            let mut all = args.into_iter().map(str::to_owned).collect::<Vec<_>>();
            all.extend(auth.iter().map(|s| (*s).to_owned()));
            invoke(&all.iter().map(String::as_str).collect::<Vec<_>>(), success)
        };
        let page = call(vec!["ls", image, "/", "--limit", "1"], true);
        let page: serde_json::Value = serde_json::from_slice(&page.stdout).unwrap();
        assert_eq!(page["entries"].as_array().unwrap().len(), 1);
        assert_eq!(page["next_index"], 1);
        let content = call(vec!["read", image, file], true).stdout;
        let expected = if encrypted {
            "486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7"
        } else {
            "d17db066fd31241f1d01b298db6e3e705e1f3b979251c599e27cb5f77d2fee3a"
        };
        assert_eq!(format!("{:x}", Sha256::digest(&content)), expected);
        let hash = call(vec!["hash", image, file], true);
        assert_eq!(String::from_utf8(hash.stdout).unwrap().trim(), expected);
        let exported = scratch.join(name.replace(".vhdx", ".txt"));
        call(
            vec!["export", image, file, exported.to_str().unwrap()],
            true,
        );
        assert_eq!(fs::read(&exported).unwrap(), content);
        call(
            vec!["export", image, file, exported.to_str().unwrap()],
            false,
        );
        assert_eq!(fs::read(&exported).unwrap(), content);
        let tail = call(
            vec!["read", image, file, "--offset", "2", "--length", "64"],
            true,
        );
        assert_eq!(tail.stdout, &content[2..]);
        let eof = call(vec!["read", image, file, "--offset", "999"], true);
        assert!(eof.stdout.is_empty());
        call(vec!["read", image, "/../can.txt"], false);
        call(vec!["read", image, "/file-that-does-not-exist"], false);
        // Nonresident 2 MiB NTFS data, across sector and 64 KiB cache boundaries.
        let large = call(
            vec!["read", image, "/$LogFile", "--length", "2097152"],
            true,
        )
        .stdout;
        assert_eq!(large.len(), 2097152);
        for offset in [0, 511, 4095, 65535, 1048573, 2097135] {
            let offset_string = offset.to_string();
            let chunk = call(
                vec![
                    "read",
                    image,
                    "/$LogFile",
                    "--offset",
                    &offset_string,
                    "--length",
                    "257",
                ],
                true,
            )
            .stdout;
            assert_eq!(chunk, &large[offset..(offset + 257).min(large.len())]);
        }
        if encrypted {
            let password = examples.join("password.txt");
            let by_password = invoke(
                &[
                    "read",
                    image,
                    file,
                    "--password-file",
                    password.to_str().unwrap(),
                ],
                true,
            );
            assert_eq!(
                by_password.stdout, content,
                "password and recovery key must read identical file bytes"
            );
            let by_password_hash = invoke(
                &[
                    "hash",
                    image,
                    file,
                    "--password-file",
                    password.to_str().unwrap(),
                ],
                true,
            );
            assert_eq!(
                String::from_utf8(by_password_hash.stdout).unwrap().trim(),
                expected
            );
            let locked = invoke(&["ls", image], false);
            assert!(String::from_utf8_lossy(&locked.stderr).contains("locked"));
            let wrong = scratch.join("wrong-password.txt");
            fs::write(&wrong, b"deliberately-wrong-credential").unwrap();
            let bad = invoke(
                &["ls", image, "--password-file", wrong.to_str().unwrap()],
                false,
            );
            assert!(String::from_utf8_lossy(&bad.stderr).contains("could not unlock"));
            assert!(!String::from_utf8_lossy(&bad.stderr).contains("deliberately-wrong-credential"));
        }
        assert_eq!(digest(Path::new(image)), before, "image bytes changed");
    }
}
