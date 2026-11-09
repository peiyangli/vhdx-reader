#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Run this script on macOS.' >&2; exit 1; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"
export PUB_CACHE="$repo_root/.tools/pub-cache-macos"
flutter="${FLUTTER:-$repo_root/.tools/flutter-macos/bin/flutter}"
app="$repo_root/app/build/macos/Build/Products/Release/VHDX Reader.app"
container="$HOME/Library/Containers/org.vhdxreader.reader/Data"
[[ -d "$app" ]] || { echo 'Build the release app first.' >&2; exit 1; }
launch_pid=''
fixtures=''
cleanup() {
    if [[ -n "$fixtures" && -d "$fixtures" ]]; then
        mkdir -p "${VHDX_TEST_OUTPUT:-$repo_root/.native/macos-validation}"
        for png in "$fixtures/"*.png; do
            [[ ! -f "$png" ]] || cp "$png" "${VHDX_TEST_OUTPUT:-$repo_root/.native/macos-validation}/"
        done
    fi
    if [[ -n "$launch_pid" ]]; then kill "$launch_pid" 2>/dev/null || true; fi
    if [[ -n "$fixtures" ]]; then rm -rf "$fixtures"; fi
}
trap cleanup EXIT
# Let macOS create the sandbox container normally, rather than modifying its metadata.
if [[ ! -d "$container" ]]; then
    "$app/Contents/MacOS/VHDX Reader" > "$repo_root/.native/macos-launch.log" 2>&1 &
    launch_pid=$!
    for ((i=0; i<100; i++)); do
        [[ -d "$container" ]] && break
        kill -0 "$launch_pid" 2>/dev/null || { cat "$repo_root/.native/macos-launch.log"; exit 1; }
        sleep 0.2
    done
    [[ -d "$container" ]] || { echo 'Sandbox container was not created.' >&2; exit 1; }
    kill "$launch_pid" 2>/dev/null || true
    wait "$launch_pid" 2>/dev/null || true
    launch_pid=''
fi
umask 077
fixtures="$(mktemp -d "$container/vhdx-test.XXXXXX")"
mkdir "$fixtures/examples"
cp "$repo_root/examples/basicvhdx.vhdx" "$repo_root/examples/bitlockervhdx.vhdx" "$repo_root/examples/password.txt" "$fixtures/examples/"
cp "$repo_root/.native/pdf-fixture/pdf-preview.vhdx" "$repo_root/.native/media-fixture/media-preview.vhdx" "$fixtures/"
export VHDX_SAMPLE_DIR="$fixtures/examples"
export VHDX_PDF_FIXTURE="$fixtures/pdf-preview.vhdx"
export VHDX_MEDIA_FIXTURE="$fixtures/media-preview.vhdx"
export VHDX_SCREENSHOT="$fixtures/native.png"
export VHDX_PDF_SCREENSHOT="$fixtures/pdf.png"
export VHDX_MEDIA_SCREENSHOT="$fixtures/video.png"
# The app must exercise its bundled libraries, not an unsandboxed build directory.
unset VHDX_NATIVE_DIR
cd "$repo_root/app"
if [[ "${VHDX_SKIP_WIDGET_TESTS:-0}" != 1 ]]; then "$flutter" test; fi
"$flutter" test "${VHDX_TEST_TARGET:-integration_test/macos_test.dart}" -d macos
