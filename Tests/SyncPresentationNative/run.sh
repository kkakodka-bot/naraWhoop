#!/bin/zsh
set -euo pipefail
syncPresentationArtifacts=${1:?External artifact directory required}
syncPresentationScript=${0:A:h}
syncPresentationRoot=${syncPresentationScript:h:h}
syncPresentationArtifacts=${syncPresentationArtifacts:A}
[[ -d "$syncPresentationArtifacts" && "$syncPresentationArtifacts" != "$syncPresentationRoot" && "$syncPresentationArtifacts" != "$syncPresentationRoot/"* ]] || exit 2
syncPresentationOutput=$(mktemp -d "$syncPresentationArtifacts/sync-presentation.XXXXXX")
syncPresentationPlatform="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
mkdir -p "$syncPresentationOutput/module-cache" "$syncPresentationOutput/tmp"
print -r -- "Artifacts: $syncPresentationOutput"
shasum -a 256 "$syncPresentationRoot/Strand/System/SyncPresentation.swift" \
  "$syncPresentationRoot/StrandTests/SyncPresentationTests.swift" > "$syncPresentationOutput/source.sha256"
git -C "$syncPresentationRoot" rev-parse HEAD > "$syncPresentationOutput/source-head.txt"
xcrun swiftc -module-name Strand -enable-testing -module-cache-path "$syncPresentationOutput/module-cache" \
  -I "$syncPresentationPlatform/usr/lib" -L "$syncPresentationPlatform/usr/lib" \
  -F "$syncPresentationPlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$syncPresentationPlatform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$syncPresentationPlatform/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$syncPresentationPlatform/usr/lib" \
  "$syncPresentationRoot/Strand/System/SyncPresentation.swift" \
  "$syncPresentationRoot/StrandTests/SyncPresentationTests.swift" "$syncPresentationScript/main.swift" \
  -o "$syncPresentationOutput/SyncPresentationNative" > "$syncPresentationOutput/build.log" 2>&1
env -i PATH=/usr/bin:/bin TMPDIR="$syncPresentationOutput/tmp/" \
  "$syncPresentationOutput/SyncPresentationNative" 2>&1 | tee "$syncPresentationOutput/tests.log"
