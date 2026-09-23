#!/usr/bin/env bash
set -euo pipefail
umask 077
root="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:?A fresh absolute external evidence directory is required}"
[[ "$output" == /* && ! -e "$output" && "$output" != "$root" && "$output" != "$root/"* ]] || exit 2
mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
[[ "$output" != "$root" && "$output" != "$root/"* ]] || exit 2
fingerprint() {
  git -C "$root" ls-files -z Packages/NoopPush/Sources Packages/NoopPush/Package.swift \
    supabase/functions/_shared supabase/migrations infra/vps/scripts/scoring-migration-catalog.mjs \
    scoring-service/scripts/test-server-pipeline.sh | while IFS= read -r -d '' source; do
      shasum -a 256 "$root/$source"
    done
  shasum -a 256 "$root/Packages/NoopPush/Tests/NoopPushTests/PushFreshHistoryTests.swift" \
    "$root/supabase/functions/tests/intake_consumer_sql_test.ts" "$root/Tests/ServerFixtureNative/run-fresh-history.sh"
}
git -C "$root" rev-parse HEAD > "$output/source-head.txt"
git -C "$root" diff --binary HEAD > "$output/source-diff.patch"
git -C "$root" status --porcelain=v1 --untracked-files=all > "$output/source-status.txt"
fingerprint > "$output/source-before.sha256"
NOOP_FRESH_HISTORY_FIXTURES="$output/swift-fixture" swift test --package-path "$root/Packages/NoopPush" \
  --scratch-path "$output/swift-build" --jobs 4 --filter PushFreshHistoryTests/testExportActualSwiftFreshHistoryPairs \
  > "$output/swift-export.log" 2>&1
[[ -s "$output/swift-fixture/fresh-history.json" ]]
PIPELINE_TEST_INTAKE=1 PIPELINE_TEST_FRESH_HISTORY_FIXTURE="$output/swift-fixture/fresh-history.json" \
  TMPDIR="$output" bash "$root/scoring-service/scripts/test-server-pipeline.sh" > "$output/intake-pipeline.log" 2>&1
fingerprint > "$output/source-after.sha256"
cmp -s "$output/source-before.sha256" "$output/source-after.sha256"
shasum -a 256 "$output/swift-fixture/fresh-history.json" "$output/swift-export.log" "$output/intake-pipeline.log" > "$output/evidence.sha256"
printf 'PASS: actual Swift fresh/history pairs through fully migrated intake: %s\n' "$output"
