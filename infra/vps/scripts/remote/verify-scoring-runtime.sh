#!/usr/bin/env bash
# Read-only operational acceptance. This never promotes an algorithm or repairs a network.
set -euo pipefail
release_sha="${1:-}"
[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'FAIL: expected a full release SHA' >&2; exit 1; }
SCORING_EXPECTED_IMAGE_ID="${2:-}"
[[ "$SCORING_EXPECTED_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'FAIL: provide the reviewed immutable image ID as argument 2' >&2; exit 1; }
SCORING_ALGORITHM_VERSION="${3:-frwhoop-physiology-2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/scoring-progress.sh" ]]; then
  # Installed standalone with the same exact release.
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/scoring-progress.sh"
else
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../scoring-progress.sh"
fi
# Dedicated intended configuration is authoritative, not the candidate's own destination.
# shellcheck disable=SC1091
source /opt/frwhoop/secrets.env
: "${SCORING_DATABASE_URL:?Dedicated scoring database is required}"
: "${SCORING_SUPABASE_URL:?Dedicated scoring REST endpoint is required}"
scoring_lane || { echo 'FAIL: unsupported worker version' >&2; exit 1; }
candidate_environment="$(timeout 12 docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$SCORING_CONTAINER_NAME")"
SCORING_WORKER_INSTANCE_ID="$(scoring_environment_value "$candidate_environment" SCORING_WORKER_INSTANCE_ID)"
SCORING_WORKER_SOURCE_REVISION="$release_sha"
unset candidate_environment
SCORING_ACCEPT_SECONDS="${SCORING_VERIFY_TIMEOUT_SECONDS:-180}"
export SCORING_WORKER_INSTANCE_ID SCORING_WORKER_SOURCE_REVISION SCORING_ACCEPT_SECONDS SCORING_EXPECTED_IMAGE_ID
scoring_assert_candidate "$release_sha" || { echo 'FAIL: candidate identity or same-project worker isolation' >&2; exit 1; }
scoring_wait_for_progress "$release_sha"
