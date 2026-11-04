#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Run this script on the Mac.' >&2; exit 1; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=12.0
export PUB_CACHE="$repo_root/.tools/pub-cache-macos"
export COCOAPODS_DISABLE_STATS=true
# Rust 1.96 stripping produces misaligned LINKEDIT data rejected by macOS 27.
export CARGO_PROFILE_RELEASE_STRIP=none
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none
arch="$(uname -m)"
case "$arch" in arm64) rust_target=aarch64-apple-darwin ;; x86_64) rust_target=x86_64-apple-darwin ;; *) exit 1 ;; esac
mode=release
skip_native=false
for argument in "$@"; do
    case "$argument" in --debug) mode=debug ;; --skip-native) skip_native=true ;; *) echo "Unknown argument: $argument" >&2; exit 1 ;; esac
done
python3 -c 'import sys; assert sys.version_info >= (3, 12), "Python 3.12+ is required"'
xcodebuild -version
for tool in cargo pod pkg-config make; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
if [[ -z "${FLUTTER:-}" ]]; then
    bash "$repo_root/scripts/install-flutter-macos.sh"
    FLUTTER="$repo_root/.tools/flutter-macos/bin/flutter"
fi
if [[ "$skip_native" == false ]]; then bash "$repo_root/scripts/build-native-macos.sh"; fi
export CARGO_TARGET_DIR="$repo_root/target/macos-$arch"
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-headerpad_max_install_names"
cd "$repo_root"
cargo build --locked --release --target "$rust_target" -p vhdx-app -p vhdx-cli
stage="$repo_root/.native/macos/$arch/bundle"
mkdir -p "$stage/licenses"
cp "$CARGO_TARGET_DIR/$rust_target/release/libvhdx_app.dylib" "$stage/"
for name in libbfio libvhdi libbde libfsntfs; do
    cp -L "$repo_root/.native/install-macos-$arch/lib/$name.dylib" "$stage/$name.dylib"
done
python3 "$repo_root/scripts/relocate-macos.py" "$stage"
python3 - "$repo_root" "$stage/licenses" <<'PY'
import json, pathlib, shutil, sys
root, target = map(pathlib.Path, sys.argv[1:])
for item in json.loads((root / 'scripts/native-sources.json').read_text()):
    source = root / '.native/src' / (item['name'] + '-' + item['version'])
    destination = target / item['name']
    destination.mkdir(parents=True, exist_ok=True)
    for file in [*source.glob('COPYING*'), source / 'AUTHORS']:
        shutil.copyfile(file, destination / file.name)
for name in ['LICENSE', 'THIRD_PARTY.md', 'scripts/native-sources.json', 'scripts/apple-dependencies.json']:
    source = root / name
    shutil.copyfile(source, target / source.name)
PY
printf "ARCHS = %s\nVHDX_NATIVE_ARCH = %s\n" "$arch" "$arch" > "$repo_root/app/macos/Runner/Configs/NativeBuild.xcconfig"
cd "$repo_root/app"
"$FLUTTER" pub get
python3 "$repo_root/scripts/prepare-apple-deps.py"
"$FLUTTER" build macos "--$mode"
configuration=Release
if [[ "$mode" == debug ]]; then configuration=Debug; fi
application="$repo_root/app/build/macos/Build/Products/$configuration/VHDX Reader.app"
python3 "$repo_root/scripts/verify-macos.py" "$application" "$arch"
mkdir -p "$repo_root/artifacts"
archive="$repo_root/artifacts/vhdx-reader-macos-$arch-$mode.zip"
ditto -c -k --sequesterRsrc --keepParent "$application" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
echo "macOS app (development signing): $application"
echo "Portable archive: $archive"
