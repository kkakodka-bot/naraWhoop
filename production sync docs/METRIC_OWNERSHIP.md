# Derived metric ownership and readback inventory

Implementation handoff, 2026-09-18. This is a source inventory, not a parity or deployment certificate.
Root owns AppModel, Repository, account lifecycle, HealthKit and widgets. W4 owns the server readback,
cache and Today/Sleep/detail adapters. No producer may be removed merely because readback is enabled.

## Approved wire contract

See `scoring-service/SNAPSHOT_V2_CONTRACT.md` and
`scoring-service/service/src/main/kotlin/com/frwhoop/scoring/db/EngineIngestWriter.kt` (`buildSnapshot`, `buildPayload`).
Authenticated RPC: `get_server_score_snapshot_v2(p_day)`. Omit `p_algorithm_version` to use the active pointer;
do not pin `frwhoop-server-1`. Accept only schema 2, accept unknown optional fields, retain compatible cached
results on unsupported schema/version. Owner is auth.uid(), never an arbitrary client user parameter.

Immutable fields: schemaVersion, userId, sourceDeviceId, day, timezone, algorithmVersion, inputRevision,
resultRevision, computedAt, dataThrough, status, coverage, daily, sleep. Nested daily/sleep fields retain
legacy snake_case. Sleep stages use epoch seconds: start/end/stage. Sleep is a COMPLETE replacement set;
stable UUIDs identify sessions. Empty sleep and null metrics in completed snapshots are authoritative.
Pending/failed/unsupported envelopes are not authoritative empty results. Mutable pending,
requestedInputRevision and archiveStatus live outside the canonical immutable cache payload.
Optional typed metrics/charts/history extension slots do not automatically activate new metrics.

### History extension client handoff

Readback now accepts `metrics[key] = {value,unit,status,method}`, chart buckets with count/min/max,
bounded history and dependency provenance from `W4-HISTORY-CONTRACT.md`. Status/method are strings so
future optional metadata does not reject an otherwise compatible result. Values are finite and bounded;
relative Celsius may be negative. A present typed null overrides legacy daily data. History rejects
future/duplicate days and never replaces any individually requested day, including null/no-data results.
One newest history envelope is used, not a union of competing source/algorithm histories. Efficiency
series are percent: legacy daily fractions are converted; explicitly typed percent is not rescaled.

The implicit schema-2 capability set is frozen at the original 13 fields. New scalar names require explicit
advertisement AND activation. Supported legacy daily / existing MetricCatalog extension names:

- Daily: `recovery`, `strain`, `exercise_count`, `steps`, `active_kcal_est`, `spo2_pct`, `spo2_red`,
  `spo2_ir`, `skin_temp_c`, `skin_temp_dev_c`.
- Activity/catalog: `steps_est`, `avg_hr`, `max_hr`, `hr_zones13_min`, `hr_zones45_min`, `hr_zones_all_min`,
  `strength_min`, `stress`.
- Sleep history: `sleep_performance`, `hours_vs_needed_pct`, `sleep_consistency`, `restorative_pct`,
  `restorative_min`, `sleep_need_min`, `sleep_debt_min`.
- Weekly/catalog: `fitness_age`, `vo2max_est`, `vitality`, `body_age`.

These are client adapters, not physiology-parity or activation evidence. Mill has now published
`W4-OUTPUT-DETAIL-CONTRACT.md` and `W4-SNAPSHOT-V2-NATIVE-FIXTURE.json` in the shared evidence directory.
The typed detail slice covers sleep ledger/typicals, chart metadata, baseline/driver/readiness,
session diagnostics and context records. Workout details and context-to-engine conversions remain
client coding gaps; decoding a record is not equivalent to wiring every consumer.
Owned Charge does not reconstruct local drivers; owned debt never displays a local ledger.
Unmigrated producers remain enabled. Today/LiquidToday observe scalar
state directly; owned Effort skips their local whole-day HR scoring read. Sleep scalar ownership can be
activated independently of session ownership. Input pending/error banners are generic and expose no RPC
payload. Server sleep edit controls remain disabled awaiting root's hook/fixture activation signal.

Root's central aliases now route `spo2 -> spo2_pct`, `energy_kcal -> active_kcal_est`,
`in_bed_min -> sleep_in_bed_min`. W4 uses the root mapping for Explorer and Liquid sparks. The stable
`daily(local:day:state:carry:)`, `series`, repository lifecycle and session APIs are unchanged.
All three local SleepModel builders now use `SleepModelInputs.captureLocal(from:)`, which copies root's
read-only `localSleepModelDays` / `localSleepModelSleeps` and imported sleep figures. Asynchronous builders
retain that value capture and fence cancellation, repository retirement and refresh revision before
publishing. Sleep's local hero performance and typical-range calculations use retained daily rows too;
owned performance and baseline outputs never fall back to these calculations.

Root's `localAllSleepSessions(days: Int = 4000)` is now wired in all three local SleepModel builders,
only when `requiresLocalSleepModel` is true. Server session rendering remains separate. All-owned
sleep outputs skip that read/model; partial ownership retains unoverlaid inputs for local outputs.
Habitual-midsleep and motion readers use local storage; Liquid/Sleep still perform a small habitual
lookup even when their local model is skipped. That remaining optimization is not an ownership fallback.

