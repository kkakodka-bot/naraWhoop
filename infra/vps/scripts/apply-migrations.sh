#!/usr/bin/env bash
# Apply repo migrations in lexical order via psql. Run from deploy machine with repo checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MIG_DIR="${ROOT}/supabase/migrations"
SECRETS="${ROOT}/infra/vps/secrets.env"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"

[[ -f "$SECRETS" ]] || { echo "Run generate-secrets.sh first" >&2; exit 1; }
[[ -f "$DROPLET_ENV" ]] || { echo "Run provision-droplet.sh first" >&2; exit 1; }
# shellcheck disable=SC1090,SC1091
source "$DROPLET_ENV"
source "$SECRETS"

PGPASSWORD="$POSTGRES_PASSWORD"
export PGPASSWORD

REMOTE="deploy@${DROPLET_IP}"
PSQL="docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$REMOTE" \
  "docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1" <<'SQL'
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
SQL

FILES=()
while IFS= read -r f; do
  FILES+=("$f")
done < <(ls -1 "$MIG_DIR"/*.sql | sort)

for f in "${FILES[@]}"; do
  base=$(basename "$f")
  applied=$(ssh -i "$SSH_KEY" "$REMOTE" \
    "docker exec supabase-db psql -U postgres -d postgres -tAc \"SELECT 1 FROM supabase_migrations.schema_migrations WHERE version='${base}'\"" \
    | tr -d '[:space:]')
  if [[ "$applied" == "1" ]]; then
    echo "SKIP ${base}"
    continue
  fi
  echo "APPLY ${base}"
  ssh -i "$SSH_KEY" "$REMOTE" "$PSQL" <"$f"
  ssh -i "$SSH_KEY" "$REMOTE" \
    "docker exec supabase-db psql -U postgres -d postgres -c \"INSERT INTO supabase_migrations.schema_migrations (version) VALUES ('${base}')\""
done

echo "Migrations complete: ${#FILES[@]} files"
