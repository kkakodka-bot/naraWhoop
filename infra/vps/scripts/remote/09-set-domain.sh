#!/usr/bin/env bash
# Switch public URLs to a custom domain (updates Supabase .env + Caddy + recreates Studio port patch).
set -euo pipefail

BASE="/opt/frwhoop"
SECRETS="${BASE}/secrets.env"
SUPABASE_DIR="${BASE}/supabase-docker"
CADDY_DIR="${BASE}/caddy"
COMPOSE_DIR="${SUPABASE_DIR}/docker"

API_DOMAIN="${1:?Usage: set-domain.sh api.example.com [studio.example.com]}"
STUDIO_DOMAIN="${2:-studio.${API_DOMAIN}}"
PUBLIC_URL="https://${API_DOMAIN}"

[[ -f "$SECRETS" ]] && source "$SECRETS"

set_env() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" "${COMPOSE_DIR}/.env"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${COMPOSE_DIR}/.env"
  else
    echo "${key}=${val}" >>"${COMPOSE_DIR}/.env"
  fi
}

set_env API_EXTERNAL_URL "$PUBLIC_URL"
set_env SUPABASE_PUBLIC_URL "$PUBLIC_URL"
set_env SITE_URL "$PUBLIC_URL"

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

cd "${COMPOSE_DIR}"
docker compose up -d

cd "${CADDY_DIR}"
docker compose up -d

echo "Domain configured: API=${PUBLIC_URL} Studio=https://${STUDIO_DOMAIN}"
echo "Ensure DNS A records for both hostnames point to this server's public IP before expecting TLS."