### Current bounded consumer checkpoint

`ServerScoreLocalComputePolicy(state:)` captures the four ownership gates. Sleep/Today/Liquid pass it
to `SleepModel.build(_:compute:)`. It lazily suppresses owned performance, efficiency, consistency,
hours-vs-needed, restorative percent, respiration and sleep-debt calculations (including nap-credit and
ledger work), plus owned duration/stage baselines and the owned duration trend. Server series supply the
duration trend; unavailable compound baselines/ledger remain explicitly absent. Unowned calculations
still run. Today/Liquid's 200,000-row Effort scan is skipped only when `.strain` is owned. The shared
engine's all-output flag remains false: root owns per-output engine suppression, and its unported
outputs must not disappear. Core session grouping remains necessary for local/unmigrated consumers;
activation of daily scalar fields alone does not grant server session ownership.

Current-day respiratory headlines cannot borrow older sparkline values after ownership. Both calorie
spark aliases mask owned nulls. Owned step estimates expose no local calibration control or coefficient;
owned measured steps expose no local activity-class provenance. Liquid details route owned missing
steps/calories to the authoritative source, subject to the root aliases above. Temperature selection is
by explicit owned field and user preference, not magnitude; a null preferred owned field does not switch
to another kind. Today/Liquid/Explorer use typed absolute/deviation formatting, including signed values.
Charge's missing driver breakdown is explicitly unavailable, not labelled as local strap calibration.
Today now consumes advertised Charge drivers and HRV calibration evidence; Today/Liquid consume
the separate owned readiness result. Workout and context engine conversions remain unwired.

The sleep detail slice uses existing cards, with no layout/copy changes. `ServerScoreDetails` decodes
bounded signed `sleep_ledger` evidence and nullable `sleep_typicals`; `ServerScoreChartMetadata` retains
unit/method/schema/session identity. Parent-field ownership plus explicit result detail capability is
required. Missing, null, unadvertised or unsupported-method detail remains absent, with no local refill.
Ledger and prior means feed the shared SleepModel used by Sleep/Today/Liquid. Means do not fabricate
the percentile bands used by Sleep's separate typical-range rows. Sleep HR now resolves advertised
`sleep_hr:<stable UUID>` keys with schema1/bpm/300-second metadata, not the nonexistent unscoped key;
only main-session charts are used and observation gaps remain absent. Session diagnostics are typed
and identity-checked; sparse staging feeds compatible session rows. The existing Sleep Move strip
consumes nullable server motion epochs as separate runs, preserving absolute positions and gaps.
Band-state, hypnogram and stage-insight records are decoded but not fully mapped into existing detail UI.

Typed efficiency is percent on the wire, while DailyMetric and synthetic CachedSleepSession expect
a fraction. The display adapters now convert by explicit unit, including values below 1 percent;
catalog/history series remain percent and typed null still overrides a populated legacy fraction.

Readback configuration comes from the validated `CloudAuthClient.identitySnapshot().projectURL`, not
`CloudPushSettings.enabledEndpoint()`. Pausing uploads or withholding upload consent does not revoke
activated readback ownership. All write/consent gates remain root-owned and unchanged. Score JWT reads
use a per-request ephemeral `ServerScoreReadTransport`: no shared cookies/credentials/response cache,
all redirects refused, exact captured project RPC URL, 25-second request / 30-second resource timeout,
512 KiB delivered-response bound, and owner-generation checks before admission, at headers, during
streaming and before return. The client also fences again after off-main decode.

Root's `ScoringContextSharingView()` is inserted directly below `authCard` in `ServerScoringView`.
The consent facade and its write-purpose semantics remain root-owned; this insertion does not enable
new context producers or historical backfill. Server sleep editing is still disabled pending Mill's
actual edit/restaging integration and root's explicit enable signal, regardless of root's mobile-hook
test results. Existing app runtime/lifecycle and HealthKit/widget/watch/export files were not edited.

Root approved independent activation of the existing schema-2 core family without waiting for full
metric parity. Capability is either advertised field names or the known schema-2 field family.
Activation is explicit and account/project-scoped. Authentication, configuration and capability are also
required. After activation, transient failure retains cached server values/freshness, never local fallback.
The current producer marks observations partial and reports missing policies in coverage.gaps.

## Visible fields, current producers and consumers

Catalog anchor: `Strand/Data/MetricCatalog.swift:120`. Daily storage fields:
`Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift:60`. Imported measurements are separate sources,
not permission to silently relabel one method/device as another. Manual spot HRV and live HR stay local.

