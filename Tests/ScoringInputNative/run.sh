#!/bin/zsh
set -euo pipefail
inputStoreBuild=${1:?WhoopStore debug build directory required}
inputIdentityBuild=${2:?NoopPush debug build directory required}
inputOutput=${3:?Output binary required}
inputDeveloper=$(xcode-select -p)
inputPlatform="$inputDeveloper/Platforms/MacOSX.platform/Developer"
inputScriptDir=${0:A:h}
cd "$inputScriptDir/../.."
xcrun swiftc -D SCORING_INPUT_NATIVE_TESTS \
  -I "$inputStoreBuild/Modules" -I "$inputIdentityBuild/Modules" \
  -Xcc "-fmodule-map-file=$inputStoreBuild/../../checkouts/GRDB.swift/Sources/CSQLite/module.modulemap" \
  -Xcc "-fmodule-map-file=$inputIdentityBuild/CNoopZstd.build/module.modulemap" \
  -I "$inputPlatform/usr/lib" -L "$inputPlatform/usr/lib" -F "$inputPlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$inputPlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$inputPlatform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$inputPlatform/usr/lib" \
  Strand/Push/ServerScoreSnapshot.swift Strand/Push/ServerScoreDetails.swift \
  Strand/Push/ServerScoreEvidenceDetails.swift Strand/Push/ServerScoreContextDetails.swift \
  Strand/Push/ServerScoreWorkoutDetails.swift \
  Strand/Push/ScoringInputJournal.swift Strand/Push/ScoringInputCoordinator.swift Strand/Push/ScoringInputReadback.swift Strand/Push/ScoringInputTransport.swift \
  Strand/Push/ScoringContextConsent.swift Strand/Push/ScoringContextInput.swift \
  StrandTests/ScoringInputJournalTests.swift StrandTests/ScoringInputCoordinatorTests.swift \
  StrandTests/ScoringConsentRelayTests.swift StrandTests/ScoringConsentCapacityTests.swift \
  Tests/ScoringInputNative/LoopbackTests.swift Tests/ScoringInputNative/main.swift \
  "$inputStoreBuild"/GRDB.build/*.swift.o "$inputIdentityBuild"/NoopPush.build/*.swift.o \
  "$inputStoreBuild"/WhoopStore.build/*.swift.o "$inputStoreBuild"/WhoopProtocol.build/*.swift.o \
  "$inputStoreBuild"/OuraProtocol.build/*.swift.o \
  "$inputIdentityBuild"/CNoopZstd.build/*.o -L/opt/homebrew/lib -lzstd -lz -lsqlite3 -o "$inputOutput"
"$inputOutput"
