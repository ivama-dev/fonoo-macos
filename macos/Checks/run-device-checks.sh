#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
DEVICE_CHECK_DIR="${FONU_DEVICE_CHECK_DIR:-/private/tmp/fonuAudioDeviceChecks}"
mkdir -p "$DEVICE_CHECK_DIR/module-cache"
swiftc -D DEBUG -parse-as-library -module-cache-path "$DEVICE_CHECK_DIR/module-cache" \
  Shared/CallSession.swift Shared/SIPAccount.swift Shared/SIPCore.swift \
  Shared/Diagnostics.swift Shared/IncomingCallCoordinator.swift Shared/CallManager.swift \
  macos/fonuMac/MacAudioManager.swift macos/fonuMac/MacCallActivity.swift macos/Checks/AudioDeviceChecks.swift \
  -o "$DEVICE_CHECK_DIR/AudioDeviceChecks"
"$DEVICE_CHECK_DIR/AudioDeviceChecks"