| Family / all fields in scope | Current computation and state | Observable consumers / read paths | Server follow-up |
|---|---|---|---|
| Night HRV RMSSD, 5-minute SDNN index, RHR; HRV window choice, RR overcount/quality | HRVAnalyzer, AnalyticsEngine.analyzeDay; IntelligenceEngine.swift:1303, 2037. Whole-night/deep-window preference; canonical RR identities/channels/units and exclusions | Classic Today, LiquidToday, Health/VitalSignsSummary, MetricExplorer, Charge drivers, Stress/autonomic details, exports | Core DTO carries RMSSD/SDNN/RHR. Still require Swift input-selection and window/quality parity; never label RMSSD as SDNN |
| Current/trailing HRV; manual spot HRV, beat quality, mean HR/NN, SDNN, frequency-domain autonomic readouts | AppModel.swift:769 CurrentHRV; HRVSnapshotView.swift:19; HRVFreqDomain, HRVAnalyzer | Today current-HRV tile, Live/manual capture, Breathe, Stress details | Keep live/interactive producer; any server history replacement requires distinct metric/window identity |
| Respiration nightly summary and source-era baseline | AnalyticsEngine, IntelligenceEngine.swift:1768, Baselines | Today variants, Sleep/NightDetail, Health/VitalSignsSummary, Explorer, Charge/illness | Core DTO carries nightly rate; baseline/history/source-era support still missing |
| Skin absolute C, baseline deviation C, relative marker; SpO2 percentage, experimental candidate, raw red/IR provenance | IntelligenceEngine.swift:1939, 2017, 2030; AnalyticsEngine; SkinTempDisplay; candidate experimental gate | Both Today variants, Health, VitalSignsSummary, Explorer, illness/cycle | Additional streams, wearable family/method/provenance, baseline epochs, candidate policy. Do not promote unverified candidate to calibrated percentage |
| Charge/recovery score, per-term drivers, confidence/calibration, baseline center/spread/status, z/delta/ratio, normal bands | IntelligenceEngine.swift:1745-1798 and 1932-1954; RecoveryScorer; Baselines | Both Today heroes/vitals/driver detail; Intelligence; Health; trends/reports; watch/widget/export | Ordered baseline checkpoints and as-of-day replay. Include driver evidence and confidence, not headline alone |
| Readiness classification, evidence/headline, HRV/RHR/resp baseline signals; ACWR and monotony | ReadinessEngine.swift:83, evaluate; ReadinessTrainingLoad; Today memoized summaries | Both Today readiness/synthesis, Insights and training-load displays | Versioned readiness/history summaries. Preserve distinction between readiness and Charge |
| Effort/strain, daily average/max HR, calories estimate, measured steps vs estimated steps, HR zones 1-3/4-5/all, strength duration, exercise count | AnalyticsEngine, StrainScorer; DayCycleIntelligenceIntegration; TodayView.swift:4920 and LiquidTodayView.swift:1638 local in-progress effort; workout aggregation | Today heroes/cards, WorkoutDetail, Health, Explorer, Trends, Compare, Insights, exports | Day-boundary mode, profile/HRmax/sex/effort-method config; step counter identity/wrap policy; imported active-energy precedence |
| Workout detection/session load, duration, HR buckets/zones, HR recovery, cadence/steps and activity cost | AnalyticsEngine workout detection; Repository workout writes; WorkoutDetailView.swift:119 | Workout detail, Today recent workouts, Insights activity-cost charts, training load | Complete session identity/replacement contract, actual chart buckets, overlap/dedup policy. Keep manual workouts/local live session |
| Sleep sessions, main-night grouping, naps, onset/wake, in-bed/asleep/awake/light/deep/REM minutes, efficiency, disturbances, stage timeline, sparse/HR-only confidence | AnalyticsEngine/SleepStageTotals/SleepStager; SleepModel.swift:205; SleepView mainNightGroup; user-edited bounds | Sleep hero/stages/naps, both Today sleep cards and hosted stages, NightDetailCard, AsleepDurationCard, Explorer, exports | Core DTO now carries stable sessions/stages/totals. Grouping/naps/DST/HR-only orchestration parity remains required. Full replacement eliminates obsolete sessions |
| Sleep HR/motion charts, session metadata and per-stage insight data | SleepView.swift stageCard / repo.hrBuckets; sessionMotions; local raw reads | Sleep detail, Today hosted stages, FullDayChart | Optional versioned charts with units/bucket bounds/source. Missing server chart stays empty after activation, not local recomputation |
| Rest/sleep_performance composite, personalized need, hours-vs-needed, consistency, restorative minutes/percent, typical stage/time bands | AnalyticsEngine.Rest; IntelligenceEngine.swift:796, 2022; SleepModel series methods | Rest hero, Sleep/NightDetail, hosted cards, Explorer, Trends, watch/widget | Learned need/midsleep and actual preferences as-of each day; separate model outputs from presentation ratios. Current core does NOT replace these |
| Sleep debt, nap credits, per-night ledger and confidence | SleepDebt.swift:67, debtSeries/ledger; SleepModel.debtLedger/debtNeedMin | SleepDebtLedgerCard, Sleep detail, hosted Today cards, Explorer | Ordered 14-usable-night recurrence with personalized need, imported debt precedence, nap credit and calendar gaps; correction fan-out is not simply 14 calendar days |
| Fitness age, estimated VO2 max, readiness/method/source explanations | FitnessAgeEngine, IntelligenceEngine.swift:2285-2309; user age/sex/waist/activity profile | Today, Health, Explorer, reports | Weekly Saturday-keyed outputs, 7-day readiness/input aggregation, profile/config revisions and absent-input semantics |
| Vitality, body age, sleep-consistency contributor | VitalityEngine; IntelligenceEngine.swift:2310-2334 | Today, Health, Explorer, Compare/reports | Weekly outputs; previous 7-day physiology and up to 28-night consistency inputs; preserve minimum-input gating |
| Training load, acute/chronic load, fatigue/form, ramp and monotony summaries | TrainingLoadEngine, ReadinessTrainingLoad, TrainingLoadCard | Trends/training-load card, readiness, Insights | Persist algorithm/config-specific history state and include full plotted series; different load formulas must not be conflated |
| Illness alert/signals/confidence and confounder suppression; parallel illness-distance readout | AppModel.applyIllnessSignal:1852, IllnessSignalEngine, IllnessDistance | Today HealthAlertBanner, Health HeadsUp, notifications/Intelligence | Historical baselines plus alcohol/travel/illness/cycle/workout context and notification dedup. Distance is not the alert gate |
| Cycle phase, fused curve, period-aware state | AppModel.computeCyclePhase:2039; CyclePhaseEngine, CycleTrackingStore | Cycle/Health/Intelligence and contextual cards | Temperature/RHR/HRV baselines, logged periods and per-account preferences; preserve nullable/uncertain states |
| Circadian phase/body-clock estimate | AppModel.computeCircadianPhase:2076; CircadianEngine | Sleep body-clock dial and contextual cards | Actual activity bins/timezone/DST and method confidence; do not invent replacement from sleep timestamps alone |
| Day stress, stress-onset/events, autonomic ratios and daytime baselines | StressView.swift:99-161; DaytimeStress, StressIndex, StressOnsetDetector, DaytimeBaselines | Stress view, Today stress card, Explorer, comparisons | Bounded HR/RR/motion input windows and historical daytime baselines; not covered by nightly HRV activation |
| Trends, comparisons, correlations, weekly digest/report statistics and delta captions | Repository.exploreSeries/resolvedSeries, TrendsView.swift:98, 332, 382; MetricExplorerView.swift:888; CompareView.swift:338; LabBookView correlations | Trends/TrendsReport, Explorer, Compare, Insights, LabBook, hosted trend cards | Consumers of authoritative metric history, not a separate scoring authority. Revision-based invalidation required; equal-count corrections must refresh |

