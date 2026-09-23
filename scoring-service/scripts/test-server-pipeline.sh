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
rest="nara-rest-$suffix"
auth="nara-auth-$suffix"
network="nara-net-$suffix"
cleanup() {
  docker logs "$auth" > "$evidence/auth-service.log" 2>&1 || true
  docker stop "$auth" "$rest" "$database" >/dev/null 2>&1 || true
  docker network disconnect "$network" "$auth" >/dev/null 2>&1 || true
  docker network disconnect "$network" "$rest" >/dev/null 2>&1 || true
  docker network disconnect "$network" "$database" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  if [[ "${PIPELINE_TEST_REMOVE_CONTAINERS:-false}" == true ]]; then
    docker rm "$auth" "$rest" "$database" >/dev/null 2>&1 || true
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
  -e GOTRUE_DB_DATABASE_URL=postgres://supabase_admin:isolated-pipeline-only@database:5432/postgres?search_path=auth \
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
docker run --detach --name "$auth" --network "$network" --label nara.test=server-pipeline \
  --log-opt max-size=20m --log-opt max-file=2 \
  -p 127.0.0.1::9999 -e GOTRUE_API_HOST=0.0.0.0 -e GOTRUE_API_PORT=9999 \
  -e GOTRUE_DB_DRIVER=postgres \
  -e GOTRUE_DB_DATABASE_URL=postgres://supabase_admin:isolated-pipeline-only@database:5432/postgres?search_path=auth \
  -e GOTRUE_SITE_URL=http://localhost -e API_EXTERNAL_URL=http://localhost \
  -e GOTRUE_JWT_SECRET=isolated-pipeline-jwt-secret-never-used-outside-tests \
  -e GOTRUE_JWT_AUD=authenticated -e GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated \
  -e GOTRUE_EXTERNAL_EMAIL_ENABLED=true -e GOTRUE_MAILER_AUTOCONFIRM=true \
  public.ecr.aws/supabase/gotrue:v2.197.0@sha256:1736a63078f5922b198c4cbe50f80ab9a2d3b54fe8b7b6cfb2e9dc5dbbc12c6b > "$evidence/auth.txt"
docker run --detach --name "$rest" --network "$network" --label nara.test=server-pipeline \
  --log-opt max-size=20m --log-opt max-file=2 \
  -p 127.0.0.1::3000 -e PGRST_DB_URI=postgres://supabase_admin:isolated-pipeline-only@database:5432/postgres \
  -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
  -e PGRST_JWT_SECRET=isolated-pipeline-jwt-secret-never-used-outside-tests \
  public.ecr.aws/supabase/postgrest:v14.5 > "$evidence/rest.txt"
export PIPELINE_TEST_DATABASE_CONTAINER="$database"
rest_address="$(docker port "$rest" 3000/tcp)"
database_address="$(docker port "$database" 5432/tcp)"
auth_address="$(docker port "$auth" 9999/tcp)"
export PIPELINE_TEST_REST_URL="http://$rest_address"
export PIPELINE_TEST_AUTH_URL="http://$auth_address"
export PIPELINE_TEST_DATABASE_URL="postgresql://supabase_admin:isolated-pipeline-only@$database_address/postgres"
export PIPELINE_TEST_OUTPUT="$evidence/decoders"
cd "$repo_dir/supabase/functions"
if [[ -n "${PIPELINE_TEST_REAL_RECORDING:-}" ]]; then
  # The entire output directory is private: real recording values appear in worker/API/native
  # artifacts. Only the explicit sanitized trace may be copied into a shared handoff.
  chmod 700 "$evidence"
  npx --yes deno test --allow-all tests/real_recording_replay_sql_test.ts > "$evidence/private-recording.log" 2>&1
  cd "$repo_dir"
  bash Tools/server-score-contract/run-mobile-decoders.sh "$PIPELINE_TEST_OUTPUT" > "$evidence/private-mobile.log" 2>&1
  git -C "$repo_dir" diff --binary HEAD > "$evidence/source-diff.patch"
  git -C "$repo_dir" status --porcelain=v1 --untracked-files=all > "$evidence/source-status-final.txt"
  printf 'Private actual scalar replay and both native decoders passed; sanitized trace only: %s/decoders/real_recording_input_to_result_trace.sanitized.json\n' "$evidence"
  exit 0
fi
if [[ "${PIPELINE_TEST_INTAKE:-0}" == 1 ]]; then
  npx --yes deno test --allow-all tests/intake_consumer_sql_test.ts 2>&1 | tee "$evidence/intake.log"
  git -C "$repo_dir" diff --binary HEAD > "$evidence/source-diff.patch"
  git -C "$repo_dir" status --porcelain=v1 --untracked-files=all > "$evidence/source-status-final.txt"
  printf 'Fully migrated actual intake consumer evidence: %s\n' "$evidence"
  exit 0
fi
if [[ "${PIPELINE_TEST_MULTIUSER:-0}" == 1 ]]; then
  npx --yes deno test --allow-all --filter "${PIPELINE_TEST_FILTER:-}" tests/multiuser_sql_test.ts tests/multiuser_worker_sql_test.ts 2>&1 | tee "$evidence/multiuser.log"
  git --no-replace-objects -C "$repo_dir" rev-parse --verify HEAD > "$evidence/source-sha.txt"
  git --no-replace-objects -C "$repo_dir" rev-parse --verify 'HEAD^{tree}' > "$evidence/source-tree.txt"
  git -C "$repo_dir" status --porcelain=v1 --untracked-files=all > "$evidence/source-status-final.txt"
  git -C "$repo_dir" diff --binary HEAD > "$evidence/source-diff.patch"
  git -C "$repo_dir" ls-files --others --exclude-standard > "$evidence/source-untracked.txt"
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
git --no-replace-objects -C "$repo_dir" rev-parse --verify HEAD > "$evidence/source-sha.txt"
git --no-replace-objects -C "$repo_dir" rev-parse --verify 'HEAD^{tree}' > "$evidence/source-tree.txt"
git -C "$repo_dir" status --porcelain=v1 --untracked-files=all > "$evidence/source-status-final.txt"
printf 'SQL -> actual Edge -> Swift/Kotlin decoder tests passed. Evidence: %s\n' "$evidence"
