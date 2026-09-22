#!/bin/zsh
set -euo pipefail

# Host-only tests, synthetic identities and newly created temporary stores; no radio or credentials.
# Args: WhoopStore debug build, app Debug products (PolarProtocol), output binary.
captureStoreBuild=${1:?WhoopStore debug build directory required}
captureAppProducts=${2:?app Debug products directory required}
captureOutput=${3:?output binary required}
captureDeveloper=$(xcode-select -p)
capturePlatform="$captureDeveloper/Platforms/MacOSX.platform/Developer"
captureScriptDir=${0:A:h}
cd "$captureScriptDir/../.."
xcrun swiftc -D GENERIC_CAPTURE_NATIVE_TESTS \
  -I "$captureStoreBuild/Modules" -I "$captureAppProducts" \
  -Xcc "-fmodule-map-file=$captureStoreBuild/../../checkouts/GRDB.swift/Sources/CSQLite/module.modulemap" \
  -I "$capturePlatform/usr/lib" -L "$capturePlatform/usr/lib" -F "$capturePlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$capturePlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$capturePlatform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$capturePlatform/usr/lib" \
  Strand/BLE/GenericCaptureJournal.swift Strand/BLE/StandardHRSource.swift Strand/BLE/StandardHeartRate.swift \
  Strand/App/RetiredCaptureDrain.swift StrandTests/GenericCaptureJournalTests.swift \
  Tests/GenericCaptureNative/Fixtures.swift Tests/GenericCaptureNative/main.swift \
  "$captureStoreBuild"/WhoopStore.build/*.swift.o "$captureStoreBuild"/GRDB.build/*.swift.o \
  "$captureStoreBuild"/WhoopProtocol.build/*.swift.o "$captureStoreBuild"/OuraProtocol.build/*.swift.o \
  "$captureAppProducts/PolarProtocol.o" -lsqlite3 -o "$captureOutput"
"$captureOutput"