Measured/imported-only context remains explicit: live HR, measured step counter, Apple Health VO2/active
energy/body mass/body fat/lean mass/BMI, nutrition calories/protein/carbs/fat, mood/hydration/journal,
Mi Band/Oura/WHOOP export values. Do not overwrite those sources or run new biomarker algorithms.
`rhr_primary_session` and its sample/duration diagnostics are shadow-only, not a shipped headline.

## Consumers outside W4's exclusive edit set

- Root: `StrandiOS/Widgets/WidgetPublish.swift:24`, `Strand/Data/WatchSessionBridge.swift:135`,
  `StrandiOS/Health/HealthKitBridge.swift` (sleep export and daily HRV writes),
  `Strand/Data/ShortcutHealthExport.swift:66`. These still need authoritative snapshot integration;
  Today/Sleep activation is not proof that exports/widgets have migrated.
- Root/shared Repository readers: `HealthView`, `VitalSignsSummary`, `TrendsView`, `TrendsReportView`,
  `CompareView`, `InsightsView`, `LabBookView`, `TrainingLoadCard`, Intelligence/illness/cycle/circadian.
- W4 detail lane: `MetricExplorerView` handles core metric tap-through; `NightDetailCard`,
  `StagesVsTypicalCard`, `AsleepDurationCard`, `SleepDebtLedgerCard` receive the adapted SleepModel.
  Raw live/FullDayChart and manual HRV capture remain explicitly local rather than fake server detail.

## Bounded follow-up assignments and historical invalidation

1. Baseline/history owner: new checkpoint/replay components, Baselines/Recovery/Readiness adapters and
   new tests; coordinate any shared DayScorer/EngineIngestWriter changes with Mill. Checkpoint key must
   include project/account/source/algorithm/config/timezone and input revision. For EWMA center/spread,
   a past correction can affect EVERY later result: replay from the checkpoint immediately before the
   affected day through the latest dependent day. A 14/21-night half-life is NOT a finite invalidation horizon.
   Recalibration epochs, source-era boundaries, missing observations and baseline trust status are inputs.
   Readiness uses 30 prior rows and 7/28 load windows; do not substitute that for the EWMA rule.
2. Sleep-history/edit owner: server-visible edit/tombstone input revisions, learned need/midsleep,
   consistency, Rest/debt, grouped naps and timezone/DST parity. Replay from the earliest affected sleep
   window, then enough later usable observations to rebuild all state; conservatively through latest
   until a proven convergence/checkpoint rule exists. Never leak a future night into a historical baseline.
3. Activity/history owner: remaining streams, profile/config, effort/calories/steps/workouts/zones,
   training load and weekly fitness/vitality outputs. Recompute overlapping workout/day windows and
   affected weekly buckets; recursive training-load state must replay forward from a valid checkpoint.
