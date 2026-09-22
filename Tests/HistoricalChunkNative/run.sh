#!/bin/zsh
set -euo pipefail

# Usage: zsh Tests/HistoricalChunkNative/run.sh <external artifact directory> [chunk count]
historyArtifactParent=${1:?External artifact directory required}
historyChunkCount=${2:-10000}
historyScriptDir=${0:A:h}
historySourceRoot=${historyScriptDir:h:h}
historyArtifactParent=${historyArtifactParent:A}
[[ -d "$historyArtifactParent" && "$historyArtifactParent" != "$historySourceRoot" && "$historyArtifactParent" != "$historySourceRoot/"* ]] || {
  print -u2 'Use an existing external artifact directory'; exit 2
}
historyOutput=$(mktemp -d "$historyArtifactParent/historical-native.XXXXXX")
historyBuild="$historyArtifactParent/store-build"
historyDeveloper=${DEVELOPER_DIR:-$(xcode-select -p)}
historyPlatform="$historyDeveloper/Platforms/MacOSX.platform/Developer"
mkdir -p "$historyOutput/module-cache" "$historyOutput/tmp"
historyFingerprint() {
  shasum -a 256 "$historyScriptDir"/*(.N) \
    "$historySourceRoot/Packages/WhoopStore/Package.swift" \
    "$historySourceRoot/Packages/WhoopStore/Sources"/**/*(.N) \
    "$historySourceRoot/Packages/WhoopProtocol/Sources"/**/*(.N) \
    "$historySourceRoot/Packages/OuraProtocol/Sources"/**/*(.N)
}
historyFingerprint > "$historyOutput/source-before.sha256"
historySHA=$(git -C "$historySourceRoot" rev-parse HEAD)
print -r -- "$historySHA" > "$historyOutput/source-head.txt"
print -r -- "Artifacts: $historyOutput"
xcrun swift build --package-path "$historySourceRoot/Packages/WhoopStore" \
  --scratch-path "$historyBuild" --jobs 4 > "$historyOutput/build.log" 2>&1
historyProducts=$(xcrun swift build --package-path "$historySourceRoot/Packages/WhoopStore" \
  --scratch-path "$historyBuild" --show-bin-path)
xcrun swiftc -parse-as-library -module-name HistoricalChunkNative \
  -module-cache-path "$historyOutput/module-cache" \
  -I "$historyProducts/Modules" \
  -Xcc "-fmodule-map-file=$historyProducts/../../checkouts/GRDB.swift/Sources/CSQLite/module.modulemap" \
  "$historyScriptDir/main.swift" \
  "$historyProducts"/WhoopStore.build/*.swift.o "$historyProducts"/GRDB.build/*.swift.o \
  "$historyProducts"/WhoopProtocol.build/*.swift.o "$historyProducts"/OuraProtocol.build/*.swift.o \
  -lsqlite3 -o "$historyOutput/HistoricalChunkNative" > "$historyOutput/compile.log" 2>&1
historyExit=0
env -i PATH=/usr/bin:/bin TMPDIR="$historyOutput/tmp/" NARA_SOURCE_SHA="$historySHA" \
  "$historyOutput/HistoricalChunkNative" "$historyOutput" "$historyChunkCount" \
  2>&1 | tee "$historyOutput/tests.log" || historyExit=$?
historyFingerprint > "$historyOutput/source-after.sha256"
if ! cmp -s "$historyOutput/source-before.sha256" "$historyOutput/source-after.sha256"; then
  print -u2 'Source changed during the run; evidence is not a frozen candidate result'; exit 3
fi
exit "$historyExit"
