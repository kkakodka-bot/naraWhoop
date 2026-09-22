# REMAINING 2 OF 3 — Serve server scores to users
# Authenticated readback + flag + render cached server HRV/sleep
#
# Run only after Remaining 1's gate is green (server rows exist).
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
  `ImuSessionFileStore` (commit `0da055e7`). Do not spend this prompt finishing IMU.
  Apply Android client changes anyway; if the IMU files block `:app:compileFullDebugKotlin`,
  document that the scoring/readback edits compiled at the file level and the IMU
  failure is pre-existing.
- Secrets stay in env. Never commit `.env`, `infra/vps/droplet.env`, keys, or tokens.
- Stop and report if a required host/key is missing. Do not invent credentials
  and do not point anything at the old cloud Supabase project.

Already done — do not rebuild:

- VPS + JVM scorer + `engine_ingest_scored`.
- Remaining 1: device-aware `scoring_work_items` PK `(user_id, device_id, day)`
  and at least one replayed day of `server_daily_scores` /
  `server_sleep_nights` for a real user.

Current app fact: TodayView / snapshots still render on-device scores.
`get_day_snapshot` reads `daily_metrics` (device-pushed), not the server shadow
tables. Shadow tables are **service_role only** — the app cannot read them yet.

Out of all three remaining prompts (do not start these):

- B2 derived-artifact lane
- accuracy shadow soak / Phase 5 A/B
- cloud Supabase decommission
- stripping `analyzeRecent` / rescore drain (Remaining 3)

---

# This prompt's mission

Let an authenticated user see their own server HRV + sleep scores.

1. Postgres: users can SELECT their own `server_daily_scores` /
   `server_sleep_nights` rows. Nobody else's. Machines still write as service_role.
2. Snapshot/Realtime: the app can fetch and subscribe to those rows.
3. App flag `serverScoring` (default off): when on, Today/sleep surfaces render
   the server values and keep a last-known cache with timestamps.
4. Local heavy scoring **still runs**. Remaining 3 removes it. Dual-run is
   intentional so the UI never goes blank if Realtime is late.

## Do not do in this prompt

- Do not remove `analyzeRecent`, rescore jobs, launch heals, or fingerprint
  passes. Gate them only if you must in order to compile a flag helper — the
  default remains "local scoring on".
- Do not change BLE, protocol, or analytics formulas.
- Do not change upload cadence (Remaining 3).
- Do not grant `authenticated` INSERT/UPDATE/DELETE on server score tables.
- Do not merge server rows into `daily_metrics` / `sleep_nights`. Shadow tables
  stay the canonical server scores. Device-pushed tables stay device-pushed.
- Do not use the service-role key in the app binary.

## Required access — stop if missing

| Need | Why |
|---|---|
| VPS `SUPABASE_URL` (HTTPS) | app and PostgREST/Realtime |
| Anon key + JWT-capable GoTrue on the VPS | user reads |
| At least two distinct test users (JWT or equivalent) | RLS proof: A cannot read B |
| Remaining 1 score rows for user A | something to render |
| Xcode (macOS) | `Strand` and `NOOPiOS` must compile; default CI does not |

If you cannot sign the iOS app, still compile:

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

If Xcode is missing, implement the Swift/SQL/Kotlin, run Deno tests, and hand
back the exact compile commands.

## Work

### 1. Additive migration — user read policies + snapshot overlay

New versioned migration only.

- Enable existing RLS (already on). Add SELECT policies:

  `auth.uid() = user_id` on `server_daily_scores` and `server_sleep_nights`.
  SELECT only. No write policies for `authenticated`.
  Keep the service_role ALL policies.

- Grant `select` to `authenticated`. Do not grant to `anon`.

- Extend **or** add a sibling RPC. Preferred: additive columns/object on
  `get_day_snapshot` so existing clients ignore unknown keys:

  `server_scoring` jsonb, e.g.

  ```
  {
    "algorithm_version": "frwhoop-server-1",
    "daily": { ...hrv/sleep rollup from server_daily_scores... },
    "nights": [ ...server_sleep_nights for that local day... ],
    "computed_at": "...",
    "stale": false
  }
  ```

  SECURITY INVOKER, `auth.uid()` required, same as the live snapshot. Filter
  `algorithm_version = 'frwhoop-server-1'`. If no server row, `daily`/`nights`
  are null — never fall back to another user's row and never silently
  substitute Charge/Effort/Rest.

