# Server Scoring Migration v2 — Single Execution Prompt

> Hand this whole document to the executing agent as one prompt. It is self-contained:
> decisions are locked, phases are ordered, and every phase has a verification gate.
> Repo: FRWHOOP_v2 (fork of NOOP — offline-first WHOOP companion; this fork ships a
> hosted Supabase/B2 pipeline for the owner's devices).
>
> Supersedes `2026-09-15-server-side-scoring-migration.md` (v1). What changed:
> sync becomes **pure transport** (no sync-coupled scoring at all), live readouts
> stay on-device, upload cadence is fast-and-often, the **performance A/B is the
> primary gate**, and the accuracy shadow is demoted to a parallel audit that only
> gates fleet-wide promotion.

## Mission

Move all heavy scoring/computation off-device onto one self-hosted VPS to eliminate
phone thermal throttling, CPU spikes, and sync-stall. The app's sync path becomes
pure transport: strap → app → server. Scores are computed on arrival server-side
and read back in near-real-time. **The experiment being run: does this make the app
faster and cooler? That question is answered by measurement (Phase 0 baseline →
Phase 5 A/B), not assumed.**

```
strap ──BLE──> app (transport + live readouts only)
                 │  live HR / skin temp / rmSSD graph: local, display-only,
                 │  never persisted as canonical scores
                 │  upload: small HTTPS batches, fast + often
                 ▼
        VPS (one docker-compose):
          Supabase stack: Postgres 16 + pg_cron + pg_net, GoTrue, PostgREST,
                          Realtime, Edge Runtime, Studio
          push edge fn:  auth (JWT | noop_ token) → user_id; writes rows
          scoring svc:   JVM, extracted Kotlin twin; scores on arrival
                 ▼
          Postgres (canonical scores) ──Realtime──> app renders
                 ▼
          B2: raw object lane (presigned PUT direct from device)
              + derived-artifact lane + nightly backups
```

## Repo facts the executor must know

- **Ingest today**: `supabase/functions/push/index.ts` (Deno) receives already-decoded
  samples (`hrSample`, `rrInterval`, `gravitySample`, ADC raws) and already-computed
  device scores. It never decodes BLE frames and never recomputes scores. Wire contract:
  `supabase/functions/_shared/registry.ts` (protocol 1.0/1.1/1.2). Auth: Supabase JWT
  or opaque `noop_` ingest token (`supabase/migrations/20260907140000_noop_ingest_tokens.sql`);
  deployed `verify_jwt = false` because auth is custom.
- **Workers**: `reconcile`, `retention-sweep`, `account-deletion`, `ingest-verify` —
  Deno, pg_cron-scheduled, auth via `WORKER_SECRET` or service role.
- **Raw object lane**: high-rate signal uploads go straight to B2 via presigned PUTs;
  Postgres holds manifests + `noop_signal_windows` coverage index. `derived_objects`
  table already exists — use it for the inferred-artifact lane.
- **Server-side scoring today: ~0 LOC.** Shadow columns are storage whose producer
  was deleted in MIGRATION.md Phase 7. **No Node API** (hard repo rule).
- **On-device analytics**: `Packages/StrandAnalytics` (~28k LOC Swift) and its
  byte-identical twin `android/app/src/main/java/com/noop/analytics/` (~33k LOC Kotlin,
  runs on plain JVM — `testFullDebugUnitTest` executes on Linux). Measured coupling:
  1 android import in 124 files; in-scope kernel files have 0–4 `com.noop.data`
  imports each, all Room-annotated plain data classes. Oracle tests: ~1,883 Swift +
  ~2,076 Kotlin. Scoring bible: `docs/ANALYTICS.md`; FP pins: `docs/RR-OPTIMIZATION.md`.
- **Sync-coupled scoring today (the thing being eliminated)**: `Repository.analyzeRecent`
  runs after each sync backfill (`Strand/Data/Repository.swift`); `AppModel` adds
  fingerprint-driven rescoring, launch heals, and live strain recompute. Under this
  migration the sync path keeps none of these.
- **Perf harness exists**: `docs/SYNC_TEST_PROCEDURE.md` (Test Centre Connection &
  Sync + Display & Performance domains, run sheet). Known gap: the frame monitor does
  NOT track thermal/battery — Phase 0 closes it.
- **Why not Supabase cloud for scoring** (verified, do not relitigate): Edge Functions
  cap at 2 s CPU/request, 256 MB; no plpython3u; plv8 deprecated; plpgsql a poor fit
  for multi-pass stateful FP-sensitive math.
- **Ops tooling**: `Tools/push-conformance/` (configurable `BASE_URL`/`PUSH_PATH`),
  `Tools/monitor-fleet-push.mjs` (read-only probes).
- **Edge test gate**: `cd supabase/functions && deno test --allow-all tests/` must
  stay green after any Edge edit.

## Locked decisions

1. **One VPS** (4 vCPU / 8 GB, 150 GB+ disk; Hetzner/DigitalOcean/Vultr class —
   prefer a B2 Bandwidth Alliance partner if raw-lane egress grows) running the
   official self-hosted Supabase Docker stack **plus the scoring service as one more
   container**. B2 stays external.
2. **Scoring = extracted Kotlin twin** as a JVM service (Ktor or CLI poller). Not
   Node, not plpgsql, not Edge, not a Python re-port. (Python enters later only for
   new seizure/ML work, as a separate sidecar.)
3. **Scope split**:
   - **Server computes**: RR/HRV pipeline (cleaning, baselines, readiness) + sleep
     staging + sleep score — the multi-pass, day-level, FP-sensitive work.
     Charge/Effort/Rest and insights engines remain dropped (v1 decision; reverse
     only by explicit amendment).
   - **App keeps**: live display readouts only — live HR, live skin temp, live
     rmSSD graph (`LiveSessionEngine` class of work). These are O(1)-per-sample,
     display-only, and are never persisted as canonical scores.
4. **Sync is pure transport.** The sync path is: BLE receive → decode → insert to
   local SQLite → enqueue upload. No `analyzeRecent`, no rescore chunks, no launch
   heals, no fingerprint rescoring on the sync path. Local SQLite becomes a
   cache + upload queue, not a scoring store.
5. **Fast + often uploads.** During a sync: flush per chunk-ack or ≤10 s micro-batch.
   Foreground idle: 30–60 s flush. On backgrounding: flush. Background: OS-opportunistic.
   Payloads are small already-decoded samples; this tunes the existing push pipeline's
   cadence/triggers, it is not a rewrite. Queue is durable (survives relaunch),
   acked, retried with backoff.
6. **Score-on-arrival.** Server scores when data lands — Postgres NOTIFY on ingest
   commit (or 5–10 s poll of unprocessed `noop_signal_windows`) → scorer recomputes
   the affected day windows → writes via the `engine_ingest_*` RPC shape with
   `algorithm_version = 'frwhoop-server-1'` → Realtime delivers to the subscribed app.
   Target: data lands → score rendered on phone ≤ ~60 s.
7. **Auth — three distinct identity classes, checked at distinct layers**:
   - *User (ingest)*: push fn resolves the bearer — Supabase JWT (validated via
     `auth/v1/user`) or opaque `noop_` token (SHA-256 lookup). `user_id` always comes
     from the credential, never the payload. Token mint/list/revoke routes: JWT only.
   - *User (reads)*: Postgres RLS — `auth.uid() = user_id` on every user table;
     Realtime enforces the same per-row. The app cannot read another user's rows.
   - *Machine (scorer/workers)*: service-role key / `WORKER_SECRET`, env-only on the
     VPS, never shipped to a device. VPS hardening: ufw, fail2ban, rate-limit the
     auth endpoints (GoTrue sign-in is internet-facing).
8. **B2 lanes + egress.** Raw high-rate lane unchanged (presigned PUT direct from
   device — bulk bytes never transit the VPS). Scorer adds a derived-artifact lane
   (inferred datasets, parquet or json.zst, registered in `derived_objects` +
   manifest; `reconcile`/`retention-sweep` extended to it). Nightly `pg_dump` + WAL
   archiving (wal-g) → B2. Egress: B2 charges $0 to Alliance-partner compute and
   includes 3× storage/month free otherwise — size provider choice accordingly.
9. **Performance is the primary gate.** Phase 0 baseline → Phase 5 A/B decides
   whether the migration thesis holds. The accuracy shadow (Phase 6) runs in
   parallel and gates only fleet-wide promotion — never the performance experiment
   on the owner's test devices.
10. **Offline behavior**: no connectivity = last-known values with timestamps;
    uploads queue; scorer catches up on reconnect. Stale-state UI (phone + watch)
    ships in Phase 4, before any promotion.

## Phases

### Phase 0 — Baseline instrumentation (before any migration)
- Add duration logging around every on-device scoring entry point (`analyzeRecent`,
  rescoring, staging, launch heals); log `ProcessInfo.thermalState` transitions;
  capture an Xcode Instruments CPU trace during a deep-backlog sync.
- Run `SYNC_TEST_PROCEDURE.md` UC-1 (deep backlog) + UC-3 (daily) on the oldest
  fleet phone, current build; extend the run sheet with: scoring wall time per sync,
  CPU%, thermal state, battery per sync, time-to-settled (caught-up AND scores
  rendered AND phone cool).
- Gate: baseline numbers recorded; Phase 5 success targets set from them.

### Phase 1 — VPS + self-hosted Supabase
- Provision 4 vCPU/8 GB VPS; harden (ssh keys, ufw, fail2ban); Docker + compose.
- Bring up the self-hosted stack; enable pg_cron + pg_net; Caddy/Traefik TLS; DNS.
- Replay all migrations in order (additive only — never reset, never mutate).
- Backups: nightly `pg_dump` + wal-g → B2; **test a restore**.
- Gate: migration replay clean; restore test passes; Studio reachable over TLS.

### Phase 2 — Move ingest + workers
- Deploy `push`, `reconcile`, `retention-sweep`, `account-deletion`, `ingest-verify`
  to the self-hosted Edge Runtime; port secrets; re-point pg_cron; recreate the B2
  presign flow against the same bucket.
- Cutover: staging app build pointed at the VPS; soak 48 h; then production app.
  Keep the cloud project running read-only during soak.
- Gate: deno tests green; push-conformance green against the VPS; a real device
  pushes end-to-end; fleet monitor probes green.

### Phase 3 — Extract the Kotlin scoring service
- Standalone Gradle module from `com.noop.analytics`, scope per Locked #3; Room
  data classes → plain DTOs (annotations are inert; field lists copy verbatim);
  `WhoopRepository` calls → JDBC/Postgres + B2 fetches replicating exact
  ordering/gap semantics.
- Service shell: score-on-arrival per Locked #6; heartbeats into `ingest-verify`;
  containerize (JRE 17); add to compose. Stateless — all state in Postgres + B2.
- Gate: the module's existing unit tests pass **unmodified** on the JVM (parity is
  inherited — do not "fix" formulas); a replayed device-day produces rows.

