#!/usr/bin/env bash
# Sourced by deployment and read-only acceptance. No measurement payloads leave PostgreSQL.

scoring_worker_ids() {
  local id mode environment ids
  ids="$(timeout 12 docker ps --no-trunc "$1")" || return 1
  while read -r id; do
    [[ -n "$id" ]] || continue
    environment="$(timeout 12 docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id")" || return 1
    if grep -Fxq 'SCORING_ALGORITHM_VERSION=frwhoop-physiology-2' <<<"$environment"; then
      mode="$(timeout 12 docker inspect -f '{{json .Config.Cmd}}' "$id")" || return 1
      # Optional-model and archive lanes are independent processes, not replacement targets.
      case "$mode" in
        *--models-only*|*--activate-model*|*--archive-only*|*--inventory*) continue ;;
      esac
      printf '%s\n' "$id"
    fi
  done <<<"$ids"
}

scoring_environment_value() {
  local environment="$1" key="$2" line value="" found=false
  while IFS= read -r line; do
    case "$line" in
      "$key="*)
        [[ "$found" == false ]] || return 1
        value="${line#*=}"; found=true ;;
    esac
  done <<<"$environment"
  [[ "$found" == true && -n "$value" ]] || return 1
  printf '%s' "$value"
}

scoring_identity_valid() {
  [[ "${SCORING_WORKER_INSTANCE_ID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ &&
     "${SCORING_WORKER_SOURCE_REVISION:-}" =~ ^[0-9a-f]{40}$ ]]
}

scoring_assert_candidate() {
  local release_sha="$1" container="scoring-physiology-v2" ports running candidate_id mode environment
  [[ "$(timeout 12 docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$container")" == "$release_sha" ]] || return 1
  [[ "$(timeout 12 docker inspect -f '{{.State.Running}}' "$container")" == true ]] || return 1
  [[ "$(timeout 12 docker inspect -f '{{.RestartCount}}' "$container")" == 0 ]] || return 1
  mode="$(timeout 12 docker inspect -f '{{json .Config.Cmd}}' "$container")" || return 1
  [[ "$mode" == '[]' || "$mode" == null ]] || return 1
  ports="$(timeout 12 docker port "$container")" || return 1
  [[ -z "$ports" ]] || return 1
  environment="$(timeout 12 docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container")" || return 1
  scoring_identity_valid || return 1
  [[ -n "${SCORING_DATABASE_URL:-}" && -n "${SCORING_SUPABASE_URL:-}" &&
     "$SCORING_WORKER_SOURCE_REVISION" == "$release_sha" ]] || return 1
  # Compare in memory, never print either credentials or the configured destinations.
  [[ "$(scoring_environment_value "$environment" DATABASE_URL)" == "$SCORING_DATABASE_URL" &&
     "$(scoring_environment_value "$environment" SUPABASE_URL)" == "$SCORING_SUPABASE_URL" &&
     "$(scoring_environment_value "$environment" SCORING_WORKER_INSTANCE_ID)" == "$SCORING_WORKER_INSTANCE_ID" &&
     "$(scoring_environment_value "$environment" SCORING_WORKER_SOURCE_REVISION)" == "$release_sha" ]] || return 1
  if grep -q '^REPLAY_' <<<"$environment"; then
    return 1
  fi
  candidate_id="$(timeout 12 docker inspect -f '{{.Id}}' "$container")" || return 1
  running="$(scoring_worker_ids -q)" || return 1
  [[ "$running" == "$candidate_id" ]]
}

