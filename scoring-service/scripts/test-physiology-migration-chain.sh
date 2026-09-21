#!/usr/bin/env bash
set -euo pipefail
mode="${1:-fresh}"
[[ "$mode" == fresh || "$mode" == populated ]] || { printf 'Use fresh or populated\n' >&2; exit 2; }
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
docker inspect "$container" --format '{{json .HostConfig.NetworkMode}} {{json .NetworkSettings.Ports}} {{json .HostConfig.Binds}}' > "$evidence/isolation.txt"
docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -c \
  'select version(); select current_user,rolsuper from pg_roles where rolname=current_user;' > "$evidence/platform.txt"
docker exec "$container" sh -c 'sha256sum /workspace-migrations/*.sql' > "$evidence/migration-sha256.txt"
seeded=false
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  name="${migration##*/}"
  if [[ "$mode" == populated && "$seeded" == false && "$name" == 20260918010000* ]]; then
    docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -f /seed.sql > "$evidence/seed.log" 2>&1
    seeded=true
  fi
  if ! docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 --single-transaction \
    -f "/workspace-migrations/$name" > "$evidence/$name.log" 2>&1; then
    tail -40 "$evidence/$name.log"; exit 1
  fi
  printf 'PASS %s\n' "$name" >> "$evidence/results.txt"
  if [[ "$mode" == populated && "$name" == 20260918010000_physiology_revisions.sql ]]; then
    docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -f /steps.sql > "$evidence/steps.log" 2>&1
  fi
done
if [[ "$mode" == populated ]]; then
  docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -f /verify.sql > "$evidence/verify.log" 2>&1
fi
docker exec "$container" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 -c \
  "do \$\$ begin assert not exists(select 1 from physiology_feature_defaults where algorithm_version<>'frwhoop-server-1'); assert not public.physiology_feature_is_canonical('frwhoop-physiology-2','hrv'); assert not public.physiology_feature_is_canonical('frwhoop-physiology-2','sleep'); assert not public.physiology_feature_is_canonical('frwhoop-physiology-2','respiration'); end \$\$;" > "$evidence/promotion-defaults.log"
docker logs "$container" > "$evidence/platform-init.log" 2>&1
printf '%s migration chain passed; stopped disposable container and evidence retained: %s\n' "$mode" "$evidence"
