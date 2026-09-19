#!/usr/bin/env bash
# Build and start the persistent physiology-v2 JVM scoring container on the VPS.
# Run from laptop with repo checkout. Does not print secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"
REMOTE_BUILD="/opt/frwhoop/build/frwhoop-scoring"
COMPOSE_DIR="/opt/frwhoop/supabase-docker/docker"

source "$DROPLET_ENV"
: "${DROPLET_IP:?}"
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]]; then
  echo "Refusing to deploy a dirty checkout" >&2
  exit 1
fi
RELEASE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
[[ "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid release SHA" >&2; exit 1; }

echo "========== sync exact scoring build context =========="
# Stream only committed bytes. Ignored local caches and stale remote build products must never be
# included in an image carrying the RELEASE_SHA provenance label.
git -C "$ROOT" archive "$RELEASE_SHA" android scoring-service | \
  ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
    "rm -rf '${REMOTE_BUILD}' && mkdir -p '${REMOTE_BUILD}' && tar -xf - -C '${REMOTE_BUILD}'"

echo "========== install compose override =========="
scp -i "$SSH_KEY" \
  "${ROOT}/infra/vps/templates/docker-compose.scoring-override.yml" \
  "deploy@${DROPLET_IP}:${COMPOSE_DIR}/docker-compose.scoring.yml"

echo "========== configure scoring env + build image =========="
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" bash -s -- "$RELEASE_SHA" <<'REMOTE'
set -euo pipefail
RELEASE_SHA="$1"
BASE="/opt/frwhoop"
COMPOSE_DIR="${BASE}/supabase-docker/docker"
BUILD="${BASE}/build/frwhoop-scoring"
SECRETS="${BASE}/secrets.env"
SCORING_ENV="${BASE}/scoring.env"

# shellcheck disable=SC1090
source "$SECRETS"
: "${SCORING_DATABASE_URL:?Set the hosted Supabase pooler URL in /opt/frwhoop/secrets.env}"
: "${SCORING_SUPABASE_URL:?Set the hosted Supabase PostgREST URL in /opt/frwhoop/secrets.env}"
: "${SCORING_INGEST_SECRET:?Set the hosted project's SCORING_INGEST_SECRET in /opt/frwhoop/secrets.env}"
: "${SCORING_SUPABASE_SERVICE_ROLE_KEY:?Set the hosted project's SCORING_SUPABASE_SERVICE_ROLE_KEY in /opt/frwhoop/secrets.env}"

case "$SCORING_DATABASE_URL" in
  *"@db:"*|*"//db:"*|*localhost*|*127.0.0.1*) echo "Refusing a local scoring database destination" >&2; exit 1 ;;
esac
case "$SCORING_SUPABASE_URL" in
  https://*/rest/v1) ;;
  *) echo "SCORING_SUPABASE_URL must be an HTTPS /rest/v1 endpoint" >&2; exit 1 ;;
esac

umask 077
trap 'rm -f "${SCORING_ENV}.new"' EXIT
{
  printf 'DATABASE_URL=%s\n' "$SCORING_DATABASE_URL"
  printf 'INGEST_SECRET=%s\n' "$SCORING_INGEST_SECRET"
  printf 'SUPABASE_URL=%s\n' "$SCORING_SUPABASE_URL"
  printf 'SUPABASE_SERVICE_ROLE_KEY=%s\n' "$SCORING_SUPABASE_SERVICE_ROLE_KEY"
  printf 'SCORING_POLL_SECONDS=%s\n' "${SCORING_POLL_SECONDS:-8}"
} >"${SCORING_ENV}.new"
unset REPLAY_USER_ID REPLAY_DAY REPLAY_DEVICE_ID

cd "$BUILD"
docker build --build-arg "RELEASE_SHA=${RELEASE_SHA}" \
  -t "frwhoop/scoring-service:${RELEASE_SHA}" -f scoring-service/Dockerfile .

# Check the actual candidate image's hosted database, migrations, ingest secret and REST key
# without writing any scores. A failed check leaves the current workers and their env file intact.
docker run --rm --env-file "${SCORING_ENV}.new" --env-file "${BASE}/b2.env" \
  "frwhoop/scoring-service:${RELEASE_SHA}" --check-config

cd "$COMPOSE_DIR"
export SCORING_IMAGE_TAG="$RELEASE_SHA"
SCORING_ENV_FILE="${SCORING_ENV}.new" docker compose \
  -f docker-compose.yml -f docker-compose.caddy.yml -f docker-compose.envoy.yml \
  -f docker-compose.scoring.yml config --quiet
install -m 600 "${SCORING_ENV}.new" "$SCORING_ENV"
rm -f "${SCORING_ENV}.new"
unset SCORING_ENV_FILE

# A former deployment may still be running under the old scoring-shadow or scoring name. Remove
# only physiology-v2 containers; the separately versioned v1 rollback worker must remain intact.
mapfile -t previous_v2 < <(docker ps --no-trunc -aq | while read -r id; do
  if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" 2>/dev/null | \
      grep -Fxq 'SCORING_ALGORITHM_VERSION=frwhoop-physiology-2'; then
    printf '%s\n' "$id"
  fi
done)
if ((${#previous_v2[@]})); then
  docker rm -f "${previous_v2[@]}"
fi

docker compose -f docker-compose.yml -f docker-compose.caddy.yml -f docker-compose.envoy.yml \
  -f docker-compose.scoring.yml up -d --no-build scoring-physiology-v2

echo "========== scoring container status =========="
docker compose -f docker-compose.yml -f docker-compose.caddy.yml -f docker-compose.envoy.yml \
  -f docker-compose.scoring.yml ps scoring-physiology-v2
docker port scoring-physiology-v2 2>/dev/null || echo "OK: scoring has no published ports"
test "$(docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' scoring-physiology-v2)" = "$RELEASE_SHA"
mapfile -t running_v2 < <(docker ps --no-trunc -q | while read -r id; do
  if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" | \
      grep -Fxq 'SCORING_ALGORITHM_VERSION=frwhoop-physiology-2'; then
    printf '%s\n' "$id"
  fi
done)
test "${#running_v2[@]}" -eq 1
test "${running_v2[0]}" = "$(docker inspect -f '{{.Id}}' scoring-physiology-v2)"
REMOTE

echo "Deploy complete: ${RELEASE_SHA}"
