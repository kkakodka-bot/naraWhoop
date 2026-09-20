#!/usr/bin/env bash
# Phase 2 — deploy supabase/functions to the self-hosted Edge Runtime on the VPS.
# Copies function sources, wires B2 + WORKER_SECRET env, restarts the functions container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SECRETS="${ROOT}/infra/vps/secrets.env"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"
SRC="${ROOT}/supabase/functions"
REMOTE_FUNCTIONS="/opt/frwhoop/supabase-docker/docker/volumes/functions"
COMPOSE_DIR="/opt/frwhoop/supabase-docker/docker"

source "$DROPLET_ENV"
source "$SECRETS"

: "${API_DOMAIN:?Set API_DOMAIN in infra/vps/droplet.env}"
: "${WORKER_SECRET:?Missing WORKER_SECRET in infra/vps/secrets.env}"

# B2 credentials: prefer repo .env, fall back to VPS b2.env values supplied at provision time.
B2_ENV="${ROOT}/.env"
if [[ -f "$B2_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$B2_ENV"
fi
B2_KEY_ID="${B2_KEY_ID:-${KEY_ID:-}}"
B2_APPLICATION_KEY="${B2_APPLICATION_KEY:-${APPLICATION_KEY:-}}"
B2_BUCKET="${B2_BUCKET:-${BUCKET_NAME:-FRWHOOP}}"
B2_S3_ENDPOINT="${B2_S3_ENDPOINT:-s3.us-west-004.backblazeb2.com}"
B2_REGION="${B2_REGION:-us-west-004}"

for v in B2_KEY_ID B2_APPLICATION_KEY; do
  if [[ -z "${!v:-}" ]]; then
    echo "Missing ${v} — set in .env or infra/vps/b2.env on the VPS" >&2
    exit 1
  fi
done

echo "==> Syncing function sources to deploy@${DROPLET_IP}:${REMOTE_FUNCTIONS}"
# Preserve the self-hosted router (main/) and default hello/ — only sync FRWHOOP function dirs + _shared.
for item in _shared push reconcile retention-sweep account-deletion ingest-verify; do
  rsync -az --delete \
    -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new" \
    "${SRC}/${item}/" "deploy@${DROPLET_IP}:${REMOTE_FUNCTIONS}/${item}/"
done

echo "==> Copying config.toml (per-function verify_jwt=false)"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
  "${ROOT}/supabase/config.toml" "deploy@${DROPLET_IP}:${REMOTE_FUNCTIONS}/config.toml"

echo "==> Writing .env.functions and patching docker-compose on VPS"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "deploy@${DROPLET_IP}" bash -s <<REMOTE
set -euo pipefail
COMPOSE_DIR="${COMPOSE_DIR}"
REMOTE_FUNCTIONS="${REMOTE_FUNCTIONS}"

cat >"\${COMPOSE_DIR}/.env.functions" <<EOF
WORKER_SECRET=${WORKER_SECRET}
B2_KEY_ID=${B2_KEY_ID}
B2_APPLICATION_KEY=${B2_APPLICATION_KEY}
B2_BUCKET=${B2_BUCKET}
B2_S3_ENDPOINT=${B2_S3_ENDPOINT}
B2_REGION=${B2_REGION}
RAW_STORE=b2
EOF
chmod 600 "\${COMPOSE_DIR}/.env.functions"

# Ensure env_file is wired into the functions service (idempotent patch).
python3 - <<'PY'
from pathlib import Path
path = Path("${COMPOSE_DIR}/docker-compose.yml")
text = path.read_text()
needle = "  functions:\n"
if "env_file:" not in text.split("functions:")[1].split("\n  db:")[0]:
    block = needle + "    env_file:\n      - .env.functions\n"
    if needle not in text:
        raise SystemExit("functions: service not found in docker-compose.yml")
    text = text.replace(needle, block, 1)
    path.write_text(text)
    print("patched docker-compose.yml: added env_file for functions")
else:
    print("docker-compose.yml already has env_file for functions")
PY

cd "\${COMPOSE_DIR}"
docker compose up -d --force-recreate functions
docker compose ps functions
REMOTE

echo "==> Edge functions deployed. Public push URL: https://${API_DOMAIN}/functions/v1/push"
