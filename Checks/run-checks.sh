#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
CHECK_BUILD_DIR="${FONOO_CHECK_BUILD_DIR:-build/checks}"
mkdir -p "$CHECK_BUILD_DIR/module-cache"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Shared/CallSession.swift Shared/SIPAccount.swift Shared/SIPCore.swift Shared/Diagnostics.swift \
  Shared/SIPConnectionCoordinator.swift Checks/SIPConnectionChecks.swift -o "$CHECK_BUILD_DIR/SIPConnectionChecks"
"$CHECK_BUILD_DIR/SIPConnectionChecks"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Shared/CallSession.swift Shared/SIPAccount.swift Shared/SIPCore.swift Shared/Diagnostics.swift \
  Shared/IncomingCallCoordinator.swift Shared/CallManager.swift Checks/CallFlowChecks.swift -o "$CHECK_BUILD_DIR/CallFlowChecks"
"$CHECK_BUILD_DIR/CallFlowChecks"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Shared/CallSession.swift Shared/DeviceContact.swift Checks/ContactSearchChecks.swift \
  -o "$CHECK_BUILD_DIR/ContactSearchChecks"
"$CHECK_BUILD_DIR/ContactSearchChecks"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Shared/SIPAccount.swift Checks/NATChecks.swift -o "$CHECK_BUILD_DIR/NATChecks"
"$CHECK_BUILD_DIR/NATChecks"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Shared/CallSession.swift Shared/SIPAccount.swift Shared/SIPCore.swift Shared/Diagnostics.swift \
  Shared/IncomingCallCoordinator.swift Checks/IncomingCallChecks.swift -o "$CHECK_BUILD_DIR/IncomingCallChecks"
"$CHECK_BUILD_DIR/IncomingCallChecks"
plutil -lint macos/FonooMac.xcodeproj/project.pbxproj

swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Shared/CallSession.swift Checks/CallHistoryChecks.swift -o "$CHECK_BUILD_DIR/CallHistoryChecks"
"$CHECK_BUILD_DIR/CallHistoryChecks"

swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Shared/CallSession.swift Checks/CloudHistoryChecks.swift -o "$CHECK_BUILD_DIR/CloudHistoryChecks"
"$CHECK_BUILD_DIR/CloudHistoryChecks"
python3 Checks/cloud-history-sync-checks.py

swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Shared/CallSession.swift Shared/SIPAccount.swift Shared/SystemCallActivity.swift \
  Checks/SystemCallActivityChecks.swift -o "$CHECK_BUILD_DIR/SystemCallActivityChecks"
"$CHECK_BUILD_DIR/SystemCallActivityChecks"

# Both apps compile these same models and presentation state.
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Shared/CallSession.swift Shared/TeamMember.swift Shared/TeamDirectory.swift \
  Checks/TeamDirectoryChecks.swift -o "$CHECK_BUILD_DIR/TeamDirectoryChecks"
"$CHECK_BUILD_DIR/TeamDirectoryChecks"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Shared/CallSession.swift Shared/TeamMember.swift Checks/DeviceProfileChecks.swift \
  -o "$CHECK_BUILD_DIR/DeviceProfileChecks"
"$CHECK_BUILD_DIR/DeviceProfileChecks"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Shared/CallSession.swift Shared/TeamMember.swift Shared/DeviceContact.swift Checks/TeamPresenceChecks.swift \
  -o "$CHECK_BUILD_DIR/TeamPresenceChecks"
"$CHECK_BUILD_DIR/TeamPresenceChecks"
