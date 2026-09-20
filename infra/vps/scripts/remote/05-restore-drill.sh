#!/usr/bin/env bash
# Restore drill: replay latest pg_dump into scratch DB; verify public table counts match.
set -euo pipefail

BASE="/opt/frwhoop"
BACKUP_DIR="${BASE}/backups"
LATEST=$(ls -1t "${BACKUP_DIR}"/postgres-*.dump 2>/dev/null | head -1)

if [[ -z "$LATEST" ]]; then
  echo "No pg_dump found in ${BACKUP_DIR}" >&2
  exit 1
fi

SCRATCH="frwhoop_restore_drill"
echo "Using dump: ${LATEST}"

docker exec supabase-db psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS ${SCRATCH};"
docker exec supabase-db psql -U postgres -d postgres -c "CREATE DATABASE ${SCRATCH};"

set +e
cat "$LATEST" | docker exec -i supabase-db pg_restore -U postgres -d "$SCRATCH" \
  --no-owner --no-privileges \
  --exclude-schema=cron --exclude-schema=vault
restore_status=$?
set -e

echo "=== live public table counts ==="
docker exec supabase-db psql -U postgres -d postgres -Atc \
  "SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname='public' ORDER BY relname;"

echo "=== scratch public table counts ==="
docker exec supabase-db psql -U postgres -d "$SCRATCH" -Atc \
  "SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname='public' ORDER BY relname;"

LIVE=$(docker exec supabase-db psql -U postgres -d postgres -Atc \
  "SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname='public' ORDER BY relname;")
SCRATCH_COUNTS=$(docker exec supabase-db psql -U postgres -d "$SCRATCH" -Atc \
  "SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname='public' ORDER BY relname;")

docker exec supabase-db psql -U postgres -d postgres -c "DROP DATABASE ${SCRATCH};"

if [[ "$LIVE" != "$SCRATCH_COUNTS" ]]; then
  echo "FAIL: public table counts differ (pg_restore exit=${restore_status})" >&2
  exit 1
fi

echo "Restore drill complete — public table counts match (pg_restore exit=${restore_status})."
