#!/usr/bin/env bash
# Ensure Studio is reachable on 127.0.0.1:3000 for Caddy (upstream compose omits host ports).
set -euo pipefail

COMPOSE_DIR="${1:-/opt/frwhoop/supabase-docker/docker}"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

python3 - "$COMPOSE_FILE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
needle = "    container_name: supabase-studio\n"
ports = "    ports:\n      - \"127.0.0.1:3000:3000/tcp\"\n"
if "127.0.0.1:3000:3000" in text:
    print("Studio port already configured")
else:
    if needle not in text:
        raise SystemExit("studio service anchor not found in docker-compose.yml")
    path.write_text(text.replace(needle, needle + ports, 1))
    print("Patched studio ports in docker-compose.yml")
PY

cd "$COMPOSE_DIR"
docker compose up -d --force-recreate studio
sleep 3
ss -tlnp | grep 127.0.0.1:3000
