#!/usr/bin/env bash
# Read-only runtime acceptance for the exact persistent physiology image.
set -euo pipefail

release_sha="${1:-}"
container="scoring-physiology-v2"
timeout_seconds="${SCORING_VERIFY_TIMEOUT_SECONDS:-180}"
[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "FAIL: expected a full release SHA" >&2; exit 1; }
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] && ((timeout_seconds >= 5 && timeout_seconds <= 900)) || {
  echo "FAIL: runtime verification timeout must be 5 through 900 seconds" >&2; exit 1;
}
fail() { echo "FAIL: $*" >&2; exit 1; }
monotonic_seconds() { python3 -c 'import time; print(int(time.monotonic()))'; }
project_host_from_url() {
  local authority="${1#https://}"
  authority="${authority%%/*}"
  authority="${authority%:443}"
  printf '%s' "$authority" | tr '[:upper:]' '[:lower:]'
}

[[ "$(docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$container" 2>/dev/null)" == "$release_sha" ]] || fail "unexpected scoring image"
[[ "$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)" == running ]] || fail "scoring container is not running"
ports="$(docker port "$container" 2>/dev/null)" || fail "could not inspect scoring ports"
[[ -z "$ports" ]] || fail "scoring container publishes ports"
container_id="$(docker inspect -f '{{.Id}}' "$container" 2>/dev/null)" || fail "could not inspect scoring identity"
environment="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null)" || fail "could not inspect scoring configuration"
database_url=""
algorithm_version=""
supabase_url=""
while IFS= read -r entry; do
  case "$entry" in
    DATABASE_URL=*) database_url="${entry#DATABASE_URL=}" ;;
    SUPABASE_URL=*) supabase_url="${entry#SUPABASE_URL=}" ;;
    SCORING_ALGORITHM_VERSION=*) algorithm_version="${entry#SCORING_ALGORITHM_VERSION=}" ;;
    REPLAY_*) fail "persistent worker contains replay-mode variables" ;;
  esac
