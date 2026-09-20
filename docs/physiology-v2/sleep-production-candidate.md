# Sleep production-candidate policy

Status: implemented engineering shadow candidate, not reference-qualified. No PSG,
independently timestamped opportunity, nap, or shift-worker accuracy is established
by these changes. The fixed-coefficient stager is a transparent uncalibrated baseline;
its probabilities must not be interpreted as calibrated confidence.

## Separate outputs

- `fullDaySleepEpochs` retains binary state and separately attributed context across
  the complete day, including outside retained episodes. Explicit reading, phone use,
  quiet rest, off-body, and sleep-opportunity reports retain their provenance. A bed
  or opportunity annotation alone does not establish sleep. Wrist data does not
  passively identify phone scrolling.
- Episodes have estimated boundaries and a separate denominator provenance. Their
  `main_sleep`, `nap`, `other_sleep`, or `uncertain` designation is independent of
  four-stage estimates. Manual edit/tombstone reconciliation remains server-owned.
- Independently qualified binary sleep persists if the stager predicts wake or
  lacks evidence: the stage becomes `unknown`, with `sleep_unstaged` binary state
  and a disagreement/unavailability reason. Stage estimates never select main sleep.

## Frozen engineering policy

`full-day-binary-shadow-2` is retrospective. Candidates require HR plus movement
features in at least five of six sampled 5-second bins in each 30-second epoch,
relative HR reduction, and low movement. These are sampled feature coverage, not
continuous beat coverage. A retrospective per-minute HR reference requires at least
60 represented minutes. Thresholds are not fitted or validated clinical cutoffs.

Valid gravity orientation has magnitude 0.5–1.5 g; finite but impossible vectors
provide no orientation evidence. Available strap dynamic acceleration can support
binary movement features separately, but cannot stand in for the stager's required
orientation input. Exact repetition in both HR and motion for 30 minutes is treated
as stale/constant ambiguity, not an off-body diagnosis. Independently timestamped
streams need not have identical clock phase for this check.

Contiguous candidate sleep must last at least 15 minutes and no more than 16 hours.
Unsupported longer runs remain unknown instead of becoming several artificial naps.
Main groups require at least 90 accepted binary sleep minutes and are ranked by
accepted duration, never by outer span or a fixed 03:30 midpoint. Adjacent portions
can group across gaps shorter than 60 minutes within a 16-hour outer bound. This
supports split sleep without merging distant episodes; longer secondary portions
remain `other_sleep`. A non-main episode is called a nap only if accepted duration
is at most 90 minutes and accepted sleep occupies at least 80% of its span.
Clock-of-day and historical midsleep do not demote daytime or rotating-shift sleep.

`sleep-v2-evidence-2` requires joint HR and valid orientation coverage, not either
modality alone, and breaks temporal inference at unsupported epochs. Frozen inputs,
unsupported duration, and gaps produce unknown with explicit reasons. Retrospective
output is marked as such; no causal-stage capability is implied.

## Evidence and remaining gates

Swift and server analytics-kernel adversarial tests cover accepted-duration ranking,
daytime/rotating offsets, split sleep, binary/stage disagreement, distinct secondary
types, impossible gravity, single-modality input, constant sensors, offset sensor
clocks, overlong episodes, and complete-day context serialization. These tests prove
engineering invariants, not sensitivity, specificity, staging accuracy, or overnight
device readiness. Existing stage-recipe golden inputs use tiny nonconstant valid
motion so they test the recipe separately from the constant-sensor rejection test.

Promotion still requires participant-disjoint PSG and opportunity evaluation, frozen
development-only thresholds/calibration, retained/unknown coverage, subgroup results,
signed feature-specific approval, and device/overnight evidence. No reference data
was available to this implementation task; accuracy and calibration are NOT MEASURED.
