#!/bin/zsh
set -euo pipefail
preferenceStoreBuild=${1:?WhoopStore debug build directory required}
preferenceIdentityBuild=${2:?NoopPush debug build directory required}
preferenceOutput=${3:?Private output binary required}
preferenceMode=${4:-foundation}
if [[ "$preferenceMode" != foundation && "$preferenceMode" != baseline ]]; then
  print -u2 'Mode must be foundation or baseline'
  exit 64
fi
preferenceDeveloper=$(xcode-select -p)
preferencePlatform="$preferenceDeveloper/Platforms/MacOSX.platform/Developer"
preferenceScriptDir=${0:A:h}
cd "$preferenceScriptDir/../.."
preferenceTests=(StrandTests/ScoringPreferenceIntentTests.swift Tests/ScoringPreferenceIntentNative/CrashProbe.swift Tests/ScoringPreferenceIntentNative/main.swift)
if [[ "$preferenceMode" == baseline ]]; then
  preferenceTests=(StrandTests/ScoringInputJournalTests.swift StrandTests/ScoringInputCoordinatorTests.swift StrandTests/ScoringConsentRelayTests.swift StrandTests/ScoringConsentCapacityTests.swift Tests/ScoringInputNative/LoopbackTests.swift Tests/ScoringInputNative/main.swift)
fi
xcrun swiftc -D SCORING_INPUT_NATIVE_TESTS \
  -module-cache-path "${preferenceOutput}.module-cache" \
  -I "$preferenceStoreBuild/Modules" -I "$preferenceIdentityBuild/Modules" \
  -Xcc "-fmodule-map-file=$preferenceStoreBuild/../../checkouts/GRDB.swift/Sources/CSQLite/module.modulemap" \
  -Xcc "-fmodule-map-file=$preferenceIdentityBuild/CNoopZstd.build/module.modulemap" \
  -I "$preferencePlatform/usr/lib" -L "$preferencePlatform/usr/lib" -F "$preferencePlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$preferencePlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$preferencePlatform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$preferencePlatform/usr/lib" \
  Strand/Push/ServerScoreSnapshot.swift Strand/Push/ServerScoreDetails.swift \
  Strand/Push/ServerScoreEvidenceDetails.swift Strand/Push/ServerScoreContextDetails.swift Strand/Push/ServerScoreWorkoutDetails.swift \
  Strand/Push/ScoringPreferenceIntent.swift Strand/Push/ScoringInputJournal.swift \
  Strand/Push/ScoringInputCoordinator.swift Strand/Push/ScoringInputReadback.swift Strand/Push/ScoringInputTransport.swift \
  Strand/Push/ScoringContextConsent.swift Strand/Push/ScoringContextInput.swift \
  "${preferenceTests[@]}" \
  "$preferenceStoreBuild"/GRDB.build/*.swift.o "$preferenceIdentityBuild"/NoopPush.build/*.swift.o \
  "$preferenceStoreBuild"/WhoopStore.build/*.swift.o "$preferenceStoreBuild"/WhoopProtocol.build/*.swift.o \
  "$preferenceStoreBuild"/OuraProtocol.build/*.swift.o "$preferenceIdentityBuild"/CNoopZstd.build/*.o \
  -L/opt/homebrew/lib -lzstd -lz -lsqlite3 -o "$preferenceOutput"
"$preferenceOutput"
