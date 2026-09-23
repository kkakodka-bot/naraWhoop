#!/usr/bin/env bash
set -euo pipefail
repair_root="$(cd "$(dirname "$0")/../.." && pwd)"
repair_evidence="$(mktemp -d "${TMPDIR:-/tmp}/ble-push-android.XXXXXX")"
mkdir -p "$repair_evidence/tests"
for test in PushFreshRelayTest PushObjectExpiryTest PushCoordinatorTest PushCursorTest PushProtocolTest PushObjectLaneTest \
  PushBinaryProtocolTest PushTransportFailureTest PushHttpTransportPolicyTest PushDaoPreflightTest \
  SelfHostedPushWorkerPolicyTest SelfHostedPushSettingsTest SelfHostedPushSchedulerTest \
  PushRunSignalTest PushCapabilitiesParseTest PushEndpointPolicyTest PushWorkerGateTest PushRegistryTest; do
  ln -s "$repair_root/android/app/src/test/java/com/noop/push/$test.kt" "$repair_evidence/tests/$test.kt"
done
ln -s "$repair_root/android/app/src/test/java/com/noop/data/BleRawDurabilityTest.kt" "$repair_evidence/tests/BleRawDurabilityTest.kt"
cat > "$repair_evidence/tests.init.gradle" <<'GRADLE'
allprojects { project ->
  afterEvaluate {
    if (project.path == ':app') {
      project.android.sourceSets.test.java.setSrcDirs([
        System.getenv('NARA_BLE_ANDROID_TESTS'), project.file('src/test/java/com/noop/testing')])
    }
  }
}
GRADLE
git -C "$repair_root" rev-parse HEAD > "$repair_evidence/source-sha.txt"
git -C "$repair_root" diff --binary -- android > "$repair_evidence/android-source.patch"
cd "$repair_root/android"
# Room's side-effect export is needed by the real database tests; an incremental KSP round may
# omit that output after unrelated source edits. Reprocessing regenerates the actual schema.
NARA_BLE_ANDROID_TESTS="$repair_evidence/tests" ./gradlew \
  --init-script "$repair_evidence/tests.init.gradle" :app:testFullDebugUnitTest \
  --no-daemon -Pksp.incremental=false -Pkotlin.incremental=false "$@" 2>&1 | tee "$repair_evidence/android.log"
cp -R app/build/test-results/testFullDebugUnitTest "$repair_evidence/results"
printf 'BLE Android test evidence: %s\n' "$repair_evidence"
