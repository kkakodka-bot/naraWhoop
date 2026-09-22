#!/usr/bin/env bash
# Create a 4 vCPU / 8 GB Ubuntu 24.04 droplet on DigitalOcean.
# Requires: DIGITAL_OCEAN_TOKEN in repo-root .env, deploy pubkey in infra/vps/keys/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
KEY_PUB="${ROOT}/infra/vps/keys/frwhoop_deploy.pub"
DROPLET_ENV="${ROOT}/infra/vps/droplet.env"

if [[ ! -f "${ROOT}/.env" ]]; then
  echo "Missing ${ROOT}/.env" >&2
  exit 1
fi
# shellcheck disable=SC1091
source "${ROOT}/.env"

if [[ -z "${DIGITAL_OCEAN_TOKEN:-}" ]]; then
  echo "DIGITAL_OCEAN_TOKEN not set in .env" >&2
  exit 1
fi
if [[ ! -f "$KEY_PUB" ]]; then
  echo "Missing ${KEY_PUB} — run ssh-keygen first" >&2
  exit 1
fi

PUBKEY=$(cat "$KEY_PUB")
EXISTING=$(curl -s -H "Authorization: Bearer $DIGITAL_OCEAN_TOKEN" \
  "https://api.digitalocean.com/v2/account/keys" \
  | python3 -c "import sys,json; keys=json.load(sys.stdin).get('ssh_keys',[]); print(next((str(k['id']) for k in keys if k['name']=='frwhoop-deploy'), ''))")

if [[ -z "$EXISTING" ]]; then
  SSH_KEY_ID=$(curl -s -X POST -H "Authorization: Bearer $DIGITAL_OCEAN_TOKEN" -H "Content-Type: application/json" \
    -d "{\"name\":\"frwhoop-deploy\",\"public_key\":\"${PUBKEY}\"}" \
    "https://api.digitalocean.com/v2/account/keys" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ssh_key',{}).get('id','')); import sys as s; msg=d.get('message'); (msg and print(msg, file=s.stderr))")
else
  SSH_KEY_ID=$EXISTING
fi

if [[ -z "$SSH_KEY_ID" ]]; then
  echo "Failed to register SSH key" >&2
  exit 1
fi

CREATE=$(curl -s -X POST -H "Authorization: Bearer $DIGITAL_OCEAN_TOKEN" -H "Content-Type: application/json" \
  -d "{\"name\":\"frwhoop-supabase\",\"region\":\"sfo3\",\"size\":\"s-4vcpu-8gb\",\"image\":\"ubuntu-24-04-x64\",\"ssh_keys\":[${SSH_KEY_ID}],\"ipv6\":false,\"monitoring\":true,\"tags\":[\"frwhoop\",\"supabase\"]}" \
  "https://api.digitalocean.com/v2/droplets")

DROPLET_ID=$(echo "$CREATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('droplet',{}).get('id',''))")
if [[ -z "$DROPLET_ID" ]]; then
  echo "$CREATE" >&2
  echo "Droplet create failed" >&2
  exit 1
fi

echo "DROPLET_ID=${DROPLET_ID}" >"$DROPLET_ENV"
echo "SSH_KEY_ID=${SSH_KEY_ID}" >>"$DROPLET_ENV"
echo "Created droplet ${DROPLET_ID}; waiting for public IP..."

for _ in $(seq 1 60); do
  IP=$(curl -s -H "Authorization: Bearer $DIGITAL_OCEAN_TOKEN" \
    "https://api.digitalocean.com/v2/droplets/${DROPLET_ID}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin)['droplet']; print(next((n['ip_address'] for n in d.get('networks',{}).get('v4',[]) if n['type']=='public'), ''))")
  if [[ -n "$IP" ]]; then
    echo "DROPLET_IP=${IP}" >>"$DROPLET_ENV"
    echo "Public IP: ${IP}"
    exit 0
  fi
  sleep 5
done

echo "Timed out waiting for IP" >&2
exit 1