### Phase 4 — App: transport + renderer (behind flags)
- `serverScoring` flag with per-metric subflags. When on: sync path is
  decode/insert/enqueue only (Locked #4); uploader cadence per Locked #5; scores
  read via Realtime (`postgres_changes`) with `get_day_snapshot` polling fallback;
  stale/last-known UI states implemented.
- Live readouts (`LiveSessionEngine`, HR / skin temp / rmSSD graph) untouched —
  they must work with zero connectivity.
- Gate: both `Strand` (macOS) and `NOOPiOS` build — app-target Swift is not covered
  by default CI, so build both explicitly; airplane-mode behavior verified.

### Phase 5 — Performance A/B (the decision gate)
- Same phones, same strap, same manufactured backlog (config B), flagged build vs
  baseline from Phase 0. Compare: wall time to caught-up (expect ~unchanged — BLE
  is the floor), **time-to-settled**, hitches during/after sync, memory high-water,
  CPU%, thermal state, battery per sync.
- Gate: time-to-settled and thermal materially improve; nothing regresses. If the
  thesis fails, stop here — the VPS still serves ingest, and the flag stays off.

### Phase 6 — Accuracy shadow audit (parallel; gates promotion only)
- Reference devices keep scoring locally while the server recomputes; nightly diff
  per user/day/metric into a comparison table; alert on drift beyond tolerance.
  HRV/RR first; the stager (Cole–Kripke, DoG convolution, EWMA baselines) gets the
  longest soak. Investigate via oracle tests + `docs/RR-OPTIMIZATION.md`, never by eye.
- Gate: ≥14 consecutive days within tolerance per metric before that metric may be
  promoted fleet-wide.

### Phase 7 — Derived-artifact lane to B2
- After each day/session computes, write the inferred dataset to B2; register in
  `derived_objects` + manifest; extend `reconcile`/`retention-sweep`.
- Gate: manifest↔B2 consistency under `reconcile`; retention deletes propagate.

### Phase 8 — Promotion + decommission
- Promote metrics one at a time (flag + rollback); on-device scoring code stays but
  excluded behind the flag for one release.
- Decommission the Supabase cloud project only after ≥30 days clean on the VPS and
  a final verified backup.
- Update `MIGRATION.md` (new phase), `docs/CLOUD_INGESTION.md` (the "never
  recomputes" invariant is deliberately retired), `docs/ANALYTICS.md` (canonical
  scorer = server Kotlin service), `docs/SYNC_TEST_PROCEDURE.md` (new run-sheet
  columns from Phase 0).

## Hard rules for the executor

- Additive migrations only; versioned migration + test for any schema change.
- Do not touch BLE/protocol code paths; no new write commands to hardware. Sync-path
  changes are transport-only: decode/insert/enqueue behavior stays byte-identical.
- No Node API for push or scoring (repo rule). No telemetry/phone-home additions.
- Keep the box stateless: all state in Postgres + B2; the container is replaceable.
- Medical data: de-identify before any third-party compute; secrets in env only,
  never in the repo; least-privilege keys on the VPS.
- Cross-platform parity contract still applies to what remains on-device (live
  readouts); the server Kotlin service becomes the single canonical scorer per
  promoted metric — record each promotion explicitly.

## Definition of done

Sync is pure transport (no scoring on the sync path); the app renders
server-computed HRV/RR + sleep within ~a minute of data landing; live readouts
work offline; Phase 5's A/B shows the measured improvement against the Phase 0
baseline; derived datasets archive to B2 daily; one VPS runs the whole system with
tested backups; conformance + deno + oracle suites green; cloud Supabase project
decommissioned; docs updated.
