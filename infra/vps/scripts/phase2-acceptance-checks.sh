#!/usr/bin/env bash
# Phase 2 acceptance checks — run from laptop after edge deploy + pg_cron config.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SECRETS="${ROOT}/infra/vps/secrets.env"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"

: "${SYNC_ACCEPTANCE_EVIDENCE:?NOT_READY: captured deployment/canary/device evidence is required}"
node "${ROOT}/infra/vps/scripts/verify-sync-evidence.mjs" "$SYNC_ACCEPTANCE_EVIDENCE"
[[ "${ALLOW_ACCEPTANCE_WRITES:-}" == yes ]] || {
  echo "NOT_READY: conformance sends test records; explicit ALLOW_ACCEPTANCE_WRITES=yes is required" >&2
  exit 3
}

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
echo "$body" | grep -q unauthorized && echo "OK: garbage bearer rejected" || { echo "FAIL: expected unauthorized response" >&2; exit 1; }

echo "========== 5. monitor-fleet-push probes =========="
SUPABASE_URL="${BASE_URL}" SUPABASE_SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY}" \
  node "${ROOT}/Tools/monitor-fleet-push.mjs" --now

echo "========== 6. cron.job inventory on VPS =========="
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
  "docker exec supabase-db psql -U postgres -d postgres -c \"SELECT jobid, jobname, schedule FROM cron.job ORDER BY jobname;\""

echo "========== 7. recent successful cron executions =========="
cron_ok=$(ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
  "docker exec supabase-db psql -U postgres -d postgres -tAc \"select count(*) from cron.job j where j.active and exists(select 1 from cron.job_run_details r where r.jobid=j.jobid and r.status='succeeded' and r.end_time>now()-interval '15 minutes')\"" | tr -d '[:space:]')
[[ "$cron_ok" =~ ^[0-9]+$ && "$cron_ok" -gt 0 ]] || { echo "NOT_READY: no recent successful cron work" >&2; exit 3; }

echo "Phase 2 checks passed for supplied evidence and executed checks."
