#!/usr/bin/env bash
# Read-only acceptance checks. No deployment shell configuration is loaded in ANY mode.
set -euo pipefail
trap 'echo "NOT_READY: acceptance command failed" >&2' ERR
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MODE="${1:---remote}"
case "$MODE" in
  --local|--remote|--preflight) ;;
  *) echo "Usage: $0 [--local|--remote|--preflight]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "NOT_READY: unexpected arguments" >&2; exit 2; }
if [[ "$MODE" != --local ]]; then
  : "${SYNC_ACCEPTANCE_EVIDENCE:?NOT_READY: captured evidence JSON required}"
  node "${ROOT}/infra/vps/scripts/verify-sync-evidence.mjs" "$SYNC_ACCEPTANCE_EVIDENCE"
  [[ "$MODE" != --preflight ]] || exit 0
fi

# Caller supplies SDK/JDK settings. No brew/config fallback or secrets.env/droplet.env sourcing.
: "${JAVA_HOME:?NOT_READY: explicit Java 17 JAVA_HOME required for native checks}"
[[ -x "$JAVA_HOME/bin/java" ]] || { echo "NOT_READY: JAVA_HOME/bin/java unavailable" >&2; exit 3; }
export JAVA_HOME
cd "${ROOT}/scoring-service"
./gradlew :analytics-kernel:test --no-daemon
cd "${ROOT}/android"
./gradlew testFullDebugUnitTest --tests com.noop.analytics.CurrentHrvTest --no-daemon
./gradlew compileFullDebugKotlin testFullDebugUnitTest --tests "com.noop.analytics.*" --no-daemon
cd "${ROOT}/scoring-service"
./gradlew :service:test :service:installDist --no-daemon
node "${ROOT}/infra/vps/scripts/check-sync-sources.mjs" "$ROOT"

if [[ "$MODE" == --local ]]; then
  echo "LOCAL_CHECKS_PASSED; NOT_READY: separate whole-day parity and deployment/canary/device gates were not run" >&2
  exit 3
fi
node "${ROOT}/infra/vps/scripts/check-sync-live.mjs"
