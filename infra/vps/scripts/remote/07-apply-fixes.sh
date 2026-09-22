#!/usr/bin/env bash
# Apply Phase 1 hardening fixes on a running VPS (Envoy localhost, AWS CLI, cron, scripts).
set -euo pipefail

BASE="/opt/frwhoop"
COMPOSE_DIR="${BASE}/supabase-docker/docker"

set_env() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" "${COMPOSE_DIR}/.env"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${COMPOSE_DIR}/.env"
  else
    echo "${key}=${val}" >>"${COMPOSE_DIR}/.env"
  fi
}

set_env API_GW_HTTP_PORT "127.0.0.1:8000"
set_env KONG_HTTP_PORT "127.0.0.1:8000"
set_env KONG_HTTPS_PORT "127.0.0.1:8443"
set_env STUDIO_PORT "127.0.0.1:3000"

cd "${COMPOSE_DIR}"
docker compose up -d api-gw studio

if ! command -v aws >/dev/null 2>&1; then
  bash "${BASE}/scripts/06-install-awscli.sh"
fi

if [[ ! -f /etc/cron.d/frwhoop-backup ]]; then
  echo '0 3 * * * root /opt/frwhoop/scripts/04-backup.sh >> /var/log/frwhoop-backup.log 2>&1' >/etc/cron.d/frwhoop-backup
  chmod 644 /etc/cron.d/frwhoop-backup
fi

bash "${BASE}/scripts/08-studio-localhost.sh" "${COMPOSE_DIR}"
bash "${BASE}/scripts/10-fix-supavisor.sh" "${COMPOSE_DIR}"

echo "Hardening fixes applied."
