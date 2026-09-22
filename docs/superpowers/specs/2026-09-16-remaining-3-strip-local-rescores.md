# REMAINING 3 OF 3 — Remove local rescores
# Transport-only sync when serverScoring is on
#
# Run only after Remaining 2's gate is green (flag + readback exist).
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
- When `serverScoring` is on, sync is pure transport: decode → insert → enqueue.
  No `analyzeRecent` on the sync path.
- Auth: ingest `user_id` comes from the credential (Supabase JWT or hashed `noop_`
  token), never the payload. Reads use RLS `auth.uid() = user_id`. Machine writes
  use `service_role` / `WORKER_SECRET` on the VPS only.
- Additive migrations only. Never edit `supabase/migrations/20260916160000_scoring_service_state.sql`.
- No Node API. No BLE write commands. No telemetry/phone-home.
- Do not "fix" analytics formulas. Do not delete `IntelligenceEngine` /
  `StrandAnalytics`. Leave the code behind the flag.
- Android app compile currently fails in `ImuContinuousRecorder` /
  `ImuSessionFileStore` (commit `0da055e7`). Do not spend this prompt finishing IMU.
  Apply the Android twin of every Apple sync-path change. If IMU blocks the
  module compile, document it as pre-existing.
- Secrets stay in env. Never commit `.env`, `infra/vps/droplet.env`, keys, or tokens.
- Stop and report if a required host/key is missing. Do not invent credentials
  and do not point anything at the old cloud Supabase project.

Already done — do not rebuild:

- Remaining 1: scorer writes device-attributed `frwhoop-server-1` rows.
- Remaining 2: authenticated snapshot/Realtime + `serverScoring` flag (default
  off) + last-known cache + Today/sleep render of server HRV/sleep.

Current app fact: even with the flag on, sync still drains a **rescore** job
that calls `IntelligenceEngine.analyzeRecent`. That is the CPU/thermal/sync-stall
path this prompt removes.

Out of all three remaining prompts (do not start these):

- B2 derived-artifact lane
- accuracy shadow soak / Phase 5 A/B
- cloud Supabase decommission
- deleting analytics packages
- finishing the IMU recorder feature

---

# This prompt's mission

When `serverScoring` is **on**, the phone must not run heavy scoring because
the strap synced.

Sync path becomes: BLE receive → CRC/decode → SQLite insert → enqueue upload.
Scores on screen come only from Remaining 2's server cache/Realtime.

When the flag is **off**, today's local rescore behavior stays byte-identical.

Also tighten upload cadence so the server has data soon enough to score
(Locked: during sync flush per chunk-ack or ≤10 s; foreground idle 30–60 s;
on backgrounding, flush). Live readouts stay local.

## Do not do in this prompt

- Do not delete `analyzeRecent`, `SleepStager`, or analytics tests.
- Do not disable live HR / skin temp / rmSSD graph, including offline.
- Do not change BLE write/handshake behavior, `didBond`, or protocol frames.
- Do not "fix" IMU compile except if a file you must edit cannot parse.
- Do not start B2 derived artifacts or cloud deletion.
- Do not turn the flag on by default in shipping xcconfig. Default remains
  off; the owner's test build may enable it via the Remaining 2 toggle.

## Required access — stop if missing

| Need | Why |
|---|---|
| Remaining 2 flag + cache in tree | this prompt only skips scoring when that path exists |
| Xcode | `Strand` + `NOOPiOS` compile; app-target Swift has no default CI |
| VPS push URL already in the test build | cadence changes are useless if push still points at cloud |

If Xcode is missing, land the source changes and hand back compile commands.

## Work

### 1. Inventory every heavy scoring entry point (do this first, in the report)

Search Apple + Android for at least:

- `analyzeRecent`
- `runDeferredRescoreIfOwed` / `RescoreBackgroundScheduler`
- `SyncEngine` `.rescore` / `SyncJobKind.rescore`
- `refreshAfterCompletedBackfill`
- fingerprint-driven idle/launch rescore (15-min tick, AppModel launch heals)
- Android `WhoopBleClient` post-offload `IntelligenceEngine.analyzeRecent`

List each call site with file:line and whether it is (a) sync-triggered heavy
scoring, (b) live readout, (c) user-initiated "recompute" in Test Centre, or
(d) import/heal of edited sleep that must remain for local-only flag-off.

