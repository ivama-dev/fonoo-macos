#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
MENU_BAR_CHECK_DIR="${FONU_MENU_BAR_CHECK_DIR:-/private/tmp/fonuMenuBarChecks}"
mkdir -p "$MENU_BAR_CHECK_DIR/module-cache"
swiftc -parse-as-library -module-cache-path "$MENU_BAR_CHECK_DIR/module-cache" \
  macos/fonuMac/MacMenuBarPlacement.swift macos/Checks/MenuBarPlacementChecks.swift \
  -o "$MENU_BAR_CHECK_DIR/MenuBarPlacementChecks"
"$MENU_BAR_CHECK_DIR/MenuBarPlacementChecks"
