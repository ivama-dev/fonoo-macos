#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
DEVICE_CHECK_DIR="${FONOO_DEVICE_CHECK_DIR:-/private/tmp/FonooAudioDeviceChecks}"
mkdir -p "$DEVICE_CHECK_DIR/module-cache"
swiftc -D DEBUG -parse-as-library -module-cache-path "$DEVICE_CHECK_DIR/module-cache" \
  Shared/CallSession.swift Shared/SIPAccount.swift Shared/SIPCore.swift \
  Shared/Diagnostics.swift Shared/IncomingCallCoordinator.swift Shared/CallManager.swift \
  macos/FonooMac/MacAudioManager.swift macos/FonooMac/MacCallActivity.swift macos/Checks/AudioDeviceChecks.swift \
  -o "$DEVICE_CHECK_DIR/AudioDeviceChecks"
"$DEVICE_CHECK_DIR/AudioDeviceChecks"
