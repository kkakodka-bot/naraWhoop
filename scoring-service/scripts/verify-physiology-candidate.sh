#!/usr/bin/env bash
# Run from a committed candidate. Logs stay outside the repository; no deployment or device install.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_dir"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || {
  printf 'Commit all candidate sources before exact-head verification\n' >&2; exit 2;
}
: "${PHYSIOLOGY_BUILD_ROOT:?Set an external scratch directory}"
: "${PHYSIOLOGY_PYTHON:?Set the pinned inference environment Python executable}"
: "${PHYSIOLOGY_PACKAGE_CACHE:?Set the Xcode package checkout directory}"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/physiology-exact-head.XXXXXX")"
candidate="$(git rev-parse HEAD)"
candidate_base="${PHYSIOLOGY_PR_BASE:-28a6b32e0140507dc75ece23286db4c814bbd5bc}"
git merge-base --is-ancestor "$candidate_base" "$candidate" || { printf 'Candidate does not include the recorded PR base\n' >&2; exit 2; }
printf '%s\n' "$candidate" > "$evidence/commit.txt"
git rev-parse "$candidate_base" > "$evidence/pr-base.txt"
git status --porcelain=v1 > "$evidence/initial-status.txt"
printf 'Evidence: %s\n' "$evidence"
failed=0
require_exact_candidate() {
  [[ "$(git rev-parse HEAD)" == "$candidate" && -z "$(git status --porcelain --untracked-files=all)" ]] || {
    printf 'Candidate changed during verification\n' >&2; exit 2;
  }
}
run() {
  name="$1"; shift
  require_exact_candidate
  printf '%s: running\n' "$name"
  printf '%q ' "$@" > "$evidence/$name.command"
  if "$@" > "$evidence/$name.log" 2>&1; then result=PASS; else result=FAIL; failed=1; fi
  require_exact_candidate
  printf '%s\t%s\n' "$name" "$result" | tee -a "$evidence/results.tsv"
}
gates=("${@:-all}")
if [[ "${gates[0]}" == all ]]; then
  gates=(swift kernel manifests database runtime-preflight migrations edge python checkpoint macos ios-simulator iphone iphone-device whitespace)
fi
for gate in "${gates[@]}"; do
  case "$gate" in
    swift)
      for package in StrandAnalytics WhoopProtocol WhoopStore NoopPush; do
        run "swift-$package" swift test --package-path "Packages/$package" \
          --scratch-path "$PHYSIOLOGY_BUILD_ROOT/swift-$package" --jobs 2
      done ;;
    kernel)
      run kernel bash -c 'cd "$1/scoring-service" && ./gradlew --no-daemon --max-workers=2 :analytics-kernel:test :service:test :service:installDist --rerun-tasks && mkdir -p "$2/kernel-junit" "$2/service-junit" && cp "$1/scoring-service/analytics-kernel/build/test-results/test/"TEST-*.xml "$2/kernel-junit/" && cp "$1/scoring-service/service/build/test-results/test/"TEST-*.xml "$2/service-junit/"' _ "$repo_dir" "$evidence" ;;
    manifests)
      run manifests bash -c 'cd "$1/scoring-service" && ./gradlew --no-daemon --max-workers=2 :service:installDist --rerun-tasks && java -cp "$1/scoring-service/service/build/install/service/lib/*" com.frwhoop.scoring.scoring.ProductionAlgorithmManifest > "$2/manifests.json" && cmp "$2/manifests.json" "$1/docs/physiology-v2/candidate-algorithm-manifests.json"' _ "$repo_dir" "$evidence" ;;
    database) run database bash scoring-service/scripts/test-physiology-queue.sh ;;
    runtime-preflight) run runtime-preflight bash scoring-service/scripts/test-runtime-preflight.sh ;;
    migrations)
      run migration-fresh bash scoring-service/scripts/test-physiology-migration-chain.sh fresh
      run migration-populated bash scoring-service/scripts/test-physiology-migration-chain.sh populated ;;
    edge) run edge bash -c 'cd "$1/supabase/functions" && npx --yes deno test --allow-all tests/' _ "$repo_dir" ;;
    python)
      run python-inference "$PHYSIOLOGY_PYTHON" -m unittest discover -s scoring-service/inference/tests -v
      run python-reference "$PHYSIOLOGY_PYTHON" -m unittest discover -s Tools/physiology-bench/tests -v
      run python-deployment "$PHYSIOLOGY_PYTHON" -m unittest discover -s infra/vps/tests -p 'test_*.py' -v ;;
    checkpoint)
      : "${PHYSIOLOGY_WAV2SLEEP_PYTHON:?Set the pinned released-checkpoint environment Python executable}"
      : "${PHYSIOLOGY_WAV2SLEEP_SOURCE:?Set the pinned wav2sleep source checkout}"
      : "${PHYSIOLOGY_CHECKPOINT_ROOT:?Set the verified released checkpoint root}"
      run checkpoint env PYTHONPATH="$repo_dir/scoring-service/inference:$PHYSIOLOGY_WAV2SLEEP_SOURCE/src" \
        HF_HUB_OFFLINE=1 OMP_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1 \
        "$PHYSIOLOGY_WAV2SLEEP_PYTHON" -m physiology_inference.checkpoint_smoke \
        --checkpoint-root "$PHYSIOLOGY_CHECKPOINT_ROOT" --epochs 20 --output "$evidence/checkpoint-smoke.json"
      run synthetic-probe-tests env PYTHONPATH="$repo_dir/scoring-service/inference:$repo_dir/Tools/physiology-bench:$PHYSIOLOGY_WAV2SLEEP_SOURCE/src" \
        HF_HUB_OFFLINE=1 OMP_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1 WAV2SLEEP_CHECKPOINT_ROOT="$PHYSIOLOGY_CHECKPOINT_ROOT" \
        "$PHYSIOLOGY_WAV2SLEEP_PYTHON" -m unittest discover -s Tools/physiology-bench/tests -p test_checkpoint_probe.py -v ;;
    macos|ios-simulator|iphone|iphone-device)
      run "generate-$gate" xcodegen generate
      common=(-project Strand.xcodeproj -clonedSourcePackagesDirPath "$PHYSIOLOGY_PACKAGE_CACHE"
        -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile)
      if [[ "$gate" == macos ]]; then
        run macos xcodebuild "${common[@]}" -scheme Strand -destination platform=macOS \
          -derivedDataPath "$PHYSIOLOGY_BUILD_ROOT/xcode-macos" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
          CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO test
      else
        destination='generic/platform=iOS'
        [[ "$gate" != ios-simulator ]] || destination='generic/platform=iOS Simulator'
        if [[ "$gate" == iphone-device ]]; then
          : "${PHYSIOLOGY_IPHONE_UDID:?Set an available paired iPhone UDID; this builds but does not install}"
          destination="platform=iOS,id=$PHYSIOLOGY_IPHONE_UDID"
        fi
        run "$gate" xcodebuild "${common[@]}" -scheme NOOPiOS -destination "$destination" -destination-timeout 20 \
          -derivedDataPath "$PHYSIOLOGY_BUILD_ROOT/xcode-$gate" CODE_SIGNING_ALLOWED=NO build
      fi ;;
    whitespace) run whitespace git diff --check "$candidate_base...HEAD" ;;
    *) printf 'Unknown gate: %s\n' "$gate" >&2; exit 2 ;;
  esac
done
printf 'Exact-head evidence: %s\n' "$evidence"
exit "$failed"
