#!/usr/bin/env bash
# Sourced by deployment and read-only acceptance. No measurement payloads leave PostgreSQL.

scoring_project_host() {
  local authority="${1#https://}"
  [[ "$1" == https://* ]] || return 1
  authority="${authority%%/*}"; authority="${authority%:443}"
  [[ -n "$authority" && "$authority" != *@* ]] || return 1
  printf '%s' "$authority" | tr '[:upper:]' '[:lower:]'
}

scoring_monotonic_seconds() { python3 -c 'import time; print(int(time.monotonic()))'; }

scoring_worker_ids() {
  local id mode environment ids endpoint host intended
  intended="$(scoring_project_host "${SCORING_SUPABASE_URL:-}")" || return 1
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
      endpoint="$(scoring_environment_value "$environment" SUPABASE_URL)" || return 1
      host="$(scoring_project_host "$endpoint")" || return 1
      [[ "$host" == "$intended" ]] || continue
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
  scoring_identity_valid || return 1
  local database_url="${SCORING_DATABASE_URL#jdbc:}"
  export SCORING_WORKER_INSTANCE_ID SCORING_WORKER_SOURCE_REVISION
  # A disposable client needs no local Supabase stack. The URI is inherited through the
  # environment, never placed in process arguments, logs, or a temporary file. PGDATABASE
  # alone does not expand a URI, so decode its fields once before passing libpq variables.
  local SCORING_VERIFY_DATABASE_URL="$database_url"
  local SCORING_VERIFY_QUERY_TIMEOUT="${1:-40}"
  export SCORING_VERIFY_DATABASE_URL SCORING_VERIFY_QUERY_TIMEOUT
  python3 -c '
import os, subprocess, sys
from urllib.parse import urlsplit, unquote, parse_qsl
try:
    url = urlsplit(os.environ["SCORING_VERIFY_DATABASE_URL"])
    if url.scheme not in ("postgres", "postgresql") or not url.hostname or not url.username or url.fragment:
        raise ValueError("unsupported database URI")
    names = {"sslmode": "PGSSLMODE", "sslrootcert": "PGSSLROOTCERT", "channelBinding": "PGCHANNELBINDING",
             "channel_binding": "PGCHANNELBINDING", "application_name": "PGAPPNAME", "connect_timeout": "PGCONNECT_TIMEOUT"}
    ignored = {"connectTimeout", "socketTimeout", "ApplicationName", "applicationName", "prepareThreshold"}
    options = parse_qsl(url.query, keep_blank_values=True) if url.query else []
    if any(name not in names and name not in ignored and name not in ("ssl", "targetServerType") for name, _ in options):
        raise ValueError("unsupported database URI option")
    # pgJDBC uses the last occurrence and form-style query decoding. Credential userinfo
    # above instead preserves literal plus. The acceptance connection has its own time budget.
    options = dict(options)
    budget = min(40, int(os.environ["SCORING_VERIFY_QUERY_TIMEOUT"]))
    if budget <= 0: raise ValueError("runtime deadline exhausted")
    env = os.environ.copy()
    env.pop("SCORING_VERIFY_DATABASE_URL", None)
    fields = {"PGHOST": url.hostname, "PGPORT": str(url.port or 5432),
              "PGUSER": unquote(url.username), "PGPASSWORD": unquote(url.password or ""),
              "PGDATABASE": unquote(url.path.removeprefix("/")) or "postgres"}
    fields.update({names[name]: value for name, value in options.items() if name in names})
    if "sslmode" not in options:
        fields["PGSSLMODE"] = "verify-full" if options.get("ssl", "false").lower() in ("", "true") else "prefer"
    if "targetServerType" in options:
        fields["PGTARGETSESSIONATTRS"] = {"any": "any", "primary": "primary", "secondary": "standby",
            "preferSecondary": "prefer-standby", "preferPrimary": "any"}[options["targetServerType"]]
    fields.update(PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=" + str(min(10000, budget * 1000)) + " -c lock_timeout=3000",
                  PGCONNECT_TIMEOUT=str(min(10,budget)), PGAPPNAME="physiology-runtime-acceptance")
    env.update(fields)
    command = ["docker", "run", "--rm", "-i"]
    for name in fields: command.extend(["--env", name])
    command.extend(["postgres:17-alpine", "psql", "-X", "-v", "ON_ERROR_STOP=1", "-A", "-t", "-F", "|", "-f", "-"])
    command.extend(["-v", "worker_instance_id=" + os.environ["SCORING_WORKER_INSTANCE_ID"],
                    "-v", "source_revision=" + os.environ["SCORING_WORKER_SOURCE_REVISION"]])
    sys.exit(subprocess.run(command, env=env, input=sys.stdin.buffer.read(), timeout=budget).returncode)
except Exception:
    sys.exit(1)
' 2>/dev/null <<'SQL'
with candidates as materialized (
  select process_instance_id,last_poll_at,last_score_at,last_error
  from public.physiology_worker_heartbeats
  where worker_instance_id=:'worker_instance_id'::uuid and source_revision=:'source_revision'
    and algorithm_version='frwhoop-physiology-2' limit 2
), cardinality as (select count(*) as processes from candidates), debt as (
  select *, (status='exhausted' or (failure_revision=input_revision and consecutive_failures>=8)) as exhausted,
    coalesce((status='running' and lease_expires_at>clock_timestamp())
      or (next_attempt_at<=clock_timestamp() and (lease_expires_at is null or lease_expires_at<=clock_timestamp())),false) as eligible
  from public.physiology_work_items where done_at is null
    and status in ('pending','running','retry','exhausted')
), counts as (
  select count(*) filter(where eligible and not exhausted) as eligible,
    count(*) filter(where exhausted) as exhausted,
    count(*) filter(where not eligible and not exhausted) as delayed,
    coalesce(case when bool_or(eligible and not exhausted and
      (status<>'running' or lease_expires_at is null or lease_expires_at<=clock_timestamp())) then 0
      else ceil(min(extract(epoch from lease_expires_at-clock_timestamp()))
        filter(where eligible and not exhausted))::integer end,0) as lease_wait
  from debt
)
select n.processes,coalesce(h.process_instance_id::text,'none'),
  coalesce(extract(epoch from h.last_poll_at)::bigint,0),coalesce(extract(epoch from h.last_score_at)::bigint,0),
  (h.last_error is null),c.eligible,c.lease_wait,c.exhausted,c.delayed,
  (select coalesce(max(id),0) from public.physiology_archive_outbox where algorithm_version='frwhoop-physiology-2'),
  extract(epoch from clock_timestamp())::bigint
from cardinality n cross join counts c left join candidates h on n.processes=1;
SQL
}

scoring_parse_snapshot() {
  local snapshot="$1" extra
  [[ "$snapshot" != *$'\n'* ]] || return 1
  IFS='|' read -r progress_processes progress_process progress_poll progress_score progress_healthy progress_eligible progress_lease progress_exhausted progress_delayed progress_publication progress_now extra <<<"$snapshot"
  [[ -z "$extra" && "$progress_processes" =~ ^[01]$ &&
     "$progress_poll" =~ ^[0-9]+$ && "$progress_score" =~ ^[0-9]+$ &&
     "$progress_now" =~ ^[0-9]+$ && "$progress_healthy" =~ ^[tf]$ ]] || return 1
  local value
  for value in "$progress_eligible" "$progress_lease" "$progress_exhausted" "$progress_delayed" "$progress_publication"; do
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
  done
  if [[ "$progress_processes" == 0 ]]; then
    [[ "$progress_process" == none && "$progress_poll" == 0 && "$progress_score" == 0 ]] || return 1
  else
    [[ "$progress_process" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
  fi
  ((progress_poll <= progress_now + 60 && progress_score <= progress_now + 60))
}

scoring_wait_for_progress() {
  local release_sha="$1" baseline="${2:-}" snapshot previous_poll initial_score initial_publication process_id=""
  local require_score=false poll_advances=0 seconds="${SCORING_ACCEPT_SECONDS:-1800}" attempt deadline remaining lease_wait
  [[ "$seconds" =~ ^[0-9]+$ ]] && ((seconds >= 15 && seconds <= 3600)) || return 1
  deadline=$(($(scoring_monotonic_seconds) + seconds))
  if [[ -z "$baseline" ]]; then
    baseline="$(scoring_progress_snapshot "$seconds")" || { echo 'Hosted runtime query failed' >&2; return 1; }
  fi
  scoring_parse_snapshot "$baseline" || return 1
  previous_poll="$progress_poll"; initial_score="$progress_score"
  initial_publication="$progress_publication"
  [[ "$progress_processes" == 0 ]] || process_id="$progress_process"
  ((progress_eligible + progress_delayed == 0)) || require_score=true
  ((progress_exhausted == 0)) || { echo "Retry-exhausted scoring debt remains ($progress_exhausted items)" >&2; return 1; }
  lease_wait="$progress_lease"; ((lease_wait <= 300)) || lease_wait=300
  deadline=$((deadline + lease_wait))
  echo "Runtime observation: eligible=$progress_eligible delayed=$progress_delayed exhausted=$progress_exhausted"
  for ((attempt=0; attempt<(seconds+lease_wait+4)/5; attempt++)); do
    remaining=$((deadline - $(scoring_monotonic_seconds)))
    ((remaining > 0)) || break
    if ((remaining > 5)); then sleep 5; else sleep "$remaining"; fi
    remaining=$((deadline - $(scoring_monotonic_seconds)))
    ((remaining > 0)) || break
    scoring_assert_candidate "$release_sha" || { echo 'Candidate identity/process check failed' >&2; return 1; }
    remaining=$((deadline - $(scoring_monotonic_seconds)))
    ((remaining > 0)) || break
    snapshot="$(scoring_progress_snapshot "$remaining")" || { echo 'Hosted runtime query failed' >&2; return 1; }
    scoring_parse_snapshot "$snapshot" || { echo 'Invalid hosted progress response' >&2; return 1; }
    ((progress_eligible + progress_delayed == 0)) || require_score=true
    ((progress_exhausted == 0)) || { echo "Retry-exhausted scoring debt remains ($progress_exhausted items)" >&2; return 1; }
    [[ "$progress_processes" != 0 ]] || continue
    if [[ -z "$process_id" ]]; then process_id="$progress_process"; fi
    [[ "$process_id" == "$progress_process" ]] || { echo 'Candidate process identity changed' >&2; return 1; }
    if ((progress_poll > previous_poll)); then
      poll_advances=$((poll_advances + 1)); previous_poll="$progress_poll"
    fi
    # recordScore follows confirmed publication and fenced completion in this process.
    # The immutable outbox marker corroborates publication, but is not a per-process receipt.
    if ((poll_advances >= 2)) && [[ "$progress_healthy" == t ]] &&
        { [[ "$require_score" == false ]] || ((progress_score > initial_score && progress_publication > initial_publication)); }; then
      if [[ "$require_score" == true ]]; then
        echo 'Accepted: exact process advances polls and score, corroborated by a new immutable physiology publication'
      else echo 'Accepted: exact process advances polls; no eligible scoring debt. Publication was not exercised; input-waiting jobs are excluded.'; fi
      return 0
    fi
  done
  if ((progress_delayed > 0 && progress_eligible == 0)); then
    echo "Delayed scoring debt remains ($progress_delayed items)" >&2
  elif [[ "$require_score" == true ]]; then echo 'No healthy immutable publication within observation deadline' >&2
  else echo 'No healthy advancing physiology poll within observation deadline' >&2; fi
  return 1
}
