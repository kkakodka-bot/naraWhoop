#!/bin/zsh
set -euo pipefail
runtimeStore=${1:?WhoopStore debug build directory required}
runtimePush=${2:?NoopPush debug build directory required}
runtimeAnalytics=${3:?StrandAnalytics debug build directory required}
runtimeDesign=${4:?StrandDesign debug build directory required}
runtimeOutput=${5:?Private output binary required}
runtimeDeveloper=$(xcode-select -p)
runtimePlatform="$runtimeDeveloper/Platforms/MacOSX.platform/Developer"
runtimeScriptDir=${0:A:h}
cd "$runtimeScriptDir/../.."
xcrun swiftc -D SCORING_INPUT_NATIVE_TESTS -D ACCOUNT_PREFERENCES_NATIVE_ONLY \
  -module-cache-path "${runtimeOutput}.module-cache" \
  -I "$runtimeStore/Modules" -I "$runtimePush/Modules" -I "$runtimeAnalytics/Modules" -I "$runtimeDesign/Modules" \
  -Xcc "-fmodule-map-file=$runtimeStore/../../checkouts/GRDB.swift/Sources/CSQLite/module.modulemap" \
  -Xcc "-fmodule-map-file=$runtimePush/CNoopZstd.build/module.modulemap" \
  -I "$runtimePlatform/usr/lib" -L "$runtimePlatform/usr/lib" -F "$runtimePlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$runtimePlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$runtimePlatform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$runtimePlatform/usr/lib" \
  Strand/Push/ServerScoreSnapshot.swift Strand/Push/ServerScoreDetails.swift \
  Strand/Push/ServerScoreEvidenceDetails.swift Strand/Push/ServerScoreContextDetails.swift Strand/Push/ServerScoreWorkoutDetails.swift \
  Strand/Push/ScoringPreferenceIntent.swift Strand/Push/ScoringInputJournal.swift \
  Strand/Push/ScoringInputCoordinator.swift Strand/Push/ScoringInputReadback.swift Strand/Push/ScoringInputTransport.swift \
  Strand/Push/ScoringContextConsent.swift Strand/Push/ScoringContextInput.swift \
  Strand/Push/ScoringPreferenceSnapshot.swift Strand/Push/ScoringPreferenceRuntime.swift \
  Strand/App/AccountPreferences.swift Strand/Data/Profile.swift Strand/Data/BehaviorStore.swift \
  Strand/System/Platform.swift Strand/System/MacActions.swift Strand/Screens/ProfileAvatarView.swift \
  StrandTests/ScoringPreferenceRuntimeTests.swift StrandTests/AccountAlgorithmChoicesTests.swift StrandTests/AccountPreferenceIsolationTests.swift \
  StrandTests/ScoringPreferencePublicationFenceTests.swift \
  Tests/ScoringPreferenceRuntimeNative/Fixtures.swift Tests/ScoringPreferenceRuntimeNative/CrashProbe.swift Tests/ScoringPreferenceRuntimeNative/main.swift \
  "$runtimeStore"/GRDB.build/*.swift.o "$runtimePush"/NoopPush.build/*.swift.o \
  "$runtimeStore"/WhoopStore.build/*.swift.o "$runtimeStore"/WhoopProtocol.build/*.swift.o "$runtimeStore"/OuraProtocol.build/*.swift.o \
  "$runtimeAnalytics"/StrandAnalytics.build/*.swift.o "$runtimeDesign"/StrandDesign.build/*.swift.o \
  "$runtimePush"/CNoopZstd.build/*.o -L/opt/homebrew/lib -lzstd -lz -lsqlite3 -o "$runtimeOutput"
"$runtimeOutput"
