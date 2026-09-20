#!/usr/bin/env bash
# Phase 2 — point pg_cron worker schedules at the internal Edge gateway + WORKER_SECRET.
# Run on the VPS as deploy (needs docker exec to supabase-db).
set -euo pipefail

BASE="/opt/frwhoop"
SECRETS="${BASE}/secrets.env"
if [[ ! -f "$SECRETS" ]]; then
  echo "Missing ${SECRETS}" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS"

: "${WORKER_SECRET:?WORKER_SECRET missing in secrets.env}"

# Internal gateway alias (Envoy/Kong) — must NOT hairpin through the public TLS endpoint.
BASE_URL="http://kong:8000"

docker exec supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "select vault.update_secret((select id from vault.secrets where name = 'edge_worker_secret'), '${WORKER_SECRET}');" \
  -c "select vault.update_secret((select id from vault.secrets where name = 'edge_worker_base_url'), '${BASE_URL}');" \
  -c "select public.http_post_worker('/functions/v1/retention-sweep') as retention_req_id;" \
  -c "select public.http_post_worker('/functions/v1/reconcile') as reconcile_req_id;" \
  -c "select public.http_post_worker('/functions/v1/account-deletion') as deletion_req_id;"

echo "==> cron.job inventory:"
docker exec supabase-db psql -U postgres -d postgres -c "SELECT jobid, jobname, schedule, command FROM cron.job ORDER BY jobname;"

echo "==> Recent cron.job_run_details (last 10):"
docker exec supabase-db psql -U postgres -d postgres -c \
  "SELECT jobid, status, return_message, start_time, end_time FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;"
