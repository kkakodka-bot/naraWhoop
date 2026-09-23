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

scoring_lane() {
  case "${SCORING_ALGORITHM_VERSION:-frwhoop-physiology-2}" in
    frwhoop-server-1) SCORING_ALGORITHM_VERSION=frwhoop-server-1; SCORING_CONTAINER_NAME=scoring-baseline-v1 ;;
    frwhoop-physiology-2) SCORING_ALGORITHM_VERSION=frwhoop-physiology-2; SCORING_CONTAINER_NAME=scoring-physiology-v2 ;;
    frwhoop-server-2-history) SCORING_ALGORITHM_VERSION=frwhoop-server-2-history; SCORING_CONTAINER_NAME=scoring-history ;;
    *) return 1 ;;
  esac
  export SCORING_ALGORITHM_VERSION SCORING_CONTAINER_NAME
}

scoring_worker_ids() {
  scoring_lane || return 1
  local id mode environment ids endpoint host intended
  intended="$(scoring_project_host "${SCORING_SUPABASE_URL:-}")" || return 1
  ids="$(timeout 12 docker ps --no-trunc "$1")" || return 1
  while read -r id; do
    [[ -n "$id" ]] || continue
    environment="$(timeout 12 docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id")" || return 1
    if grep -Fxq "SCORING_ALGORITHM_VERSION=$SCORING_ALGORITHM_VERSION" <<<"$environment"; then
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

scoring_client_identity_valid() {
  [[ "${SCORING_POSTGRES_CLIENT_IMAGE:-}" == docker.io/library/postgres@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3 &&
     "${SCORING_POSTGRES_CLIENT_CONFIG_DIGEST:-}" == sha256:79bd7c99e923138f136f8009d6bffa66e21e9d4fda5c0c561b00fc9c90cfe537 &&
     "${SCORING_POSTGRES_CLIENT_PLATFORM:-}" == linux/amd64 &&
     "${SCORING_POSTGRES_CLIENT_VERSION:-}" == 17.11-alpine3.24 ]]
}

