# Bounded physiology shadow runtime

This is an executable research lane, not a promoted physiology model. Every response has `publication_mode: shadow`, `canonical_outputs_allowed: false`, original owner/device/revision/hash, and explicit unavailable reasons. Functional synthetic tests are not PSG, ECG, capnography, target-device accuracy, or VPS resource validation.

## Service integration

`PhysiologyShadowRunner.fromEnvironment(dataSource, objects, environment, assembler)` builds the service lane. `evaluate(Request(...))` computes deterministic respiration without waiting for optional models. Separate durable model jobs call `evaluateModel(request, modelId)`, discover and hash/decode raw objects, and invoke one configured model. The model worker has bounded leases/retries and a separate process/deployment; see the model queue migration and `Dockerfile.model`. Raw inputs are bounded to eight objects/64 MiB decoded total. The two-local-day acquisition bound is 76 hours to cover DST and date-line travel; larger contexts are explicitly unavailable.

Contexts are caller-supplied qualified **engineering-derived binary sleep/rest**, not clinical truth or PSG labels. Empty context produces `no_qualified_respiration_context`. Contexts do not create valid beats. Request owners must match every original interval. The runner emits 120-second windows with 60-second stride and per-context median (primary), mean, accepted duration union, coverage, and `distribution_bpm`: sorted accepted-window estimates with `distribution_kind: sorted_accepted_window_estimates`. This distribution is not duration-weighted or a reference distribution. Unknown coarse-second packet timing cannot create RSA continuity. Output serialization is `.json()`; consumers must preserve this as a shadow section, not publish legacy heuristic daily respiration under the new method name.

Default WHOOP NPB1 raw decodes preserve signed counts, same-second packet identity, and unknown semantics. They **do not establish** optical wavelength, ADC/DC calibration, exact sample clock, IMU units/orientation, or cross-channel alignment. `VerifiedModelJobAssembler` uses immutable acquisition receipts from `JdbcAcquisitionContractResolver`, scoped to account, device, requested interval, input revision, model/checkpoint and pipeline versions. Receipts bind exact raw-object bytes, capture firmware/device-family attestations, signed-count channel extraction, masks and reviewed timing/semantics/units/synchronization evidence. Replayed physical records and duplicate row IDs are rejected. The configured activation stays model-specific, not user-specific. No qualified WHOOP acquisition receipts or deployed waveform activation are supplied; their absence remains unavailable. The implemented production raw adapter supports wav2sleep and NeuroKit PPG only; other adapters still require their own verified input assembler.

Optional operator configuration is selected by `PHYSIOLOGY_SHADOW_CONFIG`, a local JSON file (maximum 1 MiB):

```json
{
  "python": "/usr/local/bin/python",
  "python_path": "/opt/physiology/inference:/opt/physiology/upstream/src",
  "model_timeout_seconds": 35,
  "total_timeout_seconds": 60,
  "models": [{
    "model_id": "neurokit2",
    "activation_file": "/opt/physiology/activations/neurokit2.json",
    "asset_root": "/opt/physiology/assets"
  }]
}
```

These example paths are not installed artifacts. Wrong configuration fails closed. Jobs/activation files never come from device payloads. The JVM bridge strips DB/B2/cloud credentials, monitors output size while running, kills child descendants on cancellation, and cleans private temporary files. The Python layer uses one child, thread counts of one, offline model-hub settings, 16 MiB input/4 MiB output limits, CPU deadline and file-size limits. Linux enforces a 2 GiB **address-space** limit; macOS reports memory enforcement false. This is not a measured RSS guarantee or network sandbox. No inference model downloads are performed.

## Input and activation contracts

Jobs contain `user_id`, `device_id`, `input_revision`, `mode` (`causal`, `windowed`, `retrospective`), `signals`, and `input_hash`. Every job field except `input_hash`, including model options, receipt/checkpoint identity, epochs and features, is bound. Legacy Python jobs use sorted compact JSON; JVM jobs explicitly use `input_hash_encoding: typed-json-sha256-1` (typed UTF-8/IEEE-754 encoding with cross-language golden tests). A signal includes name, unit, sample rate, event start, values, boolean observed mask, verified timing/channel semantics, clock ID, acquisition ID, and applicable wavelength/orientation. Reconstructed/interpolated missing periods cannot become observed time. Wrong rates, shapes, ownership, missingness or semantics abstain before model load.

