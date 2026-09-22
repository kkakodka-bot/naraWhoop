#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Dedicated configuration is authoritative. No credentials are printed or passed as arguments.
# shellcheck disable=SC1091
source /opt/frwhoop/secrets.env
# shellcheck disable=SC1091
source /opt/frwhoop/scoring-client.env
export SCORING_DATABASE_URL SCORING_SUPABASE_URL SCORING_POSTGRES_CLIENT_IMAGE \
  SCORING_POSTGRES_CLIENT_CONFIG_DIGEST SCORING_POSTGRES_CLIENT_PLATFORM SCORING_POSTGRES_CLIENT_VERSION
exec python3 "$SCRIPT_DIR/scoring-hosted-query.py"
