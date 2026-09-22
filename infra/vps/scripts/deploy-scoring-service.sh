#!/usr/bin/env bash
# Deploy reviewed v1, physiology v2, and historical shadow workers on the VPS.
# Run from laptop with repo checkout. Does not print secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# The older manifest helper targets a different self-hosted, single-worker topology. Validate
# its artifact before any configuration access, but never silently substitute it for this
# hosted three-lane deployment or fall back to a mutable-image build.
if [[ "${1:-}" == --image-manifest ]]; then
  [[ "$#" == 2 ]] || { echo 'NOT_READY: --image-manifest requires one manifest path' >&2; exit 3; }
  node "$ROOT/infra/vps/scripts/scorer-image-release.mjs" validate --manifest "$2"
  echo 'NOT_READY: single-worker self-hosted image manifests cannot deploy the hosted three-lane pipeline' >&2
  exit 3
fi
[[ "$#" == 6 && "$1" == --release-manifest && "$3" == --artifact-root && "$5" == --worker-deployment ]] || {
  echo 'NOT_READY: use --release-manifest MANIFEST --artifact-root ARTIFACT_ROOT --worker-deployment DEPLOYMENT_PLAN' >&2
  exit 3
}

# Reinspect the aggregate release and its artifact bytes, then verify the registry references
# against their reviewed OCI manifest/config digests. This must happen before deployment target
# configuration or SSH is accessed.
VERIFIED_DEPLOYMENT="$(node "$ROOT/Tools/release/release-artifact-manifest.mjs" verify-deployment \
  --repo-root "$ROOT" --artifact-root "$4" --manifest "$2" --deployment "$6")"
