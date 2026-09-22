#!/bin/zsh
set -euo pipefail
umask 077

# Usage: zsh Tests/ServerFixtureNative/run.sh <fresh absolute external artifact directory>
# The caller creates only the parent. This script refuses to replace any prior evidence.
fixtureOutput=${1:?Fresh absolute external artifact directory required}
fixtureScript=${0:A:h}
fixtureRoot=${fixtureScript:h:h}
[[ "$fixtureOutput" == /* && ! -e "$fixtureOutput" ]] || { print -u2 'Use a fresh absolute output path'; exit 2; }
fixtureOutput=${fixtureOutput:A}
[[ "$fixtureOutput" != "$fixtureRoot" && "$fixtureOutput" != "$fixtureRoot/"* ]] || {
  print -u2 'Keep fixture artifacts outside the repository'; exit 2
}
mkdir -p "$fixtureOutput"
fixtureDeveloper=${DEVELOPER_DIR:-$(xcode-select -p)}
fixtureHarness="$fixtureOutput/imu-harness"
fixtureSources=(
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
  Strand/Collect/ImuSessionFileStore.swift
  Strand/Push/CloudImuPushSource.swift
  Strand/Push/CloudImuArchive.swift
  Strand/Push/CloudPushSnapshot.swift
)
fixtureTests=(StrandTests/CloudImuPushSourceTests.swift)
fixtureFingerprint() {
  for fixtureFile in "${fixtureSources[@]}" "${fixtureTests[@]}"; do shasum -a 256 "$fixtureRoot/$fixtureFile"; done
  shasum -a 256 "$fixtureScript"/*(.N) "$fixtureRoot/Tests/CloudUploadNative/BoundaryStubs.swift" \
    "$fixtureRoot/Tests/CloudUploadNative/ReceiptFixture.swift"
  for fixturePackage in NoopPush WhoopStore WhoopProtocol OuraProtocol; do
    shasum -a 256 "$fixtureRoot/Packages/$fixturePackage/Package.swift" \
      "$fixtureRoot/Packages/$fixturePackage/Sources"/**/*(.N)
  done
  shasum -a 256 "$fixtureRoot/Packages/NoopPush/Tests/NoopPushTests/PushAuxiliaryIdentityTests.swift"
}
fixtureFingerprint > "$fixtureOutput/source-before.sha256"
git -C "$fixtureRoot" rev-parse HEAD > "$fixtureOutput/source-head.txt"
mkdir -p "$fixtureOutput/tmp" "$fixtureHarness/Sources/CloudUploadHarness" "$fixtureHarness/Tests/CloudUploadHarnessTests"
ln -s "$fixtureScript/Package.swift" "$fixtureHarness/Package.swift"
ln -s "$fixtureRoot/Tests/CloudUploadNative/BoundaryStubs.swift" "$fixtureHarness/Sources/CloudUploadHarness/BoundaryStubs.swift"
ln -s "$fixtureRoot/Tests/CloudUploadNative/ReceiptFixture.swift" "$fixtureHarness/Tests/CloudUploadHarnessTests/ReceiptFixture.swift"
ln -s "$fixtureScript/ObjectReceiptFixture.swift" "$fixtureHarness/Tests/CloudUploadHarnessTests/ObjectReceiptFixture.swift"
for fixtureFile in "${fixtureSources[@]}"; do
  ln -s "$fixtureRoot/$fixtureFile" "$fixtureHarness/Sources/CloudUploadHarness/${fixtureFile:t}"
done
for fixtureFile in "${fixtureTests[@]}"; do
  ln -s "$fixtureRoot/$fixtureFile" "$fixtureHarness/Tests/CloudUploadHarnessTests/${fixtureFile:t}"
done
print -r -- "Artifacts: $fixtureOutput"

env -i PATH=/opt/homebrew/bin:/usr/bin:/bin DEVELOPER_DIR="$fixtureDeveloper" TMPDIR="$fixtureOutput/tmp/" \
  NOOP_EXPORT_AUX_FIXTURE="$fixtureOutput/aux14-swift" \
  NOOP_EXPORT_AUX_INTAKE_FIXTURE="$fixtureOutput/aux14-swift-intake-v1" \
  /usr/bin/xcrun swift test --package-path "$fixtureRoot/Packages/NoopPush" \
  --scratch-path "$fixtureOutput/push-build" --jobs 4 --filter PushAuxiliaryIdentityTests \
  2>&1 | tee "$fixtureOutput/auxiliary-tests.log"

env -i PATH=/opt/homebrew/bin:/usr/bin:/bin DEVELOPER_DIR="$fixtureDeveloper" TMPDIR="$fixtureOutput/tmp/" \
  NARA_SERVER_FIXTURE_SOURCE_ROOT="$fixtureRoot" NARA_IMF1_FIXTURE_DIR="$fixtureOutput/imf1-swift-native-v1" \
  /usr/bin/xcrun swift test --package-path "$fixtureHarness" --scratch-path "$fixtureOutput/imu-build" \
  --jobs 4 --filter CloudImuPushSourceTests/testExportActualSwiftImf1FixturesForSessionAndContinuous \
  2>&1 | tee "$fixtureOutput/imu-tests.log"

for fixtureFile in aux14-swift/payload.npb1 aux14-swift/payload.gz aux14-swift/golden.json \
  aux14-swift-intake-v1/manifest.json aux14-swift-intake-v1/payload.npb1 aux14-swift-intake-v1/payload.gz \
  aux14-swift-intake-v1/golden.json imf1-swift-native-v1/fixture.json \
  imf1-swift-native-v1/session/manifest.json imf1-swift-native-v1/session/payload.zst \
  imf1-swift-native-v1/continuous/manifest.json imf1-swift-native-v1/continuous/payload.zst; do
  [[ -s "$fixtureOutput/$fixtureFile" ]] || { print -u2 "Missing actual Swift fixture: $fixtureFile"; exit 3; }
done
fixtureFingerprint > "$fixtureOutput/source-after.sha256"
cmp -s "$fixtureOutput/source-before.sha256" "$fixtureOutput/source-after.sha256" || {
  print -u2 'Source changed during export; evidence is not an exact candidate result'; exit 4
}
shasum -a 256 "$fixtureOutput"/aux14-swift/*(.N) "$fixtureOutput"/aux14-swift-intake-v1/*(.N) \
  "$fixtureOutput"/imf1-swift-native-v1/**/*(.N) > "$fixtureOutput/fixture-files.sha256"
print -r -- 'PASS: actual Swift auxiliary and IMF1 fixtures exported; source fingerprint unchanged'
