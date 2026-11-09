#!/usr/bin/env bash
# Build/verify native libraries with build-native.sh before running this packager.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -m)" == x86_64 ]] || { echo 'This package targets Linux x64.' >&2; exit 1; }
version="$(sed -n 's/^version: \([^+]*\).*/\1/p' "$repo_root/app/pubspec.yaml")"
prefix="${VHDX_PREFIX:-$repo_root/.native/install-linux}"
output="${1:-$repo_root/artifacts/$version}"
name="vhdx-reader-$version-linux-x64-cli"
stage="$repo_root/.native/release-$version/$name"
mkdir -p "$stage/native" "$stage/licenses" "$output"
cd "$repo_root"
cargo build --release --locked --offline -p vhdx-cli
cp "$repo_root/target/release/vhdx" "$stage/vhdx"
for lib in libbfio libvhdi libbde libfsntfs; do
  cp -L "$prefix/lib/$lib.so" "$stage/native/$lib.so"
  soname="$(readelf -d "$prefix/lib/$lib.so" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
  [[ -z "$soname" || "$soname" == "$lib.so" ]] || ln -sf "$lib.so" "$stage/native/$soname"
done
cat > "$stage/vhdx-reader" <<'LAUNCH'
#!/bin/sh
reader_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LD_LIBRARY_PATH="$reader_dir/native${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$reader_dir/vhdx" --native-dir "$reader_dir/native" "$@"
LAUNCH
chmod +x "$stage/vhdx-reader"
python3 - "$repo_root" "$stage" <<'LICENSES'
import json,pathlib,shutil,sys
root,stage=map(pathlib.Path,sys.argv[1:])
for item in json.loads((root/'scripts/native-sources.json').read_text()):
 source=root/'.native/src'/f'{item["name"]}-{item["version"]}'
 dest=stage/'licenses'/item['name']; dest.mkdir(exist_ok=True)
 for f in [*source.glob('COPYING*'),source/'AUTHORS']: shutil.copyfile(f,dest/f.name)
for name in ['README.md','THIRD_PARTY.md','LICENSE']: shutil.copyfile(root/name,stage/name)
shutil.copyfile(root/'scripts/native-sources.json',stage/'licenses/native-sources.json')
shutil.copytree(root/'third_party/rust',stage/'licenses/rust',dirs_exist_ok=True)
LICENSES
python3 scripts/stage-openssl-license.py "$stage/licenses" "$prefix"
"$stage/vhdx-reader" doctor
# The wrapper and sibling SONAME links resolve transitive libraries after moving the directory.
LD_LIBRARY_PATH="$stage/native" ldd "$stage/native/libbde.so" > "$stage/licenses/linux-runtime.txt"
if grep -Eq 'not found|libcrypto|libssl' "$stage/licenses/linux-runtime.txt"; then echo 'Unexpected crypto/runtime dependency' >&2; exit 1; fi
# Runtime inventory must not expose the local checkout path.
sed -i "s|$stage/native/|native/|g" "$stage/licenses/linux-runtime.txt"
tar -czf "$output/$name.tar.gz" -C "$(dirname "$stage")" "$name"
(cd "$output" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
echo "Linux CLI archive: $output/$name.tar.gz"