4. Anomaly/context owner: illness/confounders, cycle, circadian, daytime stress/baselines. Separate
   alert-side-effect eligibility from deterministic result replay; historical replay must not emit old alerts.
5. W4: versioned DTO/cache/client and Today/LiquidToday/Sleep/detail consumers. Do not edit root lifecycle,
   shared Repository or other agents' identity/transport/server files. Root registers v48 and owns oracle updates.

Each replacement needs native Swift-vs-JVM fixtures for selected input identities AND visible outputs,
missing/partial/nulls, same-count corrections, account changes, DST/split nights, and version reprocessing.
Capability may expose a field before parity is certified, but activation/deployment readiness must be reported
separately. Do not remove the all-metric local pass until every producer it supplies has a usable replacement.

## Root lifecycle API

### Source-freeze checkpoint: 2026-09-18, after the 05:33 native gate

W4 is frozen for root review, not task-complete. No further contracts, consumers or root-owned edits
will be started before the next bounded assignment. Latest atomic delta: context DTOs/read helpers,
Sleep motion binding, native source-list separation, eight context/motion regressions and this inventory.
AppModel, IntelligenceEngine, Repository, lifecycle and producer/publication integrations remain root-owned.

Typed per-output handoff (all day/state parameters refer to one captured immutable state):

| API | Ownership / result gate | Output and current consumer |
| --- | --- | --- |
| `ServerScoreDisplay.daily(local:day:state:carry:)` | Each scalar independently owned; typed null replaces local | `DailyMetric?`; existing central Repository/Today/Sleep contract unchanged |
| `ServerScoreDisplay.series(_:through:state:)` | Independent metric ownership and per-result capability | Ordered `(day,value)` tuples; no requested-day null refill from history |
| `ServerScoreDisplay.charge(day:state:)` | `.recovery` plus advertised `charge` | `ServerScoreCharge?` with numeric drivers/confidence |
| `ServerScoreDetailPresentation.charge(day:state:)` | Same | `(drivers: [ChargeDriver], confidence: ScoreConfidence)?`; Today wired |
| `ServerScoreDisplay.baseline(_:ownedBy:day:state:)` | Caller-specified output ownership plus advertised `baselines` | `ServerScoreBaseline?`; Today HRV calibration wired; not a mutable local BaselineState |
| `ServerScoreDetailPresentation.readiness(day:state:)` | Independent `.readiness` ownership and result capability | `ReadinessEngine.Readiness?`; Today/Liquid wired; missing uses explicit unavailableReadiness |
| `ServerScoreDisplay.illness(day:state:)` | `.illnessScore` | `ServerScoreIllness?`; typed wire evidence only, NOT `IllnessSignalEngine.Result` |
| `ServerScoreDisplay.cycle(day:state:)` | `.cyclePhase` | `ServerScoreCycle?`; typed wire evidence only, NOT `CyclePhaseEngine.Result` |
| `ServerScoreDisplay.circadian(day:state:)` | `.circadianPhase` | `ServerScoreCircadian?`; acrophase/evidence only, NOT `CircadianEngine.PhaseEstimate` |
| `ServerScoreDisplay.daytimeStress(day:state:)` | `.daytimeStress` | `ServerScoreDaytimeStress?`; aggregate metadata only, NOT full `DaytimeStress.Analysis` |
| `ServerScoreDisplay.sleepLedger/sleepTypical` | Parent metric plus explicit detail capability; known typical method | Signed ledger / optional means; shared SleepModel wired |
| `ServerScoreDisplay.sleepDiagnostics(day:state:)` | `.sleepSessions`; diagnostic/core identity equality validated | `[ServerScoreSleepDiagnostics]`; sparse flags and motion wired |
| `ServerScoreDisplay.motionRuns(_:)` | Caller supplies owned diagnostics; method/unit/epoch checked | `[[ServerScoreMotionPoint]]`; Sleep Move strip preserves null holes |
| `ServerScoreSleepPresentation.model(day:state:local:)` | Per-output masking plus independent session ownership | `SleepModel?`; Today/Liquid/Sleep wired |
| `ServerScoreSleepPresentation.session(_:)`, `session(_:diagnostics:)`, `projections(day:state:)` | Caller retains account/project; projection requires session ownership | Canonical stages JSON, stable UUID/core identity and provenance; root export/HK seam unchanged |

For root V5 integration: choose server/local by `state.owns(metric)` BEFORE inspecting nullable values.
An owned missing result is nil/unavailable, never a reason to run the local engine. Context record
helpers additionally require that day's result to support the parent; they currently return bounded
wire enums as strings. Root must interpret only known enum/policy values when converting engine models
(`details.contextPolicy` currently `as-of-context-v1`). Do not fabricate missing engine-required fields.
`circadian_phase_hour` is the server's estimated temperature-minimum proxy, while detail `acrophaseHours`
is a distinct field; a complete PhaseEstimate also needs independently owned/non-null
`circadian_offset_min`. Illness evidence intentionally lacks full fired-signal/copy payloads. Daytime
stress is not the daily `stress` hero. Frequency-HRV evidence has no separate activated output API yet.
Historical context readback must not emit live notifications or stress-onset events. Nutrition, mood
and hydration remain explicitly local-input owned; this slice changes none of their producers.