An activation contains `model_id`, shadow-only authorization, a full `code_revision`, separate `rights.code/weights/training_data` entries with reviewed/not-applicable status **and meaningful evidence**, hash-addressed local `assets`, `preprocess_version`, `quality_policy_version`, and `implementation_sha256`. Reviewed rights require a nonempty `identifier`; nonapplicable rights require an explicit `reason`. Code rights always require review, as do weights for checkpoint-consuming adapters or any supplied `weights` asset. The implementation digest covers all runtime Python sources and the source lock. Compute it with `from physiology_inference.contracts import implementation_hash`. Applicable installed package Python-tree hashes must match the pinned source lock and the actual imported package. RR_Estimation additionally requires the exact inspected source/checkpoint digest. An operator assertion is not an independent legal or scientific review. No activation claiming such a review is included.

`models/manifests` remains an inventory, not runtime activation. Its rights/promotion gates intentionally remain closed. `requirements-functional-test.lock` records the exact **macOS functional-test** package versions; it is not a wheel-hash supply-chain lock or validated Linux inference image. Optional environments require their own qualified immutable dependency/wheel lock before activation.

Every activation also requires a hash-addressed `assets.environment_manifest` (maximum 1 MiB) and `environment_review` with `status: reviewed_for_shadow`, a nonempty `identifier`, and `evidence`. Capture an environment using the same interpreter, package paths and installation that the worker will use:

```sh
python -m physiology_inference.environment --model neurokit2 --output observed-environment.json
```

Capture produces `unqualified_observed_environment`, never an authorization. An external review must establish the intended environment and change its status to `qualified_shadow_environment` before its exact bytes are attached to an activation. The runtime rechecks interpreter/stdlib bytes, platform, transitive installed distribution versions/files (including native extensions), resolved import roots and already-loaded package origins. Additional adapter dependencies can be included with repeated `--distribution`; RRest requires `--octave-executable`. Missing/ambiguous distributions, alternate unrecorded import origins, changed bytes or review evidence abstain. Hashing is bounded to 100,000 files and 2 GiB per capture/verification. This checks installed bytes and import locations, not wheel origin, every operating-system shared library, legal rights or VPS suitability. No qualified optional-model environment or review is bundled.

## Same-input correction comparison

The offline runner compares the existing radius-two/20% Malik filter, censor-only intervals, Lipponen observed-original intervals and separately labeled corrected research intervals. All receive the same immutable peak identities and observed acquisition spans. It preserves cumulative correction events, original interval/pair masks, RMSSD, sample SDNN and explicit abstentions. The default grid is observed coverage 80/90/95% crossed with maximum correction fractions 0/5/10%; other minimum-pair, gap and accepted-duration policies are recorded engineering choices, not validated clinical cutoffs.

Input JSON has `schema_version: 1`, `dataset_id`, `evidence_kind: synthetic_functional|reference`, and `recordings`. Each recording requires stable `id`, `participant_id`, `source_recording_id`, `user_id`, `device_id`, original `source_sha256`, `start_s`, `end_s`, `sample_rate_hz`, `timing_verified: true`, interval `modality: ppg_pulse_intervals|ecg_intervals`, ordered `observed_spans` (`start_s`, `end_s`), and ordered original `peaks` (`id`, integer `sample_index` relative to recording start). No clock, beat identity, reference label or unobserved interval is inferred. Limits are 16 MiB input, 100 recordings, 200,000 peaks, 1,000 complete five-minute UTC windows and 5,000 peaks per window.

```sh
python -m physiology_inference.correction_comparison --input original-peaks.json --activation reviewed-neurokit.json --asset-root /qualified/assets --output comparison.json
python -m physiology_inference.correction_comparison --input original-peaks.json --activation reviewed-neurokit.json --asset-root /qualified/assets --export-method lipponen_observed --coverage 0.9 --maximum-correction 0.1 --output candidate-predictions.json
```

The CLI requires the same rights, installed environment and upstream-source checks as runtime inference. The report and each exported research manifest bind the exact activation and environment-asset hashes; directly injected test backends are explicitly unverified. No reviewed activation is supplied. The prediction export follows the W5 benchmark contract; its inline research manifest is **not** an executable promotion manifest. Independent synchronized ECG/reference files and participant-disjoint evaluation remain required to compare error or justify promotion. Functional synthetic controls exercise the actual pinned NeuroKit correction backend but do not establish physiological accuracy.

## Host resource measurement

