#!/bin/zsh
set -euo pipefail

# Compiles the production driver and native adapters; fakes replace only the radio boundary.
# Usage: zsh Tests/BLETransportNative/run.sh <output directory>
bleNativeOutput=${1:?Output directory required}
bleNativeScriptDir=${0:A:h}
bleNativeSourceRoot=${bleNativeScriptDir:h:h}
bleNativeDeveloper=$(xcode-select -p)
bleNativePlatform="$bleNativeDeveloper/Platforms/MacOSX.platform/Developer"
mkdir -p "$bleNativeOutput/module-cache" "$bleNativeOutput/tmp"
bleNativeOutput=${bleNativeOutput:A}

TMPDIR="$bleNativeOutput/tmp/" xcrun swiftc \
  -module-name Strand -enable-testing \
  -module-cache-path "$bleNativeOutput/module-cache" \
  -I "$bleNativePlatform/usr/lib" -L "$bleNativePlatform/usr/lib" \
  -F "$bleNativePlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$bleNativePlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$bleNativePlatform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$bleNativePlatform/usr/lib" \
  "$bleNativeSourceRoot/Strand/BLE/BLEConnectionOwner.swift" \
  "$bleNativeSourceRoot/Strand/BLE/BLETransportDriver.swift" \
  "$bleNativeSourceRoot/Strand/BLE/CoreBluetoothTransport.swift" \
  "$bleNativeSourceRoot/Strand/BLE/BLEPeripheralDelegateProxy.swift" \
  "$bleNativeSourceRoot/Strand/BLE/BLENotificationController.swift" \
  "$bleNativeSourceRoot/StrandTests/BLETransportDriverTests.swift" \
  "$bleNativeSourceRoot/StrandTests/BLENotificationControllerTests.swift" \
  "$bleNativeScriptDir/main.swift" \
  -o "$bleNativeOutput/BLETransportNative"

TMPDIR="$bleNativeOutput/tmp/" "$bleNativeOutput/BLETransportNative"
