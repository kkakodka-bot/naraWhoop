# Server-Side Scoring Migration — Single Execution Prompt

> Hand this whole document to the executing agent as one prompt. It is self-contained:
> decisions are locked, phases are ordered, and every phase has a verification gate.
> Repo: FRWHOOP_v2 (fork of NOOP — offline-first WHOOP companion; this fork ships a
> hosted Supabase/B2 pipeline for the owner's devices).

## Mission

Move all intensive calculation/scoring off-device onto one self-hosted VPS to improve
app performance. Target architecture:

```
strap ──BLE──> app ──HTTPS batches──> ingest (on VPS)
                                        │
                                        ▼
                              scoring service (JVM — extracted Kotlin twin)
                              computes: HRV / RR, sleep staging + sleep score
                              DROPPED: Charge / Recovery / Strain
                                        │
                                        ▼
                              Postgres (results) ──Realtime / snapshot RPC──> app (near-real-time)
                                        │
                                        ▼
                              B2 (inferred-dataset archive, derived_objects lane)
```

## Repo facts the executor must know

- **Ingest today**: `supabase/functions/push/index.ts` (Deno) receives already-decoded
  samples (`hrSample`, `rrInterval`, `gravitySample`, ADC raws) and already-computed
  device scores. It never decodes BLE frames and never recomputes scores. Wire contract
  lives in `supabase/functions/_shared/registry.ts` (protocol 1.0/1.1/1.2, stream→table
  projections). Auth: Supabase JWT or opaque `noop_` ingest tokens
  (`supabase/migrations/20260907140000_noop_ingest_tokens.sql`).
- **Workers**: `reconcile`, `retention-sweep`, `account-deletion`, `ingest-verify` —
  Deno, scheduled via pg_cron, auth via `WORKER_SECRET` or service role.
- **Raw object lane**: devices upload high-rate signal straight to B2 with presigned
  PUTs; Postgres holds only manifests + `noop_signal_windows` coverage index
  (~100 rows/device-day). `derived_objects` table already exists in the engine schema —
  use it for the inferred-artifact lane.
- **Server-side scoring today: ~0 LOC.** Shadow columns (`sleep_details.shadow_v3`,
  `daily_metrics.strain_score_v2`) are storage whose producer (Node metrics engine) was
  deleted in MIGRATION.md Phase 7. **Do not reintroduce a Node API** (hard repo rule).
- **On-device analytics**: `Packages/StrandAnalytics` (~28k LOC Swift, 114 files) and
  its byte-identical twin `android/app/src/main/java/com/noop/analytics/` (~33k LOC
  Kotlin, runs on plain JVM — `testFullDebugUnitTest` executes on Linux). Oracle tests:
  ~1,883 Swift + ~2,076 Kotlin. Scoring bible: `docs/ANALYTICS.md`; numpy replication
  pins: `docs/RR-OPTIMIZATION.md`.
- **Why not Supabase cloud for scoring** (verified, do not relitigate): Edge Functions
  cap at 2 s CPU/request, 256 MB, 400 s wall-clock; `plpython3u` is not offered; `plv8`
  is deprecated (PG15-only, removed in PG17); plpgsql is a poor fit for multi-pass
  stateful FP-sensitive math.
- **Ops tooling**: `Tools/push-conformance/` (configurable `BASE_URL` / `PUSH_PATH` —
  validates any receiver), `Tools/monitor-fleet-push.mjs` (read-only probes).
- **Edge test gate**: `cd supabase/functions && deno test --allow-all tests/` must stay
  green after any Edge edit.

## Locked decisions

1. **One VPS** (4 vCPU / 8 GB, Hetzner-class, ~$8–11/mo; region near the users or EU
   for GDPR posture) running the **official self-hosted Supabase Docker stack**
   (Postgres 16 + pg_cron + pg_net, GoTrue, PostgREST, Realtime, Edge Runtime, Studio)
   **plus the scoring service as one more container**. B2 stays external.
2. **Scoring = extracted Kotlin twin** as a JVM service (Ktor or CLI poller). Not Node,
   not plpgsql, not Edge, not a Python re-port (Python enters later only for new
   seizure/ML work, as a separate sidecar).
3. **Scope**: RR/HRV pipeline + sleep staging/scoring only. Charge/Effort/Rest and the
   insights engines are dropped, shrinking the extraction surface to ~6–8k LOC:
   - RR/HRV: `HrvAnalyzer.kt` + gap-aware cleaning + spot/current helpers (~1.5k LOC)
   - Sleep: `SleepStager.kt` + `SleepStagerV2.kt` + `SleepStageTotals.kt` +
     `WakeMotionRefinement.kt` (~4.8k LOC)
   - Glue: day windows / session assembly subset (~0.5–1k LOC)
4. **Readback**: results written through the existing `engine_ingest_*` RPC shape;
   app reads via Supabase Realtime (`postgres_changes`) with `get_day_snapshot`
   polling as fallback.
5. **Shadow-first**: devices keep scoring; the server recomputes and diffs per user per
   day against device-pushed scores (the built-in oracle — no new tooling). Promotion is
   per-metric behind a version flag with rollback. Devices stop scoring a metric only
   after its promotion.
6. **Offline behavior**: no connectivity = no fresh scores. App keeps last-known values
   with timestamps and queues uploads; scoring catches up on reconnect. Decide and
   implement the watch/phone stale-state UI before promotion.

## Phases

### Phase 0 — VPS + self-hosted Supabase
- Provision 4 vCPU/8 GB VPS; harden (ssh keys, ufw, fail2ban); Docker + compose.
- Bring up self-hosted Supabase stack; enable pg_cron + pg_net.
- Replay all 71 migrations in order (`supabase/migrations/`, additive only — never
  reset, never mutate an existing migration).
- Caddy/Traefik TLS; DNS.
- Backups: nightly `pg_dump` + WAL archiving (wal-g) → B2; **test a restore**.
- Gate: `psql` migration replay clean; restore test passes; Studio reachable over TLS.

### Phase 1 — Move ingest + workers
- Deploy `push`, `reconcile`, `retention-sweep`, `account-deletion`, `ingest-verify` to
  the self-hosted Edge Runtime; port secrets (`WORKER_SECRET`, service role, ingest
  tokens); re-point pg_cron schedules.
- Recreate B2 presign flow against the same bucket.
- Gate: `deno test --allow-all tests/` green; `Tools/push-conformance` with
  `BASE_URL` pointed at the VPS fully green; a real device pushes end-to-end and rows
  land in the right projections; `monitor-fleet-push.mjs` probes green.
- Cutover: point a staging app build at the VPS (`PROJECT_URL` + new keys); soak 48 h;
  then production app. Keep the cloud project running read-only during soak.

### Phase 2 — Extract the Kotlin scoring service
- Create a standalone Gradle module from `com.noop.analytics` (scope per Locked
  decisions #3); untangle from app glue (Room types, `IntelligenceEngine`) — introduce
  plain DTOs where the module touched app/DB types.
- Service shell: poll `noop_signal_windows` / ingest tables for unprocessed windows →
  fetch inputs (Postgres rows + B2 hourly objects) → compute → write results via the
  `engine_ingest_*` RPC shape with a new `algorithm_version` (e.g. `frwhoop-server-1`).
- Containerize (JRE 17); add to compose; wire heartbeats into `ingest-verify`.
- Gate: extracted module's existing unit tests pass unmodified on the JVM (parity is
  inherited — do not "fix" formulas); service processes a replayed device-day and
  writes rows.

### Phase 3 — Shadow validation
- Nightly + intraday shadow recompute per user; diff server vs device-pushed scores
  (HRV/RR first, sleep second — the stager is the FP-sensitive one: Cole–Kripke, DoG
  convolution, EWMA baselines; give it the longest soak).
- Write diffs to a comparison table; alert on drift beyond tolerance.
- Gate: ≥14 consecutive days within tolerance for every metric before any promotion.
  Investigate via the oracle tests and `docs/RR-OPTIMIZATION.md` pins, not by eye.

### Phase 4 — Near-real-time read path
- Realtime (`postgres_changes`) on the result tables; app subscribes with
  `get_day_snapshot` polling fallback.
- App changes behind a flag: stop running on-device scoring for shadow-promoted
  metrics; render server values; implement stale/offline states (last-known +
  timestamp, queued uploads).
- Gate: end-to-end latency strap→app-render ≤ ~60 s in normal conditions; offline
  behavior verified in airplane mode; macOS (`Strand`) and iOS (`NOOPiOS`) targets
  both build — app-target Swift is not covered by default CI, so build both.

### Phase 5 — Inferred-artifact lane to B2
- After each day/session is computed, write the inferred dataset (parquet or json.zst)
  to B2; register in `derived_objects` + manifest; extend `reconcile` /
  `retention-sweep` to the new lane.
- Gate: manifest↔B2 consistency under `reconcile`; retention deletes propagate.

### Phase 6 — Promotion + decommission
- Promote metrics one at a time (flag + rollback); disable corresponding on-device
  scoring; keep Swift/Kotlin code but excluded behind the same flag for one release.
- Decommission the Supabase cloud project only after ≥30 days clean on the VPS and a
  final verified backup.
- Update `MIGRATION.md` (new phase), `docs/CLOUD_INGESTION.md` (server now recomputes —
  the "never recomputes" invariant is deliberately retired), and `docs/ANALYTICS.md`
  (canonical scorer = server Kotlin service).

## Hard rules for the executor

- Additive migrations only; versioned migration + test for any schema change.
- Do not touch BLE/protocol code paths; no new write commands to hardware.
- No Node API for push or scoring (repo rule). No telemetry/phone-home additions.
- Keep the box stateless: all state in Postgres + B2; the container is replaceable.
- Medical data: de-identify before any third-party compute (future GPU training);
  secrets out of the repo; least-privilege API keys on the VPS.
- Cross-platform parity contract still applies to whatever remains on-device; the
  server Kotlin service becomes the single canonical scorer per promoted metric —
  record each promotion explicitly.

## Definition of done

App renders server-computed HRV/RR + sleep stages/score within ~a minute of data
landing; Charge/Effort/Rest gone from the pipeline; inferred datasets archived to B2
daily; one VPS runs the whole system with tested backups; conformance + deno + oracle
suites green; cloud Supabase project decommissioned; docs updated.
