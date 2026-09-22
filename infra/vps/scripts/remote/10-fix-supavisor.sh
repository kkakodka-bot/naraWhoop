#!/usr/bin/env bash
# Fix Supavisor crash: VAULT_ENC_KEY must be exactly 32 hex chars (openssl rand -hex 16).
# Also bind pooler ports to localhost and set POOLER_TENANT_ID.
set -euo pipefail

COMPOSE_DIR="${1:-/opt/frwhoop/supabase-docker/docker}"
ENV_FILE="${COMPOSE_DIR}/.env"
SECRETS="/opt/frwhoop/secrets.env"
OVERRIDE="${COMPOSE_DIR}/docker-compose.override.yml"

current_len=$(grep '^VAULT_ENC_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r\n' | wc -c | tr -d ' ')
if [[ "$current_len" != "32" ]]; then
  NEW_VAULT=$(openssl rand -hex 16)
  sed -i "s|^VAULT_ENC_KEY=.*|VAULT_ENC_KEY=${NEW_VAULT}|" "$ENV_FILE"
  if [[ -f "$SECRETS" ]] && grep -q '^VAULT_ENC_KEY=' "$SECRETS"; then
    sed -i "s|^VAULT_ENC_KEY=.*|VAULT_ENC_KEY=${NEW_VAULT}|" "$SECRETS"
  fi
  echo "Rotated VAULT_ENC_KEY to 32-char hex (was ${current_len} chars)."
else
  echo "VAULT_ENC_KEY length OK (32)."
fi

if grep -q '^POOLER_TENANT_ID=your-tenant-id' "$ENV_FILE"; then
  sed -i 's|^POOLER_TENANT_ID=.*|POOLER_TENANT_ID=frwhoop|' "$ENV_FILE"
  echo "Set POOLER_TENANT_ID=frwhoop"
fi

cat >"$OVERRIDE" <<'EOF'
services:
  studio:
    ports:
      - "127.0.0.1:3000:3000/tcp"
  supavisor:
    ports:
      - "127.0.0.1:5432:5432/tcp"
      - "127.0.0.1:6543:6543/tcp"
EOF

# Override ports list may merge with base compose; patch base file for localhost bind.
python3 - <<'PY'
from pathlib import Path
p = Path("/opt/frwhoop/supabase-docker/docker/docker-compose.yml")
text = p.read_text()
old = "    ports:\n      - ${POSTGRES_PORT}:5432\n      - ${POOLER_PROXY_PORT_TRANSACTION}:6543"
new = "    ports:\n      - 127.0.0.1:${POSTGRES_PORT}:5432\n      - 127.0.0.1:${POOLER_PROXY_PORT_TRANSACTION}:6543"
if "127.0.0.1:${POSTGRES_PORT}" not in text and old in text:
    p.write_text(text.replace(old, new, 1))
PY

cd "$COMPOSE_DIR"
docker compose up -d --force-recreate supavisor studio
sleep 8

status=$(docker inspect supabase-pooler --format '{{.State.Status}}')
health=$(docker inspect supabase-pooler --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)
if [[ "$status" != "running" ]]; then
  docker logs supabase-pooler 2>&1 | tail -20
  echo "FAIL: supavisor status=${status}" >&2
  exit 1
fi

docker exec supabase-pooler curl -sSfL --head -o /dev/null http://127.0.0.1:4000/api/health
echo "Supavisor OK (status=${status}, health=${health})."
