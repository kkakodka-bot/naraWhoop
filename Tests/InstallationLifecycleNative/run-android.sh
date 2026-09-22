#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/installation-android.XXXXXX")"
mkdir -p "$evidence/tests"
# Compile actual app sources and this bounded fixture set. The ordinary full test compilation is
# reported separately; this harness does not change or remove its unrelated PPG tests.
for test in PushEnrollmentStoreTest PushEnrollmentClientTest PushEnrollmentManagerTest SelfHostedPushSettingsTest ServerScoreRepositoryIdentityTest; do
  ln -s "$root/android/app/src/test/java/com/noop/push/$test.kt" "$evidence/tests/$test.kt"
done
cat > "$evidence/lifecycle.init.gradle" <<'GRADLE'
allprojects { project ->
  afterEvaluate {
    if (project.path == ':app') {
      project.android.sourceSets.test.java.setSrcDirs([System.getenv('NARA_LIFECYCLE_ANDROID_TESTS')])
    }
  }
}
GRADLE
cd "$root/android"
NARA_LIFECYCLE_ANDROID_TESTS="$evidence/tests" ./gradlew --init-script "$evidence/lifecycle.init.gradle" \
  :app:testFullDebugUnitTest --no-daemon --rerun-tasks 2>&1 | tee "$evidence/android.log"
cp -R app/build/test-results/testFullDebugUnitTest "$evidence/results"
git diff --binary > "$evidence/source-diff.patch"
git rev-parse HEAD > "$evidence/source-sha.txt"
printf 'Android lifecycle evidence: %s\n' "$evidence"