deployment_field() {
  node -e '
    const value = JSON.parse(process.argv[1]);
    if (value.status !== "WORKER_DEPLOYMENT_VERIFIED") process.exit(2);
    let field = value;
    for (const part of process.argv[2].split(".")) field = field?.[part];
    if ((typeof field !== "string" && typeof field !== "number") || String(field).includes("\n")) process.exit(2);
    process.stdout.write(String(field));
  ' "$VERIFIED_DEPLOYMENT" "$1"
}
RELEASE_SHA="$(deployment_field sourceSha)"
RELEASE_TREE="$(deployment_field sourceTree)"
DEPLOYMENT_FINGERPRINT="$(deployment_field fingerprint)"
SELECTED_V1_IMAGE="$(deployment_field selectedV1.reference)"
SELECTED_V1_CONFIG="$(deployment_field selectedV1.configDigest)"
SHADOW_V2_IMAGE="$(deployment_field shadowV2.reference)"
SHADOW_V2_CONFIG="$(deployment_field shadowV2.configDigest)"
POSTGRES_CLIENT_IMAGE="$(deployment_field postgresqlClient.reference)"
POSTGRES_CLIENT_CONFIG="$(deployment_field postgresqlClient.configDigest)"
POSTGRES_CLIENT_PLATFORM="$(deployment_field postgresqlClient.platform)"
POSTGRES_CLIENT_VERSION="$(deployment_field postgresqlClient.version)"
DROPLET_IP="$(deployment_field target.ip)"
SSH_PORT="$(deployment_field target.sshPort)"
TARGET_HOST_KEY_TYPE="$(deployment_field target.sshHostPublicKey.type)"
TARGET_HOST_KEY_LINE="$(deployment_field target.sshHostPublicKey.line)"
TARGET_HOST_KEY_FINGERPRINT="$(deployment_field target.sshHostPublicKey.fingerprint)"
DEPLOY_PUBLIC_KEY_FINGERPRINT="$(deployment_field target.deployPublicKeyFingerprint)"
[[ "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo 'NOT_READY: verified release SHA is invalid' >&2; exit 3; }
[[ "$RELEASE_TREE" =~ ^[0-9a-f]{40}$ ]] || { echo 'NOT_READY: verified release tree is invalid' >&2; exit 3; }
[[ "$DEPLOYMENT_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || { echo 'NOT_READY: verified deployment fingerprint is invalid' >&2; exit 3; }
for image in "$SELECTED_V1_IMAGE" "$SHADOW_V2_IMAGE"; do
  [[ "$image" =~ ^[a-z0-9][a-z0-9._:-]*(/[a-z0-9][a-z0-9._-]*)+@sha256:[0-9a-f]{64}$ ]] || {
    echo 'NOT_READY: verified worker image reference is invalid' >&2
    exit 3
  }
done
[[ "$POSTGRES_CLIENT_IMAGE" == docker.io/library/postgres@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3 &&
   "$POSTGRES_CLIENT_CONFIG" == sha256:79bd7c99e923138f136f8009d6bffa66e21e9d4fda5c0c561b00fc9c90cfe537 &&
   "$POSTGRES_CLIENT_PLATFORM" == linux/amd64 && "$POSTGRES_CLIENT_VERSION" == 17.11-alpine3.24 ]] || {
  echo 'NOT_READY: reviewed PostgreSQL client identity differs' >&2; exit 3;
}
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && ((SSH_PORT >= 1 && SSH_PORT <= 65535)) || {
  echo 'NOT_READY: verified target SSH port is invalid' >&2; exit 3;
}
python3 - "$DROPLET_IP" <<'PY'
import ipaddress, sys
value = ipaddress.ip_address(sys.argv[1])
if '%' in sys.argv[1] or str(value) != sys.argv[1]:
    raise SystemExit(3)
PY
[[ "$TARGET_HOST_KEY_LINE" == "$TARGET_HOST_KEY_TYPE "* &&
   "$TARGET_HOST_KEY_FINGERPRINT" =~ ^SHA256:[A-Za-z0-9+/]{43}$ &&
   "$DEPLOY_PUBLIC_KEY_FINGERPRINT" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || {
  echo 'NOT_READY: verified target SSH identity is invalid' >&2; exit 3;
}
for digest in "$SELECTED_V1_CONFIG" "$SHADOW_V2_CONFIG"; do
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo 'NOT_READY: verified worker config digest is invalid' >&2
    exit 3
  }
done
release_git() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 \
    command git --no-replace-objects -c core.fsmonitor=false -c core.hooksPath=/dev/null \
      -c protocol.allow=never -C "$ROOT" "$@"
}
[[ "$(release_git rev-parse HEAD)" == "$RELEASE_SHA" &&
   "$(release_git rev-parse "${RELEASE_SHA}^{tree}")" == "$RELEASE_TREE" ]] || {
  echo 'Refusing to deploy a checkout whose HEAD differs from the verified release' >&2
  exit 1
}
if [[ -n "$(release_git status --porcelain --untracked-files=all)" ]]; then
  echo "Refusing to deploy a dirty checkout" >&2
  exit 1
fi
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"
python3 - "$SSH_KEY" <<'PY'
import os, stat, sys
path = sys.argv[1]
value = os.lstat(path)
if not stat.S_ISREG(value.st_mode) or stat.S_ISLNK(value.st_mode) or value.st_mode & 0o077:
    raise SystemExit(3)
PY
DEPLOY_KEY_INSPECTION="$(ssh-keygen -y -f "$SSH_KEY" 2>/dev/null | ssh-keygen -E sha256 -lf - 2>/dev/null)"
[[ -n "$DEPLOY_KEY_INSPECTION" && "$DEPLOY_KEY_INSPECTION" != *$'\n'* ]] || {
  echo 'NOT_READY: local deploy private key public identity is ambiguous' >&2; exit 3;
}
OBSERVED_DEPLOY_PUBLIC_KEY_FINGERPRINT="${DEPLOY_KEY_INSPECTION#* }"
OBSERVED_DEPLOY_PUBLIC_KEY_FINGERPRINT="${OBSERVED_DEPLOY_PUBLIC_KEY_FINGERPRINT%% *}"
unset DEPLOY_KEY_INSPECTION
[[ "$OBSERVED_DEPLOY_PUBLIC_KEY_FINGERPRINT" == "$DEPLOY_PUBLIC_KEY_FINGERPRINT" ]] || {
  echo 'NOT_READY: local deploy private key does not match the plan-bound public-key fingerprint' >&2; exit 3;
}
OBSERVATION_BASE="$4/deployment-target-observations"
if [[ -e "$OBSERVATION_BASE" ]]; then
  [[ -d "$OBSERVATION_BASE" && ! -L "$OBSERVATION_BASE" ]] || {
    echo 'NOT_READY: target observation directory is unsafe' >&2; exit 3;
  }
else
  install -d -m 700 "$OBSERVATION_BASE"
fi
OBSERVATION_DIR="$(mktemp -d "${OBSERVATION_BASE}/${DEPLOYMENT_FINGERPRINT}.XXXXXX")"
chmod 700 "$OBSERVATION_DIR"
KNOWN_HOSTS="$OBSERVATION_DIR/known_hosts"
if [[ "$SSH_PORT" == 22 ]]; then KNOWN_HOST_TOKEN="$DROPLET_IP"; else KNOWN_HOST_TOKEN="[$DROPLET_IP]:$SSH_PORT"; fi
umask 077
printf '%s %s\n' "$KNOWN_HOST_TOKEN" "$TARGET_HOST_KEY_LINE" >"$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"
SSH_ARGS=(-F /dev/null -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes
  -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o PreferredAuthentications=publickey
  -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o VerifyHostKeyDNS=no
  -o "UserKnownHostsFile=$KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null -p "$SSH_PORT")
PROBE_TOKEN="FRWHOOP_TARGET_IDENTITY_OBSERVED_${DEPLOYMENT_FINGERPRINT}"
OBSERVED_TOKEN="$(ssh "${SSH_ARGS[@]}" "deploy@${DROPLET_IP}" "printf '%s\\n' '${PROBE_TOKEN}'")"
[[ "$OBSERVED_TOKEN" == "$PROBE_TOKEN" ]] || {
  echo 'NOT_READY: plan-bound target identity probe failed' >&2; exit 3;
}
TARGET_OBSERVATION="$OBSERVATION_DIR/observed-target.json"
node - "$TARGET_OBSERVATION" "$DROPLET_IP" "$SSH_PORT" "$TARGET_HOST_KEY_LINE" \
  "$TARGET_HOST_KEY_FINGERPRINT" "$DEPLOY_PUBLIC_KEY_FINGERPRINT" "$DEPLOYMENT_FINGERPRINT" <<'NODE'
const fs = require('node:fs');
const [filename, ip, port, hostKeyLine, hostKeyFingerprint, deployKeyFingerprint, deploymentFingerprint] = process.argv.slice(2);
const value = { schemaVersion: 1, kind: 'frwhoop-observed-deployment-target', observedAt: new Date().toISOString(),
  deploymentFingerprintSha256: deploymentFingerprint,
  target: { ip, sshPort: Number(port), sshHostPublicKey: { line: hostKeyLine, fingerprint: hostKeyFingerprint },
    deployPublicKeyFingerprint: deployKeyFingerprint }, observation: 'STRICT_HOST_KEY_AND_PUBLIC_KEY_AUTH_SUCCEEDED_READ_ONLY' };
const descriptor = fs.openSync(filename, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY, 0o600);
try { fs.writeFileSync(descriptor, JSON.stringify(value, null, 2) + '\n'); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
NODE
echo "Target identity observed before remote mutation; receipt: ${TARGET_OBSERVATION}"
DEPLOYMENT_TOKEN="${RELEASE_SHA}-$(python3 -c 'import uuid; print(uuid.uuid4())')"
[[ "$DEPLOYMENT_TOKEN" =~ ^[0-9a-f]{40}-[0-9a-f-]{36}$ ]] || exit 1
DEPLOYMENT_COMPLETE=false
LOCK_ACQUIRED=false
finish_deployment_session() {
  local result=$?
  trap - EXIT INT TERM
  if [[ "$DEPLOYMENT_COMPLETE" == true ]]; then
    if ! ssh "${SSH_ARGS[@]}" "deploy@${DROPLET_IP}" bash -s -- "$DEPLOYMENT_TOKEN" <<'UNLOCK'
set -euo pipefail
lock=/opt/frwhoop/scoring-deployment.lock
token="$1"
[[ -f "$lock/owner" && "$(cat "$lock/owner")" == "$token" ]] || exit 1
rm -rf -- "$lock"
UNLOCK
    then
      echo 'Deployment completed, but its remote session lock could not be released; operator review is required' >&2
      result=1
    fi
  elif [[ "$LOCK_ACQUIRED" == true ]]; then
    echo 'DEPLOYMENT_LOCK_RETAINED: the full three-lane deployment did not complete; inspect the recorded lane state before removing /opt/frwhoop/scoring-deployment.lock' >&2
  fi
  exit "$result"
}
trap finish_deployment_session EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# One fail-closed session lock spans all three independent lane cutovers. A controller or network
# interruption intentionally leaves it behind so another invocation cannot interleave with a
# partially accepted fleet.
ssh "${SSH_ARGS[@]}" "deploy@${DROPLET_IP}" bash -s -- "$DEPLOYMENT_TOKEN" <<'LOCK'
set -euo pipefail
lock=/opt/frwhoop/scoring-deployment.lock
token="$1"
umask 077
mkdir "$lock" || { echo 'Another scoring deployment session is active or requires recovery' >&2; exit 1; }
printf '%s\n' "$token" >"$lock/owner"
LOCK
LOCK_ACQUIRED=true
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
release_git archive "$RELEASE_SHA" android scoring-service \
  infra/vps/scripts/scoring-progress.sh infra/vps/scripts/remote/verify-scoring-runtime.sh \
  infra/vps/scripts/scoring-hosted-query.py infra/vps/scripts/remote/read-scoring-query.sh \
  infra/vps/scripts/verify-pinned-postgres-client.py \
  infra/vps/templates/docker-compose.scoring-override.yml | \
  ssh "${SSH_ARGS[@]}" "deploy@${DROPLET_IP}" \
    "tar -xf - -C '${REMOTE_BUILD}'"

echo "========== configure scoring env + deploy reviewed images =========="
deploy_lane() {
ssh "${SSH_ARGS[@]}" "deploy@${DROPLET_IP}" bash -s -- "$RELEASE_SHA" "$REMOTE_BUILD" "$1" \
  "$SELECTED_V1_IMAGE" "$SHADOW_V2_IMAGE" "$SELECTED_V1_CONFIG" "$SHADOW_V2_CONFIG" \
  "$POSTGRES_CLIENT_IMAGE" "$POSTGRES_CLIENT_CONFIG" "$POSTGRES_CLIENT_PLATFORM" "$POSTGRES_CLIENT_VERSION" <<'REMOTE'
set -euo pipefail
RELEASE_SHA="$1"
BASE="/opt/frwhoop"
COMPOSE_DIR="${BASE}/scoring"
BUILD="$2"
SCORING_SERVICE="${3:-scoring-physiology-v2}"
REVIEWED_BASELINE_IMAGE="$4"
REVIEWED_V2_IMAGE="$5"
REVIEWED_BASELINE_CONFIG="$6"
REVIEWED_V2_CONFIG="$7"
SCORING_POSTGRES_CLIENT_IMAGE="$8"
SCORING_POSTGRES_CLIENT_CONFIG_DIGEST="$9"
SCORING_POSTGRES_CLIENT_PLATFORM="${10}"
SCORING_POSTGRES_CLIENT_VERSION="${11}"
SECRETS="${BASE}/secrets.env"
SCORING_ENV="${BASE}/scoring.env"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
CANDIDATE_COMPOSE="${BUILD}/infra/vps/templates/docker-compose.scoring-override.yml"
# shellcheck disable=SC1091
source "${BUILD}/infra/vps/scripts/scoring-progress.sh"
case "$SCORING_SERVICE" in
  scoring-physiology-v2) SCORING_ALGORITHM_VERSION=frwhoop-physiology-2 ;;
  scoring-baseline-v1) SCORING_ALGORITHM_VERSION=frwhoop-server-1; SCORING_ENV="${BASE}/scoring-baseline.env" ;;
  scoring-history) SCORING_ALGORITHM_VERSION=frwhoop-server-2-history; SCORING_ENV="${BASE}/scoring-history.env" ;;
  *) echo 'Unknown scoring service' >&2; exit 1 ;;
esac
scoring_lane
install -d -m 700 "$COMPOSE_DIR"
exec 9>"${BASE}/scoring-deploy.lock"
flock -n 9 || { echo 'Another scoring deployment is active' >&2; exit 1; }

[[ "$SCORING_POSTGRES_CLIENT_IMAGE" == docker.io/library/postgres@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3 &&
   "$SCORING_POSTGRES_CLIENT_CONFIG_DIGEST" == sha256:79bd7c99e923138f136f8009d6bffa66e21e9d4fda5c0c561b00fc9c90cfe537 &&
   "$SCORING_POSTGRES_CLIENT_PLATFORM" == linux/amd64 &&
   "$SCORING_POSTGRES_CLIENT_VERSION" == 17.11-alpine3.24 ]] || {
  echo 'Reviewed PostgreSQL client identity differs from the deployment plan' >&2; exit 1;
}
verify_postgres_client() (
  set -euo pipefail
  local archive repo_digests
  archive="$(mktemp "${BUILD}/postgres-client.XXXXXX.tar")"
  trap 'rm -f -- "$archive"' EXIT
  timeout 300 docker pull --platform "$SCORING_POSTGRES_CLIENT_PLATFORM" "$SCORING_POSTGRES_CLIENT_IMAGE" >/dev/null
  repo_digests="$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$SCORING_POSTGRES_CLIENT_IMAGE")"
  grep -Fqx -- "$SCORING_POSTGRES_CLIENT_IMAGE" <<<"$repo_digests" || {
    echo 'Pulled PostgreSQL client repository digest differs from the deployment plan' >&2; exit 1;
  }
  timeout 300 docker image save -o "$archive" "$SCORING_POSTGRES_CLIENT_IMAGE"
  python3 "${BUILD}/infra/vps/scripts/verify-pinned-postgres-client.py" \
    --archive "$archive" --reference "$SCORING_POSTGRES_CLIENT_IMAGE" \
    --config-digest "$SCORING_POSTGRES_CLIENT_CONFIG_DIGEST" \
    --platform "$SCORING_POSTGRES_CLIENT_PLATFORM" --version "$SCORING_POSTGRES_CLIENT_VERSION" >/dev/null
)
# Verify the public client image without hosted credentials in process memory. Every later psql
# client invocation receives only this plan-bound digest reference.
verify_postgres_client
export SCORING_POSTGRES_CLIENT_IMAGE SCORING_POSTGRES_CLIENT_CONFIG_DIGEST \
  SCORING_POSTGRES_CLIENT_PLATFORM SCORING_POSTGRES_CLIENT_VERSION

# shellcheck disable=SC1090
source "$SECRETS"
: "${SCORING_DATABASE_URL:?Set the hosted Supabase pooler URL in /opt/frwhoop/secrets.env}"
: "${SCORING_SUPABASE_URL:?Set the hosted Supabase PostgREST URL in /opt/frwhoop/secrets.env}"
: "${SCORING_INGEST_SECRET:?Set the hosted project's SCORING_INGEST_SECRET in /opt/frwhoop/secrets.env}"
: "${SCORING_SUPABASE_SERVICE_ROLE_KEY:?Set the hosted project's SCORING_SUPABASE_SERVICE_ROLE_KEY in /opt/frwhoop/secrets.env}"
SCORING_BASELINE_IMAGE="$REVIEWED_BASELINE_IMAGE"
SCORING_V2_IMAGE="$REVIEWED_V2_IMAGE"
[[ "$SCORING_V2_IMAGE" =~ ^[a-z0-9][a-z0-9._:-]*(/[a-z0-9][a-z0-9._-]*)+@sha256:[0-9a-f]{64}$ &&
   "$SCORING_BASELINE_IMAGE" =~ ^[a-z0-9][a-z0-9._:-]*(/[a-z0-9][a-z0-9._-]*)+@sha256:[0-9a-f]{64}$ ]] || {
  echo 'Worker images must be pinned registry digest references' >&2; exit 1;
}
[[ "$REVIEWED_BASELINE_CONFIG" =~ ^sha256:[0-9a-f]{64}$ &&
   "$REVIEWED_V2_CONFIG" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo 'Worker image config digests must be verified sha256 identities' >&2; exit 1;
}
export SCORING_BASELINE_IMAGE SCORING_V2_IMAGE

case "$SCORING_DATABASE_URL" in
  *"@db:"*|*"//db:"*|*localhost*|*127.0.0.1*) echo "Refusing a local scoring database destination" >&2; exit 1 ;;
esac
case "$SCORING_SUPABASE_URL" in
  https://*/rest/v1) ;;
  *) echo "SCORING_SUPABASE_URL must be an HTTPS /rest/v1 endpoint" >&2; exit 1 ;;
esac

# Refuse a cutover while the hosted selection/canonicality state disagrees with the reviewed
# selected-v1 and shadow-v2/history roles. Use the exact staged query client and pinned psql image;
# this check deliberately runs before rollback state is created or any worker is stopped, started,
# renamed, removed, or assigned a restart policy. The post-deployment verifier repeats the same
# database contract to fence drift during the three-lane cutover.
selection_violations="$(SCORING_DATABASE_URL="$SCORING_DATABASE_URL" SCORING_SUPABASE_URL="$SCORING_SUPABASE_URL" \
  python3 "${BUILD}/infra/vps/scripts/scoring-hosted-query.py" <<'SQL'
select count(*) from (
  select 'default-shape' as violation
  where (select count(*) from public.physiology_feature_defaults
    where feature in ('hrv','sleep','respiration')) <> 3
     or exists(select 1 from public.physiology_feature_defaults
       where feature not in ('hrv','sleep','respiration') or algorithm_version <> 'frwhoop-server-1')
  union all
  select 'source-selection' from public.physiology_source_selection
    where algorithm_version <> 'frwhoop-server-1'
  union all
  select 'v2-canonical' from public.physiology_feature_defaults
    where public.physiology_feature_is_canonical('frwhoop-physiology-2',feature)
  union all
  select 'history-canonical' from public.physiology_feature_defaults
    where public.physiology_feature_is_canonical('frwhoop-server-2-history',feature)
) release_role_violations;
SQL
)"
[[ "$selection_violations" == 0 ]] || {
  echo 'NOT_READY: selected v1 and shadow v2/history release roles differ before cutover' >&2; exit 3;
}