```sh
python -m physiology_inference.resource_benchmark --job immutable-job.json --activation reviewed-model.json --asset-root /qualified/assets --iterations 10 --warmup 1 --tolerance 0.000001 --output host-resources.json
# Run only inside a dedicated Linux cgroup-v2 scope containing this command:
python -m physiology_inference.resource_benchmark --job immutable-job.json --activation reviewed-model.json --asset-root /qualified/assets --iterations 10 --warmup 1 --tolerance 0.000001 --process-cgroup /sys/fs/cgroup --output process-tree-resources.json
```

This serial command measures bounded child wall latency (nearest-rank p95), worker CPU, peak RSS, completed records/hour and repeatability at the explicitly supplied numerical tolerance. It binds input and activation hashes and includes environment verification/model load overhead. Missing measurements, failed runs or nondeterminism produce `not_ready`. Without process-tree accounting, RRest's external Octave resources are unavailable and cannot qualify from Python-worker diagnostics.

`--process-cgroup` requires the process's actual cgroup-v2 membership, resolved through `/proc/self/cgroup` and mount ancestry in `/proc/self/mountinfo`. Covered/replaced mounts, unreadable descendants, shared scopes, remaining descendants between runs, changed scope identity and rolled-back counters fail closed. Kernel `cpu.stat` deltas include this benchmark, inference children and descendants. `memory.peak` is reported separately as `resources.process_tree_memory_peak_bytes` with `kernel_cgroup_lifetime_charged_memory_peak` semantics. It bounds charged memory over the measured interval and may include earlier warmup, page cache and kernel memory; shared pages may be charged elsewhere. It is **not aggregate RSS** and never fills `maximum_rss_bytes`. Its promotion policy must explicitly freeze `memory_resource_metric: process_tree_memory_peak_bytes`, require that criterion, and retain matching dedicated-accounting evidence. Legacy policies continue to require RSS. No metric substitution is inferred.

External reviewers must attest exclusive ownership of the dedicated cgroup for the entire run; boundary PID inventories are not an access-control mechanism preventing another process from entering between reads. JVM, database, ingestion and optional GPU costs outside that scope are not included. A successful host measurement is only `measured_pending_external_review`, with target qualification `not_attested`; it never changes model authorization or promotion. Actual target-VPS runs, representative inputs and independently frozen resource budgets remain required. Outputs use new files only; no existing artifact is overwritten.

The Python counter/membership/policy tests use bounded filesystem fixtures. `tests/cgroup_kernel_probe.js` separately exercises real Linux kernel counters with synthetic child/grandchild allocations and CPU work in a cached network-disabled Node container. That probe is not execution of the production Python accounting module, Octave, or a physiological model; a qualified Linux Python/model run remains external acceptance.

## Implementations and limits of the evidence

| Candidate | Executable work here | Still absent / not claimed |
|---|---|---|
| Native respiration | Swift/Kotlin deterministic detrending, Hann spectrum, observed-pair autocorrelation, cycle/coverage/gap/weakness/harmonic/range rejection; verified-original-chain RSA; original-beat bandwidth cap; aligned channel fusion with disagreement abstention and no multiplied confidence; duration-union summaries | Thresholds are engineering policies, not clinical cutoffs. PPG/IMU modulation inputs require a separately qualified acquisition/extraction adapter; WHOOP counts do not qualify them. No actual physiological reference validation |
| NeuroKit2 | Actual pinned Elgendi, MSPTDfast and ECG detectors; one-to-one detector disagreement, template quality, separate PPG/ECG modality; actual Lipponen–Tarvainen/Kubios bounded passes preserving cumulative original identities and observed/corrected comparison | Perfusion is unavailable without DC calibration. Extreme-value fraction is not asserted to be physical clipping. No target-device detector validation |
| Feature sleep | Compact softmax learner; training-only standardization, participant/acquisition-disjoint development calibration, joint HR+motion coverage, explicit-duration retrospective decoding and causal emissions | Not LightGBM. No clinical trained checkpoint/PSG benchmark; synthetic calibration tests are not calibrated target-device performance. No production feature-input assembler yet |
| wav2sleep | Released pinned 9,666,562-byte checkpoint/config downloaded, hashed and actually executed twice on CPU with identical synthetic output; exact upstream PPG grid/normalization; gaps reject | No wrist acquisition qualification, domain-transfer accuracy, held-out calibration, reviewed deployment rights or actual VPS/Linux image benchmark |
| RR_Estimation | Exact 2048×4 / 64 Hz PPG+ACC validation; aligned calibrated channels; released rounding/architecture/load-weights API; checkpoint bytes actually hashed | Upstream example begins with external preprocessed pickle arrays; raw normalization cannot be invented. TensorFlow/evidential-deep-learning environment and released-weight inference not executed. Weight/data rights unresolved |
| Walch | Actual pinned feature/label assembly + deterministic serial standardized logistic comparator with explicit train/test participants; binary/three-class output only | This comparator variant does not reproduce the published ensemble or its scores; precomputed upstream feature contract remains explicit |
| SleepECG | Local classifier/verified ECG beat-time comparator; serial features; correct upstream class ordering including UNDEFINED; never splits NREM into deep/light | Only adapter-contract tests run; local released classifier/dependencies are absent. PPG transfer is not qualified |
| RRest | Unmodified pinned MATLAB/Octave FTS/ACF invocation with bounded file schema and spectral-peak dependency | Octave is not installed, so actual RRest execution is NOT_RUN. GPL review unresolved; separate-process execution does not remove license obligations |
| CorrEncoder | Released architecture/MSE reproduction with participant-explicit train/dev split; training-only deterministic shuffling, retained best dev checkpoint, local weights-only inference and frozen shape/rate; full-window waveform requires retrospective mode | One-epoch synthetic reproducibility is not an actual dataset reproduction. No released pretrained checkpoint is asserted; output waveform still needs separately qualified respiratory-rate extraction |

