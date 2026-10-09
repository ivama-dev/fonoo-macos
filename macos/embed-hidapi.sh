#!/bin/bash
set -euo pipefail
MAC_HID_SOURCE="$SRCROOT/Vendor/hidapi"
MAC_HID_OUTPUT="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libhidapi.0.dylib"
MAC_HID_FLAGS=()
for architecture in $ARCHS; do MAC_HID_FLAGS+=(-arch "$architecture"); done
mkdir -p "$(dirname "$MAC_HID_OUTPUT")"
xcrun clang -dynamiclib -O2 "${MAC_HID_FLAGS[@]}" -isysroot "$SDKROOT" \
  -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
  -I "$MAC_HID_SOURCE/hidapi" -I "$MAC_HID_SOURCE/mac" \
  "$MAC_HID_SOURCE/mac/hid.c" -framework IOKit -framework CoreFoundation \
  -install_name '@rpath/libhidapi.0.dylib' -compatibility_version 0.0.0 -current_version 0.15.0 \
  -o "$MAC_HID_OUTPUT"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$MAC_HID_OUTPUT"
fi
mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
cp "$MAC_HID_SOURCE/LICENSE-bsd.txt" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/HIDAPI-LICENSE.txt"
