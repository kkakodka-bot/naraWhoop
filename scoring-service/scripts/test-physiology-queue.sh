#!/usr/bin/env bash
set -euo pipefail
test_scope="${1:-test}"
[[ "$test_scope" == test || "$test_scope" == schema ]] || { printf 'Use test or schema\n' >&2; exit 2; }

service_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$service_dir/.." && pwd)"
pg_bin="${PG_BIN:-$(pg_config --bindir)}"
pg_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/physiology-queue.XXXXXX")"
pg_test_port="${PHYSIOLOGY_TEST_PORT:-$((54000 + RANDOM % 8000))}"
cleanup() { "$pg_bin/pg_ctl" -D "$pg_test_dir/data" -m fast stop >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$pg_bin/initdb" -D "$pg_test_dir/data" -A trust -U postgres --no-locale >"$pg_test_dir/init.log"
"$pg_bin/pg_ctl" -D "$pg_test_dir/data" -l "$pg_test_dir/server.log" \
  -o "-h 127.0.0.1 -p $pg_test_port -k $pg_test_dir" -w start
"$pg_bin/createdb" -h 127.0.0.1 -p "$pg_test_port" -U postgres physiology_queue_test
export PHYSIOLOGY_TEST_DATABASE_URL="postgresql://postgres@127.0.0.1:$pg_test_port/physiology_queue_test"
psql_cmd=("$pg_bin/psql" "$PHYSIOLOGY_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1)
"${psql_cmd[@]}" -f "$service_dir/service/src/test/resources/physiology_queue_bootstrap.sql" >"$pg_test_dir/migrations.log"
for migration in \
  20260907133000_noop_hr_samples.sql \
  20260907133100_noop_append_stream_projections.sql \
  20260907140000_noop_ingest_tokens.sql \
  20260907170000_noop_raw_object_lane.sql \
  20260911120000_noop_remaining_append_projections.sql \
  20260916160000_scoring_service_state.sql \
  20260916170000_scoring_work_items_device_id.sql \
  20260917190000_scoring_derived_artifact.sql \
  20260918010000_physiology_revisions.sql \
  20260918010000_production_scoring_durability.sql; do
  if [[ "$migration" == 20260918010000_physiology_revisions.sql ]]; then
    "${psql_cmd[@]}" -f "$service_dir/service/src/test/resources/physiology_queue_legacy_fixture.sql" >>"$pg_test_dir/migrations.log"
  fi
  "${psql_cmd[@]}" -f "$repo_dir/supabase/migrations/$migration" >>"$pg_test_dir/migrations.log"
done
if [[ -f "$repo_dir/supabase/migrations/20260918020000_physiology_publication.sql" ]]; then
  "${psql_cmd[@]}" -f "$repo_dir/supabase/migrations/20260918020000_physiology_publication.sql" >>"$pg_test_dir/migrations.log"
fi
if [[ -f "$repo_dir/supabase/migrations/20260918030000_physiology_hrv_dependencies.sql" ]]; then
  "${psql_cmd[@]}" -f "$repo_dir/supabase/migrations/20260918030000_physiology_hrv_dependencies.sql" >>"$pg_test_dir/migrations.log"
fi
"${psql_cmd[@]}" -f "$repo_dir/supabase/migrations/20260918030000_production_scoring_review_repairs.sql" >>"$pg_test_dir/migrations.log"
if [[ -f "$repo_dir/supabase/migrations/20260918040000_rr_packet_provenance.sql" ]]; then
  "${psql_cmd[@]}" -f "$repo_dir/supabase/migrations/20260918040000_rr_packet_provenance.sql" >>"$pg_test_dir/migrations.log"
fi
if [[ -f "$repo_dir/supabase/migrations/20260918050000_physiology_calendar_ownership.sql" ]]; then
  "${psql_cmd[@]}" -f "$repo_dir/supabase/migrations/20260918050000_physiology_calendar_ownership.sql" >>"$pg_test_dir/migrations.log"
fi
if [[ -f "$repo_dir/supabase/migrations/20260918060000_physiology_wear_dependencies.sql" ]]; then
  "${psql_cmd[@]}" -f "$repo_dir/supabase/migrations/20260918060000_physiology_wear_dependencies.sql" >>"$pg_test_dir/migrations.log"
fi
if [[ -f "$repo_dir/supabase/migrations/20260918070000_physiology_legacy_boundary_continuation.sql" ]]; then
  "${psql_cmd[@]}" -f "$repo_dir/supabase/migrations/20260918070000_physiology_legacy_boundary_continuation.sql" >>"$pg_test_dir/migrations.log"
fi
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  [[ -f "$migration" ]] || continue
  [[ "$(basename "$migration")" < 20260918100000_ ]] && continue
  if [[ "$(basename "$migration")" == 20260918100000_physiology_independent_work.sql ]]; then
    "${psql_cmd[@]}" -f "$service_dir/service/src/test/resources/physiology_queue_isolation_fixture.sql" >>"$pg_test_dir/migrations.log"
  fi
  if [[ "$(basename "$migration")" == 20260918200000_restore_input_revision_fencing.sql ]]; then
    "${psql_cmd[@]}" -f "$service_dir/service/src/test/resources/physiology_coalesced_claim_fixture.sql" >>"$pg_test_dir/migrations.log"
  fi
  "${psql_cmd[@]}" -f "$migration" >>"$pg_test_dir/migrations.log"
done
if [[ "$test_scope" == schema ]]; then
  printf 'Disposable PostgreSQL focused schema applied (tests not run): %s\n' "$pg_test_dir"
  exit 0
fi
cd "$service_dir"
if [[ "${PHYSIOLOGY_ALL_JVM_TESTS:-0}" == 1 ]]; then
  # The whole-day Swift oracle remains mandatory in this mode. test-server-jvm.sh produces it
  # from the actual current Swift sources before entering this disposable database harness.
  : "${W4_SWIFT_DAY_FIXTURE_DIR:?Run test-server-jvm.sh or provide a current actual-Swift corpus}"
  : "${W3_TEST_ARTIFACTS:?Provide an output directory for the real context snapshot fixture}"
  "$pg_bin/createdb" -h 127.0.0.1 -p "$pg_test_port" -U postgres runtime_preflight_test
  export RUNTIME_PREFLIGHT_TEST_DATABASE_URL="postgresql://postgres@127.0.0.1:$pg_test_port/runtime_preflight_test"
  ./gradlew clean test :service:installDist --no-daemon
else
./gradlew :service:test --tests com.frwhoop.scoring.ScoringWorkQueueIntegrationTest \
  --tests com.frwhoop.scoring.WorkerHeartbeatIntegrationTest \
  --tests com.frwhoop.scoring.PostgresDeadlineIntegrationTest \
  --tests com.frwhoop.scoring.ScoringInputGateIntegrationTest \
  --tests com.frwhoop.scoring.ProjectionInvalidationIntegrationTest \
  --tests com.frwhoop.scoring.CompositeBaselineIntegrationTest \
  --tests com.frwhoop.scoring.SkinTemperatureDependencyIntegrationTest \
  --tests com.frwhoop.scoring.IndependentScoringWorkIntegrationTest \
  --tests com.frwhoop.scoring.PhysiologyPublicationIntegrationTest \
  --tests com.frwhoop.scoring.PhysiologyPromotionIntegrationTest \
  --tests com.frwhoop.scoring.PhysiologyModelQueueIntegrationTest \
  --tests com.frwhoop.scoring.MotionEvidenceIntegrationTest \
  --tests com.frwhoop.scoring.PhysiologyDependencyIntegrationTest \
  --tests com.frwhoop.scoring.RrPacketProvenanceIntegrationTest \
  --tests com.frwhoop.scoring.StandardHRReceiptIntegrationTest \
  --tests com.frwhoop.scoring.PhysiologyWearDependencyIntegrationTest \
  --tests com.frwhoop.scoring.RawSignalCatalogueIntegrationTest \
  --tests com.frwhoop.scoring.LegacySleepContinuationIntegrationTest \
  --tests com.frwhoop.scoring.SignalInventoryIntegrationTest \
  --tests com.frwhoop.scoring.CalendarOwnershipIntegrationTest --rerun-tasks
fi
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.ScoringWorkQueueIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.WorkerHeartbeatIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.PostgresDeadlineIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.ScoringInputGateIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.ProjectionInvalidationIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.CompositeBaselineIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.SkinTemperatureDependencyIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.PhysiologyPublicationIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.PhysiologyPromotionIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.PhysiologyModelQueueIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.MotionEvidenceIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.PhysiologyDependencyIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.CalendarOwnershipIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.RrPacketProvenanceIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.StandardHRReceiptIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.PhysiologyWearDependencyIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.RawSignalCatalogueIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.LegacySleepContinuationIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.SignalInventoryIntegrationTest.xml" "$pg_test_dir/"
cp "$service_dir/service/build/test-results/test/TEST-com.frwhoop.scoring.IndependentScoringWorkIntegrationTest.xml" "$pg_test_dir/"
printf 'Disposable PostgreSQL queue evidence: %s\n' "$pg_test_dir"
