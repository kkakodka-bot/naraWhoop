# FRWHOOP Physiology Scoring Service

Standalone JVM service that runs the extracted Android analytics Kotlin twin (`com.noop.analytics`).
Scores HRV/RR, sleep and qualified respiration on arrival. It writes immutable owner/device/day/revision
snapshots via `engine_publish_physiology` under `algorithm_version = frwhoop-physiology-2`.
The hosted fleet selects this deterministic v2 snapshot through migration `20260918130000`.
Optional learned-model work inside the snapshot remains isolated shadow output and cannot replace
canonical fields. This build refuses to impersonate the v1 algorithm version. The separately built
[frozen baseline worker](legacy-baseline/README.md) remains available for an explicit rollback.

## Layout

| Module | Role |
|---|---|
| `analytics-kernel` | Scoped Kotlin twin — sources are BYTE-VERBATIM copies from `android/app/src/main/java` (synced by Gradle). Oracle tests run unmodified. |
| `service` | Fenced revision/lease queue, snapshot-scoped analytics, publication and independent archival. |

## Build

```bash
cd scoring-service
export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
./gradlew :analytics-kernel:test          # parity oracle (alias: :analytics-kernel:parityGate)
./gradlew :service:test :service:installDist
bash scripts/test-physiology-queue.sh  # new disposable local PostgreSQL; retained evidence logs
bash scripts/test-runtime-preflight.sh  # separate read-only preflight transaction/auth cases
```

## Run locally

```bash
export DATABASE_URL='postgresql://postgres:…@localhost:5432/postgres'
export INGEST_SECRET='…'
export SUPABASE_URL='https://api.example.com/rest/v1'
export SUPABASE_SERVICE_ROLE_KEY='…'
./service/build/install/service/bin/service
```

`SUPABASE_URL` is the PostgREST base and must identify the same hosted Supabase project as
`DATABASE_URL`; its HTTPS URL ends in `/rest/v1`. The writer appends `/rpc/engine_publish_physiology`.
Do not run this against production merely to verify configuration: starting/replaying performs writes.

Replay one day (dirties, claims and renews the same queue lease; publication stays revision-fenced):

```bash
export REPLAY_USER_ID='…'
export REPLAY_DEVICE_ID='…'   # required when the user has more than one device
export REPLAY_DAY='2026-09-15'
./service/build/install/service/bin/service --replay-day
```

If the user has exactly one registered device, `REPLAY_DEVICE_ID` may be omitted.
A one-shot replay can leave an archive pending; the long-running process owns archive retries.
Replay now requires the explicit `--replay-day` argument. With no arguments the process always
runs persistently; leftover `REPLAY_*` variables produce a warning and do not select replay mode.

