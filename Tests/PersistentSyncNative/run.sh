#!/bin/zsh
set -euo pipefail

# Compile production state machines and their XCTest cases without an app or Bluetooth adapter.
# Usage: zsh Tests/PersistentSyncNative/run.sh <output directory>
syncNativeOutput=${1:?Output directory required}
syncNativeScriptDir=${0:A:h}
syncNativeSourceRoot=${syncNativeScriptDir:h:h}
syncNativeDeveloper=$(xcode-select -p)
syncNativePlatform="$syncNativeDeveloper/Platforms/MacOSX.platform/Developer"
mkdir -p "$syncNativeOutput/module-cache" "$syncNativeOutput/tmp"
syncNativeOutput=${syncNativeOutput:A}

TMPDIR="$syncNativeOutput/tmp/" xcrun swiftc \
  -module-name Strand -enable-testing \
  -module-cache-path "$syncNativeOutput/module-cache" \
  -I "$syncNativePlatform/usr/lib" -L "$syncNativePlatform/usr/lib" \
  -F "$syncNativePlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$syncNativePlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$syncNativePlatform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$syncNativePlatform/usr/lib" \
  "$syncNativeSourceRoot/Strand/BLE/BLEConnectionOwner.swift" \
  "$syncNativeSourceRoot/Strand/Collect/HistoricalCommitLease.swift" \
  "$syncNativeSourceRoot/Strand/System/ResourceBudget.swift" \
  "$syncNativeSourceRoot/StrandTests/BLEConnectionOwnerTests.swift" \
  "$syncNativeSourceRoot/StrandTests/HistoricalCommitLeaseTests.swift" \
  "$syncNativeSourceRoot/StrandTests/ResourceBudgetTests.swift" \
  "$syncNativeScriptDir/main.swift" \
  -o "$syncNativeOutput/PersistentSyncNative"

TMPDIR="$syncNativeOutput/tmp/" "$syncNativeOutput/PersistentSyncNative"
