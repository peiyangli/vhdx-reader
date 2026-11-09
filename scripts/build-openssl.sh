#!/usr/bin/env bash
# Pinned, static libcrypto for native readers. No system installation or dynamic OpenSSL dependency.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
platform="${1:?Expected macos-arm64, macos-x86_64, iphoneos-arm64, iphonesimulator-arm64, android-arm64 or linux-x86_64}"
read -r version sha url < <(perl -MJSON::PP -0777 -ne 'my $m=decode_json($_); print "$m->{version} $m->{sha256} $m->{url}\n"' "$repo_root/scripts/openssl-source.json")
archive="$repo_root/.native/downloads/openssl-$version.tar.gz"
source="$repo_root/.native/src/openssl-$version"
build="$repo_root/.native/build-openssl-$platform"
prefix="$repo_root/.native/install-openssl-$platform"
mkdir -p "$build" "$prefix" "$repo_root/.native/downloads" "$repo_root/.native/src"
if [[ ! -f "$archive" ]]; then
  [[ "${VHDX_OFFLINE:-0}" != 1 ]] || { echo 'Missing pinned OpenSSL archive' >&2; exit 1; }
  curl -fL "$url" -o "$archive.part"
  mv "$archive.part" "$archive"
fi
actual="$(perl -MDigest::SHA -e 'open my $f,"<",$ARGV[0] or die $!; binmode $f; print Digest::SHA->new(256)->addfile($f)->hexdigest' "$archive")"
[[ "$actual" == "$sha" ]] || { echo 'OpenSSL checksum mismatch' >&2; exit 1; }
[[ -d "$source" ]] || tar -xf "$archive" -C "$repo_root/.native/src"
unset CC CXX AR RANLIB NM STRIP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
export CFLAGS='-O2 -fPIC'
extra=(no-shared no-tests no-apps "--prefix=$prefix" --libdir=lib)
case "$platform" in
  macos-*)
    arch="${platform#macos-}"; target="darwin64-$arch-cc"
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" MACOSX_DEPLOYMENT_TARGET=12.0
    export CC="$(xcrun --sdk macosx --find clang)"
    extra+=(-mmacosx-version-min=12.0)
    toolchain_id="$(xcrun --sdk macosx --show-sdk-version)";;
  iphoneos-arm64|iphonesimulator-arm64)
    sdk="${platform%-arm64}"
    export SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)"
    unset MACOSX_DEPLOYMENT_TARGET
    if [[ "$sdk" == iphonesimulator ]]; then
      target=iossimulator-arm64-xcrun; extra+=(-mios-simulator-version-min=15.0)
    else
      target=ios64-xcrun; extra+=(-miphoneos-version-min=15.0)
    fi
    toolchain_id="$(xcrun --sdk "$sdk" --show-sdk-version)";;
  android-arm64)
    export ANDROID_NDK_ROOT="${VHDX_ANDROID_NDK:?Set VHDX_ANDROID_NDK}"
    export PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/${VHDX_NDK_HOST:-windows-x86_64}/bin:$PATH"
    export CC=clang AR=llvm-ar RANLIB=llvm-ranlib
    target=android-arm64; extra+=(-D__ANDROID_API__=24)
    toolchain_id="$(cat "$ANDROID_NDK_ROOT/source.properties")";;
  linux-x86_64)
    target=linux-x86_64; export CC=gcc; toolchain_id="$(gcc -dumpfullversion)";;
  *) echo "Unsupported OpenSSL platform: $platform" >&2; exit 1;;
esac
identity="$sha $platform $target ${extra[*]} $toolchain_id v1"
if [[ -f "$build/verified-build.txt" && -f "$prefix/lib/libcrypto.a" && -f "$prefix/include/openssl/evp.h" && "$(cat "$build/verified-build.txt")" == "$identity" ]]; then
  echo "Verified cached OpenSSL $version $platform"; exit 0
fi
(
  cd "$build"
  if [[ -f Makefile ]]; then make clean > clean.log 2>&1; fi
  perl "$source/Configure" "$target" "${extra[@]}" > configure.log 2>&1
  make -j"${VHDX_BUILD_JOBS:-6}" build_libs > build.log 2>&1
  make install_sw > install.log 2>&1
)
printf '%s\n' "$identity" > "$build/verified-build.txt"
echo "Built static OpenSSL $version $platform"
