#!/bin/zsh
set -euo pipefail

# Usage: zsh Tests/ImuSessionNative/run.sh <store debug products> <push debug products> <external artifacts>
imuStoreBuild=${1:?WhoopStore debug products required}
imuPushBuild=${2:?NoopPush debug products required}
imuArtifactParent=${3:?External artifact directory required}
imuScriptDir=${0:A:h}
imuRoot=${imuScriptDir:h:h}
imuArtifactParent=${imuArtifactParent:A}
[[ -d "$imuArtifactParent" && "$imuArtifactParent" != "$imuRoot" && "$imuArtifactParent" != "$imuRoot/"* ]] || {
  print -u2 'Use an existing external artifact directory'; exit 2
}
imuOutput=$(mktemp -d "$imuArtifactParent/imu-native.XXXXXX")
imuDeveloper=${DEVELOPER_DIR:-$(xcode-select -p)}
imuPlatform="$imuDeveloper/Platforms/MacOSX.platform/Developer"
mkdir -p "$imuOutput/module-cache" "$imuOutput/tmp"
imuFingerprint() {
  shasum -a 256 "$imuRoot/Strand/Collect/ImuSessionFileStore.swift" \
    "$imuRoot/StrandTests/ImuSessionFileStoreTests.swift" "$imuScriptDir"/*(.N)
}
imuFingerprint > "$imuOutput/source-before.sha256"
git -C "$imuRoot" rev-parse HEAD > "$imuOutput/source-head.txt"
print -r -- "Artifacts: $imuOutput"
xcrun swiftc -module-name Strand -enable-testing -module-cache-path "$imuOutput/module-cache" \
  -I "$imuStoreBuild/Modules" -I "$imuPushBuild/Modules" \
  -Xcc "-fmodule-map-file=$imuStoreBuild/../../checkouts/GRDB.swift/Sources/CSQLite/module.modulemap" \
  -Xcc "-fmodule-map-file=$imuPushBuild/CNoopZstd.build/module.modulemap" \
  -I "$imuPlatform/usr/lib" -L "$imuPlatform/usr/lib" -F "$imuPlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$imuPlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$imuPlatform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$imuPlatform/usr/lib" \
  "$imuRoot/Strand/Collect/ImuSessionFileStore.swift" \
  "$imuRoot/StrandTests/ImuSessionFileStoreTests.swift" "$imuScriptDir/main.swift" \
  "$imuStoreBuild"/WhoopStore.build/*.swift.o "$imuStoreBuild"/GRDB.build/*.swift.o \
  "$imuStoreBuild"/WhoopProtocol.build/*.swift.o "$imuStoreBuild"/OuraProtocol.build/*.swift.o \
  "$imuPushBuild"/NoopPush.build/*.swift.o "$imuPushBuild"/CNoopZstd.build/**/*.o \
  -lsqlite3 -o "$imuOutput/ImuSessionNative" > "$imuOutput/build.log" 2>&1
imuExit=0
env -i PATH=/usr/bin:/bin TMPDIR="$imuOutput/tmp/" \
  "$imuOutput/ImuSessionNative" 2>&1 | tee "$imuOutput/tests.log" || imuExit=$?
imuFingerprint > "$imuOutput/source-after.sha256"
if ! cmp -s "$imuOutput/source-before.sha256" "$imuOutput/source-after.sha256"; then
  print -u2 'Source changed during the run'; exit 3
fi
exit "$imuExit"
