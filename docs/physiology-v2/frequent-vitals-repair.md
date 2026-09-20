# Frequent vitals: repair and limits, 2026-09-18

The app now collects the supported standard heart-rate stream throughout the day, preserves original notification evidence, repairs the repeated Apple upload error, and exposes completed five-minute heart-rate windows. This does **not** establish five-minute valid HRV, respiratory rate, calibrated SpO₂, or uninterrupted server publication. The [September 18 follow-up](readings-availability-investigation.md) diagnoses the live packet upload timeout, repairs queue liveness in source, and documents the remaining input-adapter gaps.

## Exact scope

| Identity | SHA |
|---|---|
| Original baseline | `5caa31689da0023e111beb36850d3f81d67e1be2` |
| Original physiology implementation | `5250912e5647108c548afa31b048ee4f4f6df133` |
| PR 21 before this repair | `53b13a96443eac561c2ec8c4cba6d90b5bd63f90` |
| Preserved build-348 follow-up checkpoint | `5c16cbe8911dde99cad6a4d7d9e215ee5e2f177e` |

Work was isolated in `fix/frequent-vitals-20260918`. The dirty PR-21 checkout was preserved, including its inherited changes, before repairs. The final handoff gives the ending commit. This report supplements, and does not retrospectively change, the [original independent audit](independent-audit.md) and its 22-finding ledger. That earlier readiness decision applies to its pinned revision, not to all subsequent inherited changes.

The inherited `20260918130000` migration already selects deterministic physiology-v2 as published/default. This repair preserves that selection; it supplies no reference qualification and does not promote any learned model. Supabase/VPS changes have not been deployed by this repair.

## Why the readings were missing

The inspected phone database contained roughly one heart-rate sample per second during well-covered days, and many interval records. The number of interval rows includes distinct transports and is not a count of unique consecutive beats. The phone's continuous-HRV setting was absent/off, with its overnight-only preference defaulting on. The metric-series tables did not contain five-minute HRV, resting-HR, respiration or SpO₂ series.

The cached server response contained 188 HRV attempts: 169 had no observations and 19 lacked verified timing coverage. None was valid. Raw RR count, packet identity and precise host arrival time cannot prove continuous sensor beat timing. The standard Bluetooth heart-rate service has no measurement timestamp, permits internal RR-buffer loss, and lets the sensor determine notification frequency ([Bluetooth HRS 1.0, sections 3.1.1.4–5 and 3.4](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/HRS_v1.0/out/en/index-en.html)).

The calibrated SpO₂ stream was empty. The experimental optical byte is not a calibrated saturation measurement. It remains excluded. The repaired respiratory estimator still abstains when timing, modulation, channel semantics, motion or spectral evidence are inadequate.

## Findings and disposition

No new confirmed P0 incident was observed. No new P3 item is being used as a release blocker.

