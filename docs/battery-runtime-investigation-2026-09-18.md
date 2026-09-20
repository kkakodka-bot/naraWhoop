# Battery runtime stability investigation

This work is separate from PR #18. Its starting point is `d1b313b`, the sync
and off-body recovery branch. No server code, firmware, or persistent strap
configuration is changed.

## Reproduced cause

The normal connect path set `batteryRatedHours` from the WHOOP generation, but
iOS connection restoration and scan-family fallback bypassed that assignment.
The default was WHOOP 4's 108 hours even when the restored strap was an MG.
The estimator uses rated life both as a fallback and to cap a measured forecast.

A frozen, integrity-checked phone snapshot contains 80 battery readings over
64.19 hours: 63.9% down to 40.2%, with no charge rise. An existing debug launch
on build 343 subsequently recorded a live 40% reading. Replaying those exact
readings through the estimator gives:

| Model setting | Same current charge | Estimated time to 0% |
| --- | --- | --- |
| WHOOP 4, 108 hours | 40% | 2.70 days |
| WHOOP MG, 288 hours | 40% | 4.50 days |

The three-day result is the wrong model's cap, despite the estimator reporting
its source as `measured`. This reproduces the magnitude of the reported
three-versus-five-day swing without any battery consumption or data change.
The exact reported ten-day screen was not captured. With a consistent 40%
anchor and MG model, this estimator's existing cap is 7.2 days; ten days would
require a different input/model/build or a mismatched gauge and forecast.

## Other defects found and repaired

- Disconnect erased learned battery history, while the bootstrap that seeded
  it normally ran only once per process. Reconnect could therefore replace a
  personalized rate with the generic estimate. History now survives a radio
  reconnect and is cleared when the active source device changes.
- The historical query selected the oldest 2,000 rows before keeping only
  400. On sufficiently dense histories this omitted recent discharge. A
  separate forecast query selects the newest valid rows, in chronological
  order. Export queries retain their existing ordering.
- The 400-row memory cap held only roughly two days at an eight-minute
  cadence. The bounded history now supports up to fourteen days and 4,096
  readings. New history is loaded after a completed sync.
- Forecast charge came from the last historical sample while the gauge read
  `batteryPct`. A delayed seed could therefore pair different percentages.
  The forecast now explicitly uses the gauge's current charge; history supplies
  the drain rate.
- Repeated readings at a flat maximum moved the discharge start forward,
  discarding elapsed time and overstating drain. The first reading of that
  plateau now remains the anchor.
- Invalid percentages and future/expired seed rows are rejected. A source
  generation fences asynchronous history reads, including an A→B→A switch.
- Clock diagnostics continue to require a current-link battery reading.
  Retaining forecast history does not make old battery readings fresh.

Model selection now runs in the common setup used by normal connects,
restoration, and fallback scanning. The Battery test-mode log also records
the actual model, current charge, source, and resulting forecast.

## Prediction accuracy and limits

The repair addresses inconsistent inputs and lifecycle state. It does not
claim that a larger model or a VPS can know future power consumption exactly.
Only 64 hours of this device's discharge are present in the snapshot; there is
no complete observed discharge-to-shutdown cycle to validate days remaining.

An offline forward test used only readings available at each forecast origin,
then compared predicted charge with interpolated future recorded charge.
Origins were spaced three hours apart, starting after 18 hours of history.
These overlapping origins are a diagnostic check, not independent trials:

| Forecast horizon | Origins | Mean absolute charge error | Worst error | Generic-rate mean error |
| --- | ---: | ---: | ---: | ---: |
| 6 hours | 14 | 0.28 percentage points | 0.52 | 0.18 |
| 12 hours | 12 | 0.52 percentage points | 0.89 | 0.28 |
| 24 hours | 8 | 1.13 percentage points | 1.57 | 0.25 |

The generic rate happened to predict this short period better. The result
does not justify claiming improved statistical accuracy from the lifecycle
repair, replacing the model based on this one trace, or extrapolating the
one-day error into a validated multi-day confidence interval.

The existing headline estimates time to 0%. A separate existing alert model
reserves 10 percentage points based on a different WHOOP 5 high-load discharge
capture. That cutoff has not been calibrated for this user's MG. At the
replayed rate, a 10-point reserve would leave about 3.37 days of usable runtime
instead of 4.50 days to 0%. Neither is a measured time-to-shutdown for this
device. Whole-day display rounding can also amplify small changes near a
half-day boundary.

Further accuracy work needs multiple recorded charge/discharge cycles,
charging and usage context, device-specific shutdown observations, and
forward validation against a generic-rate baseline. It should report calibrated
uncertainty rather than an exact-day guarantee. The current change preserves
the existing alert/reserve policy and Android estimator; Android parity for
the new Swift plateau and validation rules is outside this iPhone repair.

## Verification

- 63 battery analytics tests passed, including alerts, the real historical
  high-drain fixture, plateau timing, live-charge anchoring, and invalid data.
- The new storage regression passed for newest-row selection, source and time
  filtering, invalid rows, empty limits, and unchanged export ordering.
- 50 app tests passed: battery lifecycle, trace/readout, alerts, polling,
  and source-driver activation. Total targeted tests passed: 114.
- Signed iPhone build succeeded. Build 344 was installed as a same-bundle
  upgrade, preserving the phone database. No schema migration was added.
- Three physical app launches each took iOS's restored-connected path and
  selected the MG's 288-hour model. At the same live 40% reading, they produced
  108.467, 108.512, and 108.518 hours (about 4.52 days to 0%). The total spread
  was 3.07 minutes, rather than multiple days. These were restarts of NARA,
  not restarts of the strap.
- Same-process disconnect history retention and source changes passed host
  lifecycle tests. A physical radio-toggle test was not repeated for build 344.
- A fourth launch restored ordinary operation without the temporary Battery
  test-mode launch argument. The diagnostic preference was absent before and
  after the test, and the normal launch emitted no new battery diagnostic lines.
- History sync completed during the validation window; persisted
  `lastSyncedAt` advanced to 12:21:33 PDT.

The first app-test build hit a Swift type-checking timeout in a new test's
large tuple expression. Splitting that fixture into typed statements resolved
the compile error; the subsequent 50-test run passed. Existing unrelated
compiler warnings remain in the project.

Private snapshots, the exact standalone Swift replay, raw outputs, and build
logs are retained outside Git at
`/Volumes/Untitled/WHOOP NARA-battery-evidence/2026-09-18/`.
