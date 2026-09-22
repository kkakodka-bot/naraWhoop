#!/usr/bin/env bash
# Generate self-hosted Supabase secrets. Writes infra/vps/secrets.env (gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ROOT}/vps/secrets.env"

rand() { openssl rand -hex 32; }
vault_key() { openssl rand -hex 16; }

POSTGRES_PASSWORD="$(rand)"
JWT_SECRET="$(rand)"
SECRET_KEY_BASE="$(rand)"
VAULT_ENC_KEY="$(vault_key)"
PG_META_CRYPTO_KEY="$(rand)"
LOGFLARE_PUBLIC="$(rand)"
LOGFLARE_PRIVATE="$(rand)"
WORKER_SECRET="$(rand)"
DASHBOARD_USERNAME="frwhoop-admin"
DASHBOARD_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"

now=$(date +%s)
exp=$((now + 10 * 365 * 24 * 3600))

mint_jwt() {
  local role="$1"
  python3 - "$role" "$JWT_SECRET" "$now" "$exp" <<'PY'
import base64, hashlib, hmac, json, sys
role, secret, iat, exp = sys.argv[1:5]

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")

header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
payload = b64url(json.dumps({"role": role, "iss": "supabase", "iat": int(iat), "exp": int(exp)}, separators=(",", ":")).encode())
sig = b64url(hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest())
print(f"{header}.{payload}.{sig}")
PY
}

ANON_KEY="$(mint_jwt anon)"
SERVICE_ROLE_KEY="$(mint_jwt service_role)"

cat >"$OUT" <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) — NEVER COMMIT
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
JWT_SECRET=${JWT_SECRET}
SECRET_KEY_BASE=${SECRET_KEY_BASE}
VAULT_ENC_KEY=${VAULT_ENC_KEY}
PG_META_CRYPTO_KEY=${PG_META_CRYPTO_KEY}
LOGFLARE_PUBLIC_ACCESS_TOKEN=${LOGFLARE_PUBLIC}
LOGFLARE_PRIVATE_ACCESS_TOKEN=${LOGFLARE_PRIVATE}
WORKER_SECRET=${WORKER_SECRET}
DASHBOARD_USERNAME=${DASHBOARD_USERNAME}
DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
EOF

chmod 600 "$OUT"
echo "Wrote ${OUT}"
