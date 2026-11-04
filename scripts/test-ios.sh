#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Run on macOS with Xcode.' >&2; exit 1; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"
export PUB_CACHE="$repo_root/.tools/pub-cache-macos"
FLUTTER="${FLUTTER:-$repo_root/.tools/flutter-macos/bin/flutter}"
cd "$repo_root/app"
"$FLUTTER" build ios --simulator --debug
mkdir -p "$repo_root/artifacts/ios-validation"
runtime="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and r["name"].startswith("iOS")]; print(sorted(r,key=lambda x:tuple(map(int,x["version"].split("."))))[-1]["identifier"])')"
device=''
cleanup() {
  if [[ -n "$device" && "${VHDX_KEEP_TEST_SIMULATORS:-0}" == 1 ]]; then
    echo "Retained test simulator: $device"
    return
  fi
  if [[ -n "$device" ]]; then
    xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
    xcrun simctl delete "$device" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
for family in ${VHDX_TEST_FAMILIES:-iPhone iPad}; do
  device_type="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; runtime,family=sys.argv[1:]; r=next(r for r in json.load(sys.stdin)["runtimes"] if r["identifier"]==runtime); print(next(d["identifier"] for d in r["supportedDeviceTypes"] if d["name"].startswith(family)))' "$runtime" "$family")"
  device="$(xcrun simctl create "VHDX Reader $family Validation" "$device_type" "$runtime")"
  xcrun simctl boot "$device"
  xcrun simctl bootstatus "$device" -b
  bash "$repo_root/scripts/run-ios-integration.sh" "$device" "$family"
  "$FLUTTER" build ios --simulator --debug
  xcodebuild -quiet test -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
    -destination "id=$device" -only-testing:RunnerTests CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- BUILD_DIR="$PWD/build/ios"
  cleanup
  device=''
done
