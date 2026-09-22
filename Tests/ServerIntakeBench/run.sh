#!/bin/zsh
set -euo pipefail
benchOutput=${1:?External artifact directory required}
benchRepetitions=${2:-30}
benchWarmups=${3:-3}
benchRoot=${0:A:h:h:h}
benchToolRoot=/Volumes/Untitled/nara-production-sync-evidence-20260918/edge-tools
[[ "$benchOutput" == /Volumes/* ]] || { print -u2 'External artifact directory required'; exit 2; }
mkdir -p "$benchOutput/tmp"
# Darwin Unix socket paths are short; keep the disposable cluster separately, without deleting evidence.
benchServices=$(mktemp -d /Volumes/Untitled/nara-ib.XXXXXX)
cd "$benchRoot"
benchSHA=$(git rev-parse HEAD)
benchDirty=$(git status --porcelain -- supabase/functions supabase/migrations Tests/ServerIntakeBench | wc -l | tr -d ' ')
exec /usr/bin/time -l env -i PATH=/opt/homebrew/bin:/usr/bin:/bin \
  EDGE_TEST_ARTIFACTS="$benchServices" INTAKE_BENCH_OUTPUT="$benchOutput" TMPDIR="$benchOutput/tmp" \
  INTAKE_BENCH_SOURCE_SHA="$benchSHA" INTAKE_BENCH_SOURCE_DIRTY="$benchDirty" \
  INTAKE_BENCH_REPETITIONS="$benchRepetitions" INTAKE_BENCH_WARMUPS="$benchWarmups" \
  INTAKE_BENCH_HOST_CONTENTION='Concurrent root hosted build/tests may run; no isolated-host claim' \
  DENO_DIR="$benchToolRoot/deno-cache" \
  "$benchToolRoot/node_modules/@deno/darwin-arm64/deno" run --cached-only --frozen \
  --lock=supabase/functions/deno.lock --allow-env --allow-read --allow-write="$benchOutput,$benchServices" \
  --allow-run=/opt/homebrew/bin/initdb,/opt/homebrew/bin/pg_ctl,/opt/homebrew/bin/psql,/opt/homebrew/bin/postgrest \
  --allow-net=127.0.0.1,localhost Tests/ServerIntakeBench/main.ts