Only (a) is skipped when the flag is on. (b) stays. (c) can stay behind Test
Centre. (d) stays when flag is off; when flag is on, edited-sleep heals must
not re-run a 21-day `analyzeRecent` — leave a short comment if a follow-up is
needed rather than silently dropping user edits.

### 2. Skip sync-coupled rescores when the flag is on

Apple:

- `Strand/System/SyncEngine.swift` `runRescore`: if `serverScoring`, settle the
  rescore job as complete **without** calling `analyzeRecent` / deferred
  rescore. Do not leave an owed rescore that wakes forever.
- `Repository` / `AppModel` post-backfill / fingerprint / launch-heal paths
  that call `analyzeRecent` because raw data arrived: skip when flag on.
- Do not skip `LiveSessionEngine` (or equivalent) live HR / temp / rmSSD.

Android twin in the same PR:

- `WhoopBleClient` post-offload analyzeRecent
- any `SyncEngine`/ViewModel rescore analogue

Keep `skipIfUnchanged` behavior for flag-off paths. Do not refactor the engine.

### 3. Faster authenticated upload (flag on)

Today `CloudPushPeriodicScheduler.defaultInterval` is 5 minutes.

When `serverScoring` is on:

- During an active sync/offload: flush push on chunk-ack or ≤10 s micro-batch,
  whichever comes first. Reuse `CloudPushWorker.runOnce`; do not rewrite the
  push protocol.
- Foreground idle: 30–60 s (not 5 min).
- On backgrounding: one flush.
- Background: keep OS-opportunistic; do not invent a new always-on background
  mode that fights iOS.
- Queue remains durable, acked, retried with backoff (already true — do not
  replace it).
- Auth stays per-user (JWT or that user's `noop_` ingest token). Do not
  reintroduce a build-wide shared token as the only identity.

Android: same cadence policy if a periodic pusher exists; if Android push is
not in this fork yet, say so and only change Apple.

### 4. Keep serving server scores

Do not regress Remaining 2. After a flag-on sync:

- UI must not wait on local `analyzeRecent` to show HRV/sleep.
- Last-known + timestamp remains until Realtime/snapshot updates.
- Airplane mode: live readouts still move; server scores stay last-known.

### 5. Tests

- Unit/logic tests: flag on → rescore drain does not call `analyzeRecent`
  (fake IntelligenceEngine or a seam). Flag off → still calls it.
- Do not weaken existing analytics oracle tests; they still run, they just
  are not invoked from sync when the flag is on.
- Deno tests still green if you touched no Edge code (you should not).

## Files you are expected to touch

- `Strand/System/SyncEngine.swift`
- `Strand/App/AppModel.swift` (launch/fingerprint heals)
- `Strand/Data/Repository.swift` (post-backfill analyzeRecent)
- `Strand/Data/IntelligenceEngine.swift` only if you add a thin skip guard —
  prefer skipping at call sites so flag-off stays identical
- `Strand/Push/CloudPushPeriodicScheduler.swift` + any offload-ack flush site
- Android: `WhoopBleClient.kt`, `IntelligenceEngine` call sites, any push scheduler
- tests next to those seams
- `docs/CLOUD_INGESTION.md` — one paragraph: when `serverScoring` is on, the
  receiver still does not decode BLE, but the VPS JVM service **does** recompute
  HRV/sleep; the old "never recomputes" sentence is retired for this fork flag.

Do not touch `scoring-service/` or `supabase/migrations/` unless a tiny grant
is genuinely missing (it should not be).

## Verification gate (all required)

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

If Android unit tests can compile past IMU, run the new skip tests; if not,
file-level review + note the pre-existing IMU failure.

Behavioral:

- Flag **off**: sync still rescores as today.
- Flag **on**: a completed offload/sync does not enter `analyzeRecent`;
  rescore jobs do not stay owed; Today still shows Remaining 2 server cache;
  live HR still updates with the strap.
- Push interval when flag on is ≤60 s idle, and a sync chunk can trigger a
  push without waiting 5 minutes.
- No BLE protocol edits in the diff.

## Done when

The owner's test device can: pair/sync as transport, upload quickly, see
server HRV/sleep from Remaining 2, and not burn CPU on a 21-day rescore
because the strap finished offloading.

End with a call-site inventory (kept vs skipped), compile evidence, and any
Android IMU residual.
