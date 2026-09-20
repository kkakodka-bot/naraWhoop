#!/bin/zsh
set -euo pipefail

# Usage: run.sh <built WhoopStore debug dir> <built NoopPush debug dir> <output binary>
# Uses only host build artifacts and synthetic identities. No app credentials, database or network.
w4StoreBuild=${1:?WhoopStore debug build directory required}
w4IdentityBuild=${2:?NoopPush debug build directory required}
w4Output=${3:?Output binary path required}
w4Developer=$(xcode-select -p)
w4Platform="$w4Developer/Platforms/MacOSX.platform/Developer"
w4ScriptDir=${0:A:h}
cd "$w4ScriptDir/../.."
xcrun swiftc -D SERVER_SCORE_NATIVE_TESTS -D SERVER_SCORE_REPOSITORY_TESTS \
  -I "$w4StoreBuild/Modules" -I "$w4IdentityBuild/Modules" \
  -Xcc "-fmodule-map-file=$w4StoreBuild/../../checkouts/GRDB.swift/Sources/CSQLite/module.modulemap" \
  -Xcc "-fmodule-map-file=$w4IdentityBuild/CNoopZstd.build/module.modulemap" \
  -I "$w4Platform/usr/lib" -L "$w4Platform/usr/lib" -F "$w4Platform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$w4Platform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$w4Platform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$w4Platform/usr/lib" \
  Strand/Push/ServerScoreSnapshot.swift Strand/Push/ServerScoreDetails.swift Strand/Push/ServerScoreEvidenceDetails.swift Strand/Push/ServerScoreDisplay.swift Strand/Push/ServerScoreClient.swift \
  Strand/Push/ServerScoreContextDetails.swift \
  Strand/Push/ServerScoreWorkoutDetails.swift Strand/Push/ServerScoreWorkoutPresentation.swift \
  Packages/StrandAnalytics/Sources/StrandAnalytics/HeartRateRecovery.swift \
  Strand/Push/ServerScoreReadTransport.swift Strand/Push/ServerScoreLocalComputePolicy.swift \
  Strand/Push/ServerScoreRepository.swift Strand/System/SyncPipelineTrace.swift \
  Strand/Push/ServerScoreContentReadyTrace.swift \
  Strand/Push/ServerScoreSleepSession.swift Packages/StrandImport/Sources/StrandImport/HealthWriteback.swift \
  StrandTests/ServerScoreSnapshotV2Tests.swift \
  StrandTests/ServerScoreSleepSessionTests.swift \
  StrandTests/ServerScoreHistoryContractTests.swift \
  StrandTests/ServerScoreSleepDetailsTests.swift \
  StrandTests/ServerScoreContextMotionTests.swift \
  StrandTests/ServerScoreWorkoutDetailsTests.swift \
  StrandTests/ServerScoreContentReadyTraceTests.swift \
  StrandTests/ServerScoreReadTransportTests.swift StrandTests/ServerScoreLocalComputePolicyTests.swift \
  Tests/ServerScoreReadbackNative/RepositoryFixtures.swift \
  Tests/ServerScoreReadbackNative/RepositoryTests.swift Tests/ServerScoreReadbackNative/RefreshTests.swift \
  Tests/ServerScoreReadbackNative/main.swift \
  "$w4StoreBuild"/WhoopStore.build/*.swift.o "$w4StoreBuild"/GRDB.build/*.swift.o \
  "$w4StoreBuild"/WhoopProtocol.build/*.swift.o "$w4StoreBuild"/OuraProtocol.build/*.swift.o \
  "$w4IdentityBuild"/NoopPush.build/*.swift.o \
  "$w4IdentityBuild"/CNoopZstd.build/*.o -L/opt/homebrew/lib -lzstd -lz -lsqlite3 \
  -o "$w4Output"
"$w4Output" "${4:-}"

# Actual settings source, isolated preferences and synthetic identity/bundle/write-gate facades.
xcrun swiftc -I "$w4IdentityBuild/Modules" \
  -Xcc "-fmodule-map-file=$w4IdentityBuild/CNoopZstd.build/module.modulemap" \
  -I "$w4Platform/usr/lib" -L "$w4Platform/usr/lib" -F "$w4Platform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$w4Platform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$w4Platform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$w4Platform/usr/lib" \
  Strand/Push/ServerScoreSnapshot.swift Strand/Push/ServerScoreDetails.swift Strand/Push/ServerScoreEvidenceDetails.swift Strand/Push/ServerScoringSettings.swift \
  Strand/Push/ServerScoreContextDetails.swift \
  Strand/Push/ServerScoreWorkoutDetails.swift \
  Tests/ServerScoreReadbackNative/Settings/Fixtures.swift Tests/ServerScoreReadbackNative/Settings/main.swift \
  "$w4IdentityBuild"/NoopPush.build/*.swift.o \
  "$w4IdentityBuild"/CNoopZstd.build/*.o -L/opt/homebrew/lib -lzstd -lz -o "$w4Output-settings"
"$w4Output-settings"
