#!/usr/bin/env bash
# Build and start the persistent physiology-v2 JVM scoring container on the VPS.
# Run from laptop with repo checkout. Does not print secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DROPLET_ENV="${DROPLET_ENV:-${ROOT}/infra/vps/droplet.env}"

source "$DROPLET_ENV"
: "${DROPLET_IP:?}"
SSH_KEY="${SSH_KEY:-${ROOT}/infra/vps/keys/frwhoop_deploy}"
SSH_USER="${SSH_USER:-deploy}"
SSH_OPTIONS=(-i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]]; then
  echo "Refusing to deploy a dirty checkout" >&2
  exit 1
fi
RELEASE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
[[ "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid release SHA" >&2; exit 1; }
RUN_ID="${RELEASE_SHA}-$(date +%s)-$$"
REMOTE_BUILD="/opt/frwhoop/build/frwhoop-scoring/${RUN_ID}"

echo "========== sync exact scoring build context =========="
# Stream only committed bytes. Ignored local caches and stale remote build products must never be
# included in an image carrying the RELEASE_SHA provenance label.
git -C "$ROOT" archive "$RELEASE_SHA" android scoring-service \
  infra/vps/templates/docker-compose.scoring-override.yml \
  infra/vps/scripts/remote/verify-scoring-runtime.sh | \
  ssh "${SSH_OPTIONS[@]}" "${SSH_USER}@${DROPLET_IP}" \
    "mkdir -p '${REMOTE_BUILD}' && tar -xf - -C '${REMOTE_BUILD}'"

echo "========== configure scoring env + build image =========="
ssh "${SSH_OPTIONS[@]}" "${SSH_USER}@${DROPLET_IP}" bash -s -- "$RELEASE_SHA" "$RUN_ID" <<'REMOTE'
set -euo pipefail
RELEASE_SHA="$1"
RUN_ID="$2"
[[ "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ && "$RUN_ID" =~ ^${RELEASE_SHA}-[0-9]+-[0-9]+$ ]] || exit 1
BASE="/opt/frwhoop"
COMPOSE_DIR="${BASE}/scoring"
BUILD="${BASE}/build/frwhoop-scoring/${RUN_ID}"
SECRETS="${BASE}/secrets.env"
SCORING_ENV="${BASE}/scoring.env"
install -d -m 700 "$COMPOSE_DIR"
exec 9>"${COMPOSE_DIR}/deploy.lock"
flock -n 9 || { echo "Another scoring deployment is in progress" >&2; exit 1; }
install -m 600 "${BUILD}/infra/vps/templates/docker-compose.scoring-override.yml" "${COMPOSE_DIR}/docker-compose.yml"
install -m 700 "${BUILD}/infra/vps/scripts/remote/verify-scoring-runtime.sh" "${COMPOSE_DIR}/verify-scoring-runtime.sh"

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
previous_v2=()
previous_names=()
previous_running=()
cutover_started=false
accepted=false
had_env=false
cleanup() {
  local status=$?
  local candidate_id candidate_project
  trap - EXIT
  if [[ "$cutover_started" == true && "$accepted" != true ]]; then
    echo "Scoring acceptance failed; restoring the previous workers" >&2
    candidate_id="$(docker inspect -f '{{.Id}}' scoring-physiology-v2 2>/dev/null || true)"
    candidate_project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$candidate_id" 2>/dev/null || true)"
    if [[ -n "$candidate_id" && "$candidate_project" == "$compose_project" ]]; then
      docker rm -f "$candidate_id" >/dev/null 2>&1 || true
    fi
    if [[ "$had_env" == true ]]; then
      install -m 600 "${SCORING_ENV}.rollback" "$SCORING_ENV"
    else
      rm -f "$SCORING_ENV"
    fi
    for ((i=0; i<${#previous_v2[@]}; i++)); do
      docker rename "${previous_v2[$i]}" "${previous_names[$i]}" >/dev/null 2>&1 || true
      if [[ "${previous_running[$i]}" == true ]]; then
        docker start "${previous_v2[$i]}" >/dev/null || status=1
      fi
    done
  fi
  rm -f "${SCORING_ENV}.new" "${SCORING_ENV}.rollback"
  exit "$status"
}
trap cleanup EXIT
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
export SCORING_CPUS="${SCORING_CPUS:-2.0}"
export SCORING_MEMORY_LIMIT="${SCORING_MEMORY_LIMIT:-2g}"
# A fresh Compose identity prevents it from deleting retained rollback containers on redeploy.
compose_project="frwhoop-scoring-${RELEASE_SHA:0:12}-$(date +%s)-$$"
SCORING_ENV_FILE="${SCORING_ENV}.new" docker compose \
  -p "$compose_project" -f docker-compose.yml config --quiet

# Keep previous containers until the candidate proves that it polls and publishes. The old v1
# worker has a separate version and is never stopped or removed by this deployment.
is_project_v2() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | \
    awk -v endpoint="SUPABASE_URL=${SCORING_SUPABASE_URL}" \
      '$0 == "SCORING_ALGORITHM_VERSION=frwhoop-physiology-2" { version=1 }
       $0 == endpoint { project=1 } END { exit !(version && project) }'
}
mapfile -t previous_v2 < <(docker ps --no-trunc -aq | while read -r id; do
  if is_project_v2 "$id"; then
    printf '%s\n' "$id"
  fi
done)
fixed_name_id="$(docker inspect -f '{{.Id}}' scoring-physiology-v2 2>/dev/null || true)"
if [[ -n "$fixed_name_id" ]] && ! is_project_v2 "$fixed_name_id"; then
  echo "Refusing to replace scoring-physiology-v2 owned by another project or version" >&2
  exit 1
fi
for id in "${previous_v2[@]}"; do
  name="$(docker inspect -f '{{.Name}}' "$id")"
  previous_names+=("${name#/}")
  previous_running+=("$(docker inspect -f '{{.State.Running}}' "$id")")
done
if [[ -f "$SCORING_ENV" ]]; then
  install -m 600 "$SCORING_ENV" "${SCORING_ENV}.rollback"
  had_env=true
fi
# Renames and stops happen before setting the candidate's fixed name. Any error after this point
# restores the original env and all previously running v2 containers.
cutover_started=true
for ((i=0; i<${#previous_v2[@]}; i++)); do
  id="${previous_v2[$i]}"
  docker rename "$id" "${previous_names[$i]}-rollback-${id:0:12}"
  docker stop "$id" >/dev/null
done
install -m 600 "${SCORING_ENV}.new" "$SCORING_ENV"
rm -f "${SCORING_ENV}.new"
unset SCORING_ENV_FILE

docker compose -p "$compose_project" -f docker-compose.yml up -d --no-build scoring-physiology-v2

echo "========== scoring container status =========="
docker compose -p "$compose_project" -f docker-compose.yml ps scoring-physiology-v2
docker port scoring-physiology-v2 2>/dev/null || echo "OK: scoring has no published ports"
test "$(docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' scoring-physiology-v2)" = "$RELEASE_SHA"
mapfile -t running_v2 < <(docker ps --no-trunc -q | while read -r id; do
  if is_project_v2 "$id"; then
    printf '%s\n' "$id"
  fi
done)
test "${#running_v2[@]}" -eq 1
test "${running_v2[0]}" = "$(docker inspect -f '{{.Id}}' scoring-physiology-v2)"
bash "${COMPOSE_DIR}/verify-scoring-runtime.sh" "$RELEASE_SHA"
accepted=true
if ((${#previous_v2[@]})); then
  docker rm "${previous_v2[@]}" >/dev/null
fi
REMOTE

echo "Deploy complete: ${RELEASE_SHA}"