| ID / severity | Requirement and exact evidence | Reproduction / impact | Narrow repair and regression | Status |
|---|---|---|---|---|
| FV1 / P1 | Uploads must complete against Apple schema. `Strand/Push/CloudPushSnapshot.swift` selected `workout.routePolyline`, absent from actual SQLite. | Query fails even with zero workouts; each cycle reports localDatabase. Other independent streams could still upload. | Optional absent route exports null; an existing route is preserved; missing required columns still fail. Real migrated SQLite and copied-phone schema tests. | Fixed |
| FV2 / P1 | Available local metrics must not be suppressed by a partial/stale overlay. `ServerScoringSettings`, `CloudScoreIdentity`, `ServerScoreRepository` treated any available/stale feature as sufficient to skip all local scoring. | Server HRV-only/stale daily row suppressed work for other local-only metrics. | Remove blanket skip; keep existing scheduling/coalescing; stale is not live. Swift/Android selection and skip tests. | Fixed |
| FV3 / P1 | Account identity must survive asynchronous responses safely. `Strand/Push/ServerScoreRepository.swift` wrote remembered owner before response acceptance. | Old request completes after sign-out/account change and changes remembered identity despite rejected cache. | Generation/owner acceptance before identity writes; clear ingest owner on sign-in/out. Race tests preserve account boundaries. | Fixed |
| FV4 / P1 | Every dependency commit must invalidate an old publication capability. Inherited migration `150000` kept revisions constant during running claims. | Late input then old-worker publication passed current-revision checks; clean checkpoint reproduced nine PG failures. | Migration `200000` restores revision/token fencing and invalidates previously coalesced dirty claims. Original strict tests restored, not relaxed. | Fixed |
| FV5 / P1 | Successful work must eventually progress under frequent arrivals. Strict fencing invalidates every run receiving newer input. | Actual disposable PostgreSQL: 20 claim→arrival→finish cycles, zero completions. A subsequent quiet run completes. No inference about actual VPS timing. | Pending deadline now cannot be postponed indefinitely. Full completion needs window-specific dependencies or coordinated immutable input acquisition/publication with durable buffering. Stale publication was not re-enabled. | **Remaining** |
| FV6 / P1 | Device identity must bind at receipt, not flush. New Swift `Collector` initially buffered under mutable active device. | Receive A, fail flush, switch B, retry: A could land under B. | Preserve owner for HR, RR, contact and raw receipts; group persistence/retry by owner; contact state per owner. Actual collector A→B retry test. | Fixed during fresh review |
| FV7 / P1 | Explicit off-body evidence must exclude new HR windows. `DayScorer` initially passed only wrist-event spans. | Dense HR60 / quiet motion plus confirmed off_body annotation produced a low-motion estimate. | Union confirmed off-body annotations into exclusions. Service-level cutoff/context test. | Fixed during fresh review |
| FV8 / P2 | Range/provenance labels must describe shown values. `MetricExplorerView`, `LiquidTodayView` compared requested/coerced ranges incorrectly and labelled local fallback as server. | Shorter unlocked range shows sparse/widened warning; local value receives server caption. | Compare effective range against coerced range; caption actual source. 2W/3W range regressions covered. | Fixed |
| FV9 / P2 | Current HRV must query the same completed window it measures. `AppModel.deriveCurrentHRV` queried now−300…now while scorer used the preceding aligned UTC window. | At t=459, read159…459 for measurement0…300. | Shared completed-window bounds; provenance adapter; clear absent/stale results; device fence after await. No unverified span creation. | Fixed |
| FV10 / P2 | Repeated receipt identity must retain the same original evidence. Generic hosted upsert could overwrite bytes while native insert preserved first receipt. | Same receipt ID with changed bytes/clocks diverged local/server originals. | Immutable-evidence trigger; identical replay and delivery metadata accepted, conflicting evidence rejected. Independently executed PG reproduction. | Fixed |
| FV11 / P2 | New windows must refresh while the screen remains visible. Initial cards refreshed only with sync/manual events. | Standard HR continues without an offload completion; card retains old windows. | Foreground-only five-minute boundary refresh; Swift active scene and Android RESUMED lifecycle. No phone background timer promise. | Fixed |
| FV12 / P2 | Missing/deleted/unknown server sleep must not silently borrow local sleep. Inherited universal vital fallback violated existing sleep acceptance. | Existing Android TodayServerSleep test expected unavailable, received two hours of local sleep. | Sleep remains strictly server-scoped when enabled; independent vital fallback stays explicit. Original integration assertion retained. | Fixed |
| FV13 / P2 | Battery estimate must initialize from the persisted strap model before connection. `BLEManager.init` did not seed model-rated lifetime. | MG test returned108h default instead of288h model lifetime. | Initialize the same model lifetime as connectCore. Existing assertion unchanged. This is a configured estimate, not a measured battery result. | Fixed |

The backfill lifecycle test failures were inherited test configuration: onboarding blocked their fake transport before the behavior under test. Fixtures now explicitly onboard and restore preferences. No lifecycle assertion was weakened.

## What runs every five minutes

`HeartRateWindows` in Swift/Kotlin calculates UTC-aligned completed 300-second windows. Each unique sampled second contributes once. Conflicting duplicates and off-body samples are excluded. At least 90% sampled-second coverage is required. Low-motion averages additionally require at least 90% heart-rate samples matched to valid quiet dynamic-acceleration observations, no quiet-data gap longer than 30 seconds, and no off-body evidence; moving seconds are excluded from the average. Missing motion is not quietness. These engineering gates are not clinical validation.

Both clients show this history separately from the overnight resting-heart-rate baseline. Cards refresh at boundaries while visible, after sync, and manually. The Kotlin server uses the same implementation and emits owner/device-scoped `daily.heart_rate_windows`; RPC readback follows the selected HRV device/version. Its deployment and sustained fresh-publication cadence remain pending.

