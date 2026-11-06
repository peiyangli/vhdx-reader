#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Run on macOS with Xcode.' >&2; exit 1; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
artifact_dir="${VHDX_ARTIFACT_DIR:-$repo_root/artifacts}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"
export PUB_CACHE="$repo_root/.tools/pub-cache-macos"
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.96.1}"
export CARGO_PROFILE_RELEASE_STRIP=none
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none
export CARGO_TARGET_DIR="$repo_root/target/ios"
export IPHONEOS_DEPLOYMENT_TARGET=15.0
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-headerpad_max_install_names"
FLUTTER="${FLUTTER:-$repo_root/.tools/flutter-macos/bin/flutter}"
if [[ "${1:-}" != --skip-native ]]; then bash "$repo_root/scripts/build-native-ios.sh"; fi
rustup target add --toolchain "$RUSTUP_TOOLCHAIN" aarch64-apple-ios aarch64-apple-ios-sim
cd "$repo_root"
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  sdk=iphoneos
  [[ "$target" != aarch64-apple-ios-sim ]] || sdk=iphonesimulator
  SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" cargo build --locked --release -p vhdx-app --target "$target"
done
python3 scripts/package-native-ios.py
cd app
"$FLUTTER" pub get
python3 "$repo_root/scripts/prepare-apple-deps.py" --ios
"$FLUTTER" build ios --simulator --debug
python3 "$repo_root/scripts/verify-ios.py" build/ios/iphonesimulator/Runner.app IOSSIMULATOR
mkdir -p "$artifact_dir"
ditto -c -k --sequesterRsrc --keepParent build/ios/iphonesimulator/Runner.app "$artifact_dir/vhdx-reader-ios-simulator-arm64.zip"
# A real device build can be validated without an Apple account; installation needs signing.
"$FLUTTER" build ios --release --no-codesign
python3 "$repo_root/scripts/verify-ios.py" build/ios/iphoneos/Runner.app IOS
ditto -c -k --sequesterRsrc --keepParent build/ios/iphoneos/Runner.app "$artifact_dir/vhdx-reader-ios-device-arm64-unsigned.zip"

(cd "$artifact_dir" && shasum -a 256 vhdx-reader-ios-simulator-arm64.zip vhdx-reader-ios-device-arm64-unsigned.zip > vhdx-reader-ios.sha256)
