#!/bin/zsh
set -euo pipefail

# Host-only DTO/adapter interoperability against an actual fresh JVM publication.
# Usage: zsh run.sh <pinned analytics debug dir> <output binary> <exact populated fixture>
# Built analytics types are an explicit dependency, not a new scoring/app/device claim.
contextAnalyticsBuild=${1:?Pinned analytics debug directory required}
contextOutput=${2:?Output binary path required}
contextFixture=${3:?Fresh populated-context fixture path required}
contextDeveloper=$(xcode-select -p)
contextPlatform="$contextDeveloper/Platforms/MacOSX.platform/Developer"
contextScriptDir=${0:A:h}
cd "$contextScriptDir/../.."
[[ -f "$contextFixture" && "${contextFixture:t}" == W4-POPULATED-CONTEXT-SNAPSHOT-V2-NATIVE-FIXTURE.json ]]
xcrun swiftc -D SERVER_SCORE_NATIVE_TESTS \
  -I "$contextAnalyticsBuild/Modules" \
  -Xcc "-fmodule-map-file=$contextAnalyticsBuild/../../checkouts/GRDB.swift/Sources/CSQLite/module.modulemap" \
  -I "$contextPlatform/usr/lib" -L "$contextPlatform/usr/lib" -F "$contextPlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$contextPlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$contextPlatform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$contextPlatform/usr/lib" \
  Strand/Push/ServerScoreSnapshot.swift Strand/Push/ServerScoreDetails.swift \
  Strand/Push/ServerScoreEvidenceDetails.swift Strand/Push/ServerScoreContextDetails.swift \
  Strand/Push/ServerScoreWorkoutDetails.swift Strand/Push/ServerScoreDisplay.swift \
  Strand/Push/ServerScoreContextPresentation.swift StrandTests/ServerScoreContextInteroperabilityTests.swift \
  Tests/ServerScoreContextNative/Fixtures.swift Tests/ServerScoreContextNative/main.swift \
  "$contextAnalyticsBuild"/StrandAnalytics.build/*.swift.o \
  "$contextAnalyticsBuild"/WhoopStore.build/*.swift.o "$contextAnalyticsBuild"/GRDB.build/*.swift.o \
  "$contextAnalyticsBuild"/WhoopProtocol.build/*.swift.o "$contextAnalyticsBuild"/OuraProtocol.build/*.swift.o \
  -lz -lsqlite3 -o "$contextOutput"
W4_POPULATED_CONTEXT_FIXTURE="$contextFixture" "$contextOutput"