done <<< "$environment"
unset environment entry
[[ "$algorithm_version" == frwhoop-physiology-2 ]] || fail "unexpected scoring algorithm"
[[ -n "$database_url" ]] || fail "scoring database is unconfigured"
[[ "$supabase_url" == https://* ]] || fail "scoring project is unconfigured"
project_host="$(project_host_from_url "$supabase_url")"
database_url="${database_url#jdbc:}"

running_v2=0
other_projects=0
running_ids="$(docker ps --no-trunc -q)" || fail "could not inspect running containers"
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  other_env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" 2>/dev/null)" || fail "could not inspect running worker"
  peer_version=""
  peer_url=""
  while IFS= read -r entry; do
    case "$entry" in
      SCORING_ALGORITHM_VERSION=*) peer_version="${entry#SCORING_ALGORITHM_VERSION=}" ;;
      SUPABASE_URL=*) peer_url="${entry#SUPABASE_URL=}" ;;
    esac
  done <<< "$other_env"
  if [[ "$peer_version" == frwhoop-physiology-2 ]]; then
    [[ "$peer_url" == https://* ]] || fail "could not determine a running physiology worker's project"
    peer_host="$(project_host_from_url "$peer_url")"
    if [[ "$peer_host" == "$project_host" ]]; then
      ((running_v2 += 1))
      [[ "$id" == "$container_id" ]] || fail "another physiology-v2 worker is running"
    else
      ((other_projects += 1))
    fi
  fi
done <<< "$running_ids"
unset other_env entry
[[ "$running_v2" -eq 1 ]] || fail "expected exactly one physiology-v2 worker"
if ((other_projects > 0)); then echo "Ignored $other_projects running physiology workers for other projects."; fi

snapshot() {
  # A disposable client needs no local Supabase stack. The URI is inherited through the
  # environment, never placed in process arguments, logs, or a temporary file. PGDATABASE
  # alone does not expand a URI, so decode its fields once before passing libpq variables.
  local SCORING_VERIFY_DATABASE_URL="$database_url"
  local SCORING_VERIFY_QUERY_TIMEOUT="$1"
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
    sys.exit(subprocess.run(command, env=env, input=sys.stdin.buffer.read(), timeout=budget).returncode)
except Exception:
    sys.exit(1)
' 2>/dev/null <<'SQL'
with debt as (
  select *, (status='exhausted' or (failure_revision=input_revision and consecutive_failures>=8)) as exhausted,
    coalesce((status='running' and lease_expires_at>clock_timestamp())
      or (next_attempt_at<=clock_timestamp() and (lease_expires_at is null or lease_expires_at<=clock_timestamp())),false) as eligible
  from public.physiology_work_items where done_at is null
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
select h.version,coalesce(h.last_poll_at::text,''),coalesce(h.last_score_at::text,''),
  (h.last_error is null),c.eligible,c.lease_wait,c.exhausted,c.delayed,
  (select coalesce(max(id),0) from public.physiology_archive_outbox where algorithm_version='frwhoop-physiology-2')
from public.physiology_service_heartbeats h cross join counts c where h.id=1;
SQL
}

read_snapshot() {
  local row extra remaining
  remaining=$((deadline - $(monotonic_seconds)))
  ((remaining > 0)) || fail "runtime observation deadline exhausted"
  row="$(snapshot "$remaining")" || fail "hosted runtime query failed or exceeded its deadline"
  [[ -n "$row" && "$row" != *$'\n'* ]] || fail "missing or malformed physiology heartbeat"
  IFS='|' read -r version poll score healthy eligible lease_wait exhausted delayed publication_marker extra <<< "$row"
  [[ "$version" == frwhoop-physiology-2 && "$healthy" =~ ^[tf]$ && -z "$extra" ]] || fail "invalid physiology runtime state"
  for value in "$eligible" "$lease_wait" "$exhausted" "$delayed" "$publication_marker"; do
    [[ "$value" =~ ^[0-9]+$ ]] || fail "invalid physiology runtime counts"
  done
  ((exhausted == 0)) || fail "retry-exhausted scoring debt remains ($exhausted items)"
}

started_at="$(monotonic_seconds)"
deadline=$((started_at + timeout_seconds))
read_snapshot
initial_poll="$poll"
initial_score="$score"
initial_publication_marker="$publication_marker"
require_publication=false
((eligible + delayed > 0)) && require_publication=true
((lease_wait > 300)) && lease_wait=300
max_wait_seconds=$((timeout_seconds + lease_wait))
deadline=$((started_at + max_wait_seconds))
echo "Runtime observation: eligible=$eligible delayed=$delayed exhausted=$exhausted"

while (( $(monotonic_seconds) < deadline )); do
  remaining=$((deadline - $(monotonic_seconds)))
  ((remaining > 5)) && remaining=5
  ((remaining > 0)) || break
  sleep "$remaining"
  (( $(monotonic_seconds) < deadline )) || break
  read_snapshot
  ((eligible + delayed > 0)) && require_publication=true
  if [[ "$healthy" == t && -n "$poll" ]]; then
    if [[ "$require_publication" == false && "$poll" != "$initial_poll" ]]; then
      echo "PASS: exact persistent worker advances its poll; no unfinished scoring debt. Publication was not exercised."
      exit 0
    fi
    if [[ "$require_publication" == true && -n "$score" && "$score" != "$initial_score" ]] &&
        ((publication_marker > initial_publication_marker)); then
      echo "PASS: exact persistent worker produced a new immutable physiology publication; eligible=$eligible delayed=$delayed."
      exit 0
    fi
  fi
done

if ((delayed > 0 && eligible == 0)); then
  fail "delayed scoring debt remains ($delayed items); no new immutable publication within ${max_wait_seconds}s"
elif [[ "$require_publication" == true ]]; then
  fail "no healthy immutable publication within ${max_wait_seconds}s; eligible=$eligible delayed=$delayed"
else
  fail "no healthy advancing physiology poll within ${max_wait_seconds}s"
fi
