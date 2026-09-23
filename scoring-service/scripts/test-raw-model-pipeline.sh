#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
source_sha="$(git --no-replace-objects -C "$repo_dir" rev-parse --verify HEAD)"
source_tree="$(git --no-replace-objects -C "$repo_dir" rev-parse --verify 'HEAD^{tree}')"
source_status="$(git -C "$repo_dir" status --porcelain=v1 --untracked-files=all)"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/server-pipeline.XXXXXX")"
if [[ -n "$source_status" ]]; then
  printf '%s\n' "$source_status" > "$evidence/source-status.txt"
else
  : > "$evidence/source-status.txt"
fi
source_status_sha256="$(node -e 'const fs=require("fs"),c=require("crypto"); process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$evidence/source-status.txt")"
source_status_line_count="$(awk 'END { print NR + 0 }' "$evidence/source-status.txt")"
source_clean=false
[[ -s "$evidence/source-status.txt" ]] || source_clean=true
export PIPELINE_TEST_SOURCE_SHA="$source_sha"
export PIPELINE_TEST_SOURCE_TREE="$source_tree"
export PIPELINE_TEST_SOURCE_CLEAN="$source_clean"
export PIPELINE_TEST_SOURCE_STATUS_SHA256="$source_status_sha256"
export PIPELINE_TEST_SOURCE_STATUS_LINE_COUNT="$source_status_line_count"
node - "$source_sha" "$source_tree" "$source_clean" "$source_status_sha256" "$source_status_line_count" > "$evidence/source-receipt.json" <<'NODE'
const [commitSha, treeSha, clean, statusSha256, statusLineCount] = process.argv.slice(2);
process.stdout.write(JSON.stringify({
  schemaVersion: 1,
  commitSha,
  treeSha,
  worktreeClean: clean === "true",
  statusSha256,
  statusLineCount: Number(statusLineCount),
}, null, 2) + "\n");
NODE
suffix="$(basename "$evidence" | tr '[:upper:]' '[:lower:]')"
database="nara-db-$suffix"
network="nara-net-$suffix"
cleanup() {
  docker stop "$database" >/dev/null 2>&1 || true
  docker network disconnect "$network" "$database" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  if [[ "${PIPELINE_TEST_REMOVE_CONTAINERS:-false}" == true ]]; then
    docker rm "$database" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
printf 'Local raw model evidence: %s\n' "$evidence"
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
  public.ecr.aws/supabase/gotrue:v2.197.0@sha256:1736a63078f5922b198c4cbe50f80ab9a2d3b54fe8b7b6cfb2e9dc5dbbc12c6b auth migrate > "$evidence/platform-auth-migrations.log" 2>&1 \
  || { tail -30 "$evidence/platform-auth-migrations.log"; exit 1; }
docker cp "$repo_dir/supabase/migrations" "$database:/migrations"
node --input-type=module -e 'const {MIGRATION_CATALOG,verifyMigrationSources}=await import(process.argv[1]); verifyMigrationSources(process.argv[2]); for(const row of MIGRATION_CATALOG) console.log(row.basename);' \
  "file://$repo_dir/infra/vps/scripts/scoring-migration-catalog.mjs" "$repo_dir/supabase/migrations" > "$evidence/migration-order.txt"
while IFS= read -r migration; do
  docker exec "$database" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 --single-transaction \
    -f "/migrations/$migration" > "$evidence/$migration.log" 2>&1 || { tail -40 "$evidence/$migration.log"; exit 1; }
done < "$evidence/migration-order.txt"
# The cloned database retains every hosted migration and real Auth schema.
# This JVM-only gate migrates Auth schema; it does not start or test Auth HTTP.
# Only this freshly created, labelled disposable instance is quiesced for the clone.
docker exec "$database" psql -U supabase_admin -d template1 -X -v ON_ERROR_STOP=1 -c "alter database postgres with allow_connections false;"
docker exec "$database" psql -U supabase_admin -d template1 -X -v ON_ERROR_STOP=1 -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='postgres';"
docker exec "$database" createdb -U supabase_admin --maintenance-db template1 -T postgres physiology_queue_test
docker exec "$database" psql -U supabase_admin -d template1 -X -v ON_ERROR_STOP=1 -c "alter database postgres with allow_connections true;"
database_address="$(docker port "$database" 5432/tcp)"
export PHYSIOLOGY_TEST_DATABASE_URL="postgresql://supabase_admin:isolated-pipeline-only@$database_address/physiology_queue_test"
docker exec "$database" psql -U supabase_admin -d physiology_queue_test -X -v ON_ERROR_STOP=1 -c "insert into internal.app_secrets(name,value) values('ingest','test') on conflict(name) do update set value=excluded.value;"
cd "$repo_dir/scoring-service"
./gradlew :service:test --tests com.frwhoop.scoring.RawSignalCatalogueIntegrationTest --tests com.frwhoop.scoring.VerifiedModelJobAssemblerTest --tests com.frwhoop.scoring.PhysiologyShadowRunnerTest --tests com.frwhoop.scoring.PhysiologyModelQueueIntegrationTest --tests com.frwhoop.scoring.ScoringInputGateIntegrationTest --no-daemon --rerun-tasks
cp -R service/build/test-results/test "$evidence/jvm-test-results"
git -C "$repo_dir" diff --binary HEAD > "$evidence/source-diff.patch"
git -C "$repo_dir" status --porcelain=v1 --untracked-files=all > "$evidence/source-status-final.txt"
printf 'Full-chain raw model integration evidence: %s\n' "$evidence"
