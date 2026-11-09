#!/usr/bin/env bash
# Run the exact libcaes backend compiled for macOS or an already booted iOS simulator.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${1:?macosx or iphonesimulator}"; arch="$(uname -m)"
case "$sdk" in
 macosx) platform="macos-$arch"; triple="$arch-apple-macos12.0";;
 iphonesimulator) platform=iphonesimulator-arm64; triple=arm64-apple-ios15.0-simulator;;
 *) echo 'Unsupported test SDK' >&2; exit 1;;
esac
build="$repo_root/.native/build-$platform/libbde"
crypto="$repo_root/.native/install-openssl-$platform"
out="${VHDX_TEST_OUTPUT:-$repo_root/.native/crypto-tests}/$platform"
mkdir -p "$out"
"$(xcrun --sdk "$sdk" --find clang)" -O2 -target "$triple" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
  -DHAVE_CONFIG_H -DHAVE_LOCAL_LIBCAES -DHAVE_LOCAL_LIBCERROR \
  -I"$build/common" -I"$build/include" -I"$build/libcaes" -I"$build/libcerror" -I"$crypto/include" \
  "$repo_root/scripts/benchmarks/crypto.c" "$build/libcaes/libcaes_context.c" "$build/libcaes/libcaes_tweaked_context.c" \
  "$build/libcerror/libcerror_error.c" "$build/libcerror/libcerror_system.c" "$crypto/lib/libcrypto.a" -o "$out/crypto-test"
codesign --force --sign - --timestamp=none "$out/crypto-test"
if [[ "$sdk" == iphonesimulator ]]; then
  xcrun simctl spawn "${2:?simulator UUID}" "$out/crypto-test" "$out/vectors.bin" > "$out/sectors.csv"
else
  "$out/crypto-test" "$out/vectors.bin" > "$out/sectors.csv"
fi
echo "Passed $platform CBC/XTS and duplicate-key decrypt regression"
