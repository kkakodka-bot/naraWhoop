# REMAINING 1 OF 3 — Enable server scoring
# Device-aware queue + replay that writes versioned score rows
#
# Run this prompt first. Remaining 2 and 3 are blocked until this gate is green.
# Paste everything below the line into a fresh agent session.

---

# FRWHOOP_v2 — Universal Context (normative)

You are executing ONE remaining prompt of the server-scoring cutover in FRWHOOP_v2,
a fork of NOOP. This fork ships a hosted Supabase/B2 pipeline for the owner's devices.
Read this entire notice before touching anything. Where it conflicts with your
defaults, this notice wins.

Target path:

```
strap --BLE--> app (decode + local cache + live display-only + upload queue)
                 --> authenticated HTTPS push
                 --> self-hosted Supabase on one VPS
                 --> JVM Kotlin scoring service (extracted Android twin)
                 --> server_daily_scores / server_sleep_nights
                     (algorithm_version = frwhoop-server-1)
                 --> authenticated Realtime / snapshot
                 --> app renders cached/latest server scores
```

Locked decisions:

- Server computes RR/HRV pipeline + sleep staging/score only. Charge/Effort/Rest
  are dropped from server output even if the kernel computes them internally.
- App keeps live HR, live skin temp, live rmSSD graph. Those are O(1)-per-sample,
  display-only, and never canonical scores.
- When the later flag is on, sync is pure transport: decode → insert → enqueue.
  No `analyzeRecent` on the sync path. That strip is Remaining 3, not this prompt.
- Auth: ingest `user_id` comes from the credential (Supabase JWT or hashed `noop_`
  token), never the payload. Reads use RLS `auth.uid() = user_id`. Machine writes
  use `service_role` / `WORKER_SECRET` on the VPS only.
- Additive migrations only. Never edit `supabase/migrations/20260916160000_scoring_service_state.sql`.
- No Node API. No BLE write commands. No telemetry/phone-home.
- Do not "fix" analytics formulas. `analytics-kernel` sources stay byte-verbatim
  copies of the Android twin.
- Android app compile currently fails in `ImuContinuousRecorder` /
  `ImuSessionFileStore` (commit `0da055e7`). That is not a scoring-service failure.
  Do not spend this prompt finishing IMU.
- Secrets stay in env. Never commit `.env`, `infra/vps/droplet.env`, keys, or tokens.
- Stop and report if a required host/key is missing. Do not invent credentials
  and do not point anything at the old cloud Supabase project.

Already done — do not rebuild:

- VPS self-hosted Supabase + scoring container (container healthy; heartbeat
  `last_poll_at` advancing).
- `scoring-service/` with `analytics-kernel` (746 tests green) + poller +
  `engine_ingest_scored`.
- `EngineIngestWriter` emits `source_device_id` / `device_id` on output rows.
- `DayScorer` uses user-local `dayLo`/`dayHi` from `UserDayBounds`.
- PostgresClient JDBC userinfo stripping.

Current production fact: **zero** `server_daily_scores` / `server_sleep_nights`
rows. Work items are still keyed `(user_id, day)`. `loadDay` still picks the
most-recently-seen device. Discovery watermark was pinned to now to avoid a
full-history flood until this prompt lands.

Out of all three remaining prompts (do not start these):

- B2 derived-artifact lane
- accuracy shadow soak / Phase 5 A/B
- cloud Supabase decommission
- Phase 0 thermal instrumentation

---

# This prompt's mission

Make the JVM scorer produce trustworthy, device-attributed score rows for a
known user/day, then leave those rows sitting in Postgres for Remaining 2.

Success is: a replayed device-day writes `server_daily_scores` and
`server_sleep_nights` under `algorithm_version = 'frwhoop-server-1'`, and the
durable queue can discover/claim that same work as `(user_id, device_id, day)`
without mixing devices.

## Do not do in this prompt

- No app UI, no Realtime subscriptions, no RLS policies for `authenticated`.
- No `serverScoring` flag.
- No stripping of `analyzeRecent` / rescore jobs.
- No upload-cadence changes.
- No formula changes in `Packages/StrandAnalytics` or `android/.../analytics`.
- No edits to BLE/protocol packages.
- Do not unpin the discovery watermark to epoch. Replay named days; do not
  flood-score the whole history.

## Required access — stop if missing

You need all of these. If any is absent, write a precise access request and
stop that step. Do not guess.

| Need | Typical location (do not print secret values) |
|---|---|
| VPS SSH | `infra/vps/droplet.env` / owner SSH config |
| `DATABASE_URL` / `SCORING_DATABASE_URL` | VPS scoring container env / local `.env` |
| `INGEST_SECRET` (for `engine_ingest_scored`) | same |
| `SUPABASE_URL` + service-role key | VPS / `.env` |
| `REPLAY_USER_ID` | owner supplies; a user that already has `noop_hr_samples` / `noop_rr_intervals` |
| `REPLAY_DAY` | owner supplies; a local calendar day that has night-window HR or RR |
| `REPLAY_DEVICE_ID` | uuid from `public.devices` for that user; do not invent |

If `REPLAY_*` are not in env, query (read-only) for a user/device/day that has
night-window samples, print the ids (not secrets), and ask the owner to confirm
before scoring a real patient. If you cannot reach the VPS, implement the schema
+ code locally, run unit tests, and hand back the exact deploy commands.

## Work

### 1. Additive migration — device-aware work items

Add a **new** versioned migration (do not mutate `20260916160000`).

Change `public.scoring_work_items` so the identity is `(user_id, device_id, day)`:

- `device_id uuid not null references public.devices(id)` (or equivalent FK that
  already exists).
