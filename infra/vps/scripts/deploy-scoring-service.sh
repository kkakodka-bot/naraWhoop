#!/usr/bin/env bash
# Build and start the persistent physiology-v2 JVM scoring container on the VPS.
# Run from laptop with repo checkout. Does not print secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"

DEPLOY_TARGET="$(python3 "${ROOT}/infra/vps/scripts/read-deploy-target.py" "$DROPLET_ENV")"
IFS='|' read -r DROPLET_IP SSH_PORT <<<"$DEPLOY_TARGET"
SSH_ARGS=(-F /dev/null -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes
  -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o PreferredAuthentications=publickey
  -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -p "$SSH_PORT")
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]]; then
  echo "Refusing to deploy a dirty checkout" >&2
  exit 1
fi
RELEASE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
[[ "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid release SHA" >&2; exit 1; }
# RELEASE_SHA is validated above; only this literal is expanded into the remote command.
# shellcheck disable=SC2029
REMOTE_BUILD="$(ssh "${SSH_ARGS[@]}" "deploy@${DROPLET_IP}" \
  "mkdir -p /opt/frwhoop/build/frwhoop-scoring && mktemp -d '/opt/frwhoop/build/frwhoop-scoring/${RELEASE_SHA}.XXXXXX'")"
[[ "$REMOTE_BUILD" =~ ^/opt/frwhoop/build/frwhoop-scoring/${RELEASE_SHA}\.[a-zA-Z0-9]{6}$ ]] || exit 1

echo "========== sync exact scoring build context =========="
# Stream only committed bytes. Ignored local caches and stale remote build products must never be
# included in an image carrying the RELEASE_SHA provenance label.
# REMOTE_BUILD passed the exact path/character whitelist above.
# shellcheck disable=SC2029
git -C "$ROOT" archive "$RELEASE_SHA" android scoring-service \
  infra/vps/scripts/scoring-progress.sh infra/vps/scripts/remote/verify-scoring-runtime.sh \
  infra/vps/templates/docker-compose.scoring-override.yml | \
  ssh "${SSH_ARGS[@]}" "deploy@${DROPLET_IP}" \
    "tar -xf - -C '${REMOTE_BUILD}'"

echo "========== configure scoring env + build image =========="
ssh "${SSH_ARGS[@]}" "deploy@${DROPLET_IP}" bash -s -- "$RELEASE_SHA" "$REMOTE_BUILD" <<'REMOTE'
set -euo pipefail
RELEASE_SHA="$1"
BASE="/opt/frwhoop"
COMPOSE_DIR="${BASE}/scoring"
BUILD="$2"
SECRETS="${BASE}/secrets.env"
SCORING_ENV="${BASE}/scoring.env"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
CANDIDATE_COMPOSE="${BUILD}/infra/vps/templates/docker-compose.scoring-override.yml"
# shellcheck disable=SC1091
source "${BUILD}/infra/vps/scripts/scoring-progress.sh"
install -d -m 700 "$COMPOSE_DIR"
exec 9>"${BASE}/scoring-deploy.lock"
flock -n 9 || { echo 'Another scoring deployment is active' >&2; exit 1; }

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
rollback_dir="$(mktemp -d "${BASE}/scoring-rollback.XXXXXX")"
candidate_env="${rollback_dir}/candidate.env"
old_env=false; old_compose=false; cutover=false; accepted=false; candidate_attempted=false
declare -a previous_v2=() previous_names=() previous_running=() stopped=() renamed=()
[[ ! -f "$SCORING_ENV" ]] || { cp -p "$SCORING_ENV" "${rollback_dir}/scoring.env"; old_env=true; }
[[ ! -f "$COMPOSE_FILE" ]] || { cp -p "$COMPOSE_FILE" "${rollback_dir}/docker-compose.scoring.yml"; old_compose=true; }
finish() {
  local result=$? index actual_name candidate_id candidate_project candidate_quiet=true rollback_failed=false
  trap - EXIT
  if [[ "$cutover" == true && "$accepted" == false ]]; then
    # Prior containers are retained by ID; Compose must not recreate/delete their labels.
    if [[ "$candidate_attempted" == true ]]; then
      if candidate_id="$(timeout 12 docker ps --no-trunc -aq --filter 'name=^/scoring-physiology-v2$')"; then
        if [[ -n "$candidate_id" ]]; then
          candidate_project="$(timeout 12 docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$candidate_id")" || candidate_project=""
          if [[ "$candidate_project" != "$compose_project" ]]; then
            # Another invocation may have acquired the fixed name while Compose failed.
            # Never stop/remove it, or start a competing prior scorer with unknown ownership.
            candidate_quiet=false; rollback_failed=true
          elif ! timeout 40 docker rm -f "$candidate_id" >/dev/null; then
            rollback_failed=true
            timeout 40 docker stop --time 30 "$candidate_id" >/dev/null || candidate_quiet=false
          fi
        fi
      else candidate_quiet=false; rollback_failed=true; fi
    fi
    if [[ "$old_env" == true ]]; then
      install -m 600 "${rollback_dir}/scoring.env" "$SCORING_ENV" || rollback_failed=true
    else rm -f "$SCORING_ENV"; fi
    if [[ "$old_compose" == true ]]; then
      cp -p "${rollback_dir}/docker-compose.scoring.yml" "$COMPOSE_FILE" || rollback_failed=true
    else rm -f "$COMPOSE_FILE"; fi
    for ((index=0; index<${#previous_v2[@]}; index++)); do
      if [[ "${renamed[index]}" == true ]]; then
        actual_name="$(timeout 12 docker inspect -f '{{.Name}}' "${previous_v2[index]}")" || rollback_failed=true
        if [[ "$actual_name" != "/${previous_names[index]}" ]]; then
          timeout 12 docker rename "${previous_v2[index]}" "${previous_names[index]}" >/dev/null || rollback_failed=true
        fi
      fi
      if [[ "$candidate_quiet" == true && "${stopped[index]}" == true && "${previous_running[index]}" == true ]]; then
        timeout 40 docker start "${previous_v2[index]}" >/dev/null || rollback_failed=true
      fi
    done
    if [[ "$rollback_failed" == true ]]; then
      echo "Rollback incomplete; preserved recovery evidence: ${rollback_dir}" >&2
    else echo 'Candidate rejected; previous worker and configuration restored' >&2; fi
  fi
  rm -f "$candidate_env"
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SCORING_WORKER_INSTANCE_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
SCORING_WORKER_SOURCE_REVISION="$RELEASE_SHA"
scoring_identity_valid
{
  printf 'DATABASE_URL=%s\n' "$SCORING_DATABASE_URL"
  printf 'INGEST_SECRET=%s\n' "$SCORING_INGEST_SECRET"
  printf 'SUPABASE_URL=%s\n' "$SCORING_SUPABASE_URL"
  printf 'SUPABASE_SERVICE_ROLE_KEY=%s\n' "$SCORING_SUPABASE_SERVICE_ROLE_KEY"
  printf 'SCORING_POLL_SECONDS=%s\n' "${SCORING_POLL_SECONDS:-8}"
  printf 'SCORING_WORKER_INSTANCE_ID=%s\n' "$SCORING_WORKER_INSTANCE_ID"
  printf 'SCORING_WORKER_SOURCE_REVISION=%s\n' "$SCORING_WORKER_SOURCE_REVISION"
} >"$candidate_env"
unset REPLAY_USER_ID REPLAY_DAY REPLAY_DEVICE_ID

cd "$BUILD"
docker build --build-arg "RELEASE_SHA=${RELEASE_SHA}" \
  -t "frwhoop/scoring-service:${RELEASE_SHA}" -f scoring-service/Dockerfile .

# Check the actual candidate image's hosted database, migrations, ingest secret and REST key
# without writing any scores. A failed check leaves the current workers and their env file intact.
docker run --rm --env-file "$candidate_env" --env-file "${BASE}/b2.env" \
  "frwhoop/scoring-service:${RELEASE_SHA}" --check-config

cd "$COMPOSE_DIR"
export SCORING_IMAGE_TAG="$RELEASE_SHA"
export SCORING_CPUS="${SCORING_CPUS:-2.0}"
export SCORING_MEMORY_LIMIT="${SCORING_MEMORY_LIMIT:-2g}"
compose_project="frwhoop-scoring-${SCORING_WORKER_INSTANCE_ID}"
SCORING_ENV_FILE="$candidate_env" docker compose \
  -p "$compose_project" -f "$CANDIDATE_COMPOSE" config --quiet

prior_ids="$(scoring_worker_ids -aq)"
while read -r id; do
  [[ -n "$id" ]] || continue
  previous_v2+=("$id")
  previous_names+=("$(timeout 12 docker inspect -f '{{.Name}}' "$id" | sed 's,^/,,')")
  previous_running+=("$(timeout 12 docker inspect -f '{{.State.Running}}' "$id")")
  stopped+=(false); renamed+=(false)
done <<<"$prior_ids"
# Refuse a same-name container outside the precisely selected physiology worker set.
if existing_id="$(timeout 12 docker inspect -f '{{.Id}}' scoring-physiology-v2 2>/dev/null)"; then
  grep -Fxq "$existing_id" <<<"$prior_ids" || { echo 'Candidate container name is occupied' >&2; exit 1; }
fi
cutover=true
for ((index=0; index<${#previous_v2[@]}; index++)); do
  id="${previous_v2[index]}"
  printf '%s|%s|%s\n' "$id" "${previous_names[index]}" "${previous_running[index]}" >>"${rollback_dir}/containers.tsv"
  stopped[index]=true
  timeout 40 docker stop --time 30 "$id" >/dev/null
  renamed[index]=true
  timeout 12 docker rename "$id" "scoring-rollback-${RELEASE_SHA:0:12}-${id:0:12}"
done
# Capture only after previous deterministic workers stop, so their progress cannot qualify this image.
baseline="$(scoring_progress_snapshot)"
scoring_parse_snapshot "$baseline"
install -m 600 "$candidate_env" "$SCORING_ENV"
install -m 600 "$CANDIDATE_COMPOSE" "$COMPOSE_FILE"
unset SCORING_ENV_FILE
candidate_attempted=true
timeout 60 docker compose -p "$compose_project" -f docker-compose.yml \
  run -d --no-deps --name scoring-physiology-v2 scoring-physiology-v2
candidate_id="$(timeout 12 docker inspect -f '{{.Id}}' scoring-physiology-v2)"
candidate_project="$(timeout 12 docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$candidate_id")"
[[ "$candidate_project" == "$compose_project" ]] || { echo 'Candidate ownership changed before restart policy update' >&2; exit 1; }
timeout 12 docker update --restart unless-stopped "$candidate_id" >/dev/null
scoring_wait_for_progress "$RELEASE_SHA" "$baseline"
accepted=true
install -m 700 "${BUILD}/infra/vps/scripts/scoring-progress.sh" "${COMPOSE_DIR}/scoring-progress.sh"
install -m 700 "${BUILD}/infra/vps/scripts/remote/verify-scoring-runtime.sh" "${COMPOSE_DIR}/verify-scoring-runtime.sh"
echo "Prior worker/configuration retained for rollback: ${rollback_dir}"
REMOTE

echo "Deploy complete: ${RELEASE_SHA}"
