#!/bin/zsh
set -euo pipefail
intervalOutput=${1:?Output directory required}
intervalScriptDir=${0:A:h}
intervalRoot=${intervalScriptDir:h:h}
intervalPlatform="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
mkdir -p "$intervalOutput/module-cache" "$intervalOutput/tmp"
intervalOutput=${intervalOutput:A}
TMPDIR="$intervalOutput/tmp/" xcrun swiftc -module-name Strand -enable-testing \
  -module-cache-path "$intervalOutput/module-cache" \
  -I "$intervalPlatform/usr/lib" -L "$intervalPlatform/usr/lib" \
  -F "$intervalPlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$intervalPlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$intervalPlatform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$intervalPlatform/usr/lib" \
  "$intervalRoot/Strand/System/SyncPipelineTrace.swift" \
  "$intervalRoot/StrandTests/SyncIntervalMetricsTests.swift" "$intervalScriptDir/main.swift" \
  -o "$intervalOutput/SyncIntervalNative"
TMPDIR="$intervalOutput/tmp/" "$intervalOutput/SyncIntervalNative"
