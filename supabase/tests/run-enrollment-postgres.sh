#!/usr/bin/env bash
set -euo pipefail

service_dir="$(cd "$(dirname "$0")/../../scoring-service" && pwd)"
repo_dir="$(cd "$service_dir/.." && pwd)"
pg_bin="${PG_BIN:-$(pg_config --bindir)}"
pg_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/enrollment-audit.XXXXXX")"
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
  20260907170000_noop_raw_object_lane.sql \
  20260911120000_noop_remaining_append_projections.sql \
  20260916160000_scoring_service_state.sql \
  20260916170000_scoring_work_items_device_id.sql \
  20260917190000_scoring_derived_artifact.sql \
  20260918010000_physiology_revisions.sql; do
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
for migration in "$repo_dir"/supabase/migrations/20260918[1-9]*.sql; do
  [[ -f "$migration" ]] || continue
  if [[ "$(basename "$migration")" == 20260918100000_physiology_independent_work.sql ]]; then
    "${psql_cmd[@]}" -f "$service_dir/service/src/test/resources/physiology_queue_isolation_fixture.sql" >>"$pg_test_dir/migrations.log"
  fi
  if [[ "$(basename "$migration")" == 20260918200000_restore_input_revision_fencing.sql ]]; then
    "${psql_cmd[@]}" -f "$service_dir/service/src/test/resources/physiology_coalesced_claim_fixture.sql" >>"$pg_test_dir/migrations.log"
  fi
  "${psql_cmd[@]}" -f "$migration" >>"$pg_test_dir/migrations.log"
done
"${psql_cmd[@]}" -f "$repo_dir/supabase/migrations/20260919010000_skin_temperature_dependencies.sql" >>"$pg_test_dir/migrations.log"

# These platform columns exist in production; the queue fixture omits them because queue tests do not register devices.
"${psql_cmd[@]}" -c "alter table devices add column source_kind text; alter table devices add column external_device_id text; alter table devices add column updated_at timestamptz default now(); create unique index devices_user_external_fixture on devices(user_id,source_kind,external_device_id) where external_device_id is not null;" >>"$pg_test_dir/migrations.log"
for migration in 20260907140000_noop_ingest_tokens.sql 20260919200000_noop_enrollment_identity.sql 20260919210000_enrolled_device_scores.sql; do
  "${psql_cmd[@]}" -f "$repo_dir/supabase/migrations/$migration" >>"$pg_test_dir/migrations.log"
done
"${psql_cmd[@]}" -f "$repo_dir/supabase/tests/enrollment-identity.sql"
race_sql="select set_config('request.jwt.claim.role','service_role',false); select * from redeem_noop_enrollment(repeat('c',64),'cccccccc-cccc-4ccc-8ccc-cccccccccccc','ios','fixture',repeat('7',64),300);"
"${psql_cmd[@]}" -c "$race_sql" >"$pg_test_dir/race-a.log" &
race_a=$!
"${psql_cmd[@]}" -c "$race_sql" >"$pg_test_dir/race-b.log" &
race_b=$!
wait "$race_a"
wait "$race_b"
"${psql_cmd[@]}" -c "do \$\$ begin if (select count(*) from noop_ingest_tokens where source_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc' and revoked_at is null) <> 1 then raise exception 'concurrent redemption minted multiple credentials'; end if; if (select count(*) from noop_enrollment_redemptions where source_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc') <> 2 then raise exception 'concurrent retry not recorded'; end if; end \$\$;"
printf 'PASS enrollment, source binding, per-device readback, override concurrency and privileges; evidence: %s\n' "$pg_test_dir"
