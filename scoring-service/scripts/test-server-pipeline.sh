#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/server-pipeline.XXXXXX")"
suffix="$(basename "$evidence" | tr '[:upper:]' '[:lower:]')"
database="nara-db-$suffix"
rest="nara-rest-$suffix"
network="nara-net-$suffix"
cleanup() {
  docker stop "$rest" "$database" >/dev/null 2>&1 || true
  docker network disconnect "$network" "$rest" >/dev/null 2>&1 || true
  docker network disconnect "$network" "$database" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  if [[ "${PIPELINE_TEST_REMOVE_CONTAINERS:-false}" == true ]]; then
    docker rm "$rest" "$database" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
printf 'Local pipeline evidence: %s\n' "$evidence"
database_mount=()
if [[ "${PIPELINE_TEST_BIND_DATA:-0}" == 1 ]]; then
  mkdir -p "$evidence/database-data"
  database_mount=(--mount "type=bind,source=${PIPELINE_TEST_DATABASE_DATA:-$evidence/database-data},target=/var/lib/postgresql/data")
fi
pg_storage=()
if [[ "${PIPELINE_TEST_PG_TMPFS:-false}" == true ]]; then
  pg_storage=(--tmpfs /var/lib/postgresql/data:rw,size=768m)
fi
if (( ${#database_mount[@]} > 0 && ${#pg_storage[@]} > 0 )); then
  printf 'PIPELINE_TEST_BIND_DATA and PIPELINE_TEST_PG_TMPFS are mutually exclusive.\n' >&2
  exit 2
fi
docker network create "$network" > "$evidence/network.txt"
docker run --detach --name "$database" --network "$network" --network-alias database \
  "${pg_storage[@]}" \
  "${database_mount[@]}" \
  --label nara.test=server-pipeline --memory 2g --cpus 2 \
  --log-opt max-size=20m --log-opt max-file=2 \
  -p 127.0.0.1::5432 -e POSTGRES_PASSWORD=isolated-pipeline-only \
  public.ecr.aws/supabase/postgres:17.6.1.127@sha256:be60aee15997daca475b710b734bc6bfe52cd544dcd7e9fd2ff58210b6747d83 > "$evidence/database.txt"
ready=false
for attempt in {1..60}; do
  if docker exec -e PGPASSWORD=isolated-pipeline-only "$database" psql -h 127.0.0.1 -U supabase_admin -d postgres -Atc 'select 1' >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { docker logs "$database"; exit 1; }
docker run --rm --network "$network" \
  -e GOTRUE_DB_DRIVER=postgres \
  -e GOTRUE_DB_DATABASE_URL=postgres://supabase_admin:isolated-pipeline-only@database:5432/postgres \
  -e GOTRUE_SITE_URL=http://localhost -e API_EXTERNAL_URL=http://localhost \
  -e GOTRUE_JWT_SECRET=isolated-pipeline-jwt-secret-never-used-outside-tests \
  public.ecr.aws/supabase/gotrue:v2.197.0 auth migrate > "$evidence/platform-auth-migrations.log" 2>&1 \
  || { tail -30 "$evidence/platform-auth-migrations.log"; exit 1; }
docker cp "$repo_dir/supabase/migrations" "$database:/migrations"
node --input-type=module -e 'const {MIGRATION_CATALOG,verifyMigrationSources}=await import(process.argv[1]); verifyMigrationSources(process.argv[2]); for(const row of MIGRATION_CATALOG) console.log(row.basename);' \
  "file://$repo_dir/infra/vps/scripts/scoring-migration-catalog.mjs" "$repo_dir/supabase/migrations" > "$evidence/migration-order.txt"
while IFS= read -r migration; do
  docker exec "$database" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 --single-transaction \
    -f "/migrations/$migration" > "$evidence/$migration.log" 2>&1 || { tail -40 "$evidence/$migration.log"; exit 1; }
done < "$evidence/migration-order.txt"
docker run --detach --name "$rest" --network "$network" --label nara.test=server-pipeline \
  --log-opt max-size=20m --log-opt max-file=2 \
  -p 127.0.0.1::3000 -e PGRST_DB_URI=postgres://supabase_admin:isolated-pipeline-only@database:5432/postgres \
  -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
  -e PGRST_JWT_SECRET=isolated-pipeline-jwt-secret-never-used-outside-tests \
  public.ecr.aws/supabase/postgrest:v14.5 > "$evidence/rest.txt"
export PIPELINE_TEST_DATABASE_CONTAINER="$database"
rest_address="$(docker port "$rest" 3000/tcp)"
database_address="$(docker port "$database" 5432/tcp)"
export PIPELINE_TEST_REST_URL="http://$rest_address"
export PIPELINE_TEST_DATABASE_URL="postgresql://supabase_admin:isolated-pipeline-only@$database_address/postgres"
export PIPELINE_TEST_OUTPUT="$evidence/decoders"
cd "$repo_dir/supabase/functions"
if [[ "${PIPELINE_TEST_MULTIUSER:-0}" == 1 ]]; then
  npx --yes deno test --allow-all --filter "${PIPELINE_TEST_FILTER:-}" tests/multiuser_sql_test.ts tests/multiuser_worker_sql_test.ts 2>&1 | tee "$evidence/multiuser.log"
  git rev-parse HEAD > "$evidence/source-sha.txt"
  git diff --binary > "$evidence/source-diff.patch"
  printf 'Fully migrated local multi-user evidence: %s\n' "$evidence"
  exit 0
fi
npx --yes deno test --allow-all tests/server_pipeline_sql_test.ts 2>&1 | tee "$evidence/edge.log"
cd "$repo_dir"
bash Tools/server-score-contract/run-mobile-decoders.sh "$PIPELINE_TEST_OUTPUT" 2>&1 | tee "$evidence/mobile.log"
swift_decoder="$(swift build --package-path Tools/server-score-contract/swift --show-bin-path)/DecodeContract"
node Tools/server-score-contract/test-canonical-runners.mjs "$PIPELINE_TEST_OUTPUT" "$swift_decoder" \
  "$repo_dir/Tools/server-score-contract/android/build/install/server-score-decoder-contract/bin/server-score-decoder-contract" \
  2>&1 | tee "$evidence/canonical-mutations.log"
git rev-parse HEAD > "$evidence/source-sha.txt"
printf 'SQL -> actual Edge -> Swift/Kotlin decoder tests passed. Evidence: %s\n' "$evidence"