Remaining coding inventory, not external gates:

- Workout DTO/session identity/HR buckets/zones/recovery/steps/activity-cost adapters and existing
  WorkoutDetail binding: not implemented. No workout files added in this checkpoint.
- Typed training-load history, fitness-age/vitality evidence, HR-zone/step/skin calibration, day-cycle
  and experimental SpO2 provenance detail adapters: not implemented; supported scalar reads alone do
  not replace these compound engines. Full baseline mutable-engine-state reconstruction is not provided.
- Context-to-existing-engine conversions and AppModel/Intelligence/V5 publication: root next slice.
  Context hourly chart auxiliary fields (`meanHr`, `rmssd`, `maskedForActivity`) are not yet retained by
  the generic chart DTO. Existing Body Clock / Stress / Cycle consumers are not newly wired here.
- Session hypnogram/band-state/stage-insight presentation and Effort/Rest confidence adapters remain;
  records are typed, but their complete existing-view mappings are not finished.
- Local model raw-reader gating is implemented; dedicated exhaustive all-owned/one-unowned policy
  regressions and additional typed Charge/readiness conversion regressions remain useful next tests.

Activation prerequisites are separate: configured + authenticated + capable + explicitly activated,
per output/account/project; each result must support the output. Implicit schema2 stays at 13 fields.
The newly added readiness/workout/context enum cases are not automatically added to activation groups.
Approve usable contract/parity for the particular output before suppressing its local producer;
`skipsSyncCoupledRescore` remains false. Owned-null behavior is mandatory after activation. Root owns
consent-purpose checks and producer/publication gates. Sleep editing remains disabled until root's
explicit signal after actual server edit/restaging integration. No new visual layout/design activation.

Exact W4 frozen source/test inventory (relative to this shared checkout; excludes root-owned files):

```text
Strand/Push/ServerScoreClient.swift
Strand/Push/ServerScoreContentReadyTrace.swift
Strand/Push/ServerScoreContextDetails.swift
Strand/Push/ServerScoreDetailPresentation.swift
Strand/Push/ServerScoreDetails.swift
Strand/Push/ServerScoreDisplay.swift
Strand/Push/ServerScoreEvidenceDetails.swift
Strand/Push/ServerScoreLocalComputePolicy.swift
Strand/Push/ServerScoreMotionTrace.swift
Strand/Push/ServerScoreReadTransport.swift
Strand/Push/ServerScoreRepository.swift
Strand/Push/ServerScoreSleepPresentation.swift
Strand/Push/ServerScoreSleepSession.swift
Strand/Push/ServerScoreSnapshot.swift
Strand/Push/ServerScoreStatusNote.swift
Strand/Push/ServerScoringSettings.swift
Strand/Push/ServerScoringView.swift
Strand/Screens/TodayView.swift
Strand/Liquid/LiquidTodayView.swift
Strand/Screens/SleepView.swift
Strand/Screens/SleepModel.swift
Strand/Screens/SleepDebtLedgerCard.swift
Strand/Screens/MetricExplorerView.swift
Packages/WhoopStore/Sources/WhoopStore/ServerScoreCache.swift
Packages/WhoopStore/Sources/WhoopStore/ServerScoreCacheMigration.swift
Packages/WhoopStore/Tests/WhoopStoreTests/ServerScoreSnapshotCacheTests.swift
Packages/WhoopStore/Tests/WhoopStoreTests/ServerScoreCacheTests.swift
StrandTests/ServerScoreSnapshotV2Tests.swift
StrandTests/ServerScoreSleepSessionTests.swift
StrandTests/ServerScoreHistoryContractTests.swift
StrandTests/ServerScoreSleepDetailsTests.swift
StrandTests/ServerScoreSleepModelTests.swift
StrandTests/ServerScoreContextMotionTests.swift
StrandTests/ServerScoreContentReadyTraceTests.swift
StrandTests/ServerScoreReadTransportTests.swift
StrandTests/ServerScoreLocalComputePolicyTests.swift
Tests/ServerScoreReadbackNative/RepositoryFixtures.swift
Tests/ServerScoreReadbackNative/RepositoryTests.swift
Tests/ServerScoreReadbackNative/main.swift
Tests/ServerScoreReadbackNative/run.sh
Tests/ServerScoreReadbackNative/Settings/Fixtures.swift
Tests/ServerScoreReadbackNative/Settings/main.swift
production sync docs/METRIC_OWNERSHIP.md
```

Recent app-source additions that xcodegen must include: `ServerScoreDetails.swift`,
`ServerScoreEvidenceDetails.swift`, `ServerScoreDetailPresentation.swift`,
`ServerScoreContextDetails.swift`, `ServerScoreMotionTrace.swift`. Latest new app-test class is
`ServerScoreContextMotionTests` (8 tests); root's reported 05:28 build/122 passing app tests preceded it.
Root reported all seven SleepDetails tests passed. This native checkpoint independently passed
82 readback + 4 actual-settings tests, zero failures, and canonical synthetic server fixture round-trip
at 05:33. Latest changed source syntax parse and scoped diff whitespace check passed. These do not
replace a fresh integrated app-host/Release gate or device frame/background evidence.