Lipponen correction is limited to observed runs; it never repairs an acquisition outage into continuity. Original observed pairs require three unaffected original endpoints. Corrected research estimates are labeled separately and cannot replace original beat provenance. Ambiguity is not an arrhythmia diagnosis.

## Functional verification

Run from this directory using a Python 3.10.18 environment containing the pinned functional-test versions and pinned NeuroKit source:

```sh
python -m unittest discover -s tests -v
```

Set `WALCH_SOURCE` to the inspected pinned checkout to execute its actual feature assembler. Missing optional packages produce explicit skipped tests; do not count skipped optional tests as model execution. Tests include synthetic alias/rate/weak/harmonic controls, coarse timing rejection, identity/conflict/gap preservation, rights/hash guards, actual NeuroKit calls, actual compact-model child execution, timeout/busy isolation, causal prefix invariance, actual Walch feature assembly, and deterministic CorrEncoder training/reload. Swift and Kotlin share `respiration_oracle.json` and V2 missing-RSA goldens. Raw-reader fixtures contain actual gzip/zstd NPB1 bytes; Edge checksum tests exercise actual gzip and preserve raw-uncompressed versus derived-compressed digest semantics.

No code, dependencies, datasets, model weights, or infrastructure were deployed. Independent reference cohorts, Linux/VPS benchmark, exact optional model environments, and locked-phone soak remain `NOT_RUN`/`NOT_READY`.

## Pinned offline wav2sleep package

`requirements-wav2sleep-linux-amd64.lock` pins the CPython 3.11/Linux x86_64 CPU package versions. Build the wheels in the pinned Linux image (including a wheel for the source-only `antlr4-python3-runtime` release); do not substitute macOS native wheels. The bundle builder rejects missing/unexpected/version-mismatched/platform-mismatched wheels, binds actual wheel bytes with pip `--require-hashes`, verifies upstream Python source and released checkpoint/config hashes, retains the upstream license, and records every bundled file.

```sh
python -m physiology_inference.bundle build --source /reviewed/wav2sleep --checkpoint-root /reviewed/checkpoint --wheelhouse /reviewed/linux-wheels --output /new/offline-bundle
python -m physiology_inference.bundle verify --root /new/offline-bundle
docker buildx build --platform linux/amd64 --build-context model_bundle=/new/offline-bundle -f scoring-service/Dockerfile.model .
python -m physiology_inference.checkpoint_smoke --checkpoint-root /reviewed/checkpoint --epochs 20 --output /new/smoke.json
```

Bundle checks are integrity checks, not signatures or self-issued rights/activation approvals. After installation, capture and independently review the actual environment using the worker interpreter, then supply a qualified input receipt and operator activation. The image recipe and bundle tests are implemented; a completed Linux wheel bundle/image and actual VPS resource results are not supplied. See [model/input availability and evidence](../../docs/physiology-v2/learned-model-production-candidate.md).
