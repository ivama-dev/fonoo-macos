#!/bin/bash
set -euo pipefail
MAC_BUILD_DIR="${FONOO_MAC_BUILD_DIR:-/private/tmp/FonooMacNativeBuild}"
APP="$MAC_BUILD_DIR/Build/Products/Debug/fonoo.app"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/fonoo" --check-telephony
"$APP/Contents/MacOS/fonoo" --check-sip-lifecycle
"$APP/Contents/MacOS/fonoo" --check-authentication
