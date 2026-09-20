# Physiology reference benchmark

Offline evaluation support for specification sections 7–10. Python 3.10+ and the standard library are sufficient. No model weights, patient data, cloud credentials, inference dependencies or deployment actions are included.

Status: the harness and functional tests are implemented. Model adapter and host-measurement commands are implemented separately in `scoring-service/inference`; optional-model execution gates remain closed. Target-device scientific validation, prospective reference acquisition, target-resource qualification and locked-phone soak remain **not ready**. The test fixtures are explicitly synthetic functional controls; their scores and gate simulations are not scientific evidence.

## Run and verify

From this directory:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
python3 bench.py --help
python3 bench.py validate-model --manifest ../../models/manifests/wav2sleep-cardiorespiratory.json
python3 bench.py validate-model --manifest ../../models/manifests/wav2sleep-cardiorespiratory.json --for-execution
```

The final command must fail while that candidate is metadata-only. Optional inference packages belong to their actual adapter's exact-version environment lock, not this stdlib harness. Nothing is installed dynamically.

Commands write stdout unless `--output` names a new file. Existing paths are never overwritten. Exit codes: 0 completed, 2 invalid input/I/O, 3 promotion `NOT_READY`. Place data, keys, caches and reports outside the repository on an adequately sized volume; never commit participant identifiers or key material.

## Reproducible workflow

1. The data custodian establishes independent participant identities, original acquisition IDs, reference rights, timestamp alignment and adjudication. Split people before creating windows. Keep future recordings from held-out people and external site/device cohorts separate; do not move a training participant's later night into a purported participant-disjoint test set.
2. Generate and freeze the participant assignment. The same IDs and seed give the same split independent of input order. The default 60/20/20 allocation is an engineering convenience, not a prospective power analysis. The Python API accepts prespecified fractions; external participants are explicit.
3. Audit sequence receptive fields, including all padding/lookback/future context. Higher-priority held-out context wins when purging overlapping original recordings. A participant cannot be reassigned across splits. Renaming an export is not a new source recording.
4. Fit normalization, thresholds, calibration, feature selection and model selection only in train/development. `fit-audit` requires every component, exact implementation/input/frozen-parameter hashes and fit participants. A genuinely fixed component declares `not_fitted` with a reason. The included median/MAD normalizer rejects held-out fitting and never refits during `transform`.
5. Independently freeze the evaluation configuration, reference-quality/censoring rules, scientific budgets, intended-use subgroups, model manifest, fit audit and resource budgets **before** held-out evaluation. The templates contain nulls intentionally; they are not usable promotion policies.
6. Produce baseline and candidate predictions from immutable inputs. Preserve abstention, observed time, receptive field, model version and correction fraction. Actual model inference is separate from this harness.
7. Evaluate both on identical held-out reference time; pass the original reference files to verify their byte hashes. Record functional, provenance, resource and hardware evidence separately. Sign the frozen policy and reviewed evaluation artifact using an externally managed key.
8. `promotion-check` verifies the bindings and gates. Even a successful decision is only `ELIGIBLE_FOR_HUMAN_REVIEW`; publication remains disabled. This tool never enrolls a cohort, changes the promoted-version registry, deploys a model or removes the previous model.

Example commands use custodian-supplied files, not bundled scientific data:

```sh
python3 bench.py split --dataset reference.json --seed frozen-study-seed --external-participant external-person --output split.json
python3 bench.py purge --windows receptive-fields.json --split split.json --embargo-seconds 0 --output purged.json
python3 bench.py fit-audit --artifacts fit-components.json --split split.json --output fit-audit.json
python3 bench.py evaluate --dataset reference.json --baseline baseline.json --candidate candidate.json --split split.json --config evaluation-config.json --policy frozen-policy.json --fit-audit fit-audit.json --model-manifest candidate-manifest.json --reference-artifact original-reference.bin --output evaluation.json
python3 bench.py sign --payload frozen-policy.json --key-file /secure/offline-signing-key --signer reference-reviewer --output policy.signed.json
python3 bench.py sign --payload evaluation.json --key-file /secure/offline-signing-key --signer reference-reviewer --output evaluation.signed.json
python3 bench.py promotion-check --policy policy.signed.json --evaluation evaluation.signed.json --trusted-key-file /secure/offline-signing-key --output decision.json
```

Repeat `--reference-artifact` for each source. `evaluate` starts with `functional_gates_passed: false` and empty evidence/resources. It never manufactures a passing evidence package. A reviewer must independently assemble and attest the missing evidence before signing. The sample commands therefore do not by themselves make a promotable artifact.

## Version 1 input contracts

`physiology_bench/contracts.py` is the executable validator. JSON documents must be objects; duplicate JSON keys, NaN/Infinity, files above 64 MiB, invalid units, nonfinite times, duplicate identities and incompatible modalities are rejected. All time is seconds on one aligned UTC axis; intervals are half-open. No offset is guessed or automatically applied. Within-source overlapping exported recording spans are rejected to prevent double counting.

Reference document:

| Object | Required fields / meaning |
|---|---|
| Root | `schema_version: 1`, `dataset_id`, `evidence_kind: reference` or `synthetic_functional`, `participants`, `recordings` |
| Participant | Stable `id`; `subgroups` maps prespecified names to explicit labels, e.g. site, age group, skin tone, firmware or disease context. Missing labels are not inferred. |
| Recording | `id`, immutable `source_recording_id`, `participant_id`, `start_s`, `end_s`, `reference` and modality-specific observations |
| Reference provenance | `modality`, `version`, original-file `sha256`, `license`, explicit boolean `adjudicated`; `synchronization` contains `method`, `offset_s`, nonnegative `uncertainty_s`, `applied: true`. Optional `label_uncertainty` and `scorer_agreement` are retained, absent values remain null. |
| ECG | `beats`: ordered unique `{id, time_s, nn_eligible}`; `observed_spans`: explicit acquisition intervals. No inferred beat train or synthesized NN labels. |
| PSG | `epochs`: `{start_s, end_s, stage, scorable}` at exactly 30 s. Input W/N1/N2/N3/R maps to wake/light/light/deep/rem; unknown/unscorable epochs are excluded from reference labels. |
| Sleep opportunities | Nonoverlapping `{start_s, end_s, type, annotation_source}` where type is main_sleep/nap/other_sleep; optional independently known `bed_entry_s`, `sleep_onset_s`, `final_wake_s`. No inferred bed occupancy. |
| Detection annotation coverage | `opportunity_annotation_spans`: independent `{start_s, end_s, annotation_source}` spans in which presence **and absence** of opportunities were assessed. Without these spans, detection recall/false-episode rates are unavailable, not perfect. Partially covered proposed episodes are excluded and counted explicitly. |
| Respiratory reference | Modality airflow/capnography/validated_respiratory_effort; `respiration` contains `{start_s, end_s, value, unit: "breaths/min"}`. Rates must already be adjudicated and aligned. Sliding windows may overlap; exact duplicate bounds are invalid. |
| Independent strata | `window_annotations` and PSG `behavior_annotations`: `{start_s, end_s, annotation_source, labels: {name: label}}`. Only fully enclosed windows/epochs enter that stratum. Rate-range, motion, clean high variability, reading and phone-use labels are supplied by the study, never generated by candidate output. |

Prediction document root: `schema_version: 1`, `model_id`, `algorithm_version`, `model_manifest_sha256`, `computation_mode: causal|retrospective`, `recordings`. Each recording has `recording_id` and optional `windows`, `epochs`, `episodes`, `beat_times_s`.

All window/epoch/episode rows contain `start_s`, `end_s`, `input_start_s`, `input_end_s`. The input span must be inside the declared recording; causal outputs cannot read beyond output end. Whole-night/future-context models must declare retrospective mode.

- Scalar windows also contain `metric: rmssd_ms|sdnn_ms|respiratory_rate_bpm`, matching `unit: ms|breaths/min`, nullable `value`, `observed_duration_s`, nullable `confidence`, optional `correction_fraction`. Null values require `abstention_reason`; a genuine zero is not missing. Overlapping sliding windows are supported.
- Optional `observed_spans` must sum to `observed_duration_s`. They permit a real observed-time union across overlapping windows. Without spans, only the potentially overlapping observed-window-duration sum is known; the union remains null.
- Epochs are 30 s, with `stage: wake|light|deep|rem|sleep_unstaged|state_unknown`, observed duration and nullable confidence. The last two states need an abstention reason. Optional four-stage probabilities must sum to one and state `probability_status: calibrated|uncalibrated`.
- Episodes use `type: main_sleep|nap|other_sleep|uncertain`; uncertain episodes do not assert detected sleep. Predicted episodes must not overlap. Predicted R-peak times must be strictly increasing.

Fit-components root: `artifacts` with exactly normalization, thresholds, calibration, feature_selection and model_selection. Each component has `split_sha256`, `implementation_sha256`, `status` and `participants`. Fitted components require `fit_inputs_sha256`, `frozen_parameters_sha256` and train/development participant IDs. Fixed components have no fit participants and require `reason`. The audit binds the full split but cannot inspect undocumented external training; reproducible training logs and custodian review are still necessary.

## Reference adapters and metrics

- ECG reference adapter forms intervals only between consecutive adjudicated eligible beats within observed acquisition spans. Five-minute UTC windows preserve original beat-pair identity; rejected beats/gaps do not become new adjacency. RMSSD zero remains zero; sample SDNN is separate. Beat precision/recall uses chronological one-to-one maximum-cardinality matching at the explicitly configured tolerance. Window reference coverage and maximum-gap filters are frozen independently of the model.
- PSG adapter maps labels without guessing missing stages. Four-stage confusion, precision/recall/F1, macro-F1, kappa, probability Brier/log loss/reliability/ECE and accepted coverage are reported. Conditional confusion statistics exclude abstentions; full-reference per-stage recall, wake specificity and sleep sensitivity expose their cost. `sleep_unstaged` contributes to qualified binary sleep, not stage accuracy; unknown contributes to neither sleep nor wake.
- Episode matching maximizes one-to-one matches, then overlap, at the prespecified IoU. Detection, nap precision/recall, false episodes per 24 independently annotated hours, matched onset/offset errors, TST/WASO and bed-entry-based latency are separate. TST comparisons retain unknown prediction time explicitly and exclude incomplete reference opportunities. TST is not a measured-time-in-bed claim.
- Scalar metrics: signed bias (prediction minus reference), MAE, RMSE, descriptive bias ± 1.96 sample-SD limits of agreement, and within-2-breaths/min fraction for respiration. Native coverage uses each model's own accepted windows; paired accuracy uses only common accepted reference windows. Exact bound mismatches count as abstention; there is no silent interpolation.
- Accepted-time coverage uses interval unions per recording, so overlapping sliding windows do not multiply recorded time. Confidence risk/coverage includes both count and time coverage. Fixed confidence operating points are reporting bins, not validated physiological cutoffs.
- Four-stage risk/coverage reports each model at explicit confidence thresholds 0, .25, .5, .75, .9, .95 and 1 on the same full scored-PSG denominator. It includes accepted time, participant count, conditional misclassification risk/accuracy/kappa/macro-F1 and full-reference wake specificity/sleep sensitivity. Missing confidence is not imputed from probabilities; missing or rejected predictions remain unknown in full-reference metrics.
- Nightly-context summaries require the complete scalar window to be covered by independently scored PSG sleep. Both mean and median errors are retained per recording; the study must prespecify its actual nightly ownership/aggregation. A recording that contains multiple nights must be partitioned into independently identified nights before using it as a nightly summary.
- Bootstrap intervals use 95% percentiles from resampled **participants**, retaining each person's correlated rows together. They describe the pooled-window statistic, not an equal-participant point estimate. Fewer than two participants yields unavailable uncertainty. Reported interval families include MAE, paired MAE difference, kappa, paired kappa difference and TST bias. Limits of agreement are descriptive, not participant-level confidence bounds.

Evaluation configuration is explicit: partition development/test/external, seed, bootstrap replicate count (10–10,000), minimum reference observed fraction, maximum reference gap, episode matching IoU and ECG beat tolerance when ECG is present. `evaluation-config.template.json` deliberately leaves study choices null. No physiological cutoffs or cohort size requirements are invented here.

## Signed artifacts and promotion boundary

Canonical JSON sorts keys, uses compact UTF-8 and rejects nonfinite numbers. Hashes are SHA-256. Signed envelopes authenticate schema version, payload, signer identity and key ID with **HMAC-SHA256**, using a key of at least 32 secret bytes. This is shared-secret authenticity, not a public-key signature or proof of clinical truth. Verifiers possess signing capability; use separate managed keys and an external immutable custody process where independent attestations/nonrepudiation are required. No key is generated or committed by this tool.

A frozen policy binds dataset/split/config/model/fit-audit hashes, feature-specific metric family, participant/subgroup budgets, strict paired improvement, native-coverage noninferiority, every required subgroup's regression budget and actual-target latency/RSS/CPU/throughput budgets. Coverage and subgroup criteria must use that same feature family. Participant budgets count people with qualified paired outputs for the feature, both overall and within each subgroup; unrelated modalities, rejected reference windows and all-abstaining predictions cannot pad those counts. Participant identities must match the held-out split, and paired bootstrap uncertainty must be available. Original all-recording participant counts remain diagnostic. Sleep additionally requires full-reference wake noninferiority and independently annotated detection recall/false-episode budgets. Test results cannot be used to tune the frozen limits.

Memory budgets may explicitly freeze `memory_resource_metric: process_tree_memory_peak_bytes` instead of `maximum_rss_bytes` (the backward-compatible default). The criterion must use that exact resource path and matching `resource_accounting` metadata: method `dedicated_cgroup_v2_process_tree`, semantics `kernel_cgroup_lifetime_charged_memory_peak`, and `dedicated_scope_checked: true`. This is lifetime kernel-charged memory for the dedicated process tree, not aggregate RSS; caches/kernel memory may be included and shared-page charges can belong elsewhere. A cgroup measurement cannot satisfy an RSS budget, nor can worker-only RSS satisfy the cgroup budget. Actual target-scope ownership and isolation still require the independently attested resource evidence. Both metric paths retain all scientific, rights, soak and human-review gates.

The signed evaluation requires the matching executable shadow model manifest, fit audit, reference byte hashes/adjudication, functional suite evidence, reference-custodian attestation, locked-phone soak and actual-target resource evidence. Reviewed code, weight and training-data rights require nonempty license identifiers and evidence references; nonapplicable rights require an explicit reason, and required weights cannot be marked nonapplicable. Each evidence item has passed status, artifact SHA-256 and reviewer. Missing/null/mismatched/tampered fields fail closed. A trusted signer's false provenance assertion cannot be detected cryptographically; signatures never turn synthetic data or vendor agreement into ground truth.

Scientific readiness is separate from software readiness. No real evaluation, acceptable WHOOP accuracy, legal clearance, physical-device continuity or deployment readiness is asserted by this change. The executable `physiology_inference.correction_comparison` runner compares Lipponen–Tarvainen/Malik/censor-only on identical original peaks, preserves correction provenance, sweeps 80/90/95% observed coverage and 0/5/10% correction limits, and exports this prediction contract. See `scoring-service/inference/README.md` for commands and required acquisition fields. Its synthetic tests and research manifests are not promotion evidence; actual independent ECG-reference evaluation remains required. Likewise, waveform accuracy claims need waveform references; scalar rate error does not establish apnea detection.
