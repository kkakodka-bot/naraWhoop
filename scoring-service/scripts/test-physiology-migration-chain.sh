#!/usr/bin/env bash
set -euo pipefail
mode="${1:-fresh}"
[[ "$mode" == fresh || "$mode" == populated || "$mode" == hosted-upgrade ]] || {
  printf 'Use fresh, populated, or hosted-upgrade\n' >&2; exit 2;
}
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/physiology-chain-$mode.XXXXXX")"
container="physiology-chain-$(basename "$evidence" | tr '[:upper:]' '[:lower:]')"
image="public.ecr.aws/supabase/postgres:17.6.1.127@sha256:be60aee15997daca475b710b734bc6bfe52cd544dcd7e9fd2ff58210b6747d83"
cleanup() { docker stop "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run --detach --name "$container" --network none --memory 2g --cpus 2 \
  --env POSTGRES_PASSWORD=disposable-local-test-only "$image" > "$evidence/container-id.txt"
ready=false
for attempt in {1..60}; do
  if docker exec --env PGPASSWORD=disposable-local-test-only "$container" \
    psql -h 127.0.0.1 -U supabase_admin -d postgres -Atc 'select 1' > /dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { docker logs "$container"; exit 1; }
docker cp "$repo_dir/supabase/migrations" "$container:/workspace-migrations"
docker cp "$repo_dir/scoring-service/service/src/test/resources/physiology_chain_seed.sql" "$container:/seed.sql"
docker cp "$repo_dir/scoring-service/service/src/test/resources/physiology_chain_verify.sql" "$container:/verify.sql"
docker cp "$repo_dir/scoring-service/service/src/test/resources/physiology_chain_steps.sql" "$container:/steps.sql"
docker cp "$repo_dir/scoring-service/service/src/test/resources/release_hosted_upgrade_seed.sql" "$container:/release-upgrade-seed.sql"
docker cp "$repo_dir/scoring-service/service/src/test/resources/release_hosted_upgrade_verify.sql" "$container:/release-upgrade-verify.sql"
docker cp "$repo_dir/Tools/release/verify-integrated-schema.sql" "$container:/integrated-schema-verify.sql"
docker inspect "$container" --format '{{json .HostConfig.NetworkMode}} {{json .NetworkSettings.Ports}} {{json .HostConfig.Binds}}' > "$evidence/isolation.txt"
docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -c \
  'select version(); select current_user,rolsuper from pg_roles where rolname=current_user;' > "$evidence/platform.txt"
docker exec "$container" sh -c 'sha256sum /workspace-migrations/*.sql' > "$evidence/migration-sha256.txt"
docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -c \
  'create schema if not exists supabase_migrations; create table supabase_migrations.scoring_source_identities (basename text primary key, sha256 text not null);' > "$evidence/ledger-init.log"
catalog_rows="$(node --input-type=module -e '
  const { pathToFileURL } = await import("node:url");
  const { MIGRATION_CATALOG, verifyMigrationSources } = await import(pathToFileURL(process.argv[1]));
  verifyMigrationSources(process.argv[2]);
  for (const row of MIGRATION_CATALOG) console.log(row.basename + "|" + row.sha256);
' "$repo_dir/infra/vps/scripts/scoring-migration-catalog.mjs" "$repo_dir/supabase/migrations")"
seeded=false
while IFS='|' read -r name source_sha; do
  if [[ "$mode" == hosted-upgrade && "$name" == 20260922120000* ]]; then
    docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -c \
      'select release_upgrade_fixture.seed_previous_compute_dispositions();' > "$evidence/previous-disposition-seed.log" 2>&1
  fi
  if [[ "$mode" == hosted-upgrade && "$seeded" == false && "$name" == 20260921110000* ]]; then
    docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 \
      -f /release-upgrade-seed.sql > "$evidence/upgrade-seed.log" 2>&1
    docker exec "$container" psql -U postgres -d postgres -X -qAt -v ON_ERROR_STOP=1 -c \
      "select jsonb_build_object('full_identity_rows',(select count(*) from supabase_migrations.scoring_source_identities),'next_identity','$name','fixture_users',2,'fixture_devices',2)::text;" \
      > "$evidence/pre-upgrade-state.json"
    [[ "$(node -p "require('$evidence/pre-upgrade-state.json').full_identity_rows")" == 117 ]] || {
      printf 'Hosted upgrade boundary is not the attested 117-identity baseline.\n' >&2; exit 1;
    }
    # Exercise the production atomic migration/receipt wrapper against a local
    # predecessor, including the timestamp-collision ledger that must not change.
    docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -c \
      "create table if not exists supabase_migrations.schema_migrations(version text primary key,name text);
       insert into supabase_migrations.schema_migrations(version,name)
       select distinct on (left(basename,14)) left(basename,14),substring(basename from 16)
       from supabase_migrations.scoring_source_identities order by left(basename,14),basename;" \
      > "$evidence/native-ledger-seed.log"
    docker exec "$container" psql -U postgres -d postgres -X -qAt -v ON_ERROR_STOP=1 -c \
      "select coalesce(jsonb_agg(jsonb_build_object('version',version,'name',name) order by version),'[]')
       from supabase_migrations.schema_migrations;" > "$evidence/native-ledger-before.json"
    seeded=true
  fi
  if [[ "$mode" == populated && "$seeded" == false && "$name" == 20260918010000* ]]; then
    docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -f /seed.sql > "$evidence/seed.log" 2>&1
    seeded=true
  fi
  if [[ "$mode" == hosted-upgrade && "$seeded" == true ]]; then
    docker exec "$container" psql -U postgres -d postgres -X -qAt -v ON_ERROR_STOP=1 -c \
      "select coalesce(jsonb_agg(jsonb_build_object('stableIdentity',basename,'sha256',sha256) order by basename),'[]')
       from supabase_migrations.scoring_source_identities;" > "$evidence/pre-apply-full-identity.json"
    node --input-type=module - "$repo_dir" "$evidence" "$name" "$source_sha" > "$evidence/wrapped-$name" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const [root,evidence,identity,sha256]=process.argv.slice(2);
const {migrationApplySQL,PENDING_IDENTITIES}=await import(pathToFileURL(path.join(root,'Tools/release/hosted-migration-release.mjs')));
const index=PENDING_IDENTITIES.indexOf(identity);
if(index<0) throw new Error('not a reviewed forward migration');
process.stdout.write(migrationApplySQL({
  migrationBytes:fs.readFileSync(path.join(root,'supabase/migrations',identity)),
  migration:{stableIdentity:identity,sha256,applyOrdinal:index+1},
  expectedNativeLedger:JSON.parse(fs.readFileSync(path.join(evidence,'native-ledger-before.json'))),
  expectedFullIdentityLedger:JSON.parse(fs.readFileSync(path.join(evidence,'pre-apply-full-identity.json'))),
}));
NODE
    docker cp "$evidence/wrapped-$name" "$container:/wrapped-migration.sql"
    if ! docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 \
      -f /wrapped-migration.sql > "$evidence/$name.log" 2>&1; then
      tail -40 "$evidence/$name.log"; exit 1
    fi
  else
    if ! docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 --single-transaction \
      -f "/workspace-migrations/$name" > "$evidence/$name.log" 2>&1; then
      tail -40 "$evidence/$name.log"; exit 1
    fi
    docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -c \
      "insert into supabase_migrations.scoring_source_identities values ('$name','$source_sha');" >> "$evidence/ledger-init.log"
  fi
  printf 'PASS %s\n' "$name" >> "$evidence/results.txt"
  if [[ "$mode" == populated && "$name" == 20260918010000_physiology_revisions.sql ]]; then
    docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -f /steps.sql > "$evidence/steps.log" 2>&1
  fi
done <<<"$catalog_rows"
docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -Atc \
  "select json_agg(json_build_object('version',basename,'sha256',sha256) order by basename) from supabase_migrations.scoring_source_identities;" > "$evidence/applied-ledger.json"
node "$repo_dir/infra/vps/scripts/scoring-migration-plan.mjs" "$repo_dir/supabase/migrations" \
  "$evidence/applied-ledger.json" > "$evidence/lineage-plan.json"
node -e 'const p=require(process.argv[1]); if(p.pending.length || p.applied.length !== Number(process.argv[2])) process.exit(1);' \
  "$evidence/lineage-plan.json" "$(printf '%s\n' "$catalog_rows" | wc -l | tr -d ' ')"
if [[ "$mode" == populated ]]; then
  docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -f /verify.sql > "$evidence/verify.log" 2>&1
fi
if [[ "$mode" == hosted-upgrade ]]; then
  [[ "$seeded" == true ]] || { printf 'Hosted upgrade boundary was not reached.\n' >&2; exit 1; }
  docker exec "$container" psql -U postgres -d postgres -X -qAt -v ON_ERROR_STOP=1 \
    -f /release-upgrade-verify.sql > "$evidence/upgrade-verification.json"
  docker exec "$container" psql -U postgres -d postgres -X -qAt -v ON_ERROR_STOP=1 -c \
    "select coalesce(jsonb_agg(jsonb_build_object('version',version,'name',name) order by version),'[]')
     from supabase_migrations.schema_migrations;" > "$evidence/native-ledger-after.json"
  cmp "$evidence/native-ledger-before.json" "$evidence/native-ledger-after.json"
fi
docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -c \
  "do \$\$ begin assert not exists(select 1 from physiology_feature_defaults where algorithm_version<>'frwhoop-server-1'); assert not public.physiology_feature_is_canonical('frwhoop-physiology-2','hrv'); assert not public.physiology_feature_is_canonical('frwhoop-physiology-2','sleep'); assert not public.physiology_feature_is_canonical('frwhoop-physiology-2','respiration'); end \$\$;" > "$evidence/promotion-defaults.log"
docker exec "$container" psql -U postgres -d postgres -X -qAt -v ON_ERROR_STOP=1 \
  -f /integrated-schema-verify.sql > "$evidence/integrated-schema-verification.json"
docker logs "$container" > "$evidence/platform-init.log" 2>&1
printf '%s migration chain passed; stopped disposable container and evidence retained: %s\n' "$mode" "$evidence"
