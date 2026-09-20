#!/usr/bin/env bash
# Phase 2 acceptance checks — run from laptop after edge deploy + pg_cron config.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SECRETS="${ROOT}/infra/vps/secrets.env"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"

source "$DROPLET_ENV"
source "$SECRETS"

: "${API_DOMAIN:?Set API_DOMAIN}"
BASE_URL="https://${API_DOMAIN}"
PUSH_URL="${BASE_URL}/functions/v1/push"

echo "========== 1. deno tests (local) =========="
cd "${ROOT}/supabase/functions"
deno test --allow-all tests/

echo "========== 2. push-conformance against VPS =========="
: "${AUTH:?Set AUTH to a valid noop_ ingest token or user JWT (not service-role)}"
BASE_URL="${PUSH_URL}" PUSH_PATH= AUTH="${AUTH}" \
  node "${ROOT}/Tools/push-conformance/push-conformance.mjs"

echo "========== 3. unauthenticated push returns 401 =========="
code=$(curl -sS -o /dev/null -w '%{http_code}' "${PUSH_URL}" -H "apikey: ${ANON_KEY}")
[[ "$code" == "401" ]] && echo "OK: unauthenticated GET push -> ${code}" || { echo "FAIL: expected 401, got ${code}" >&2; exit 1; }

echo "========== 4. garbage bearer returns protocol unauthorized =========="
body=$(curl -sS "${PUSH_URL}" -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer garbage" -H "noop-push-accept-version: 1.1")
echo "$body" | grep -q unauthorized && echo "OK: garbage bearer rejected" || { echo "FAIL: ${body}" >&2; exit 1; }

echo "========== 5. monitor-fleet-push probes =========="
SUPABASE_URL="${BASE_URL}" SUPABASE_SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY}" \
  node "${ROOT}/Tools/monitor-fleet-push.mjs" --now

echo "========== 6. cron.job inventory on VPS =========="
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
  "docker exec supabase-db psql -U postgres -d postgres -c \"SELECT jobid, jobname, schedule FROM cron.job ORDER BY jobname;\""

echo "========== 7. function logs use internal gateway URL =========="
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
  "docker logs supabase-edge-functions 2>&1 | tail -20 | grep -E 'api-gw|kong:8000' && echo 'OK: internal gateway references in logs' || echo 'NOTE: no recent internal URL log lines (trigger a worker fire to populate)'"

echo "All Phase 2 automated acceptance checks finished."