In the preserved 24-hour phone database immediately before build 354, collection was already dense: 83,496 unique HR seconds and 83,501 gravity seconds produced 275 measured five-minute windows. The old any-motion veto retained 46 low-motion windows; the revised quiet-sample policy retained 121, recovering 75 without counting the moving seconds in the average. This is one device-day behavior reproduction, not population or accuracy validation.

The daytime awake-rest respiration lane is stricter than the low-motion HR estimate: all 300 seconds must have valid motion observations and none may show movement. Missing accelerometer seconds cannot certify a whole two-minute respiratory window as motion-clean. The published HR-window provenance carries both moving seconds and the independently observed motion fraction.

Existing strict HRV measurements already use five-minute windows. They remain null without real timing/continuity evidence. The current-HRV read now requests the correct aligned window and retains packet provenance. Apple SDNN and WHOOP RMSSD remain separate. The new HR history does not substitute itself for HRV, nightly resting HR, respiration or SpO₂.

The once-only preference migration enables the user's requested all-day continuous acquisition; subsequent settings remain respected. Existing low-power/off-body behavior stays in force. The raw notification journal adds original bytes, exact RR tick slots, session/ordinal identities and host clocks labelled `host-arrival-unmapped`. Reconnect is a new identity namespace; retry preserves the old identity. No undocumented producer-control command or synthetic beat clock was added.

## Storage, ownership and model evidence

- Swift v51 and Android Room42 are additive. Migration tests retain old intervals and create no invented historical receipts. Device deletion/rekey includes the new table. PPG identity code is not replaced.
- Same-second equal notifications remain distinct; identical replay is idempotent. Nanoseconds cross JSON as decimal strings, preserving values above 2^53.
- Hosted receipt rows have composite owner/device constraints, owner-only SELECT RLS and service-only writes. Raw evidence cannot be overwritten. Nested HR window ownership is checked before publication.
- Queue revision, run and lease checks remain mandatory. Old work cannot publish, finish, or release a replacement lease. Archive delivery remains separately retryable.
- New received bytes are evidence, not verified waveform-model input. Existing raw-object digest/shape checks and checkpoint/preprocess contracts were not bypassed. No shadow-model output is connected to the new HR statistics, and no learned model is promoted by this delta.
- Earlier algorithm upgrades improve identity, coverage, missingness, sleep/nap handling, abstention and revision correctness. They do not prove improved physiological accuracy. Larger VPS models are not a substitute for acquired, validated input channels.

## Verification

All results below are executions of this repair, not assumed from the build agent's report.

| Suite / command | Result |
|---|---|
| `swift test --package-path Packages/WhoopProtocol --scratch-path /Volumes/Untitled/physiology-build/frequent-protocol --jobs 2` | 748 executed, 2 skipped, zero failures |
| `swift test --package-path Packages/WhoopStore --scratch-path /Volumes/Untitled/physiology-build/frequent-store --jobs 3` | 609 executed, 1 skipped, zero failures |
| `swift test --package-path Packages/StrandAnalytics --scratch-path /Volumes/Untitled/physiology-build/frequent-analytics --jobs 3` | 1,930 passed |
| `swift test --package-path Packages/NoopPush --scratch-path /Volumes/Untitled/physiology-build/frequent-vitals-push --jobs 2` | 31 passed |
| Actual CloudPushSnapshot source harness, including copied-phone DB read-only | 6 passed |
| `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath /Volumes/Untitled/physiology-build/frequent-macos -jobs 4 CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO test` | 1,732 executed, 2 skipped, zero failures |
| Android `:app:testFullDebugUnitTest --rerun-tasks -Pksp.incremental=false --no-daemon --max-workers=2` | 5,698 passed, 6 skipped |
| JVM `:analytics-kernel:test :service:test --rerun-tasks --no-daemon --max-workers=2` | Kernel803 passed/5 skipped; service65 passed/89 DB cases skipped here |
| `scoring-service/scripts/test-physiology-queue.sh` against disposable PG | Those89 database tests passed, zero skipped |
| From `supabase/functions`: `npx --yes deno test --allow-all tests/`, type checking enabled | 73 passed |
| Regenerated real-scorer fixture consumers | Swift7 passed; Android28 passed; previous JSON fields unchanged |
| Final iPhone build349, schemeNOOPiOS, physical destination | Build succeeded |
| Independent fresh review | Protocol3 passed; actual PG immutable replay/debounce/fence checks passed; continuous-arrival failure independently reproduced |
| `git diff --check` | Passed |

