# Reference validation: production candidate

Scientific status: **NOT_READY / NOT_MEASURED** for HRV, sleep and respiration. The repository contains synthetic engineering controls, not a synchronized target-device reference cohort. No accuracy, retained-coverage or vendor-equivalence result is asserted here. Publication remains shadow until each feature independently passes the immutable signed gate.

## Implemented evaluation paths

`Tools/physiology-bench` implements participant-level splitting and context-overlap audits, train/development-only fit provenance, frozen pre-held-out policy checks, exact reference-byte verification, signed review artifacts and an offline bridge to the feature-specific database approval gate. Running the bridge neither writes an approval nor selects a model.

| Endpoint | Implemented report | Current measured evidence |
|---|---|---|
| HRV | Beat precision/recall; five-minute RMSSD and SDNN bias, MAE, RMSE and descriptive limits of agreement; retained valid-time coverage; independent-night mean comparisons; participant bootstrap intervals | None from synchronized target-device ECG |
| Sleep | End-to-end annotated episode matching; main/nap/other counts; independent binary sensitivity/wake specificity; four-stage confusion, macro-F1, kappa and calibration; unknown coverage; per-person/subgroup results | None from target-device PSG plus independently timestamped opportunities |
| Respiration | MAE, RMSE, bias, descriptive limits of agreement, within-2-breaths/min rate; retained time; representative-night coverage; per-person/subgroup results | None from synchronized airflow, capnography or validated effort |

Independent annotations support motion, gaps, rhythm ambiguity, clean-high-HRV, perfusion, supported-rate and harmonic-error strata. Missing strata are not imputed. Shift work, rotating schedules and naps require prospectively defined independent labels. An absent subgroup cannot satisfy its frozen participant/regression budget.

The stage and binary contracts are separate. Stage wake cannot remove qualified binary sleep or alter TST. Real-reference prediction epochs require independently attributed binary state. The sleep promotion wake budget uses binary wake specificity, not stage-derived wake.

Representative-night comparisons use independently annotated main-sleep bounds, minimum duration, minimum accepted fraction and temporal-third coverage from the frozen evaluation configuration. Censoring the reference itself cannot shrink a six-hour night into a dense early island. Common-time per-recording summaries remain diagnostic. HRV and respiration promotion require separate nightly accuracy/retained-coverage budgets and participant-level uncertainty: mean-window HRV and median-window respiration. A production endpoint using another aggregation must supply a matching frozen endpoint evaluation before claiming nightly accuracy.

Repeated epochs/windows never become independent participants. Bootstrap uncertainty resamples complete participant clusters. Limits of agreement are descriptive pooled-error limits, not person-independent confidence intervals. Single-participant uncertainty remains unavailable.

## Exact external blockers

1. No consented, licensed target-device cohort with synchronized ECG and adjudicated R peaks/NN exclusions has been provided. Required deliverables are original reference bytes, stable person/acquisition IDs, timestamp alignment with uncertainty, motion/rhythm adjudication, device/source/firmware metadata and full-night annotation coverage.
2. No synchronized target-device PSG cohort with scored 30-second epochs and independently timestamped opportunities/annotated non-sleep time has been provided. Nap, daytime shift, rotating schedule, split-sleep and subgroup representation cannot be established by synthetic fixtures.
3. No synchronized target-device airflow, capnography or validated respiratory-effort cohort has been provided. Perfusion, motion, out-of-supported-rate and dominant-harmonic strata therefore have no held-out accuracy or coverage estimates.
4. No prospective, powered, signed feature-specific promotion policy or train/development-fitted artifact/calibration package has been provided. Template thresholds remain null intentionally; no held-out result is available to inspect or tune against.
5. No real-feature reviewer approval, approved checkpoint/input-contract package, locked-phone overnight soak evidence or actual-target VPS resource attestation has been supplied to this harness. Functional fixtures cannot substitute for any of them.

The custodian must freeze participant assignments, normalization, artifact policies, feature selection, calibration, reference-quality rules, aggregation, subgroup budgets and promotion limits before opening held-out predictions. The source and runtime must then match the registered immutable algorithm/feature manifests. Each reviewer signs the exact evaluation and feature identity using a separately managed approval key. Editing a database qualification row cannot manufacture this evidence.

## Engineering verification

Functional regressions cover exact-byte approval signatures; missing/wrong/future evidence; feature/checkpoint/preprocessing/quality/mode isolation; held-out preflight ordering; independent binary/stage disagreement; censored and candidate-only early-night islands; person-level split/fit leakage; unknown coverage; and absent reference provenance. These are test outcomes only. Exact-head command results belong in the final integration verification report; this document does not transfer working-tree test results to a later commit or deployment.