scoring_progress_snapshot() {
  # The local postgres container supplies psql only. The dedicated HOSTED URL is passed on
  # stdin, never as a printed Docker argument; no local database default is permitted.
  [[ -n "${SCORING_DATABASE_URL:-}" && "$SCORING_DATABASE_URL" != *$'\n'* ]] || return 1
  scoring_identity_valid || return 1
  case "$SCORING_DATABASE_URL" in
    *"@db:"*|*"//db:"*|*localhost*|*127.0.0.1*) return 1 ;;
  esac
  # The single-quoted psql launcher expands its variable inside the client container only.
  # shellcheck disable=SC2016
  {
    printf '%s\n' "$SCORING_DATABASE_URL"
    printf '%s\n' "BEGIN READ ONLY;
SET LOCAL statement_timeout='5s';
SET LOCAL lock_timeout='500ms';
SET LOCAL idle_in_transaction_session_timeout='10s';
WITH candidates AS MATERIALIZED (
 SELECT process_instance_id,last_poll_at,last_score_at,last_error
 FROM public.physiology_worker_heartbeats
 WHERE worker_instance_id='${SCORING_WORKER_INSTANCE_ID}'::uuid
   AND source_revision='${SCORING_WORKER_SOURCE_REVISION}'
   AND algorithm_version='frwhoop-physiology-2' LIMIT 2
), cardinality AS (SELECT count(*) AS processes FROM candidates)
SELECT n.processes,coalesce(h.process_instance_id::text,'none'),coalesce(extract(epoch from h.last_poll_at)::bigint,0),
 coalesce(extract(epoch from h.last_score_at)::bigint,0),(h.last_error IS NULL),
 EXISTS(SELECT 1 FROM public.physiology_work_items w WHERE w.done_at IS NULL
   AND w.status IN ('pending','running','retry')
   AND (w.next_attempt_at<=clock_timestamp() OR
        (w.status='running' AND w.lease_expires_at>clock_timestamp()))
   AND (w.failure_revision<>w.input_revision OR w.consecutive_failures<8)),
 extract(epoch from clock_timestamp())::bigint
FROM cardinality n LEFT JOIN candidates h ON n.processes=1;
ROLLBACK;"
  } | timeout 12 docker exec -i supabase-db sh -c '
    IFS= read -r scoring_database_url
    export PGCONNECT_TIMEOUT=5
    exec psql "$scoring_database_url" -X -q -A -t -F "|" -v ON_ERROR_STOP=1
  ' 2>/dev/null
}

scoring_parse_snapshot() {
  local snapshot="$1" extra
  [[ "$snapshot" != *$'\n'* ]] || return 1
  IFS='|' read -r progress_processes progress_process progress_poll progress_score progress_healthy progress_debt progress_now extra <<<"$snapshot"
  [[ -z "$extra" && "$progress_processes" =~ ^[01]$ &&
     "$progress_poll" =~ ^[0-9]+$ && "$progress_score" =~ ^[0-9]+$ &&
     "$progress_now" =~ ^[0-9]+$ && "$progress_healthy" =~ ^[tf]$ &&
     "$progress_debt" =~ ^[tf]$ ]] || return 1
  if [[ "$progress_processes" == 0 ]]; then
    [[ "$progress_process" == none && "$progress_poll" == 0 && "$progress_score" == 0 ]] || return 1
  else
    [[ "$progress_process" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
  fi
  ((progress_poll <= progress_now + 60 && progress_score <= progress_now + 60))
}

scoring_wait_for_progress() {
  local release_sha="$1" baseline="$2" snapshot previous_poll initial_score process_id=""
  local require_score=false poll_advances=0 seconds="${SCORING_ACCEPT_SECONDS:-1800}" attempt deadline
  [[ "$seconds" =~ ^[0-9]+$ ]] && ((seconds >= 15 && seconds <= 3600)) || return 1
  scoring_parse_snapshot "$baseline" || return 1
  previous_poll="$progress_poll"; initial_score="$progress_score"
  [[ "$progress_processes" == 0 ]] || process_id="$progress_process"
  [[ "$progress_debt" != t ]] || require_score=true
  deadline=$((SECONDS + seconds))
  for ((attempt=0; attempt<(seconds+4)/5 && SECONDS<deadline; attempt++)); do
    sleep 5
    scoring_assert_candidate "$release_sha" || { echo 'Candidate identity/process check failed' >&2; return 1; }
    snapshot="$(scoring_progress_snapshot)" || { echo 'Hosted progress query failed' >&2; return 1; }
    scoring_parse_snapshot "$snapshot" || { echo 'Invalid hosted progress response' >&2; return 1; }
    [[ "$progress_debt" != t ]] || require_score=true
    [[ "$progress_processes" != 0 ]] || continue
    if [[ -z "$process_id" ]]; then process_id="$progress_process"; fi
    [[ "$process_id" == "$progress_process" ]] || { echo 'Candidate process identity changed' >&2; return 1; }
    if ((progress_poll > previous_poll)); then
      poll_advances=$((poll_advances + 1)); previous_poll="$progress_poll"
    fi
    # Two post-cutover poll advances demonstrate another cycle, not merely startup before
    # a stuck first job. A score advance is required if eligible debt appears at any sample.
    if ((poll_advances >= 2)) && [[ "$progress_healthy" == t ]] &&
        { [[ "$require_score" == false ]] || ((progress_score > initial_score)); }; then
      echo 'Accepted: exact worker, advancing hosted polls and required publication progress'
      return 0
    fi
  done
  echo 'Candidate did not demonstrate bounded hosted scoring progress' >&2
  return 1
}
