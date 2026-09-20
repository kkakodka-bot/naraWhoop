#!/usr/bin/env bash
set -euo pipefail

service_dir="$(cd "$(dirname "$0")/.." && pwd)"
pg_bin="${PG_BIN:-$(pg_config --bindir)}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/runtime-preflight.XXXXXX")"
test_port="${RUNTIME_PREFLIGHT_TEST_PORT:-$((54000 + RANDOM % 8000))}"
cleanup() { "$pg_bin/pg_ctl" -D "$test_dir/data" -m fast stop >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$pg_bin/initdb" -D "$test_dir/data" -A trust -U postgres --no-locale >"$test_dir/init.log"
"$pg_bin/pg_ctl" -D "$test_dir/data" -l "$test_dir/server.log" \
  -o "-h 127.0.0.1 -p $test_port -k $test_dir" -w start
"$pg_bin/createdb" -h 127.0.0.1 -p "$test_port" -U postgres runtime_preflight_test
export RUNTIME_PREFLIGHT_TEST_DATABASE_URL="postgresql://postgres@127.0.0.1:$test_port/runtime_preflight_test"
cd "$service_dir"
./gradlew :service:test --tests com.frwhoop.scoring.RuntimePreflightCommandTest \
  --tests com.frwhoop.scoring.WorkerHeartbeatIdentityTest \
  --tests com.frwhoop.scoring.RuntimePreflightIntegrationTest --no-daemon --max-workers=2 --rerun-tasks
cp service/build/test-results/test/TEST-com.frwhoop.scoring.RuntimePreflight*.xml "$test_dir/"
cp service/build/test-results/test/TEST-com.frwhoop.scoring.WorkerHeartbeatIdentityTest.xml "$test_dir/"
printf 'Disposable PostgreSQL preflight evidence: %s\n' "$test_dir"