Exact executable commands, environment/cache paths and logs are retained under `/Volumes/Untitled/physiology-build/frequent-vitals-final-verification.md` and `frequent-vitals-app-test-repair.md`. The PostgreSQL final evidence directory is `/Volumes/Untitled/physiology-audit/tmp/physiology-queue.5HMvXh`.

Initial macOS test linking required adding direct GRDB to the test target at the already pinned version. The signed host then could not load the Homebrew zstd dylib under library validation. The successful test run used ordinary local ad-hoc test signing without hardened runtime; the physical iPhone build remains normally signed. Android's incremental KSP schema output was missing on an intermediate run; forced regeneration fixed it without weakening schema checks.

Skipped/not-established evidence: external HRV/reference datasets and WHOOP_R20_CORPUS are absent; optional private/Xiaomi fixtures are absent in the app-host suite; there is no overnight soak, battery measurement, target-device/reference accuracy study, production migration execution or VPS sustained-throughput test. The copied-phone exporter fixture was executed separately in the isolated harness.

## Bounded physical-phone check

Installed and launched NARA 11.1.1 build 349 on the connected iPhone 16. The app was briefly stopped to capture consistent pre/post database, WAL, SHM and preference backups; it was relaunched afterward. Private backups and hashes remain outside the repository. Both databases pass `quick_check`.

The phone applied v51 and recorded 220 original standard-HR notifications across two sessions and 237 seconds, under one device, all explicitly `host-arrival-unmapped`. Thirty-seven notifications carried the RR-present flag. This demonstrates real capture, not continuous beat coverage or a qualified HRV result. Preferences confirm continuous acquisition on and overnight-only off.

Pre/post counts: HR 248,310→248,825; RR 284,540→284,845; PPG-derived HR 4,251→4,258; waveform records 7,990→8,015. Primary-key comparisons found zero missing pre-install identities in those four tables. Daily records remained four. This checks this migration/install; it is not a universal data-loss guarantee.

The copied post-install status shows 13,332 records accepted during a push cycle, but also `HTTP500 ... push_failed`. Comparing those initial preference snapshots shows 6,598 more accepted records across seven batches, and both previously broken workout export checkpoints were created. A later 18:14 preference capture shows the interval cursor advancing from 5,000 to 10,000, while original packet receipts remain at 5,770. Build 350 and production logs subsequently identify the failed original-packet projection; see the follow-up report.

Live authenticated capabilities GET returned HTTP 200/protocol 1.2. It omits the new standardHRReceipt stream, and the client correctly withholds it until advertised, so that new lane does not explain the observed 500. The old local workout-column error is repaired; overall deployed upload health is **not yet verified**. Established SSH access/server logs were unavailable, so the POST failure's root cause remains unknown. No server change was deployed or production database modified during this repair.

## Release decision

| Area | Implemented | Unit-tested | Integration-tested | Device-tested | Overnight-soaked | Reference-validated | Deployed |
|---|---|---|---|---|---|---|---|
| All-day capture and original receipts | Yes | Yes | SQLite/export/PG | Bounded phone check only; see final handoff | No | No | Phonebuild349; new server lane pending |
| Five-minute sampled/low-motion HR | Yes | Shared fixtures | Actual scorer and both clients | UI/accuracy not qualified | No | No | Phonebuild349; server changes pending |
| Valid five-minute HRV / respiration | Strict abstention implemented; timing evidence incomplete | Yes | Yes | No qualifying acquisition proof | No | No | No new qualification |
| Calibrated SpO₂ | Unsupported on observed input | Abstention retained | No calibrated input | No | No | No | No |
| Queue revision safety | Yes | Yes | 89 PG cases | N/A | No | N/A | Pending |
| Continuous-arrival completion | Incomplete | Counterexample | Confirmed remaining P1 | N/A | No | N/A | Not ready |
| Learned waveform models | Existing shadow isolation only | Existing tests | No new production proof | No | No | No | No promotion |

Recommendation: **needs another engineering pass** for reliable continuous server freshness. The bounded phone changes can collect more useful original data for qualification. Green repository tests do not make the branch production-ready.
