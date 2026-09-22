#!/usr/bin/env bash
# Phase 2 — full historical data copy from cloud Supabase to VPS (maintenance window).
# Requires: pg_dump/psql locally, cloud DB connection in repo .env, SSH to VPS.
# Copies public schema data + auth.users/auth.identities. Schema must already exist on VPS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SECRETS="${ROOT}/infra/vps/secrets.env"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"
CLOUD_ENV="${ROOT}/.env"
DUMP="/tmp/frwhoop-cloud-data-$(date +%Y%m%d%H%M%S).sql"

source "$DROPLET_ENV"
source "$SECRETS"
# shellcheck disable=SC1090
source "$CLOUD_ENV"

: "${SESSION_POOLER_STRING:?Set SESSION_POOLER_STRING in .env}"
: "${POSTGRES_PASSWORD:?Missing VPS POSTGRES_PASSWORD in secrets.env}"

echo "==> Dumping cloud public + auth data to ${DUMP}"
# Cloud is Postgres 17; use matching client (local pg_dump 16 aborts on version mismatch).
# NOTE: --table and --schema are ANDed — list auth tables in a second dump, not combined with --schema=public.
run_dump() {
  local outfile="$1"
  shift
  if docker run --rm postgres:17 pg_dump --version >/dev/null 2>&1; then
    docker run --rm -v /tmp:/tmp postgres:17 pg_dump "$SESSION_POOLER_STRING" "$@" \
      -f "/tmp/$(basename "$outfile")"
    mv "/tmp/$(basename "$outfile")" "$outfile"
  else
    pg_dump "$SESSION_POOLER_STRING" "$@" -f "$outfile"
  fi
}
PUBLIC_DUMP="/tmp/frwhoop-cloud-public-$(date +%s).sql"
AUTH_DUMP="/tmp/frwhoop-cloud-auth-$(date +%s).sql"
# Exclude cloud-only tables absent from VPS schema (e.g. retired device_ingest_tokens).
run_dump "$PUBLIC_DUMP" --data-only --no-owner --no-privileges --schema=public \
  --exclude-table=public.device_ingest_tokens
run_dump "$AUTH_DUMP" --data-only --no-owner --no-privileges --table=auth.users --table=auth.identities
cat "$PUBLIC_DUMP" "$AUTH_DUMP" >"$DUMP"
rm -f "$PUBLIC_DUMP" "$AUTH_DUMP"

echo "==> Dump size: $(du -h "$DUMP" | cut -f1)"

echo "==> Truncating VPS data before restore"
scp -i "$SSH_KEY" "${ROOT}/infra/vps/scripts/remote/12-truncate-for-restore.sh" \
  "deploy@${DROPLET_IP}:/tmp/12-truncate-for-restore.sh"
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" "bash /tmp/12-truncate-for-restore.sh"

echo "==> Copying dump to VPS"
scp -i "$SSH_KEY" "$DUMP" "deploy@${DROPLET_IP}:/tmp/frwhoop-cloud-data.sql"

echo "==> Restoring on VPS (disable triggers during load)"
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" bash -s <<'REMOTE'
set -euo pipefail
{
  echo 'SET session_replication_role = replica;'
  cat /tmp/frwhoop-cloud-data.sql
  echo 'SET session_replication_role = DEFAULT;'
} | docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1
REMOTE

echo "==> Reset sequences on VPS"
scp -i "$SSH_KEY" "${ROOT}/infra/vps/scripts/remote/13-reset-sequences.sql" \
  "deploy@${DROPLET_IP}:/tmp/13-reset-sequences.sql"
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" bash -s <<'REMOTE'
docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < /tmp/13-reset-sequences.sql
REMOTE

echo "==> Row-count verification"
CLOUD_COUNTS=$(psql "$SESSION_POOLER_STRING" -Atc \
  "SELECT relname||':'||n_live_tup FROM pg_stat_user_tables WHERE schemaname='public' AND n_live_tup>0 ORDER BY relname;")
VPS_COUNTS=$(ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
  "docker exec supabase-db psql -U postgres -d postgres -Atc \"SELECT relname||':'||n_live_tup FROM pg_stat_user_tables WHERE schemaname='public' AND n_live_tup>0 ORDER BY relname;\"")

CLOUD_TOKENS=$(psql "$SESSION_POOLER_STRING" -Atc "SELECT count(*) FROM noop_ingest_tokens;")
VPS_TOKENS=$(ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
  "docker exec supabase-db psql -U postgres -d postgres -Atc 'SELECT count(*) FROM noop_ingest_tokens;'")

echo "noop_ingest_tokens: cloud=${CLOUD_TOKENS} vps=${VPS_TOKENS}"
if [[ "$CLOUD_TOKENS" != "$VPS_TOKENS" ]]; then
  echo "WARN: ingest token count mismatch" >&2
fi

DIFF=$(diff <(echo "$CLOUD_COUNTS") <(echo "$VPS_COUNTS") || true)
if [[ -n "$DIFF" ]]; then
  echo "WARN: table count mismatch (pg_stat may lag; run ANALYZE if needed):"
  echo "$DIFF"
else
  echo "OK: public table row counts match"
fi

echo "Data copy finished at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
