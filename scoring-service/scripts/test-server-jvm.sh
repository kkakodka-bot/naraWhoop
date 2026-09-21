#!/usr/bin/env bash
set -euo pipefail

service_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$service_dir/.." && pwd)"
evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/server-jvm.XXXXXX")"
export W4_SWIFT_CURRENT_EXPORT_DIR="$evidence_dir/w4-whole-day-current-v2"
export W4_SWIFT_DAY_FIXTURE_DIR="$W4_SWIFT_CURRENT_EXPORT_DIR"
export W3_TEST_ARTIFACTS="$evidence_dir/context-artifacts"
export PHYSIOLOGY_ALL_JVM_TESTS=1
git -C "$repo_dir" rev-parse --verify HEAD > "$evidence_dir/source-sha.txt"

preserve_results() {
  for component in analytics-kernel service; do
    for report in "$service_dir/$component/build/test-results/test/"TEST-*.xml; do
      [[ -f "$report" ]] || continue
      mkdir -p "$evidence_dir/$component-test-results"
      cp "$report" "$evidence_dir/$component-test-results/"
    done
  done
}

printf 'Local JVM/Swift/PostgreSQL evidence: %s\n' "$evidence_dir"
# The write-once exporter checks real current-source hashes and retains the historical corpora.
# This fails closed if the Swift package or its explicit unsupported-capability controls fail.
if ! swift test --package-path "$repo_dir/Packages/StrandAnalytics" \
  --filter WholeDaySwiftCurrentCorpusTests > "$evidence_dir/swift-export.log" 2>&1; then
  tail -60 "$evidence_dir/swift-export.log"
  exit 1
fi
[[ -s "$W4_SWIFT_DAY_FIXTURE_DIR/manifest.json" ]] || { printf 'Swift manifest missing\n' >&2; exit 1; }
if ! bash "$service_dir/scripts/test-physiology-queue.sh" > "$evidence_dir/jvm-postgres.log" 2>&1; then
  preserve_results
  tail -80 "$evidence_dir/jvm-postgres.log"
  exit 1
fi
preserve_results
cp "$service_dir/service/build/resources/main/scoring-source-revision.txt" "$evidence_dir/jvm-packaged-source-sha.txt"
if ! cmp -s "$evidence_dir/source-sha.txt" "$evidence_dir/jvm-packaged-source-sha.txt"; then
  printf 'JVM source identity is dirty, unavailable, or changed during verification\n' >&2
  exit 1
fi
printf 'JVM source inputs match committed revision\n' > "$evidence_dir/jvm-source-cleanliness.txt"
tail -8 "$evidence_dir/jvm-postgres.log"
printf 'Clean JVM tests and installDist passed with a newly exported actual-Swift corpus: %s\n' "$evidence_dir"
