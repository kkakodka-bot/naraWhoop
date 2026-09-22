#!/bin/zsh
set -euo pipefail

# Usage: zsh Tests/CloudUploadNative/run.sh <existing external artifact directory> [swift test options]
cloudNativeArtifactParent=${1:?Existing external artifact directory required}
shift
[[ -d "$cloudNativeArtifactParent" ]] || { print -u2 'Artifact directory does not exist'; exit 2; }
cloudNativeScriptDir=${0:A:h}
cloudNativeSourceRoot=${cloudNativeScriptDir:h:h}
cloudNativeArtifactParent=${cloudNativeArtifactParent:A}
[[ "$cloudNativeArtifactParent" != "$cloudNativeSourceRoot" && "$cloudNativeArtifactParent" != "$cloudNativeSourceRoot/"* ]] || {
  print -u2 'Place build artifacts outside the repository'; exit 2
}
cloudNativeOutput=$(mktemp -d "$cloudNativeArtifactParent/cloud-upload-native.XXXXXX")
cloudNativeDeveloper=${DEVELOPER_DIR:-$(xcode-select -p)}
cloudNativeSources=(
  Strand/Push/CloudMetadataStore.swift
  Strand/Push/CloudSelectionSpool.swift
  Strand/Push/CloudUploadJournal.swift
  Strand/Push/CloudUploadQueue.swift
  Strand/Push/CloudUploadSession.swift
  Strand/Push/CloudPushPreparedSelection.swift
  Strand/Push/CloudPushProgressStore.swift
  Strand/Push/CloudPushTransport.swift
  Strand/Push/CloudAccountPushTransport.swift
  Strand/Push/CloudPushBackgroundRuntime.swift
  Strand/Push/CloudPushRefreshCompletion.swift
  Strand/System/ResourceBudget.swift
  Strand/System/SyncPipelineTrace.swift
)
cloudNativeTests=(StrandTests/CloudUploadQueueTests.swift StrandTests/CloudUploadOutcomeTests.swift StrandTests/CloudMetadataMigrationTests.swift)
mkdir -p "$cloudNativeOutput/Sources/CloudUploadHarness" "$cloudNativeOutput/Tests/CloudUploadHarnessTests" "$cloudNativeOutput/fixtures"
ln -s "$cloudNativeScriptDir/Package.swift" "$cloudNativeOutput/Package.swift"
ln -s "$cloudNativeScriptDir/BoundaryStubs.swift" "$cloudNativeOutput/Sources/CloudUploadHarness/BoundaryStubs.swift"
ln -s "$cloudNativeScriptDir/ReceiptFixture.swift" "$cloudNativeOutput/Tests/CloudUploadHarnessTests/ReceiptFixture.swift"
for cloudNativeFile in "${cloudNativeSources[@]}"; do
  ln -s "$cloudNativeSourceRoot/$cloudNativeFile" "$cloudNativeOutput/Sources/CloudUploadHarness/${cloudNativeFile:t}"
done
for cloudNativeFile in "${cloudNativeTests[@]}"; do
  ln -s "$cloudNativeSourceRoot/$cloudNativeFile" "$cloudNativeOutput/Tests/CloudUploadHarnessTests/${cloudNativeFile:t}"
done

cloudNativeFingerprint() {
  for cloudNativeFile in "${cloudNativeSources[@]}" "${cloudNativeTests[@]}"; do
    shasum -a 256 "$cloudNativeSourceRoot/$cloudNativeFile"
  done
  shasum -a 256 "$cloudNativeScriptDir"/*(.N) "$cloudNativeSourceRoot/Packages/NoopPush/Package.swift" \
    "$cloudNativeSourceRoot/Packages/NoopPush/Sources"/**/*(.N)
}
cloudNativeFingerprint > "$cloudNativeOutput/source-before.sha256"
git -C "$cloudNativeSourceRoot" rev-parse HEAD > "$cloudNativeOutput/source-head.txt"
print -r -- "Artifacts: $cloudNativeOutput"
cloudNativeExit=0
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin DEVELOPER_DIR="$cloudNativeDeveloper" \
  NARA_CLOUD_SOURCE_ROOT="$cloudNativeSourceRoot" NARA_TEST_FIXTURE_ROOT="$cloudNativeOutput/fixtures" \
  /usr/bin/xcrun swift test --package-path "$cloudNativeOutput" --scratch-path "$cloudNativeOutput/build" \
  --jobs 4 "$@" 2>&1 | tee "$cloudNativeOutput/tests.log" || cloudNativeExit=$?
cloudNativeFingerprint > "$cloudNativeOutput/source-after.sha256"
if ! cmp -s "$cloudNativeOutput/source-before.sha256" "$cloudNativeOutput/source-after.sha256"; then
  print -u2 'Source changed during the run; evidence is not an exact candidate result'
  exit 3
fi
exit "$cloudNativeExit"
