#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Run this script on macOS.' >&2; exit 1; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
arch="$(uname -m)"
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported CPU: $arch" >&2; exit 1 ;; esac
python3 "$repo_root/scripts/prepare-native.py"
prefix="$repo_root/.native/install-macos-$arch"
build_root="$repo_root/.native/build-macos-$arch"
export MACOSX_DEPLOYMENT_TARGET=12.0
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun --find clang)"
export CFLAGS="-O2 -fPIC -arch $arch -mmacosx-version-min=12.0"
export LDFLAGS="-arch $arch -mmacosx-version-min=12.0 -Wl,-headerpad_max_install_names"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
unset PKG_CONFIG_PATH
mkdir -p "$prefix" "$build_root"
while read -r name version; do
    if [[ ! -d "$build_root/$name" ]]; then
        cp -R "$repo_root/.native/src/$name-$version" "$build_root/$name"
    fi
    (
        # Upstream archives contain generated Linux headers: configure in a build copy.
        cd "$build_root/$name"
        extra=(--disable-nls)
        if [[ "$name" != libbfio ]]; then extra+=("--with-libbfio=$prefix"); fi
        ./configure --prefix="$prefix" --disable-static --enable-shared \
            --disable-python --with-pthread=no --with-openssl=no "${extra[@]}" > configure.log 2>&1
        make -j"${VHDX_BUILD_JOBS:-4}" > build.log 2>&1
        make install > install.log 2>&1
    )
    echo "Built macOS $arch $name $version"
done < <(python3 - "$repo_root/scripts/native-sources.json" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1])):
    print(item['name'], item['version'])
PY
)
