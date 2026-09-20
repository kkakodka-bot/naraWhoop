#!/usr/bin/env bash
# Phase 3 acceptance checks — Kotlin twin extraction + scoring service.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SECRETS="${ROOT}/infra/vps/secrets.env"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"

source "$DROPLET_ENV" 2>/dev/null || true
export JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk@17 2>/dev/null)/libexec/openjdk.jdk/Contents/Home}"

echo "========== 1a. scoped HRV/sleep parity gate (extracted JVM module) =========="
cd "${ROOT}/scoring-service"
./gradlew :analytics-kernel:test --no-daemon

echo "========== 1b. CurrentHrvTest on Android (classify kernel failure) =========="
cd "${ROOT}/android"
./gradlew testFullDebugUnitTest --tests com.noop.analytics.CurrentHrvTest --no-daemon

echo "========== 1c. full analytics oracle (android app module, unmodified) =========="
./gradlew compileFullDebugKotlin testFullDebugUnitTest --tests "com.noop.analytics.*" --no-daemon

echo "========== 2. scoring service tests + installDist =========="
cd "${ROOT}/scoring-service"
./gradlew :service:test :service:installDist --no-daemon

echo "========== 3. import scan =========="
if rg '^import (android\.|androidx\.|com\.noop\.(data|ingest))' "${ROOT}/scoring-service/" \
  | grep -v 'analytics-kernel/src/main/kotlin/android/content/SharedPreferences.kt' \
  | grep -v 'analytics-kernel/src/main/kotlin/com/noop/data/' \
  | grep -v 'Baselines.kt.*android.content.SharedPreferences'; then
  echo "FAIL: forbidden imports in scoring-service" >&2
  exit 1
fi
echo "OK: import scan clean"

echo "========== 4. physiology-v2 queue and heartbeat migrations present =========="
test -f "${ROOT}/supabase/migrations/20260918100000_physiology_independent_work.sql"
grep -q physiology_service_heartbeats "${ROOT}/supabase/migrations/20260918100000_physiology_independent_work.sql"
grep -q physiology_work_items "${ROOT}/supabase/migrations/20260918100000_physiology_independent_work.sql"
grep -q engine_publish_physiology "${ROOT}/supabase/migrations/20260918100000_physiology_independent_work.sql"
echo "OK: physiology-v2 migration file present"

if [[ -f "$SECRETS" ]]; then
  # shellcheck disable=SC1090
  source "$SECRETS"
fi

if [[ -n "${DROPLET_IP:-}" && -f "$SSH_KEY" ]]; then
  echo "========== 5–7. exact physiology-v2 container and advancing hosted heartbeat =========="
  RELEASE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
  ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" bash -s -- "$RELEASE_SHA" \
    < "${ROOT}/infra/vps/scripts/remote/verify-scoring-runtime.sh"
else
  echo "NOT_READY: VPS runtime acceptance was not run (no DROPLET_IP / SSH key)." >&2
  exit 2
fi

echo "Phase 3 local checks and read-only VPS runtime acceptance passed."
