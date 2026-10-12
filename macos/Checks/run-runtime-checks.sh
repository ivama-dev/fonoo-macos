#!/bin/bash
set -euo pipefail
MAC_BUILD_DIR="${FONU_MAC_BUILD_DIR:-/private/tmp/fonuMacNativeBuild}"
APP="$MAC_BUILD_DIR/Build/Products/Debug/fonu.app"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/fonu" --check-telephony
"$APP/Contents/MacOS/fonu" --check-sip-lifecycle
"$APP/Contents/MacOS/fonu" --check-authentication
