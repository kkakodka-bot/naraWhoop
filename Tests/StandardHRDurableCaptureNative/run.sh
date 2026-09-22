#!/bin/zsh
set -euo pipefail

# Private macOS host build; synthetic stores, startCentral:false, no device commands.
# Args: Store debug products, Polar debug products, output binary, [current|baseline],
#       [preserved source root], [preserved StandardHRCurrentRedTests.swift].
captureStoreBuild=${1:?WhoopStore debug directory required}
capturePolarBuild=${2:?PolarProtocol products directory required}
captureOutput=${3:?private output binary required}
captureMode=${4:-current}
captureScriptDir=${0:A:h}
captureRepository=${captureScriptDir:h:h}
captureSourceRoot=${5:-$captureRepository}
captureDeveloper=$(xcode-select -p)
capturePlatform="$captureDeveloper/Platforms/MacOSX.platform/Developer"
captureOutputDir=${captureOutput:h}
mkdir -p "$captureOutputDir/module-cache" "$captureOutputDir/tmp"

captureFlags=(-D GENERIC_CAPTURE_NATIVE_TESTS)
captureTests=()
if [[ "$captureMode" == baseline ]]; then
  captureFlags+=(-D STANDARD_HR_CAPTURE_BASELINE)
  captureTests+=("${6:?preserved baseline test file required}")
elif [[ "$captureMode" == current ]]; then
  captureTests+=("$captureSourceRoot/StrandTests/GenericCaptureJournalTests.swift"
    "$captureSourceRoot/StrandTests/RetiredCaptureDrainTests.swift"
    "$captureSourceRoot/StrandTests/StandardHRDurableCaptureTests.swift")
else
  print -u2 "Unknown capture mode: $captureMode"
  exit 64
fi
capturePolarObjects=()
if [[ -f "$capturePolarBuild/PolarProtocol.o" ]]; then
  capturePolarObjects+=("$capturePolarBuild/PolarProtocol.o")
else
  capturePolarObjects+=("$capturePolarBuild"/PolarProtocol.build/*.swift.o(N))
fi
(( ${#capturePolarObjects} > 0 )) || { print -u2 'PolarProtocol objects missing'; exit 65; }

xcrun swiftc -module-name Strand -enable-testing "${captureFlags[@]}" \
  -module-cache-path "$captureOutputDir/module-cache" \
  -I "$captureStoreBuild/Modules" -I "$capturePolarBuild" -I "$capturePolarBuild/Modules" \
  -Xcc "-fmodule-map-file=$captureStoreBuild/../../checkouts/GRDB.swift/Sources/CSQLite/module.modulemap" \
  -I "$capturePlatform/usr/lib" -L "$capturePlatform/usr/lib" -F "$capturePlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$capturePlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$capturePlatform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$capturePlatform/usr/lib" \
  "$captureSourceRoot/Strand/BLE/GenericCaptureJournal.swift" \
  "$captureSourceRoot/Strand/BLE/StandardHRSource.swift" \
  "$captureSourceRoot/Strand/BLE/StandardHeartRate.swift" \
  "$captureSourceRoot/Strand/App/RetiredCaptureDrain.swift" \
  "${captureTests[@]}" "$captureScriptDir/Fixtures.swift" "$captureScriptDir/CrashProbe.swift" \
  "$captureScriptDir/main.swift" \
  "$captureStoreBuild"/WhoopStore.build/*.swift.o "$captureStoreBuild"/GRDB.build/*.swift.o \
  "$captureStoreBuild"/WhoopProtocol.build/*.swift.o "$captureStoreBuild"/OuraProtocol.build/*.swift.o \
  "${capturePolarObjects[@]}" -lsqlite3 -o "$captureOutput"
TMPDIR="$captureOutputDir/tmp/" STANDARD_HR_CAPTURE_FIXTURES="$captureOutputDir/tmp" "$captureOutput"