umask 077
rollback_dir="$(mktemp -d "${BASE}/scoring-rollback.XXXXXX")"
candidate_env="${rollback_dir}/candidate.env"
candidate_client_env="${rollback_dir}/scoring-client.env"
old_env=false; old_compose=false; cutover=false; accepted=false; candidate_attempted=false
declare -a previous_v2=() previous_names=() previous_running=() stopped=() renamed=()
[[ ! -f "$SCORING_ENV" ]] || { cp -p "$SCORING_ENV" "${rollback_dir}/scoring.env"; old_env=true; }
[[ ! -f "$COMPOSE_FILE" ]] || { cp -p "$COMPOSE_FILE" "${rollback_dir}/docker-compose.scoring.yml"; old_compose=true; }
finish() {
  local result=$? index actual_name candidate_id candidate_project rollback_failed=false
  trap - EXIT
  if [[ "$cutover" == true && "$accepted" == false ]]; then
    # Prior containers are retained by ID; Compose must not recreate/delete their labels.
    if [[ "$candidate_attempted" == true ]]; then
      if candidate_id="$(timeout 12 docker ps --no-trunc -aq --filter "name=^/${SCORING_SERVICE}$")"; then
        if [[ -n "$candidate_id" ]]; then
          candidate_project="$(timeout 12 docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$candidate_id")" || candidate_project=""
          if [[ "$candidate_project" != "$compose_project" ]]; then
            # Another invocation may have acquired the fixed name while Compose failed.
            # Never stop/remove it or activate a competing prior scorer with unknown ownership.
            rollback_failed=true
          elif ! timeout 40 docker rm -f "$candidate_id" >/dev/null; then
            rollback_failed=true
            timeout 40 docker stop --time 30 "$candidate_id" >/dev/null || rollback_failed=true
          fi
        fi
      else rollback_failed=true; fi
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
    done
    if [[ "$rollback_failed" == true ]]; then
      echo "Rollback incomplete; preserved recovery evidence: ${rollback_dir}" >&2
    fi
    echo "ROLLBACK_BLOCKED: candidate rejected; prior worker retained stopped and requires a separately reviewed compatible rollback artifact. Evidence: ${rollback_dir}" >&2
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
  printf 'SCORING_ALGORITHM_VERSION=%s\n' "$SCORING_ALGORITHM_VERSION"
} >"$candidate_env"
{
  printf 'SCORING_POSTGRES_CLIENT_IMAGE=%s\n' "$SCORING_POSTGRES_CLIENT_IMAGE"
  printf 'SCORING_POSTGRES_CLIENT_CONFIG_DIGEST=%s\n' "$SCORING_POSTGRES_CLIENT_CONFIG_DIGEST"
  printf 'SCORING_POSTGRES_CLIENT_PLATFORM=%s\n' "$SCORING_POSTGRES_CLIENT_PLATFORM"
  printf 'SCORING_POSTGRES_CLIENT_VERSION=%s\n' "$SCORING_POSTGRES_CLIENT_VERSION"
} >"$candidate_client_env"
unset REPLAY_USER_ID REPLAY_DAY REPLAY_DEVICE_ID

