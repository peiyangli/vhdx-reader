#!/usr/bin/env bash
# Isolated A/B build. Does not change the installed app or production native prefix.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Run on macOS.' >&2; exit 1; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"
# Match the production macOS build: avoid Rust 1.96 LINKEDIT stripping issues.
export CARGO_PROFILE_RELEASE_STRIP=none
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none
arch="$(uname -m)"
case "$arch" in arm64) openssl_target=darwin64-arm64-cc;; x86_64) openssl_target=darwin64-x86_64-cc;; *) exit 1;; esac
work="$repo_root/.native/crypto-benchmark-macos-$arch"
base="$repo_root/.native/install-macos-$arch"
image="${1:-$repo_root/examples/bitlockervhdx.vhdx}"
file="${2:-/video/avi.avi}"
export VHDX_BENCH_PASSWORD_FILE="${VHDX_BENCH_PASSWORD_FILE:-$repo_root/examples/password.txt}"
mkdir -p "$work/results"
if [[ "${VHDX_BENCH_SKIP_BUILD:-0}" != 1 ]]; then
python3 "$repo_root/scripts/prepare-native.py"
read -r openssl_version openssl_sha openssl_url < <(python3 - "$repo_root/scripts/openssl-source.json" <<'PYJSON'
import json,sys
m=json.load(open(sys.argv[1])); print(m['version'],m['sha256'],m['url'])
PYJSON
)
archive="$repo_root/.native/downloads/openssl-$openssl_version.tar.gz"
[[ -f "$archive" ]] || curl -fL "$openssl_url" -o "$archive"
echo "$openssl_sha  $archive" | shasum -a 256 -c -
source="$repo_root/.native/src/openssl-$openssl_version"
[[ -d "$source" ]] || tar -xf "$archive" -C "$repo_root/.native/src"
export MACOSX_DEPLOYMENT_TARGET=12.0
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun --find clang)"
export CFLAGS="-O2 -fPIC -arch $arch -mmacosx-version-min=12.0"
export LDFLAGS="-arch $arch -mmacosx-version-min=12.0 -Wl,-headerpad_max_install_names"
export PKG_CONFIG_LIBDIR="$base/lib/pkgconfig"
unset PKG_CONFIG_PATH
mkdir -p "$work/openssl-build"
(
  cd "$work/openssl-build"
  perl "$source/Configure" "$openssl_target" no-shared no-tests no-apps --prefix="$work/openssl-install" --libdir=lib > configure.log 2>&1
  make -j"${VHDX_BUILD_JOBS:-6}" build_libs > build.log 2>&1
  make install_sw > install.log 2>&1
)
bde_version="$(python3 -c 'import json,sys; print(next(x["version"] for x in json.load(open(sys.argv[1])) if x["name"]=="libbde"))' "$repo_root/scripts/native-sources.json")"
for backend in builtin openssl; do
  build="$work/build-$backend"
  [[ -d "$build" ]] || cp -R "$repo_root/.native/src/libbde-$bde_version" "$build"
  (
    cd "$build"
    crypto=no
    [[ "$backend" != openssl ]] || crypto="$work/openssl-install"
    ./configure --prefix="$work/install-$backend" --disable-static --enable-shared --disable-python \
      --with-pthread=no --disable-nls --with-libbfio="$base" --with-openssl="$crypto" > configure.log 2>&1
    if [[ "$backend" == openssl ]]; then
      # Reject silently falling back to built-in or legacy EVP padding behavior.
      for macro in HAVE_LIBCRYPTO HAVE_OPENSSL_EVP_H HAVE_EVP_CIPHERINIT_EX2 HAVE_EVP_CRYPTO_AES_CBC HAVE_EVP_CRYPTO_AES_ECB HAVE_EVP_CRYPTO_AES_XTS; do
        grep -q "^#define $macro 1$" common/config.h || { echo "Missing $macro" >&2; exit 1; }
      done
      if grep -q '^#define HAVE_OPENSSL_AES_H 1$' common/config.h; then echo 'Unexpected legacy AES backend' >&2; exit 1; fi
    else
      if grep -q '^#define HAVE_LIBCRYPTO 1$' common/config.h; then echo 'Baseline unexpectedly uses OpenSSL' >&2; exit 1; fi
    fi
    subdirs="$(python3 - <<'PYSUB'
import pathlib,re
text=pathlib.Path('Makefile.am').read_text()
section=re.search(r'SUBDIRS\s*=\s*(.*?)(?:\n\s*\n)',text,re.S).group(1)
print(' '.join(p for p in section.replace('\\','').split() if p in ('common','include') or p.startswith('lib')))
PYSUB
)"
    make -j"${VHDX_BUILD_JOBS:-6}" SUBDIRS="$subdirs" > build.log 2>&1
    make SUBDIRS="$subdirs" install > install.log 2>&1
  )
  native="$work/$backend"
  mkdir -p "$native"
  for name in libbfio libvhdi libfsntfs; do cp -L "$base/lib/$name.dylib" "$native/"; done
  cp -L "$work/install-$backend/lib/libbde.dylib" "$native/"
  # Make the staged set independent of build/install paths, then re-sign.
  python3 - "$native" <<'PYRELOC'