For a read-only owner/night signal-availability report, use `--inventory-signals` with explicit
`INVENTORY_USER_ID`, `INVENTORY_DEVICE_ID`, `INVENTORY_DAY` and optional paired `INVENTORY_START`/`INVENTORY_END`.
See the [inventory contract and example](../docs/physiology-v2/acquisition.md#executable-ownernight-inventory).
Unlike replay, this command does not initialize scoring or mutate queue/archive state.

## Durable state (Postgres)

All progress survives container restarts (`kill -9` → clean resume):

| Table | Purpose |
|---|---|
| `physiology_work_items` | Deterministic v2 scoring debt, input/measurement revisions, renewable leases and retry state |
| `scoring_work_items` | Independent v1 debt; migration `20260918120000` requires the patched baseline transport |
| `scoring_timezone_history` | Prospective event-time IANA ownership segments |
| `scoring_service_heartbeats` / `physiology_service_heartbeats` | Separate v1/v2 liveness records |
| `server_physiology_results` | Immutable version/revision snapshots, including the complete generated episode set |
| `physiology_sleep_overrides` | Owner-scoped optimistic corrections and tombstones |
| `physiology_archive_outbox` | Independent retries of the exact committed payload |
| `physiology_feature_qualifications` / `physiology_source_selection` | Human-reviewed feature gates and explicit owner/device/version selection |

The old `server_daily_scores` and `server_sleep_nights` remain preserved. Both workers publish
immutable version-scoped snapshots and independently retryable archive debt. See
[revision-protocol.md](docs/revision-protocol.md) for actual transaction and dependency behavior.

The scorer **never** writes `daily_metrics` or `sleep_nights` (device-pushed tables).

## Docker (VPS)

Build from **repo root** (kernel syncs from `../android`):

```bash
docker build -t frwhoop/scoring-service:latest -f scoring-service/Dockerfile .
```

See `infra/vps/templates/docker-compose.scoring-override.yml`. It runs the persistent
`scoring-physiology-v2` service from an immutable commit tag against the hosted Supabase database
and PostgREST endpoint. Keep the separately built, patched v1 image available for rollback.

The deploy script requires dedicated hosted-project variables in `/opt/frwhoop/secrets.env`:
`SCORING_DATABASE_URL`, `SCORING_SUPABASE_URL` (ending `/rest/v1`),
`SCORING_SUPABASE_SERVICE_ROLE_KEY`, and `SCORING_INGEST_SECRET`. The generic `SERVICE_ROLE_KEY`
created during VPS provisioning belongs to the separate self-hosted database and is not a fallback.

Before replacing any worker, the candidate image runs `--check-config`: a read-only database/schema
and ingest-secret check followed by an authenticated read of the hosted heartbeat. It checks that
the direct database hostname or pooler username identifies the same project as the canonical
`https://<project>.supabase.co/rest/v1` URL. Custom domains need separate binding evidence and are
rejected by this deployment check. Failures produce a fixed stage code without printing secrets.
Passing preflight is configuration evidence; `phase3-acceptance-checks.sh` still verifies actual
advancing poll/publication timestamps after deployment. Process existence alone is not worker health.

The operations-only `ingest-verify` report exposes `physiology_processing` independently of
`complete` (`complete_scope: ingestion_only`). It distinguishes a worker that never polled, queued
or failed work, absent/stale publication, and published results whose measurements are unavailable.

## Scoped kernel (Locked #3)

Server computes: RR/HRV pipeline + sleep staging/score. Charge/Effort/Rest are computed internally
by `AnalyticsEngine` but **not written** to Postgres. Only the scoped physiology snapshot is published.

## Input sources

HR/RR/resp/gravity/steps/events, band state and supported annotations come from `noop_*` projections.
Checked RR receipts preserve original packet-local words/zeros but do not invent a verified beat clock
or cross-packet continuity. Coarse timing remains unavailable for qualified HRV/RSA. Historical IANA
segments own full local days and preceding-night context, including DST and within-day travel.
Snapshot fencing rejects future-dated samples/spans and incomplete HRV windows. Known awake/off-body
gaps stay distinct from unknown; reported boundaries are not sleep truth. Unsupported inputs, including
habitual timing and waveform channel semantics, carry explicit unavailable states.

Optional raw/model work uses bounded GET/hash/decode and a separately configured shadow lane. See
[inference/README.md](inference/README.md). The JVM Docker image does not install approved Python model
environments; absent activation/assets disables those candidates, not the independent deterministic work.

## Immutable derived archives

Publication atomically creates durable archive debt for the exact canonical JSON snapshot. A separate
bounded worker retries upload and readback verification to the same configured B2 bucket:

```text
v3/derived/users/{user}/devices/{device}/days/{day}/{algorithm}/revisions/{revision}/{hash}.json.zst
```

Requires the same B2 env as Edge (`B2_KEY_ID`, `B2_APPLICATION_KEY`, `B2_BUCKET_NAME`, …) — the
VPS compose override loads `/opt/frwhoop/b2.env`. For baseline-only operation, this build can run `--archive-only` to drain both versions
without claiming or computing physiology work. Postgres scores remain readable when B2 fails;
`physiology_archive_outbox` retains the independent status/retry debt. A client hash or HEAD response
does not verify raw content. Changed decode metadata revokes old proof, while identical repeat
verification does not endlessly dirty scores. Raw-uncompressed and derived-compressed digest
conventions remain distinct.

## Selection, rollback and evidence

Per-feature source selection rejects unqualified shadow versions. The offline benchmark gate only
returns eligibility for human review; it never changes production selection. Preserve additive
migrations and immutable snapshots during rollback. Select the retained `frwhoop-server-1` feature
and use the separately built baseline image containing the original pinned numerical kernel
plus the fenced transport patch. The unpatched baseline binary is rejected after migration
`20260918120000`. Changing this build's version string, dropping tables or rewriting user data is not rollback.

See the [implementation ledger](../docs/physiology-v2/implementation-plan.md),
[acquisition contract](../docs/physiology-v2/acquisition.md), [HRV contract](../docs/physiology-v2/hrv.md),
and [benchmark harness](../Tools/physiology-bench/README.md). Outputs remain provisional without
acquisition completeness attestation; period closure alone is insufficient. Local tests and builds
do not establish ECG/PSG/respiratory accuracy, verified WHOOP subsecond clocks, model rights/weights,
physical background/power soak, target-VPS resources, or deployed/rollout readiness.
