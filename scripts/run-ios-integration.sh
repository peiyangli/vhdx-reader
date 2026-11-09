#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
device="${1:?Provide a test simulator UUID}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"
export PUB_CACHE="$repo_root/.tools/pub-cache-macos"
FLUTTER="${FLUTTER:-$repo_root/.tools/flutter-macos/bin/flutter}"
label="${2:-iPhone}"
cd "$repo_root/app"
xcrun simctl install "$device" build/ios/iphonesimulator/Runner.app
container="$(xcrun simctl get_app_container "$device" org.vhdxreader.reader data)"
fixtures="$container/Documents/vhdx-validation"
mkdir -p "$fixtures"
chmod 700 "$fixtures"
cp "$repo_root/examples/basicvhdx.vhdx" "$repo_root/examples/bitlockervhdx.vhdx" "$repo_root/examples/password.txt" "$fixtures/"
cp "$repo_root/.native/pdf-fixture/pdf-preview.vhdx" "$repo_root/.native/media-fixture/media-preview.vhdx" "$fixtures/"
chmod 600 "$fixtures/"*
rm -f "$fixtures/.complete" "$fixtures/.copied"
"$FLUTTER" test integration_test/ios_test.dart -d "$device" --dart-define=VHDX_COLLECT_SCREENSHOTS=true &
test_pid=$!
# Flutter uninstalls the test app at exit. Copy screenshots while tearDownAll waits.
while kill -0 "$test_pid" 2>/dev/null; do
  container="$(xcrun simctl get_app_container "$device" org.vhdxreader.reader data 2>/dev/null || true)"
  fixtures="$container/Documents/vhdx-validation"
  if [[ -n "$container" && -f "$fixtures/.complete" ]]; then
    destination="${VHDX_TEST_OUTPUT:-$repo_root/.native/ios-validation}/$label"
    mkdir -p "$destination"
    for png in "$fixtures/"*.png; do
      [[ ! -f "$png" ]] || cp "$png" "$destination/"
    done
    touch "$fixtures/.copied"
    break
  fi
  sleep 1
done
wait "$test_pid"
