#!/usr/bin/env bash
# Phase 1 acceptance checks — run from laptop after deploy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SECRETS="${ROOT}/infra/vps/secrets.env"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"
SSH_KEY="${ROOT}/infra/vps/keys/frwhoop_deploy"

source "$DROPLET_ENV"
source "$SECRETS"

: "${API_DOMAIN:?Set API_DOMAIN in infra/vps/droplet.env or export before running}"
STUDIO_DOMAIN="${STUDIO_DOMAIN:-studio.${API_DOMAIN}}"

echo "========== 1. ufw status =========="
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" "sudo ufw status verbose"

echo "========== 2. TLS health =========="
curl -fsS "https://${API_DOMAIN}/auth/v1/health" -H "apikey: ${ANON_KEY}"
echo
curl -fsS "https://${API_DOMAIN}/rest/v1/noop_hr_samples?limit=0" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ANON_KEY}" >/dev/null
echo "REST noop_hr_samples: OK"

echo "========== 3. Studio TLS =========="
curl -fsSI -u "${DASHBOARD_USERNAME}:${DASHBOARD_PASSWORD}" "https://${STUDIO_DOMAIN}/" | head -5

echo "========== 4. pg extensions =========="
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
  "docker exec supabase-db psql -U postgres -d postgres -c \"SELECT extname FROM pg_extension ORDER BY 1;\""

echo "========== 5. migration count =========="
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
  "docker exec supabase-db psql -U postgres -d postgres -c \"SELECT count(*) FROM supabase_migrations.schema_migrations;\""

echo "========== 6. RLS spot-check (noop_hr_samples + noop_ingest_tokens) =========="
for table in noop_hr_samples noop_ingest_tokens; do
  enabled=$(ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
    "docker exec supabase-db psql -U postgres -d postgres -Atc \"SELECT c.relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relname = '${table}';\"" \
    | tr -d '[:space:]')
  if [[ "$enabled" != "t" ]]; then
    echo "FAIL: RLS not enabled on public.${table}" >&2
    exit 1
  fi
  echo "OK: RLS enabled on public.${table}"
done
derived=$(ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
  "docker exec supabase-db psql -U postgres -d postgres -Atc \"SELECT to_regclass('public.derived_objects');\"" \
  | tr -d '[:space:]')
[[ "$derived" == "derived_objects" ]] && echo "OK: derived_objects exists" || { echo "FAIL: derived_objects missing" >&2; exit 1; }
signal=$(ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
  "docker exec supabase-db psql -U postgres -d postgres -Atc \"SELECT to_regclass('public.noop_signal_windows');\"" \
  | tr -d '[:space:]')
[[ "$signal" == "noop_signal_windows" ]] && echo "OK: noop_signal_windows exists" || { echo "FAIL: noop_signal_windows missing" >&2; exit 1; }

echo "========== 7. restore drill =========="
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" "sudo bash /opt/frwhoop/scripts/05-restore-drill.sh"

echo "========== 8. docker compose ps / listeners =========="
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" "cd /opt/frwhoop/supabase-docker/docker && docker compose ps"
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" "ss -tlnp | grep -E ':(22|80|443|5432|6543|8000|3000)\s' || true"
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
  "! ss -tlnp | grep -E '0\\.0\\.0\\.0:(5432|6543|8000|3000)|\\[::\\]:(5432|6543|8000|3000)' || (echo 'FAIL: internal service bound publicly' >&2; exit 1)"
ssh -i "$SSH_KEY" "deploy@${DROPLET_IP}" \
  "sudo python3 /opt/frwhoop/scripts/14-pooler-network.py --check --running"

echo "All acceptance checks finished."
