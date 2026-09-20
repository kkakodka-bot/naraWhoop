#!/usr/bin/env bash
# Phase 3 acceptance checks — Kotlin twin extraction + scoring service.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"
LOCAL_ONLY=false
case "${1:-}" in
  --local-only) LOCAL_ONLY=true ;;
  '') ;;
  *) echo 'Usage: phase3-acceptance-checks.sh [--local-only]' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || exit 2

DROPLET_IP=""; SSH_PORT=22
if [[ "$LOCAL_ONLY" == false ]]; then
  [[ -f "$DROPLET_ENV" && -f "$SSH_KEY" ]] || {
    echo 'NOT_READY: VPS target or deploy key missing; use --local-only for local checks only' >&2; exit 3;
  }
  DEPLOY_TARGET="$(python3 "${ROOT}/infra/vps/scripts/read-deploy-target.py" "$DROPLET_ENV")" || {
    echo 'NOT_READY: invalid VPS target configuration' >&2; exit 3;
  }
  IFS='|' read -r DROPLET_IP SSH_PORT <<<"$DEPLOY_TARGET"
fi
SSH_ARGS=(-F /dev/null -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes
  -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o PreferredAuthentications=publickey
  -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -p "$SSH_PORT")
export JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk@17 2>/dev/null)/libexec/openjdk.jdk/Contents/Home}"

echo "========== 1a. scoped HRV/sleep parity gate (extracted JVM module) =========="
cd "${ROOT}/scoring-service"
./gradlew :analytics-kernel:test --no-daemon

echo "========== 2. scoring service tests + installDist =========="
cd "${ROOT}/scoring-service"
./gradlew :service:test :service:installDist --no-daemon

echo "========== 3. import scan =========="
./gradlew :analytics-kernel:verifyKernelScope --no-daemon
python3 "${ROOT}/infra/vps/scripts/check-scoring-imports.py" "$ROOT"
echo "OK: import scan clean"

echo "========== 4. physiology-v2 queue and heartbeat migrations present =========="
test -f "${ROOT}/supabase/migrations/20260918100000_physiology_independent_work.sql"
grep -q physiology_service_heartbeats "${ROOT}/supabase/migrations/20260918100000_physiology_independent_work.sql"
grep -q physiology_work_items "${ROOT}/supabase/migrations/20260918100000_physiology_independent_work.sql"
grep -q engine_publish_physiology "${ROOT}/supabase/migrations/20260918100000_physiology_independent_work.sql"
echo "OK: physiology-v2 migration file present"

if [[ "$LOCAL_ONLY" == false ]]; then
  echo "========== 5–7. exact physiology-v2 container and advancing hosted heartbeat =========="
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] || {
    echo 'Cannot accept an exact release from a dirty checkout' >&2; exit 1;
  }
  RELEASE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
  if ! {
    cat "${ROOT}/infra/vps/scripts/scoring-progress.sh"
    cat <<'REMOTE'
set -euo pipefail
release_sha="$1"
# shellcheck disable=SC1091
source /opt/frwhoop/secrets.env
: "${SCORING_DATABASE_URL:?}"
: "${SCORING_SUPABASE_URL:?}"
candidate_environment="$(timeout 12 docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' scoring-physiology-v2)"
SCORING_WORKER_INSTANCE_ID="$(scoring_environment_value "$candidate_environment" SCORING_WORKER_INSTANCE_ID)"
SCORING_WORKER_SOURCE_REVISION="$release_sha"
unset candidate_environment
scoring_assert_candidate "$release_sha"
scoring_wait_for_progress "$release_sha"
REMOTE
  } | ssh "${SSH_ARGS[@]}" "deploy@${DROPLET_IP}" bash -s -- "$RELEASE_SHA"; then
    echo 'NOT_READY: VPS identity/configuration/progress acceptance failed' >&2; exit 3
  fi
else
  echo 'LOCAL_ONLY_PASS: local checks passed; VPS deployment acceptance NOT_VERIFIED'
  exit 0
fi

echo 'PASS: local checks and exact VPS deployment progress verified'