Exact native command, from the shared checkout:

```sh
zsh Tests/ServerScoreReadbackNative/run.sh \
  /Volumes/Untitled/nara-production-sync-evidence-20260918/w4-store-build/arm64-apple-macosx/debug \
  /Volumes/Untitled/nara-production-sync-evidence-20260918/w2-swift-build/arm64-apple-macosx/debug \
  /Volumes/Untitled/nara-production-sync-evidence-20260918/w4-context-motion-freeze-tests \
  /Volumes/Untitled/nara-production-sync-evidence-20260918/W4-SNAPSHOT-V2-NATIVE-FIXTURE.json
```

Log: `/Volumes/Untitled/nara-production-sync-evidence-20260918/w4-context-motion-freeze-tests.log`.
Runner compiles real DTO/display/repository/transport/policy sources with synthetic auth/settings
facades and host package object files. It does not compile SwiftUI or the StrandAnalytics-dependent
DetailPresentation/SleepPresentation; root's integrated gate covers those. No production requests,
secrets, app databases or device commands were used. No commits or root-file edits in this slice.

Main actor: `ServerScoreRepository()`, `wire(store:)`, `configure(timeZone:)`, `setForeground(_:)`,
`invalidate()` on old-runtime teardown. Keep compatibility `startPolling(todayKey:)`/`stopPolling()`.
`refreshVisibleDays(todayKey: String? = nil) async` fetches newly calculated current day plus selected day.
`refreshRecentDays(limit: Int = 14) async` is bounded catch-up for sleep/history. No local daily row is required.
Views consume `@EnvironmentObject ServerScoreRepository` and immutable `state`. Root injects that instance
alongside AppModel. `setActivated(_:enabled:)` persists explicit field-family choice per AccountScope namespace.
Post `ServerScoreRepository.refreshRequested` after a VALIDATED upload receipt/result invalidation;
the notification carries no raw data. The repository observes identity, calendar-day, timezone and settings
notifications itself. Pass the profile timezone when known; a different server timezone produces an explicit
mismatch state, not a silently re-keyed result. Root owns account runtime recreation and app foreground hooks.

Important: root must call `setForeground(active)` rather than just `startPolling` / `stopPolling`.
The foreground API also cancels hydration and in-flight requests and suppresses notification-triggered
fetches while inactive. `invalidate()` revokes the retired runtime without signing out its replacement.
`signOut()` calls `CloudAuthClient.clearSessionChecked()`. A failed durable clear publishes
`signOutNeedsRetry` plus `lastError`; a replacement repository recovers that warning from the identity
facade's persistence error. Settings exposes an explicit retry, not a successful sign-out message.

The v48 helper is `ServerScoreCacheMigration.register(in:)`, with `migrate(_:)` for direct application.
Table `serverScoreSnapshotCache`: non-null TEXT projectURL/userID/sourceDeviceID/day/timeZoneID/
algorithmVersion/state; INTEGER schemaVersion/inputRevision/resultRevision; BLOB payload;
DOUBLE fetchedAt/accessedAt. Composite primary key: projectURL,userID,sourceDeviceID,day,timeZoneID,
schemaVersion,algorithmVersion. Index `serverScoreSnapshotCache_eviction(accessedAt,resultRevision)`.
Root owns migration registration and the schema oracle. Legacy unscoped rows are not adopted.

Instrumentation in owned app sources: real cache hydration, RPC refresh and immutable publication use
`SyncPipelineTrace` stage intervals, completed via defer with success/failure/cancellation/pending outcomes.
No user identifiers or payload values are logged. These intervals are not evidence of actual frame presentation.

Sleep session handoff: `ServerScoreSleepPresentation.session(_:) -> CachedSleepSession` now carries the
complete compatible epoch-segment `stagesJSON`, including an explicit `[]` when no stages are supplied.
Encoding occurs during DTO decode, not in view bodies; the derived string is excluded from the wire/cache
schema. UUID and nap classification cannot fit in CachedSleepSession, so
`projections(day:state:) -> [ServerScoreSleepProjection]` pairs each row with its original `sleep` DTO and
user/source/day/timezone/schema/algorithm/input/result revision metadata. The caller retains project scope.
Absent owned snapshots return no presentation rows; export deletion still requires a completed snapshot.
V2 supplies no user-edit or adjusted-onset flags, so the adapter does not invent them. The diagnostics
overload carries an explicitly supplied sparse-staging flag; the one-argument legacy seam leaves it nil.
Root owns metric-key aliases in `RepositoryServerScores.swift`; `ServerScoreDisplay.daily(...)` is unchanged.

Sleep identity extension: optional `originalStart: Int?`, `originalEnd: Int?`, `editEntity: String?` uses
the exact camelCase wire names. Root's latest strict rule is enforced: all three absent (legacy), or all
three present, with positive ordered original seconds and `sleep:<lowercase UUID>` matching session id.
This is stricter than the earlier input handoff's preferred-entity wording; root/Mill must keep it aligned.
`anchoredOriginalStart`, `anchoredOriginalEnd`, `resolvedEditEntity` expose the legacy first-edit fallback;
the durable writer must retain the original anchor afterward. Grouped main-night bounds are not one
editable identity. Root owns exact-session resolution, revisioned input, delete/undo/manual naps and tests.