scoring_assert_candidate() {
  scoring_lane || return 1
  local release_sha="$1" container="$SCORING_CONTAINER_NAME" ports running candidate_id mode environment
  [[ "$(timeout 12 docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$container")" == "$release_sha" ]] || return 1
  [[ "$(timeout 12 docker inspect -f '{{.State.Running}}' "$container")" == true ]] || return 1
  [[ "$(timeout 12 docker inspect -f '{{.RestartCount}}' "$container")" == 0 ]] || return 1
  mode="$(timeout 12 docker inspect -f '{{json .Config.Cmd}}' "$container")" || return 1
  if [[ "$SCORING_ALGORITHM_VERSION" == frwhoop-server-2-history ]]; then
    [[ "$mode" == '["--history"]' ]] || return 1
  else [[ "$mode" == '[]' || "$mode" == null ]] || return 1; fi
  [[ "${SCORING_EXPECTED_IMAGE_ID:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  [[ "$(timeout 12 docker inspect -f '{{.Image}}' "$container")" == "$SCORING_EXPECTED_IMAGE_ID" ]] || return 1
  ports="$(timeout 12 docker port "$container")" || return 1
  [[ -z "$ports" ]] || return 1
  environment="$(timeout 12 docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container")" || return 1
  if [[ "$SCORING_ALGORITHM_VERSION" == frwhoop-server-1 ]]; then
    [[ "$(scoring_environment_value "$environment" JAVA_OPTS)" == '-Xmx512m -XX:+UseContainerSupport' ]] || return 1
    if grep -Eq '^(JAVA_TOOL_OPTIONS|JDK_JAVA_OPTIONS|_JAVA_OPTIONS)=' <<<"$environment"; then return 1; fi
  fi
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
  scoring_lane || return 1
  scoring_identity_valid || return 1
  scoring_client_identity_valid || return 1
  local database_url="${SCORING_DATABASE_URL#jdbc:}"
  export SCORING_WORKER_INSTANCE_ID SCORING_WORKER_SOURCE_REVISION SCORING_POSTGRES_CLIENT_IMAGE \
    SCORING_POSTGRES_CLIENT_CONFIG_DIGEST SCORING_POSTGRES_CLIENT_PLATFORM SCORING_POSTGRES_CLIENT_VERSION
  # A disposable client needs no local Supabase stack. The URI is inherited through the
  # environment, never placed in process arguments, logs, or a temporary file. PGDATABASE
  # alone does not expand a URI, so decode its fields once before passing libpq variables.
  local SCORING_VERIFY_DATABASE_URL="$database_url"
  local SCORING_VERIFY_QUERY_TIMEOUT="${1:-40}"
  local SCORING_TLS_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scoring-tls.py"
  export SCORING_VERIFY_DATABASE_URL SCORING_VERIFY_QUERY_TIMEOUT SCORING_TLS_HELPER
  python3 -c '
import os, subprocess, sys, importlib.util
from urllib.parse import urlsplit, unquote, parse_qsl
try:
    expected_client = {
        "SCORING_POSTGRES_CLIENT_IMAGE": "docker.io/library/postgres@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3",
        "SCORING_POSTGRES_CLIENT_CONFIG_DIGEST": "sha256:79bd7c99e923138f136f8009d6bffa66e21e9d4fda5c0c561b00fc9c90cfe537",
        "SCORING_POSTGRES_CLIENT_PLATFORM": "linux/amd64",
        "SCORING_POSTGRES_CLIENT_VERSION": "17.11-alpine3.24",
    }
    if any(os.environ.get(name) != value for name, value in expected_client.items()):
        raise ValueError("reviewed PostgreSQL client identity required")
    client_image = os.environ["SCORING_POSTGRES_CLIENT_IMAGE"]
    url = urlsplit(os.environ["SCORING_VERIFY_DATABASE_URL"])
    if url.scheme not in ("postgres", "postgresql") or not url.hostname or not url.username or url.fragment:
        raise ValueError("unsupported database URI")
    names = {"sslmode": "PGSSLMODE", "sslrootcert": "PGSSLROOTCERT", "channelBinding": "PGCHANNELBINDING",
             "channel_binding": "PGCHANNELBINDING", "application_name": "PGAPPNAME", "connect_timeout": "PGCONNECT_TIMEOUT"}
    ignored = {"connectTimeout", "socketTimeout", "ApplicationName", "applicationName", "prepareThreshold"}
    pairs = parse_qsl(url.query, keep_blank_values=True) if url.query else []
    if len({name for name, _ in pairs}) != len(pairs):
        raise ValueError("duplicate database URI option")
    if any(name not in names and name not in ignored and name not in ("ssl", "targetServerType") for name, _ in pairs):
        raise ValueError("unsupported database URI option")
    # pgJDBC uses the last occurrence and form-style query decoding. Credential userinfo
    # above instead preserves literal plus. The acceptance connection has its own time budget.
    options = dict(pairs)
    if options.get("sslmode") != "verify-full" or "ssl" in options:
        raise ValueError("verified hosted database connection required")
    tls_spec = importlib.util.spec_from_file_location("scoring_tls", os.environ["SCORING_TLS_HELPER"])
    tls = importlib.util.module_from_spec(tls_spec)
    tls_spec.loader.exec_module(tls)
    trust_mounts = tls.verified_root_mounts(options.get("sslrootcert"))
    budget = min(40, int(os.environ["SCORING_VERIFY_QUERY_TIMEOUT"]))
    if budget <= 0: raise ValueError("runtime deadline exhausted")
    env = {name: os.environ[name] for name in ("PATH", "HOME", "DOCKER_CONFIG", "DOCKER_HOST", "XDG_RUNTIME_DIR")
           if name in os.environ}
    fields = {"PGHOST": url.hostname, "PGPORT": str(url.port or 5432),
              "PGUSER": unquote(url.username), "PGPASSWORD": unquote(url.password or ""),
              "PGDATABASE": unquote(url.path.removeprefix("/")) or "postgres"}
    fields.update({names[name]: value for name, value in options.items() if name in names})
    if "targetServerType" in options:
        fields["PGTARGETSESSIONATTRS"] = {"any": "any", "primary": "primary", "secondary": "standby",
            "preferSecondary": "prefer-standby", "preferPrimary": "any"}[options["targetServerType"]]
    fields.update(PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=" + str(min(10000, budget * 1000)) + " -c lock_timeout=3000",
                  PGCONNECT_TIMEOUT=str(min(10,budget)), PGAPPNAME="physiology-runtime-acceptance")
    env.update(fields)
    command = ["docker", "run", "--rm", "-i"]
    command.extend(trust_mounts)
    for name in fields: command.extend(["--env", name])
    command.extend([client_image, "psql", "-X", "-v", "ON_ERROR_STOP=1", "-A", "-t", "-F", "|", "-f", "-"])
    version = os.environ["SCORING_ALGORITHM_VERSION"]
    command.extend(["-v", "worker_instance_id=" + os.environ["SCORING_WORKER_INSTANCE_ID"],
                    "-v", "source_revision=" + os.environ["SCORING_WORKER_SOURCE_REVISION"],
                    "-v", "algorithm_version=" + version])
    query = sys.stdin.buffer.read().decode()
    if version == "frwhoop-server-1":
        query = query.replace("public.physiology_work_items", "public.scoring_work_items")
    elif version == "frwhoop-server-2-history":
        q = chr(39)
        query = query.replace("public.physiology_work_items", f"(select case when dead_letter then {q}exhausted{q} when lease_until>clock_timestamp() then {q}running{q} else {q}pending{q} end as status, null::timestamptz as done_at, input_revision as failure_revision, input_revision, consecutive_failures, lease_until as lease_expires_at, not_before as next_attempt_at from public.scoring_jobs_v2 where completed_revision<input_revision and algorithm_version=:{q}algorithm_version{q}) history")
        query = query.replace("max(id)", "max(result_revision)").replace("public.physiology_archive_outbox", "public.scoring_snapshots_v2")
    sys.exit(subprocess.run(command, env=env, input=query.encode(), timeout=budget).returncode)
except Exception:
    sys.exit(1)
' 2>/dev/null <<'SQL'
with candidates as materialized (
  select process_instance_id,last_poll_at,last_score_at,last_error
  from public.physiology_worker_heartbeats
  where worker_instance_id=:'worker_instance_id'::uuid and source_revision=:'source_revision'
    and algorithm_version=:'algorithm_version' limit 2
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
  (select coalesce(max(id),0) from public.physiology_archive_outbox where algorithm_version=:'algorithm_version'),
  extract(epoch from clock_timestamp())::bigint,
  (select count(*) from public.noop_projection_debt where state<>'complete'),
  (select coalesce(max(greatest(0,extract(epoch from clock_timestamp()-created_at)))::bigint,0)
    from public.noop_projection_debt where state<>'complete')
from cardinality n cross join counts c left join candidates h on n.processes=1;
SQL
}

scoring_parse_snapshot() {
  local snapshot="$1" extra
  [[ "$snapshot" != *$'\n'* ]] || return 1
  IFS='|' read -r progress_processes progress_process progress_poll progress_score progress_healthy progress_eligible progress_lease progress_exhausted progress_delayed progress_publication progress_now progress_projection_pending progress_projection_age extra <<<"$snapshot"
  [[ -z "$extra" && "$progress_processes" =~ ^[01]$ &&
     "$progress_poll" =~ ^[0-9]+$ && "$progress_score" =~ ^[0-9]+$ &&
     "$progress_now" =~ ^[0-9]+$ && "$progress_healthy" =~ ^[tf]$ ]] || return 1
  local value
  for value in "$progress_eligible" "$progress_lease" "$progress_exhausted" "$progress_delayed" "$progress_publication" "$progress_projection_pending" "$progress_projection_age"; do
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
  done
  if [[ "$progress_processes" == 0 ]]; then
    [[ "$progress_process" == none && "$progress_poll" == 0 && "$progress_score" == 0 ]] || return 1
  else
    [[ "$progress_process" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
  fi
  ((progress_poll <= progress_now + 60 && progress_score <= progress_now + 60))
}

scoring_projection_healthy() {
  local max_age="${SCORING_MAX_PROJECTION_AGE_SECONDS:-120}"
  [[ "$max_age" =~ ^[0-9]+$ ]] && ((max_age > 0)) || return 1
  if ((progress_projection_pending > 0 && progress_projection_age > max_age)); then
    echo "Projection stalled: pending=$progress_projection_pending oldest_seconds=$progress_projection_age" >&2
    return 1
  fi
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
  scoring_projection_healthy || return 1
  previous_poll="$progress_poll"; initial_score="$progress_score"
  initial_publication="$progress_publication"
  [[ "$progress_processes" == 0 ]] || process_id="$progress_process"
  case "${SCORING_REQUIRE_PUBLICATION:-false}" in
    true) require_score=true ;;
    false) ;;
    *) return 1 ;;
  esac
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
    scoring_projection_healthy || return 1
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