verify_reviewed_image() {
  local reviewed_image="$1" expected_config="$2" actual_config repo_digests
  timeout 300 docker pull "$reviewed_image" >/dev/null
  actual_config="$(docker image inspect -f '{{.Id}}' "$reviewed_image")"
  [[ "$actual_config" == "$expected_config" ]] || {
    echo 'Pulled worker image config digest differs from the verified deployment plan' >&2; exit 1;
  }
  repo_digests="$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$reviewed_image")"
  grep -Fqx -- "$reviewed_image" <<<"$repo_digests" || {
    echo 'Pulled worker image repository digest differs from the verified deployment plan' >&2; exit 1;
  }
  [[ "$(docker image inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$reviewed_image")" == "$RELEASE_SHA" ]] || exit 1
  [[ "$(docker image inspect -f '{{ index .Config.Labels "io.frwhoop.heartbeat.contract" }}' "$reviewed_image")" == physiology_worker_heartbeats-v1 ]] || exit 1
  [[ "$(docker image inspect -f '{{ index .Config.Labels "io.frwhoop.image.platform" }}' "$reviewed_image")" == linux/amd64 ]] || exit 1
  [[ "$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$reviewed_image")" == linux/amd64 ]] || exit 1
}
verify_reviewed_image "$SCORING_BASELINE_IMAGE" "$REVIEWED_BASELINE_CONFIG"
verify_reviewed_image "$SCORING_V2_IMAGE" "$REVIEWED_V2_CONFIG"
candidate_image="$SCORING_V2_IMAGE"
SCORING_EXPECTED_IMAGE_ID="$REVIEWED_V2_CONFIG"
if [[ "$SCORING_SERVICE" == scoring-baseline-v1 ]]; then
  candidate_image="$SCORING_BASELINE_IMAGE"
  SCORING_EXPECTED_IMAGE_ID="$REVIEWED_BASELINE_CONFIG"
  [[ "$(docker image inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$candidate_image")" == "$RELEASE_SHA" ]] || exit 1
  [[ "$(docker image inspect -f '{{ index .Config.Labels "io.frwhoop.algorithm.version" }}' "$candidate_image")" == frwhoop-server-1 ]] || exit 1
  [[ "$(docker image inspect -f '{{ index .Config.Labels "io.frwhoop.baseline.commit" }}' "$candidate_image")" == 5caa31689da0023e111beb36850d3f81d67e1be2 ]] || exit 1
  for patch_name in transport runtime-identity; do
    patch_sha="$(sha256sum "${BUILD}/scoring-service/legacy-baseline/${patch_name}.patch" | cut -d ' ' -f 1)"
    label_name=transport; [[ "$patch_name" != runtime-identity ]] || label_name=identity
    [[ "$(docker image inspect -f "{{ index .Config.Labels \"io.frwhoop.baseline.${label_name}-sha256\" }}" "$candidate_image")" == "$patch_sha" ]] || exit 1
  done
else
  [[ "$(docker image inspect -f '{{ index .Config.Labels "io.frwhoop.algorithm.roles" }}' "$candidate_image")" == frwhoop-physiology-2,frwhoop-server-2-history ]] || exit 1
fi
[[ "$SCORING_EXPECTED_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
export SCORING_EXPECTED_IMAGE_ID

# Check the repaired image's version-specific hosted schema, ingest secret and REST key.
# The frozen baseline has no preflight command; its fenced SQL is checked by the v2 preflight.
# A failed check leaves current workers and their environment files intact.
preflight_version="$SCORING_ALGORITHM_VERSION"
[[ "$preflight_version" != frwhoop-server-1 ]] || preflight_version=frwhoop-physiology-2
docker run --rm --env-file "$candidate_env" --env-file "${BASE}/b2.env" \
  -e "SCORING_ALGORITHM_VERSION=$preflight_version" \
  "$SCORING_V2_IMAGE" --check-config

cd "$COMPOSE_DIR"
export SCORING_CPUS="${SCORING_CPUS:-2.0}"
export SCORING_MEMORY_LIMIT="${SCORING_MEMORY_LIMIT:-2g}"
compose_project="frwhoop-scoring-${SCORING_WORKER_INSTANCE_ID}"
SCORING_ENV_FILE="$candidate_env" SCORING_BASELINE_ENV_FILE="$candidate_env" SCORING_HISTORY_ENV_FILE="$candidate_env" docker compose \
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
if existing_id="$(timeout 12 docker inspect -f '{{.Id}}' "$SCORING_SERVICE" 2>/dev/null)"; then
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
export SCORING_ENV_FILE="$SCORING_ENV" SCORING_BASELINE_ENV_FILE="$SCORING_ENV" SCORING_HISTORY_ENV_FILE="$SCORING_ENV"
timeout 60 docker compose -p "$compose_project" -f docker-compose.yml \
  run -d --no-deps --name "$SCORING_SERVICE" "$SCORING_SERVICE"
candidate_id="$(timeout 12 docker inspect -f '{{.Id}}' "$SCORING_SERVICE")"
candidate_project="$(timeout 12 docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$candidate_id")"
[[ "$candidate_project" == "$compose_project" ]] || { echo 'Candidate ownership changed before restart policy update' >&2; exit 1; }
export SCORING_REQUIRE_PUBLICATION=true
scoring_wait_for_progress "$RELEASE_SHA" "$baseline"
timeout 12 docker update --restart unless-stopped "$candidate_id" >/dev/null
accepted=true
install -m 600 "$candidate_client_env" "${BASE}/scoring-client.env"
install -m 700 "${BUILD}/infra/vps/scripts/scoring-progress.sh" "${COMPOSE_DIR}/scoring-progress.sh"
install -m 700 "${BUILD}/infra/vps/scripts/remote/verify-scoring-runtime.sh" "${COMPOSE_DIR}/verify-scoring-runtime.sh"
install -m 700 "${BUILD}/infra/vps/scripts/scoring-hosted-query.py" "${COMPOSE_DIR}/scoring-hosted-query.py"
install -m 700 "${BUILD}/infra/vps/scripts/remote/read-scoring-query.sh" "${COMPOSE_DIR}/read-scoring-query.sh"
echo "Prior worker/configuration retained for rollback: ${rollback_dir}"
REMOTE
}

for lane in scoring-baseline-v1 scoring-physiology-v2 scoring-history; do
  deploy_lane "$lane"
done

ssh "${SSH_ARGS[@]}" "deploy@${DROPLET_IP}" bash -s -- "$RELEASE_SHA" "$SELECTED_V1_CONFIG" "$SHADOW_V2_CONFIG" <<'VERIFY'
set -euo pipefail
revision="$1"
v1_config="$2"
v2_config="$3"
[[ "$revision" =~ ^[0-9a-f]{40}$ && "$v1_config" =~ ^sha256:[0-9a-f]{64}$ &&
   "$v2_config" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1

environment_value() {
  local container="$1" key="$2" environment matches
  environment="$(timeout 12 docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container")"
  matches="$(sed -n "s/^${key}=//p" <<<"$environment")"
  [[ -n "$matches" && "$matches" != *$'\n'* ]] || return 1
  printf '%s' "$matches"
}
verify_lane() {
  local container="$1" algorithm="$2" config="$3" command="$4" worker actual_command
  actual_command="$(timeout 12 docker inspect -f '{{json .Config.Cmd}}' "$container")"
  if [[ "$command" == default ]]; then
    [[ "$actual_command" == '[]' || "$actual_command" == null ]] || return 1
  else
    [[ "$actual_command" == "$command" ]] || return 1
  fi
  [[ "$(timeout 12 docker inspect -f '{{.State.Running}}' "$container")" == true &&
     "$(timeout 12 docker inspect -f '{{.RestartCount}}' "$container")" == 0 &&
     "$(timeout 12 docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container")" == unless-stopped &&
     "$(timeout 12 docker inspect -f '{{.Image}}' "$container")" == "$config" &&
     "$(timeout 12 docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$container")" == "$revision" &&
     "$(environment_value "$container" SCORING_ALGORITHM_VERSION)" == "$algorithm" &&
     "$(environment_value "$container" SCORING_WORKER_SOURCE_REVISION)" == "$revision" ]] || return 1
  worker="$(environment_value "$container" SCORING_WORKER_INSTANCE_ID)"
  [[ "$worker" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
  printf '%s' "$worker"
}
v1_worker="$(verify_lane scoring-baseline-v1 frwhoop-server-1 "$v1_config" default)"
v2_worker="$(verify_lane scoring-physiology-v2 frwhoop-physiology-2 "$v2_config" default)"
history_worker="$(verify_lane scoring-history frwhoop-server-2-history "$v2_config" '["--history"]')"

selection_violations="$(/opt/frwhoop/scoring/read-scoring-query.sh <<SQL
select count(*) from (
  select 'default-shape' as violation
  where (select count(*) from public.physiology_feature_defaults
    where feature in ('hrv','sleep','respiration')) <> 3
     or exists(select 1 from public.physiology_feature_defaults
       where feature not in ('hrv','sleep','respiration') or algorithm_version <> 'frwhoop-server-1')
  union all
  select 'source-selection' from public.physiology_source_selection
    where algorithm_version <> 'frwhoop-server-1'
  union all
  select 'v2-canonical' from public.physiology_feature_defaults
    where public.physiology_feature_is_canonical('frwhoop-physiology-2',feature)
  union all
  select 'history-canonical' from public.physiology_feature_defaults
    where public.physiology_feature_is_canonical('frwhoop-server-2-history',feature)
) release_role_violations;
SQL
)"
[[ "$selection_violations" == 0 ]] || {
  echo 'NOT_READY: selected v1 and shadow v2/history release roles differ from the deployment plan' >&2; exit 3;
}

unserved="$(/opt/frwhoop/scoring/read-scoring-query.sh <<SQL
select count(*) from (
  select algorithm_version from public.physiology_feature_defaults
  union select algorithm_version from public.physiology_source_selection
) selected where not exists (
  select 1 from public.physiology_worker_heartbeats h
  where h.algorithm_version=selected.algorithm_version and h.source_revision='$revision'
    and h.last_poll_at>clock_timestamp()-interval '120 seconds' and h.last_error is null
);
SQL
)"
[[ "$unserved" == 0 ]] || { echo 'NOT_READY: selected algorithm version lacks a healthy exact-source producer' >&2; exit 3; }

missing_planned="$(/opt/frwhoop/scoring/read-scoring-query.sh <<SQL
with required(algorithm_version,worker_instance_id) as (values
  ('frwhoop-server-1','$v1_worker'::uuid),
  ('frwhoop-physiology-2','$v2_worker'::uuid),
  ('frwhoop-server-2-history','$history_worker'::uuid)
)
select count(*) from required r where not exists (
  select 1 from public.physiology_worker_heartbeats h
  where h.algorithm_version=r.algorithm_version and h.worker_instance_id=r.worker_instance_id
    and h.source_revision='$revision' and h.last_poll_at>clock_timestamp()-interval '120 seconds'
    and h.last_score_at is not null and h.last_score_at>=h.started_at and h.last_error is null
);
SQL
)"
[[ "$missing_planned" == 0 ]] || { echo 'NOT_READY: all three planned lanes require exact-container poll and publication heartbeats' >&2; exit 3; }
VERIFY

DEPLOYMENT_COMPLETE=true
echo "Deploy complete: ${RELEASE_SHA}"