- Publication: add the two tables to the existing Realtime publication if one
  exists; otherwise document how the app will poll `get_day_snapshot` every
  N seconds as fallback. Polling fallback is required even with Realtime.

Apply on the VPS. `cd supabase/functions && deno test --allow-all tests/` green.

### 2. Prove RLS with two users

Using two JWTs (or `SET request.jwt.claim.sub` in a SQL test):

- User A SELECT of A's server rows: returns rows.
- User A SELECT of B's `user_id`: zero rows / RLS denial, never data.
- Anon: no access.
- service_role: still can write (scorer unchanged).

If you cannot mint a second JWT, write a SQL test that sets `auth.uid()` via
the project's existing test pattern (`supabase/functions/tests/` or a pgTAP
file if one exists). Do not weaken RLS to make a demo pass.

### 3. App flag and client

Apple (required this prompt):

- Add `serverScoring` (bool, default **false**) with the existing settings
  pattern (UserDefaults / `CloudPushSettings`-style, design tokens only if
  you add UI). A Developer / Test Centre toggle is enough. Do not bury it
  as a compile-only `#if` that cannot be flipped on a test device.
- When false: behavior unchanged.
- When true:
  - After sign-in / on appear / on snapshot poll: call `get_day_snapshot`
    (or the new RPC) with the user JWT against the **VPS** URL already used
    for push.
  - Subscribe to `postgres_changes` on `server_daily_scores` and
    `server_sleep_nights` filtered by the signed-in user.
  - Persist last-known server daily + nights + `computed_at` in local SQLite
    or an existing cache table (additive WhoopStore migration if you need a
    new table — versioned, tested).
  - Today / sleep UI reads that cache for HRV rmSSD, resting HR, sleep totals
    / stages when the flag is on. Live HR / skin temp / rmSSD **graph** stay
    on-device engines.
  - Stale UI: if `computed_at` is older than a documented threshold or
    snapshot has null `daily`, show last-known + timestamp, not a spinner
    forever and not fabricated numbers.

Android (parity, same flag name/default):

- Same flag, same snapshot/cache behavior on the surfaces that show daily
  HRV/sleep. If IMU compile blocks the full module, still land the files.

Per-user auth: the read client must use the signed-in user's JWT (or the
existing session). Do not send `NOOPPushToken` as the read credential.
Do not share one ingest token across users for score reads.

### 4. Wire contract

- `user_id` on reads is only `auth.uid()`.
- `algorithm_version` default `frwhoop-server-1`.
- Ignore Charge/Effort/Rest if a payload ever contains them.
- Endpoint is the self-hosted URL, same project the scorer writes to.

## Files you are expected to touch

- new `supabase/migrations/` file
- possibly `supabase/functions/_shared/` only if snapshot helpers live there
- `supabase/functions/tests/` for RLS/auth tests
- `Packages/WhoopStore/` if a cache table is needed (migration + test)
- `Strand/` screens + settings + a small server-score repository
- `StrandiOS/` only if the iOS shell needs a settings hook the macOS file
  does not share — keep shared files compiling for both
- `android/app/src/main/java/com/noop/...` flag + read client

Do not touch `scoring-service/` unless a column you need is missing from
`engine_ingest_scored` (unlikely; prefer reading existing columns).

## Verification gate (all required)

- Deno tests green, including new RLS/auth cases.
- SQL/RPC: user A sees A's server HRV/sleep; user B does not see A.
- Flag off: UI unchanged.
- Flag on, with Remaining 1 rows present: Today/sleep show server values
  (or last-known + timestamp if you cannot run a device — then prove via a
  unit/integration test of the mapper + cache).
- `Strand` and `NOOPiOS` compile (or exact compiler errors handed back).
- No service-role key in app sources or xcconfig that ships to devices.
- Local `analyzeRecent` still runs (Remaining 3 has not happened).

## Handoff to Remaining 3

Report:

- migration filename
- flag default and where it is toggled
- which screens read server scores
- cache table/key
- compile evidence
- RLS proof method
- anything still falling back to device-pushed `daily_metrics`
