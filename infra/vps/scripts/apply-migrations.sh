#!/usr/bin/env bash
# Apply an explicitly reviewed self-hosted lineage in catalog dependency order via psql.
set -euo pipefail

# This is the separately operated self-hosted stack, not the hosted scorer database.
# A matching timestamp is insufficient when historical streams contain collisions.
[[ "${1:-}" == --self-hosted-reviewed ]] || {
  printf '%s\n' 'NOT_READY: this legacy runner targets VPS-local supabase-db, not hosted scoring.' \
    'Export the actual target ledger and review scoring-migration-plan.mjs first.' \
    'Use --self-hosted-reviewed only for an explicitly authorized self-hosted plan.' >&2
  exit 3
}

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MIG_DIR="${ROOT}/supabase/migrations"
SECRETS="${ROOT}/infra/vps/secrets.env"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"

MIGRATION_FILES="$(node --input-type=module -e '
  const { pathToFileURL } = await import("node:url");
  const { MIGRATION_CATALOG, verifyMigrationSources } = await import(pathToFileURL(process.argv[1]));
  verifyMigrationSources(process.argv[2]);
  for (const row of MIGRATION_CATALOG) console.log(process.argv[2] + "/" + row.basename);
' "$ROOT/infra/vps/scripts/scoring-migration-catalog.mjs" "$MIG_DIR")"

[[ -f "$SECRETS" ]] || { echo "Run generate-secrets.sh first" >&2; exit 1; }
[[ -f "$DROPLET_ENV" ]] || { echo "Run provision-droplet.sh first" >&2; exit 1; }
# shellcheck disable=SC1090,SC1091
source "$DROPLET_ENV"
source "$SECRETS"

PGPASSWORD="$POSTGRES_PASSWORD"
export PGPASSWORD

REMOTE="deploy@${DROPLET_IP}"
PSQL="docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1"
SSH_ARGS=(-F /dev/null -i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes -o ConnectTimeout=10)

# Read and validate the complete target lineage before any database mutation. Native timestamp
# rows and unhashed historical rows need separate human reconciliation; this runner cannot
# rename them or use current files as evidence of what was previously executed.
plan_dir="$(mktemp -d "${TMPDIR:-/tmp}/scoring-migration-review.XXXXXX")"
ledger_exists="$(ssh "${SSH_ARGS[@]}" "$REMOTE" \
  "docker exec supabase-db psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -tAc \"SELECT to_regclass('supabase_migrations.schema_migrations') IS NOT NULL\"")"
case "$ledger_exists" in
  t)
    ssh "${SSH_ARGS[@]}" "$REMOTE" \
      "docker exec supabase-db psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -tAc \"SELECT coalesce(json_agg(json_build_object('version',version,'name',to_jsonb(m)->>'name','sha256',to_jsonb(m)->>'source_sha256') ORDER BY version),'[]'::json) FROM supabase_migrations.schema_migrations m\"" >"$plan_dir/ledger.json" ;;
  f) printf '[]\n' >"$plan_dir/ledger.json" ;;
  *) echo 'NOT_READY: target ledger inspection failed' >&2; exit 3 ;;
esac
node "$ROOT/infra/vps/scripts/scoring-migration-plan.mjs" "$MIG_DIR" "$plan_dir/ledger.json" >"$plan_dir/plan.json"
node --input-type=module -e '
  const fs=await import("node:fs"),rows=JSON.parse(fs.readFileSync(process.argv[1]));
  if(!rows.every(row=>/^[0-9]{14}_[a-z0-9_]+[.]sql$/.test(row.version)&&/^[0-9a-f]{64}$/.test(row.sha256))){
    console.error("NOT_READY: self-hosted runner requires reconciled full-basename/hash ledger rows");process.exit(3);
  }
' "$plan_dir/ledger.json"
echo "Reviewed target plan retained: $plan_dir"

ssh "${SSH_ARGS[@]}" "$REMOTE" \
  "docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1" <<'SQL'
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
  version text PRIMARY KEY,
  source_sha256 text,
  applied_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE supabase_migrations.schema_migrations ADD COLUMN IF NOT EXISTS source_sha256 text;
CREATE TABLE IF NOT EXISTS supabase_migrations.scoring_execution_receipts (
  basename text PRIMARY KEY,
  source_sha256 text NOT NULL,
  state text NOT NULL CHECK (state IN ('started','applied')),
  started_at timestamptz NOT NULL DEFAULT now()
);
SQL

unreconciled=$(ssh "${SSH_ARGS[@]}" "$REMOTE" \
  "docker exec supabase-db psql -U postgres -d postgres -tAc \"SELECT count(*) FROM supabase_migrations.schema_migrations WHERE source_sha256 IS NULL OR version !~ '^[0-9]{14}_[a-z0-9_]+[.]sql$'\"" | tr -d '[:space:]')
[[ "$unreconciled" == 0 ]] || {
  echo 'NOT_READY: reconcile historical full identities and source hashes before applying any migration' >&2
  exit 3
}

FILES=()
while IFS= read -r f; do
  FILES+=("$f")
done <<<"$MIGRATION_FILES"

for f in "${FILES[@]}"; do
  base=$(basename "$f")
  source_sha=$(node --input-type=module -e '
    const fs=await import("node:fs"),c=await import("node:crypto"),p=await import("node:path"),u=await import("node:url");
    const {MIGRATION_HASHES}=await import(u.pathToFileURL(process.argv[2]));
    const sha=c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex");
    if(sha!==MIGRATION_HASHES.get(p.basename(process.argv[1])))throw new Error("NOT_READY: migration source changed after plan");
    console.log(sha);
  ' "$f" "$ROOT/infra/vps/scripts/scoring-migration-catalog.mjs")
  applied=$(ssh "${SSH_ARGS[@]}" "$REMOTE" \
    "docker exec supabase-db psql -U postgres -d postgres -tAc \"SELECT source_sha256 FROM supabase_migrations.schema_migrations WHERE version='${base}'\"" \
    | tr -d '[:space:]')
  if [[ -n "$applied" ]]; then
    [[ "$applied" == "$source_sha" ]] || { echo "NOT_READY: applied hash differs for $base" >&2; exit 3; }
    echo "SKIP ${base}"
    continue
  fi
  # An interrupted execution remains a stop condition, never an invitation to replay SQL.
  ssh "${SSH_ARGS[@]}" "$REMOTE" \
    "docker exec supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \"INSERT INTO supabase_migrations.scoring_execution_receipts(basename,source_sha256,state) VALUES ('${base}','${source_sha}','started')\""
  echo "APPLY ${base}"
  ssh "${SSH_ARGS[@]}" "$REMOTE" "$PSQL" <"$f"
  ssh "${SSH_ARGS[@]}" "$REMOTE" \
    "docker exec supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \"BEGIN; INSERT INTO supabase_migrations.schema_migrations (version,source_sha256) VALUES ('${base}','${source_sha}'); UPDATE supabase_migrations.scoring_execution_receipts SET state='applied' WHERE basename='${base}' AND source_sha256='${source_sha}'; COMMIT;\""
done

echo "Migrations complete: ${#FILES[@]} files"
