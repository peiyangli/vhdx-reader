#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$repo_root/scripts/prepare-native.py"
build_root="${VHDX_BUILD_ROOT:-$repo_root/.native/build-linux}"
prefix="${VHDX_PREFIX:-$repo_root/.native/install-linux}"
mkdir -p "$build_root" "$prefix"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
while read -r name version; do
    if [[ ! -d "$build_root/$name" ]]; then
        cp -a "$repo_root/.native/src/$name-$version" "$build_root/$name"
    fi
    (
        cd "$build_root/$name"
        extra=()
        if [[ "$name" != libbfio ]]; then extra+=("--with-libbfio=$prefix"); fi
        ./configure --prefix="$prefix" --disable-static --enable-shared "${extra[@]}" > configure.log 2>&1
        make -j"${VHDX_BUILD_JOBS:-4}" > build.log 2>&1
        make install > install.log 2>&1
    )
    echo "Built $name $version"
done < <(python3 -c 'import json,sys; [print(x["name"],x["version"]) for x in json.load(open(sys.argv[1]))]' "$repo_root/scripts/native-sources.json")
echo "Native library directory: $prefix/lib"