import pathlib,subprocess,sys
p=pathlib.Path(sys.argv[1]); names=['libbfio','libvhdi','libbde','libfsntfs']
for name in names:
 f=p/(name+'.dylib')
 subprocess.run(['install_name_tool','-id','@loader_path/'+f.name,str(f)],check=True)
 for line in subprocess.check_output(['otool','-L',str(f)],text=True).splitlines()[1:]:
  dep=line.strip().split(' (')[0]
  match=next((n for n in names if pathlib.Path(dep).name.startswith(n+'.')),None)
  if match and dep != '@loader_path/'+f.name:
   subprocess.run(['install_name_tool','-change',dep,'@loader_path/'+match+'.dylib',str(f)],check=True)
  elif not match and not dep.startswith(('/usr/lib/','/System/Library/')): raise SystemExit('Unbundled dependency: '+dep)
 subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(f)],check=True)
PYRELOC
  # Bash 3.2 treats an empty array as unset with set -u.
  extra=(-mmacosx-version-min=12.0)
  [[ "$backend" != openssl ]] || extra+=("-I$work/openssl-install/include" "$work/openssl-install/lib/libcrypto.a")
  "$CC" -O2 -DHAVE_CONFIG_H -DHAVE_LOCAL_LIBCAES -DHAVE_LOCAL_LIBCERROR \
    -I"$build/common" -I"$build/include" -I"$build/libcaes" -I"$build/libcerror" \
    "$repo_root/scripts/benchmarks/crypto.c" "$build/libcaes/libcaes_context.c" "$build/libcaes/libcaes_tweaked_context.c" \
    "$build/libcerror/libcerror_error.c" "$build/libcerror/libcerror_system.c" \
    "${extra[@]}" -o "$work/crypto-$backend"
done
fi
cd "$repo_root"
cargo build --release --locked --offline -p vhdx-core --example pipeline_benchmark
reader="$repo_root/target/release/examples/pipeline_benchmark"
export VHDX_BENCH_ROUNDS=1
# The first pass is warmup; reverse order each pass.
expected=''
for pass in 0 1 2 3 4 5; do
  order=(builtin openssl)
  (( pass % 2 )) || order=(openssl builtin)
  for backend in "${order[@]}"; do
    export VHDX_NATIVE_DIR="$work/$backend"
    for mode in ram file; do
      output="$work/results/$backend-$mode-$pass.csv"
      "$reader" "$image" "$file" "$mode" > "$output"
      hash="$(grep '^# sha256=' "$output")"
      [[ -n "$hash" ]] || exit 1
      [[ -n "$expected" ]] || expected="$hash"
      [[ "$hash" == "$expected" ]] || { echo 'Backend plaintext mismatch' >&2; exit 1; }
    done
  done
done
for backend in builtin openssl; do
  "$work/crypto-$backend" "$work/results/$backend-vectors.bin" > "$work/results/$backend-sectors.csv"
done
cmp "$work/results/builtin-vectors.bin" "$work/results/openssl-vectors.bin"
echo 'PASS: file hashes, random reads, CBC known answer, CBC/XTS roundtrips and ciphertext equivalence'
