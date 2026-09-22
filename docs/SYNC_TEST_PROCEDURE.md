# Multi-phone sync test procedure — iOS · WHOOP 5.0/MG

A repeatable field procedure for running one WHOOP 5.0/MG strap (or several) across a fleet of
iPhones and collecting comparable evidence on four axes:

1. **Chunk parsing time** — per-chunk decode/insert/ack latency during history offload.
2. **Syncing ease** — time and friction from fresh install to a completed, caught-up sync.
3. **App performance** — frame hitches and memory while syncing and while touring the app.
4. **Data collection** — what actually landed in the on-device store, and whether the strap still
   owes history.

Everything below uses shipped, in-app machinery: the Test Centre (Connection & Sync, Display &
Performance), the PII-scrubbed strap log, and the standard export paths. No code changes, no
jailbreak, no proxy. BLE behavior is deliberately not CI-tested in this repo — this document is the
hardware-validation counterpart to [`CONTRIBUTING.md`](CONTRIBUTING.md)'s "verify on a real strap"
rule.

## Read first — five facts that shape the procedure

1. **History sync on WHOOP 5.0/MG is experimental (#580).** A 5/MG can ack
   `SEND_HISTORICAL_DATA` and then emit no offload frames at all. The app treats a sustained empty
   5/MG offload as *"connected, history experimental"* — **not** an error — and clears that note
   only when a real `HISTORY_COMPLETE` arrives with banked sensor records. A test run whose verdict
   is "history experimental" is a valid, honest result; record it, don't retry-loop it away.
2. **Chunk timing only exists while Connection & Sync is ON.** The per-chunk
   `offload chunk … decodeMs=…` lines and the session `chunk phase timing` summary are gated behind
   the Test Centre Connection domain. Enable it **before pairing** or the first — usually deepest —
   offload goes unmeasured.
3. **The strap log is a 5,000-line ring.** A deep first offload plus a long app tour can overflow
   it. Export promptly after each phase, or enable the scheduled daily export for multi-day runs.
4. **One strap bonds to one phone at a time, and acked chunks are trimmed from the strap.** The
   first phone to complete a sync *drains* the strap's retained history; the next phone's "fresh
   first sync" sees only what the strap still retains. Run order is an experimental variable — plan
   it (see Fleet configurations).
5. **No official WHOOP app on test phones.** A competing central steals the link and corrupts the
   measurement. The Connection domain has an `otherCentral` capture precisely because this happens.

## Equipment & fleet setup

- 2+ iPhones on the oldest and newest iOS versions in the fleet (deployment target: iOS 17).
  Spread hardware tiers — the oldest phone is the interesting one for chunk-parse latency.
- 1+ WHOOP 5.0/MG straps, charged to 100% before each deep-backlog run (a strap whose clock has
  lost sync stops banking history; the sync banner names this and full charge is the remedy).
- A Mac with Xcode for build-from-source installs, or AltStore/SideStore for `.ipa` sideloads.
- A shared folder (or the fork's push pipeline, see Optional: cloud push) for harvested logs.

**Fleet configurations.** Pick per campaign:

| Config | What it measures |
|---|---|
| **A — Sequential, one strap** | Phone 1 gets the deep-backlog first sync; phones 2..N get fresh-install *short* offloads. Measures both extremes; not symmetric. |
| **B — One strap per phone** | Symmetric deep first syncs; the cleanest cross-phone chunk-parse comparison. |
| **C — Daily driver** | Phones stay paired; periodic/manual incremental syncs over days; measures steady-state ease + reconnect churn. |

To manufacture a deep backlog for config B: wear each strap with Bluetooth off (or far from any
paired phone) for several days so it banks history locally.

## Phase 0 — Build & fresh install

- [ ] Record the build identity: `git rev-parse HEAD`, `MARKETING_VERSION` from `project.yml`.
- [ ] Build from source: `xcodegen generate`, then build the **`NOOPiOS`** scheme
      (`xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'platform=iOS' …`).
      For a fleet, signing under your own Apple ID is required: copy
      `Config/BundleIdSecrets.example.xcconfig` → `Config/BundleIdSecrets.xcconfig`, set
      `BUNDLE_ID_PREFIX`, re-run `xcodegen generate`, and select your Team for **NOOPiOS** and
      **NOOPiOSWidgets** (see [`IOS.md`](IOS.md) §Build from source). Sideloaded `.ipa` via
      AltStore/SideStore also works — but a free Apple ID signature **expires after 7 days**, which
      will silently kill a week-long config-C run unless the sideloader refreshes it.
- [ ] Guarantee "fresh": if NOOP was ever on this phone, remove the strap inside the app first,
      delete the app, then iOS Settings → Bluetooth → **Forget** the WHOOP entry. Bond state lives
      on both sides; skipping the Bluetooth forget produces a misleadingly fast or a stuck pairing.
- [ ] Install, but **do not open the app yet** if you want a clean t0.

## Phase 1 — Instrument before first launch

Timing beats: everything from here is timestamped in the strap log (`[HH:mm:ss]` prefix), so the
log itself is the stopwatch. Wall-clock notes are only needed for events outside the app.

- [ ] Launch the app. The onboarding wizard appears (fresh install ⇒ `noop.onboarded` is unset).
- [ ] **Before pairing:** finish or park the wizard far enough to reach Settings → **Test Centre**,
      and enable:
  - [ ] **Connection & Sync** — gates `connectTiming`, `bondState`, `frameTiming`,
        `reconnectChurn`, `offloadProgress`, `offloadStalls`, `firmwareDecode`, `clockDrift`,
        `otherCentral`, and the chunk phase timing lines.
  - [ ] **Display & Performance** — starts the frame monitor (mean/p95 frame ms, hitches > 33 ms,
        memory high-water). It runs only while the mode is on.
  - [ ] Optional, multi-day runs: **scheduled daily strap-log export**.
- [ ] Keep the app foregrounded and the phone on charge during timed phases. iOS background BLE is
      wired, but a foregrounded phone removes power-state variance from the comparison.

## Phase 2 — Onboarding → BLE connection

The wizard walks Welcome → … → Bluetooth → Wear → **Scan** → **Bonded** → Profile → … → Done.
Record (the log carries most of it; note wall-clock for the rest):

| Checkpoint | Evidence |
|---|---|
| t0 first launch | wall-clock note |
| t1 scan started | wizard step; strap log scan lines |
| t2 strap discovered | wall-clock note (time-to-discover is a phone-radio signal) |
| t3 bonded / encrypted | `bondState encryptedBond family=whoop5 …` (Connection mode) |
| t4 handshake done | connect-handshake completion; offload may log `deferred — connect handshake not done yet` if it races ahead |

**Ease observations to note qualitatively:** did scan find the strap on the first try; did bonding
need a retry or an iOS pairing dialog; did the wizard's expectations match what happened (a 5/MG
that connects but stays "history experimental" should *not* read as broken).

## Phase 3 — First sync (primary measurement)

A connect-triggered `requestSync(.connect)` fires ~1.5 s after the handshake. A deep backlog is
served as repeated ~50-record chunks, each closed by `HISTORY_END`, and may be segmented by the
firmware into several `HISTORY_COMPLETE` slices — the app auto-continues (capped at 6 slices per
connection) until the strap is caught up. **One "first sync" is therefore the whole chain of
sessions, not the first session.**

Watch: the Today sync chip (`Syncing strap history…` + chunk count), and the strap log.

Collect per session (all gated lines require Connection & Sync ON):

| Log line (grep prefix) | Carries |
|---|---|
| `Backfill: session started — historical offload requested` | session t-start |
| `offload chunk trim=… frames=… decodeMs=… insertMs=… ackMs=… totalMs=…` | per-chunk phases |
| `Backfill: chunk phase timing n=… total p50/p99=… decode p50/p99=… insert p50/p99=… inter-chunk gap p50/p99=…` | **axis 1 headline numbers** |
| `Backfill: session persisted N rows (M with motion, K skin-temp) across X night(s).` | per-session yield |
| `Backfill: rows landed on yyyy-MM-dd… · clock ref: identity - correct for 5/MG …` | dates + clock health |
| `Backfill: session ended — reason=HISTORY_COMPLETE` (or `timeout`) | exit cause |
| `offload result=complete rows=N nights=K` | connection-level outcome |
| `Backfill: WHOOP 5/MG offload empty N× — history sync is experimental…` | the honest-empty path |
| `Backfill: N frame(s) this chunk carried no sensor records …` | console-only chunks (clock/banking symptom) |
| `frameTiming type=METADATA t=…s` | frame arrival cadence |

Derive for the run sheet: time t3→t4 (bond → first session start), first-chunk latency, total
wall time until caught up, chunks and rows total, decode/insert p50/p99 across sessions.

**5/MG acceptance bar:** the chain ends in *caught up* (real `HISTORY_COMPLETE` with banked rows)
**or** in the explicit history-experimental state. Anything else — a sync error banner, a stall
that never reaches the 60 s idle watchdog, a reboot loop — is a defect: export the log immediately
(Phase 7) before the ring wraps.

## Phase 4 — Steady-state sync passes (ease, repeatability)

After the first caught-up sync:

- [ ] **Manual sync:** pull-to-sync / Sync now. Expect a short session or a clean caught-up exit;
      note `lastSyncError` stays empty.
- [ ] **Periodic sync:** leave the app alive ≥ 15 min (the periodic floor); confirm an automatic
      session runs and is short.
- [ ] **Reconnect churn:** toggle iOS Bluetooth off/on, or walk out of range and back. The
      Connection readout panel counts involuntary reconnects; a bounce should re-sync cleanly and
      must not wedge in "syncing".
- [ ] **Background/foreground:** background the app for ~20 min, return. Note whether a
      foreground-triggered sync ran and what the chip reports.
- [ ] Record each session's `chunk phase timing` line — incremental sessions are the per-phone
      baseline that config C compares day over day.

## Phase 5 — App performance pass

With **Display & Performance** still on:

- [ ] During a sync: scroll Today, open the HR chart, switch tabs. Note hitch count and p95 frame
      ms *while `backfilling` is true* — sync must not stall the UI (decode runs off the main
      thread; this phase is how that claim gets field-checked).
- [ ] After sync: tour the heavy screens — Today, Sleep (hypnogram), Trends, Live, Intelligence,
      Workouts, Metric Explorer. 60–90 s per screen.
- [ ] Record from the Display readout: mean/p95 frame ms, hitch count, memory high-water MB, and
      the `dataVolume` probe (doubles as a footprint check for axis 4).
- [ ] Note thermal/battery qualitatively (hot phone, big drain) — the monitor does not track those.

## Phase 6 — Data collection completeness

In-app, after the caught-up sync:

- [ ] **Sync chip / LiveState:** `historyPendingSync` false (strap has nothing newer than the local
      HR frontier); `lastSyncedAt` stamped; `lastSyncError` empty.
- [ ] **Session tallies:** sum the `session persisted N rows` lines; compare against
      `cumulativeDrainedRows` in Test Centre.
- [ ] **Reject/console accounting:** `rejectedFramesThisSession` should be 0 or explained (new
      firmware layout); console-only chunk lines should not dominate a strap that was worn.
- [ ] **Dates sane:** `rows landed on …` covers the nights the strap was actually worn, with the
      5/MG identity clock-ref note (identity is *correct* on 5/MG — do not flag it as the #700
      misdating bug).
- [ ] **Saved-log header:** the Save… export prepends the diagnostics block (`Provides(48h)` per
      stream, last sync, environment dump) — verify HR/R-R/motion/steps presence there.
- [ ] **Test Centre → Sync status panel:** last offload, last re-score, owed jobs drained, journal
      quiet.
- [ ] Optional deep cut: **Data Backup → `.noopbak`** export for offline SQLite diffing across
      phones (same strap ⇒ same nights should converge).
- [ ] Optional, 5/MG only: **Test Centre → 5/MG Raw Data Collector** — create a historical session
      over a worn interval and check `imu-coverage.json` (`complete`, `missing_ranges`,
      `conflict_count`). This is the high-rate-motion completeness check; see
      [`RAW_DATA_CAPTURE.md`](RAW_DATA_CAPTURE.md).

## Phase 7 — Harvest & handoff

Per phone, per run:

- [ ] Test Centre → STRAP LOG → **Save…** (includes the diagnostics header). Name it
      `noop-strap-log_<phone>_<ios>_<strap>_<yyyymmdd-HHMM>_uc<N>.txt`.
- [ ] For defects: Test Centre **Report** flow (redacted ZIP) in addition to the raw log.
- [ ] Fill the run sheet row (below) while the numbers are on screen.
- [ ] If the strap moves to another phone next: remove the strap in-app, delete the app on the
      finished phone only if it leaves the fleet, and **Forget** the strap in iOS Bluetooth
      settings on the finished phone before the next phone bonds.

### Run sheet

| Field | Value |
|---|---|
| Phone model / iOS / storage free | |
| Build (version + commit) / install method | |
| Strap ID / charge % at start / backlog days | |
| Fleet config (A/B/C) + use-case (UC-1…4) | |
| t0 launch → t3 bonded (s) / t3 → first session (s) | |
| Sessions in first-sync chain / auto-continued? | |
| Chunks total / rows total / nights | |
| decode p50 / p99 (ms) — first session | |
| insert p50 / p99 (ms) — first session | |
| inter-chunk gap p50 / p99 (ms) | |
| Wall time to caught-up (min) | |
| Exit: caught-up / experimental / error (which) | |
| Rejected frames / console-only chunks | |
| Perf: p95 frame ms (sync / tour) / hitches / mem MB | |
| `historyPendingSync` at end / Provides(48h) OK? | |
| Log filename(s) | |

## Use-case profiles (assign one per phone-run)

- **UC-1 — Fresh install, deep backlog.** Phases 0–7 in order. The headline run for axes 1–2.
- **UC-2 — Fresh install, post-drain.** Same strap right after another phone drained it. Verifies
  the small-offload and honest-empty paths still behave (no false errors, correct chip states).
- **UC-3 — Incremental daily sync.** Config C; Phase 4 daily + Phase 6 checks; establishes each
  phone's steady-state baseline.
- **UC-4 — Churn & background.** Phase 4's reconnect/background passes, repeated; the
  `reconnectChurn` and `offloadStalls` captures are the evidence.

## Pass / flag guidance

There is no project-wide numeric bar yet — the first campaign **is** the baseline. Flag for
investigation:

- decode or insert **p99 > 5× its own p50** within a session (GC/IO contention smell);
- any sync that ends in a user-visible error state on a healthy, charged strap;
- `rejectedFramesThisSession` > 0 without a known new-layout explanation;
- hitches spiking only while `backfilling` (main-thread work leaking into sync);
- `rows landed on` dates that don't match worn nights (clock-correlation suspect);
- a second phone (UC-2) reporting *more* history than the drain phone banked (trim/ack suspect).

Report defects with the strap log + Report ZIP attached, per
[`CONTRIBUTING.md`](CONTRIBUTING.md) — and note exactly which phone, iOS, and strap firmware
produced it. "It synced fine on my phone" is a fleet result, not a close-out.

## Optional: cloud push corroboration (FRWHOOP fork only)

If the test phones are enrolled in the fork's hosted push pipeline, the Sync status panel shows
last-push success per phone, and `Tools/monitor-fleet-push.mjs` corroborates ingest-side coverage
(`noop_signal_windows`) after each run. This validates the *upload* leg only — chunk timing and
pairing ease still come from the local strap log. See [`CLOUD_INGESTION.md`](CLOUD_INGESTION.md).
