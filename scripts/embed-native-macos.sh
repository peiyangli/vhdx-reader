#!/usr/bin/env bash
# Xcode build phase: copy before the containing app receives its code signature.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
arch="${VHDX_NATIVE_ARCH:-$(uname -m)}"
stage="$repo_root/.native/macos/$arch/bundle"
destination="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}/vhdx"
resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/licenses"
[[ -d "$stage" ]] || { echo 'Run scripts/build-macos.sh to prepare the native libraries first.' >&2; exit 1; }
mkdir -p "$destination" "$resources"
for name in libvhdx_app libbfio libvhdi libbde libfsntfs; do
    source="$stage/$name.dylib"
    [[ -f "$source" ]] || { echo "Missing library: $source" >&2; exit 1; }
    /usr/bin/lipo -verify_arch "$arch" "$source"
    cp -f "$source" "$destination/$name.dylib"
    if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$destination/$name.dylib"
    fi
done
ditto "$stage/licenses" "$resources"
