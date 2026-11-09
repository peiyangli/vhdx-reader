#!/usr/bin/env bash
# Run from MSYS2 bash (Windows NDK) or Linux (Linux NDK). Originals remain untouched.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ndk_root="${VHDX_ANDROID_NDK:?Set VHDX_ANDROID_NDK to the NDK directory}"
host_tag="${VHDX_NDK_HOST:-windows-x86_64}"
toolchain="$ndk_root/toolchains/llvm/prebuilt/$host_tag/bin"
export PATH="$repo_root/.tools/msys-make/usr/bin:$repo_root/.tools/msys-pkgconf/usr/bin:$toolchain:$PATH"
export CC="clang --target=aarch64-linux-android24"
export CXX="clang++ --target=aarch64-linux-android24"
export AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip NM=llvm-nm
export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"
export LDFLAGS="-Wl,-z,max-page-size=16384"
export PKG_CONFIG=pkg-config
bash "$repo_root/scripts/build-openssl.sh" android-arm64
prefix="$repo_root/.native/android/arm64-v8a"
build="$repo_root/.native/build-android/arm64-v8a"
mkdir -p "$prefix" "$build"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
# The caller verifies native-sources.json archives before invoking this script.
for spec in libbfio:20260623 libvhdi:20260901 libbde:20260916 libfsntfs:20260827; do
    name="${spec%:*}"; version="${spec#*:}"
    if [[ -f "$prefix/$name.complete" && "$name" != libbde ]]; then continue; fi
    if [[ "$name" == libbde && -f "$build/$name/Makefile" ]]; then (cd "$build/$name" && make clean > clean.log 2>&1); fi
    if [[ ! -f "$build/$name/configure" ]]; then
        cp -a "$repo_root/.native/src/$name-$version/." "$build/$name/"
    fi
    (
        cd "$build/$name"
        extra=(--disable-nls)
        crypto=no
        [[ "$name" != libbde ]] || crypto="$repo_root/.native/install-openssl-android-arm64"
        if [[ "$name" != libbfio ]]; then extra+=("--with-libbfio=$prefix"); fi
        # configure cannot run its XTS probe on a cross target. This pinned
        # OpenSSL backend is checked by the target crypto regression tool.
        if [[ "$name" == libbde ]]; then export ac_cv_openssl_xts_duplicate_keys=yes; fi
        ./configure --host=aarch64-linux-android \
            --prefix="$prefix" --disable-static --enable-shared --disable-nls \
            --disable-python --with-pthread=no --with-openssl="$crypto" "${extra[@]}" > configure.log 2>&1
        # Android resolves packaged libraries by SONAME; never embed host build paths.
        sed -i -e 's/^hardcode_libdir_flag_spec=.*/hardcode_libdir_flag_spec=""/' -e 's/^runpath_var=.*/runpath_var=/' libtool
        make -j"${VHDX_BUILD_JOBS:-8}" PTHREAD_LIBADD= > build.log 2>&1
        make install PTHREAD_LIBADD= > install.log 2>&1
    )
    if [[ "$name" == libbde ]]; then bash "$repo_root/scripts/record-native-crypto.sh" "$build/$name/common/config.h" "$prefix" android-arm64; fi
    touch "$prefix/$name.complete"
    echo "Built Android ARM64 $name $version"
done
