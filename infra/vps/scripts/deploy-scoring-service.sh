#!/usr/bin/env bash
# Build and start the Phase 3 JVM scoring container on the VPS.
# Run from laptop with repo checkout. Does not print secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"
REMOTE_BUILD="/opt/frwhoop/build/frwhoop-scoring"
COMPOSE_DIR="/opt/frwhoop/supabase-docker/docker"

if [[ $# -gt 0 ]]; then
  [[ $# -eq 2 && "$1" == --image-manifest ]] || { echo "Usage: $0 [--image-manifest file]" >&2; exit 2; }
  node "${ROOT}/infra/vps/scripts/scorer-image-release.mjs" validate --manifest "$2"
  # Only an explicitly requested deployment loads this legacy host selector, after offline validation.
  source "$DROPLET_ENV"
  : "${DROPLET_IP:?}" "${SCORER_KNOWN_HOSTS:?Explicit verified known-hosts path required}"
  exec node "${ROOT}/infra/vps/scripts/scorer-image-release.mjs" deploy-pinned \
    --manifest "$2" --host "$DROPLET_IP" --key "$SSH_KEY" --known-hosts "$SCORER_KNOWN_HOSTS"
fi

echo "Legacy mutable-image deployment: NOT_READY for production-sync image provenance." >&2
source "$DROPLET_ENV"
: "${DROPLET_IP:?}"

echo "========== sync scoring build context =========="
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" "mkdir -p ${REMOTE_BUILD}"
rsync -az --delete \
  --exclude '.gradle' --exclude 'build' --exclude '.kotlin' \
  -e "ssh -i ${SSH_KEY}" \
  "${ROOT}/scoring-service/" "deploy@${DROPLET_IP}:${REMOTE_BUILD}/scoring-service/"
rsync -az --delete \
  --exclude '.gradle' --exclude 'build' --exclude '.git' \
  -e "ssh -i ${SSH_KEY}" \
  "${ROOT}/android/" "deploy@${DROPLET_IP}:${REMOTE_BUILD}/android/"

echo "========== install compose override =========="
scp -i "$SSH_KEY" \
  "${ROOT}/infra/vps/templates/docker-compose.scoring-override.yml" \
  "deploy@${DROPLET_IP}:${COMPOSE_DIR}/docker-compose.scoring.yml"

echo "========== configure scoring env + build image =========="
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" bash -s <<'REMOTE'
set -euo pipefail
BASE="/opt/frwhoop"
COMPOSE_DIR="${BASE}/supabase-docker/docker"
BUILD="${BASE}/build/frwhoop-scoring"
SECRETS="${BASE}/secrets.env"
ENV_FILE="${COMPOSE_DIR}/.env"

# shellcheck disable=SC1090
source "$SECRETS"

API_DOMAIN="${API_DOMAIN:-narawhoop.convexia.bio}"
PUBLIC_URL="https://${API_DOMAIN}"

# Scoring connects to Postgres on the docker network; PostgREST via internal rest service.
SCORING_DATABASE_URL="jdbc:postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/postgres"
INGEST_SECRET="${INGEST_SECRET:-service-role-bypass}"

set_kv() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >>"$ENV_FILE"
  fi
}

set_kv SCORING_DATABASE_URL "$SCORING_DATABASE_URL"
set_kv SUPABASE_PUBLIC_URL "$PUBLIC_URL"
set_kv INGEST_SECRET "$INGEST_SECRET"
set_kv SERVICE_ROLE_KEY "${SERVICE_ROLE_KEY}"
set_kv WORKER_SECRET "${WORKER_SECRET:-}"
set_kv SCORING_POLL_SECONDS "${SCORING_POLL_SECONDS:-8}"

cd "$BUILD"
docker build -t frwhoop/scoring-service:latest -f scoring-service/Dockerfile .

cd "$COMPOSE_DIR"
docker compose -f docker-compose.yml -f docker-compose.caddy.yml -f docker-compose.envoy.yml \
  -f docker-compose.scoring.yml up -d scoring

echo "========== scoring container status =========="
docker compose -f docker-compose.yml -f docker-compose.caddy.yml -f docker-compose.envoy.yml \
  -f docker-compose.scoring.yml ps scoring
docker port scoring 2>/dev/null || echo "OK: scoring has no published ports"
REMOTE

echo "Deploy complete."