Today/Sleep/Liquid have appearance/account-generation/day-scoped content-readiness hooks. The new
`ServerScoreContentReadyTrace` cancels unfinished intervals on disappearance/generation/day change and
ends once when authoritative nonempty view state is ready. Root registered Stage.cachedContentReady;
the trace now calls `.cachedContentReady` directly. `firstUsableFrame` is
reserved for actual frame evidence. These hooks do not claim rendering, hardware scanout or phone latency.

## Evidence / remaining gates

Current host checks on this checkout:

- WhoopStore: 10 new snapshot-cache tests plus 1 legacy cache test passed, including 128 session generations,
  file close/reopen, tombstones, revision conflicts, byte/row limits and last-observed source/version hydration.
- Native readback: 13 DTO/ownership tests plus 6 repository lifecycle tests passed. Covers mutable-envelope
  stripping, unsupported versions, null ownership, malformed/bounded input, stages, DST, immediate fetch
  without local rows, midnight, single-flight, retired reply rejection, inactive notifications and failed
  sign-out across runtime replacement/retry. Lifecycle tests compile the actual repository/client against
  synthetic auth/settings facades and built package modules; no Keychain/network/app data is accessed.
- Sleep projection: 7 additional native tests passed, exercising the actual HealthWriteback stage parser,
  exact epoch bounds/gaps, single/empty stages, unknown flags, UUID/nap/provenance, null ownership and
  complete replacement. Total native readback tests: 26. The new Today source-label test is app-host-only
  and has not been counted in that total.
- Earlier expanded native run: **49 tests passed** (13 DTO, 6 repository, 10 sleep/session identity,
  16 metadata/history/scalar-ownership and 4 content-ready interval lifecycle tests). The runner compiles
  actual display adapters too. Strict all-or-none identity, typed-null priority, negative temperature,
  core-only implicit capability, every added scalar, history correction/tombstone precedence, percent
  efficiency units and cancelled/once-only intervals are covered. Latest WhoopStore rerun: 11 passed.
- Current expanded native run: **67 readback tests plus 4 actual-settings tests passed**. Additional
  coverage: per-field lazy producer suppression/all four gates, owned-null headline vs historical tail,
  explicit temperature-kind ownership, calorie alias masking, private transport configuration,
  exact project routing, redirect delegate refusal for same/foreign origins, admission cancellation,
  owner retirement while streaming, unauthorized replies, announced/unannounced response overflow and
  the exact 512 KiB boundary. Settings tests compile the actual settings source with isolated preferences
  and synthetic configuration; paused uploads/unaccepted upload terms retain ownership without opening
  the write gate. Redirect tests exercise the delegate contract, not a live HTTP redirect service.
- Prior current-source WhoopStore cache gate: **11 passed** after rebuilding the package.
- Root's `root-bundled-context-integrated.log` passed all W4 suites, including the three SleepModel
  tests for suppression, duration trend and immutable local-input capture. That overall 280-test run
  had three metadata failures and is not a whole-suite green claim. Root's later 78-test profile/context
  selection passed but did not select W4 readback suites.
- Earlier detail checkpoint: **74 native readback plus 4 actual-settings tests passed**, including seven
  new detail/unit/chart regressions. Mill's 64 KiB synthetic native RPC/publication fixture decoded and
  canonical-round-tripped successfully. This is schema interoperability, not physiological golden parity.
  A fourth app-host SleepModel test covers signed server ledger replacement, prior means and owned-null
  removal. Root subsequently reported successful integrated builds and 122 passing app tests including
  the seven SleepDetails tests; see the source-freeze checkpoint above for exact current native coverage.
- Owned source syntax parse and focused DTO typecheck passed. A fresh integrated Release build is required
  after these UI edits; earlier successful builds do not certify the current evolving source.

Reproduce host lifecycle/DTO tests with `zsh Tests/ServerScoreReadbackNative/run.sh <WhoopStore debug dir>
<NoopPush debug dir> <external output binary>`. Both package directories must contain their native built
Modules and object files. `StrandTests/ServerScoreSnapshotV2Tests.swift` also belongs to normal app tests.
An optional fourth runner argument is the synthetic canonical server fixture path. The runner compiles
the new `ServerScoreDetails.swift` and `ServerScoreSleepDetailsTests.swift`; root's generated app project
must pick up those files too. Stable repository and central-overlay APIs have not changed.

Root needs to revise two pre-existing `ServerScoringRescoreSkipTests` expectations: flag-on may no longer
skip the all-metric producer or clear its owed rescore debt. W4 did not edit those existing tests.
Server-owned sleep editing stays explicitly unavailable until server edit/restaging integration passes;
this is not W4.6 edit-sync completion. Full history, other consumer/export migration and Swift/JVM parity
remain follow-up gates. Host readback checks do not establish actual UI rendering, phone frame pacing,
real Keychain fault behavior, background URLSession restoration or end-to-end server compatibility.
No production/device data, deployment, physical smoothness, background acceptance or full parity is claimed.
