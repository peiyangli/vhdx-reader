#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Run this script on macOS.' >&2; exit 1; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="$repo_root/.tools/flutter-macos"
arch="$(uname -m)"
case "$arch" in arm64) sdk_arch=arm64 ;; x86_64) sdk_arch=x64 ;; *) exit 1 ;; esac
read -r url sha < <(python3 - "$repo_root/scripts/flutter-sdk-macos.json" "$sdk_arch" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
item = next(x for x in manifest['archives'] if x['dart_sdk_arch'] == sys.argv[2])
print(manifest['base_url'].rstrip('/') + '/' + item['archive'], item['sha256'])
PY
)
if [[ -x "$sdk/bin/flutter" ]]; then
    [[ -f "$sdk/.vhdx-sdk-sha256" && "$(cat "$sdk/.vhdx-sdk-sha256")" == "$sha" ]] || {
        echo "Existing SDK is not the pinned installation: $sdk" >&2; exit 1;
    }
    exit 0
fi
mkdir -p "$repo_root/.native/downloads" "$repo_root/.tools"
archive="$repo_root/.native/downloads/flutter-macos-$sdk_arch-3.47.9.zip"
if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 3 "$url" -o "$archive.part"
    mv "$archive.part" "$archive"
fi
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$sha" ]] || {
    echo 'Flutter archive checksum mismatch' >&2; exit 1;
}
temporary="$(mktemp -d "$repo_root/.tools/flutter-extract.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
ditto -x -k "$archive" "$temporary"
mv "$temporary/flutter" "$sdk"
printf '%s\n' "$sha" > "$sdk/.vhdx-sdk-sha256"
echo "Installed pinned Flutter SDK: $sdk"