- New primary key `(user_id, device_id, day)`.
- Keep `dirty_at` / `claimed_at` / `done_at` / `attempts` / `last_error` /
  `last_duration_ms` semantics.
- Due index still supports `where done_at is null`.
- Backfill existing rows: if any `(user_id, day)` rows exist, attach the
  device_id from `public.devices` for that user (most recent `last_seen_at` is
  acceptable **only for backfill of already-queued rows**). New discovery must
  not use that heuristic.

Service-role-only RLS stays. Do not add `authenticated` policies here.

### 2. Discovery groups by user, device, and local day

Update `ScoringWorkQueue`:

- `discoverLocalDays` must include `device_id` from `noop_hr_samples`,
  `noop_rr_intervals`, and `noop_signal_windows` (those tables already have
  `device_id`). Group by `(user_id, device_id, local day)`.
- `WorkItem` carries `deviceId`.
- `upsert` / `claim` / `markDone` / `markFailed` / `selectDue` all key on
  `(user_id, device_id, day)`.
- Dirty-at requeue semantics stay: new ingest while in-flight bumps `dirty_at`
  and completion refuses to mark done if `dirty_at` moved.

Add/extend unit tests with a fake connection or SQL-shaped assertions so the
GROUP BY and PK are covered without a live DB if possible. If a live DB is
required for a test, skip it when `DATABASE_URL` is unset — do not open Hikari
to localhost in unit tests.

### 3. `loadDay` uses the claimed device

Update `ScoreInputProvider` / `SignalSampleReader` / `ScoringPoller`:

- `loadDay(userId, day, deviceId)` — required `deviceId`, no
  `loadPrimaryDeviceId` fallback on the scoring path.
- Sample reads already filter `device_id`; keep that.
- Profile `device_family` must come from **that** device row, not "latest
  device for user".
- `--replay-day` must require `REPLAY_DEVICE_ID` (or resolve it only when the
  user has exactly one device; if more than one, stop and ask).

`EngineIngestWriter` already emits `source_device_id`. Keep that. The written
device must equal the claimed device.

### 4. Diagnose the unfinished work item, then replay one day

On the VPS (or local DB if that is what you have):

1. Read `scoring_work_items.last_error`, `attempts`, `done_at` for the existing
   row. Fix a real scorer bug if that error is a code defect. Do not "fix" a
   formula.
2. Apply the new migration.
3. Rebuild and redeploy the scoring image (`infra/vps/scripts/deploy-scoring-service.sh`
   or the documented equivalent). Confirm the container stays up and
   `scoring_service_heartbeats.last_poll_at` advances.
4. Run `--replay-day` for the confirmed `REPLAY_USER_ID` / `REPLAY_DEVICE_ID` /
   `REPLAY_DAY`.
5. Confirm rows:

```sql
select user_id, day, algorithm_version, source_device_id, hrv_rmssd_ms, sleep_total_min, computed_at
from public.server_daily_scores
where algorithm_version = 'frwhoop-server-1'
order by computed_at desc
limit 5;

select user_id, period_day, device_id, algorithm_version, asleep_min, computed_at
from public.server_sleep_nights
where algorithm_version = 'frwhoop-server-1'
order by computed_at desc
limit 5;
```

If replay writes nothing because the night window has no HR/RR, pick a
different day with samples. Log the skip reason; do not lower the night window
to "whatever data exists" in a way that diverges from `UserDayBounds`.

### 5. Prove the queue path once

After replay works, enqueue one work item for that same `(user, device, day)`
(dirty it) and let the poller claim it. Confirm it completes (`done_at` set,
`last_error` null) and does not duplicate-key-smash a different device.

Leave the discovery watermark as-is (not epoch).

## Files you are expected to touch

- new file under `supabase/migrations/` (timestamp after 20260916160000)
- `scoring-service/service/src/main/kotlin/com/frwhoop/scoring/db/ScoringWorkQueue.kt`
- `scoring-service/service/src/main/kotlin/com/frwhoop/scoring/db/SignalSampleReader.kt`
- `scoring-service/service/src/main/kotlin/com/frwhoop/scoring/db/ScoreInputProvider.kt`
- `scoring-service/service/src/main/kotlin/com/frwhoop/scoring/scoring/ScoringPoller.kt`
- `scoring-service/service/src/main/kotlin/com/frwhoop/scoring/ScoringApplication.kt` (replay args)
- matching tests under `scoring-service/service/src/test/`
- `docs/ops/PHASE3-BLOCKERS.md` — mark blocker 5 discovery/queue side resolved
- `scoring-service/README.md` — document `REPLAY_DEVICE_ID` and the new PK

Do not touch `Strand/`, `StrandiOS/`, `android/app` (except the kernel sync
source list if a test path requires it — it should not).

## Verification gate (all required)

```bash
cd scoring-service
export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
./gradlew :analytics-kernel:test :service:test :service:installDist --no-daemon
cd supabase/functions && deno test --allow-all tests/
```

- Kernel tests remain 746 pass, 0 fail. Do not add CurrentHrv back into the kernel.
- Service tests pass with **no** real localhost Postgres in unit tests.
- New migration applies on the VPS.
- Replay writes ≥1 `server_daily_scores` row and the sleep nights the day
  actually has (zero sleep nights is OK only if the kernel produced none).
- `source_device_id` / `device_id` on those rows equal `REPLAY_DEVICE_ID`.
- Queue claim/complete works for that triple.
- Heartbeat `last_score_at` is non-null after the successful score.
- Container not crash-looping.

## Handoff to Remaining 2

End with a short report:

- migration filename
- replay user / device / day (ids only)
- row counts written
- any skip/`last_error` still present
- whether VPS deploy happened or only local code is done
- secrets you needed but did not have

Remaining 2 must not start if zero server score rows exist.
