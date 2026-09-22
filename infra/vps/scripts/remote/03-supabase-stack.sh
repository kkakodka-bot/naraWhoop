#!/usr/bin/env bash
# Clone official self-hosted Supabase, pin release, merge FRWHOOP env + Caddy.
# Run as deploy user on VPS. Expects /opt/frwhoop/secrets.env and API_DOMAIN.
set -euo pipefail

BASE="/opt/frwhoop"
SUPABASE_DIR="${BASE}/supabase-docker"
CADDY_DIR="${BASE}/caddy"
SECRETS="${BASE}/secrets.env"

if [[ ! -f "$SECRETS" ]]; then
  echo "Missing ${SECRETS}" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS"

API_DOMAIN="${API_DOMAIN:?Set API_DOMAIN}"
STUDIO_DOMAIN="${STUDIO_DOMAIN:-studio.${API_DOMAIN}}"
PUBLIC_URL="https://${API_DOMAIN}"

mkdir -p "$BASE"
if [[ ! -d "${SUPABASE_DIR}/docker" ]]; then
  git clone --depth 1 --branch master https://github.com/supabase/supabase.git "$SUPABASE_DIR"
fi

cd "${SUPABASE_DIR}/docker"
if [[ ! -f .env ]]; then
  cp .env.example .env
fi

set_env() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >>.env
  fi
}

set_env POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
set_env JWT_SECRET "$JWT_SECRET"
set_env ANON_KEY "$ANON_KEY"
set_env SERVICE_ROLE_KEY "$SERVICE_ROLE_KEY"
set_env SECRET_KEY_BASE "$SECRET_KEY_BASE"
set_env VAULT_ENC_KEY "$VAULT_ENC_KEY"
set_env PG_META_CRYPTO_KEY "$PG_META_CRYPTO_KEY"
set_env LOGFLARE_PUBLIC_ACCESS_TOKEN "$LOGFLARE_PUBLIC_ACCESS_TOKEN"
set_env LOGFLARE_PRIVATE_ACCESS_TOKEN "$LOGFLARE_PRIVATE_ACCESS_TOKEN"
set_env DASHBOARD_USERNAME "$DASHBOARD_USERNAME"
set_env DASHBOARD_PASSWORD "$DASHBOARD_PASSWORD"
set_env API_EXTERNAL_URL "$PUBLIC_URL"
set_env SUPABASE_PUBLIC_URL "$PUBLIC_URL"
set_env SITE_URL "$PUBLIC_URL"

# Enable pg_cron + pg_net (official docker uses db init scripts; ensure extensions via SQL after boot)
mkdir -p "${BASE}/postgres-init"
cat >"${BASE}/postgres-init/01-frwhoop-extensions.sql" <<'EOF'
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;
EOF

# Bind Kong/Studio to localhost only — Caddy publishes 443
python3 - <<'PY'
from pathlib import Path
p = Path("docker-compose.yml")
text = p.read_text()
# Studio and Kong should not publish to 0.0.0.0 on production; comment default ports if present.
# Official compose uses ${KONG_HTTP_PORT}:8000 etc. — override via .env
Path("../.env.kong").write_text("KONG_HTTP_PORT=127.0.0.1:8000\nKONG_HTTPS_PORT=127.0.0.1:8443\n")
PY

set_env KONG_HTTP_PORT "127.0.0.1:8000"
set_env KONG_HTTPS_PORT "127.0.0.1:8443"
set_env API_GW_HTTP_PORT "127.0.0.1:8000"
set_env STUDIO_PORT "127.0.0.1:3000"

# Caddy reverse proxy
mkdir -p "$CADDY_DIR"
cat >"${CADDY_DIR}/Caddyfile" <<EOF
{
  email admin@${API_DOMAIN}
}

${API_DOMAIN} {
  reverse_proxy 127.0.0.1:8000
}

${STUDIO_DOMAIN} {
  basicauth {
    ${DASHBOARD_USERNAME} $(docker run --rm caddy:2.8.4-alpine caddy hash-password --plaintext "${DASHBOARD_PASSWORD}")
  }
  reverse_proxy 127.0.0.1:3000
}
EOF

cat >"${CADDY_DIR}/docker-compose.yml" <<'EOF'
services:
  caddy:
    image: caddy:2.8.4-alpine
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
volumes:
  caddy_data:
  caddy_config:
EOF

# Studio is not published by default in upstream compose — expose on localhost for Caddy.
cat >"${SUPABASE_DIR}/docker/docker-compose.override.yml" <<'EOF'
services:
  studio:
    ports:
      - "127.0.0.1:3000:3000/tcp"
EOF

docker compose pull
docker compose up -d

python3 - "${SUPABASE_DIR}/docker/docker-compose.yml" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
needle = "    container_name: supabase-studio\n"
ports = "    ports:\n      - \"127.0.0.1:3000:3000/tcp\"\n"
if "127.0.0.1:3000:3000" not in text:
    path.write_text(text.replace(needle, needle + ports, 1))
PY
cd "${SUPABASE_DIR}/docker"
docker compose up -d --force-recreate studio

cd "$CADDY_DIR"
docker compose pull
docker compose up -d

echo "Supabase + Caddy started. API=${PUBLIC_URL} Studio=https://${STUDIO_DOMAIN}"
