#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Run on macOS with Xcode.' >&2; exit 1; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$repo_root/scripts/prepare-native.py"
for sdk in iphoneos iphonesimulator; do
  bash "$repo_root/scripts/build-openssl.sh" "$sdk-arm64"
  prefix="$repo_root/.native/install-$sdk-arm64"
  build_root="$repo_root/.native/build-$sdk-arm64"
  export SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)"
  triple=arm64-apple-ios15.0
  [[ "$sdk" != iphonesimulator ]] || triple=arm64-apple-ios15.0-simulator
  export CC="$(xcrun --sdk "$sdk" --find clang)"
  export CFLAGS="-O2 -fPIC -target $triple -isysroot $SDKROOT"
  export LDFLAGS="-target $triple -isysroot $SDKROOT -Wl,-headerpad_max_install_names"
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  unset PKG_CONFIG_PATH MACOSX_DEPLOYMENT_TARGET
  mkdir -p "$prefix" "$build_root"
  while read -r name version; do
    [[ -d "$build_root/$name" ]] || cp -R "$repo_root/.native/src/$name-$version" "$build_root/$name"
    (
      cd "$build_root/$name"
      extra=(--disable-nls)
      crypto=no
      [[ "$name" != libbde ]] || crypto="$repo_root/.native/install-openssl-$sdk-arm64"
      [[ "$name" == libbfio ]] || extra+=("--with-libbfio=$prefix")
      # configure cannot run its XTS probe on a cross target. This pinned
      # OpenSSL backend is checked by the target crypto regression tool.
      if [[ "$name" == libbde ]]; then export ac_cv_openssl_xts_duplicate_keys=yes; fi
      ./configure --host=aarch64-apple-darwin --prefix="$prefix" \
        --disable-static --enable-shared --disable-python --with-pthread=no --with-openssl="$crypto" \
        "${extra[@]}" > configure.log 2>&1
      # Only the libraries and headers: never cross-build upstream CLI tools/tests.
      subdirs="$(python3 - "$name" <<'PY'
import pathlib, re, sys
text = pathlib.Path('Makefile.am').read_text()
section = re.search(r'SUBDIRS\s*=\s*(.*?)(?:\n\s*\n)', text, re.S).group(1)
print(' '.join(p for p in section.replace('\\', '').split() if p in ('common', 'include') or p.startswith('lib')))
PY
)"
      make -j"${VHDX_BUILD_JOBS:-4}" SUBDIRS="$subdirs" > build.log 2>&1
      make SUBDIRS="$subdirs" install > install.log 2>&1
    )
    if [[ "$name" == libbde ]]; then bash "$repo_root/scripts/record-native-crypto.sh" "$build_root/$name/common/config.h" "$prefix" "$sdk-arm64"; fi
    echo "Built $sdk arm64 $name"
  done < <(python3 - "$repo_root/scripts/native-sources.json" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1])): print(item['name'], item['version'])
PY
)
done
