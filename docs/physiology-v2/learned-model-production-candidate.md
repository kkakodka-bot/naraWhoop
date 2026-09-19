# Learned-model implementation and input availability

Date: 2026-09-19. Starting PR21 head: `27156ff257115acd1d345d27c7e52f107899a8c9`.

This report describes candidate code and local synthetic execution, not production accuracy, deployment, reference qualification, or vendor equivalence. Every learned output remains shadow. No LLM estimates physiology, quality, stages or missing samples.

## Implemented candidate

The chosen released four-stage challenger is the pinned cardiorespiratory **wav2sleep** checkpoint, using its supported PPG input and retrospective inference. Selection is based on a runnable released checkpoint, inspectable MIT declarations and an explicit input contract, not network size. The adapter uses the released normalization and 1,024 samples per 30-second epoch. It rejects unknown timing, unsupported downsampling, gaps, nonfinite values and extrapolation. Softmax values are explicitly **uncalibrated**; they are not calibrated wrist-sleep confidence.

The local `feature-softmax-duration-2` learner remains a separate compact supervised challenger, not LightGBM. It requires qualified HR and motion jointly (at least 90% coverage of each epoch), preserves unknown/null-probability epochs, and does not smooth across gaps or recordings. Training standardization and transitions are training-person-only. Optional temperature calibration requires disjoint development participants and acquisitions, rejects held-out-labelled rows, and is scoped to emission probabilities—not duration-decoded posterior marginals. Synthetic PSG-shaped fixtures are not actual PSG evidence. No deployable clinical feature-model checkpoint is supplied.

Model outputs bind model/checkpoint, code, preprocessing, quality policy, input hash, owner/device/revision and causal versus retrospective mode. The Python process rejects mismatched output identities and corrupt envelopes. JVM-to-Python job hashes use a tested typed binary encoding instead of assuming their JSON float printers match. Deterministic measurements do not wait for this optional lane.

## Verified input assembly and remaining acquisition blocker

The production `VerifiedModelJobAssembler` and `JdbcAcquisitionContractResolver` consume immutable, operator-issued acquisition receipts keyed by account, device, requested start/end, input revision, model, checkpoint and preprocessing/quality-policy versions. This avoids per-user model activation. Receipt arrivals can wake waiting model jobs.

Receipts must bind exact object digests and owner/device, decoder identity, per-object capture firmware/device-family attestations and their evidence hashes, a reviewed timing/semantics/units/synchronization record, extraction offsets/strides/counts, sample rates, exact start/end coverage, optical wavelength, clock identity and boolean masks. The assembler extracts actual signed raw values; the receipt cannot supply substitute physiology. Duplicate row IDs and physical packet replays across different archive objects are rejected. Missing receipts, unsupported channel sets and missing evidence abstain.

The receipt registry is a trusted ingestion/operator boundary, not automatic proof generation. Evidence hashes identify external review artifacts; their existence does not replace hardware validation. WHOOP NPB1 decoding alone still sets waveform timing and channel semantics unverified. No qualified WHOOP receipt, sample-clock proof, wavelength proof or capture-metadata evidence was available here. Therefore current device archives do not qualify for model inference automatically. No interpolation is relabelled as acquisition.

| Input or model | Availability in this candidate | External blocker |
|---|---|---|
| NPB1 signed PPG counts and raw-object ownership/digests | Preserved and decoded | Sample clock, channel semantics/wavelength and capture attestations remain unqualified |
| wav2sleep PPG assembly | Implemented receipt-driven production adapter | Qualified receipt, shadow environment/rights approval and target-device reference cohort |
| NeuroKit PPG detectors | Implemented receipt-driven adapter; actual pinned synthetic detector calls tested | Qualified receipt and ECG-adjudicated detector/HRV evaluation |
| Verified ECG | Python comparator contract available | No proven continuous synchronized ECG acquisition in current product |
| Feature learner | Python training/calibration/inference runnable | Real person-separated PSG features/checkpoint; production feature-input assembler not supplied |
| Respiratory PPG+IMU model | Shape/timing/unit contracts available | Proven synchronized calibrated axes and released raw preprocessing; no production assembler |
| Learned respiration checkpoint execution | Not run | RR_Estimation preprocessing/environment qualification; no pretrained CorrEncoder checkpoint asserted |

## Open-model and primary-evidence comparison

| Candidate/evidence | Inputs/checkpoint/rights | Decision |
|---|---|---|
| [wav2sleep official code](https://github.com/joncarter1/wav2sleep), [released checkpoint](https://huggingface.co/joncarter/wav2sleep), [primary paper](https://arxiv.org/abs/2411.04644) | Released cardiorespiratory PPG/ECG/effort model; MIT declarations; supports missing modalities but this adapter rejects missing time | Select pinned PPG-only checkpoint for shadow execution. Do not infer validated wrist transfer from cardiorespiratory/PSG training |
| [Olsen SleepStagePrediction](https://github.com/MADSOLSEN/SleepStagePrediction) | Wrist PPG/accelerometry spectrogram approach; repository advertises pretrained example | Relevant compatibility comparator, but checkpoint identity, explicit code/weight rights and preprocessing must be resolved before adding execution |
| [SleepPPG-Net reproduction](https://github.com/DavyWJW/sleep-staging-models) | MIT reproduction code, waveform architecture | Do not equate reproduction architecture with an independently verified released clinical checkpoint; no replacement selected |
| [SleepECG](https://github.com/cbrnr/sleepecg) | BSD-3-Clause; verified ECG beat features; binary/three-class comparator | Useful comparator, not a four-stage wrist PPG model. Never split NREM into light/deep without evidence |
| [SleepFM](https://github.com/zou-group/sleepfm-clinical) | Released pretrained/fine-tuned models, PSG modalities, CC BY-NC 4.0 | Input and deployment-rights mismatch; larger model does not resolve absent channels |
| [RR_Estimation](https://github.com/kazemikianoosh/RR_Estimation) | Released H5 weights, 2,048×4 PPG/ACC at 64 Hz; MIT code | Preserve adapter but do not invent preprocessing from the example's external preprocessed pickle arrays; no actual TensorFlow inference claim |
| [CorrEncoder](https://github.com/harryjdavies/correncoder_ppg_respiration) | MIT architecture; external training signals; no released pretrained checkpoint asserted | Participant-explicit synthetic train/reload only. Waveform prediction is not a qualified respiratory-rate measurement |
| [2026 home cardiorespiratory study](https://www.frontiersin.org/journals/neuroscience/articles/10.3389/fnins.2026.1693860/full) | Chest ECG/accelerometry respiration and participant-held-out adaptation | Domain/placement and fine-tuning requirements matter; this is not validation of WHOOP optical inputs |
| [2026 PPG sleep benchmark preprint](https://arxiv.org/abs/2608.00943) | Examines dataset/task/metric effects in PPG staging | Supports evaluating end-to-end detection, participant separation and coverage, not adopting a headline epoch score as product accuracy |

These are primary author repositories/papers inspected for this candidate. Published comparator scores are not copied into a product accuracy claim. Code, checkpoint and training/evaluation data rights remain separately reviewed gates; an upstream MIT declaration is not a completed deployment review.

## Actual released-checkpoint execution

Verified downloaded artifacts:

- Upstream source: `278e30463c8149c4e6899b8784da492fec695bd9`.
- Checkpoint revision: `8b6e46ab3ef6e3945282b81f631933c59db0b205`.
- `state_dict.pth`: 9,666,562 bytes, SHA-256 `ea6fb4410315cf6cce406fe1ffd44cba83e8dc69be6a69101aff62cc2cbee0bc`.
- `config.yaml`: SHA-256 `b92f4e26f3290f5207b53be343d82a4e338968b54782718f13429e800f114509`.
- Pinned upstream Python-tree digest: `e1edae588d341025a78911a71f9c2b9329f4e08a0e4c174d5b4062006aa6eb7a`.

`python -m physiology_inference.checkpoint_smoke` loaded these actual weights on CPU, scored 20 synthetic 30-second PPG epochs twice, required byte-identical structured output, and rejected a false observed-mask sample. The first development run on macOS arm64/Python 3.11.13 took 2.636 seconds wall/1.465 seconds CPU for both runs and reported process peak RSS 346,521,600 bytes. This is a development-host diagnostic on 10 minutes of synthetic input, **not** overnight throughput, actual VPS capacity, or accuracy. Exact-final-head execution belongs in the final test ledger; the smoke report records its runtime implementation hash.

Local external artifacts for reproducibility (not committed weights or user data): `/Volumes/Untitled/physiology-build/pr21-wav2sleep.qCdQKo/`; source checkout `/Volumes/Untitled/physiology-v2-baseline.ROUXBD/wav2sleep-source`. No activation or canonical promotion was generated.

## Packaging, execution isolation and resource readiness

The offline bundle builder verifies released source/checkpoint hashes, requires an exact Linux CPU wheel-version inventory, emits wheel-hash-pinned installation requirements, preserves the upstream license and inventories every file. The combined JVM/Python model-worker recipe pins Linux/amd64 JDK, JRE and Python images. An installed environment still needs capture and independent review; a bundle integrity hash is not an approval signature.

The dedicated SQL model queue, leases, retries, cancellation/revision fences and deployment recipe are separate from deterministic scoring. Per-model jobs do not wait on another model's inference. Worker output remains shadow. Serial and concurrency benchmark tooling reports latency, CPU, throughput and dedicated-cgroup memory separately from RSS, with no qualification from an unreviewed host.

Linux packaging preflight subsequently built and verified all 33 pinned CPU wheels, installed them offline with no broken requirements, and ran the actual checkpoint twice successfully under Linuxamd64 emulation. Repeatability is within each environment; cross-platform byte identity is not claimed. The combined JVM image build was cancelled during Kotlin compilation when the shared local Docker VM became unresponsive with 96% disk utilization. No completed combined image or actual-VPS run is claimed. See [exact preflight commands, identities and cleanup](linux-model-packaging-preflight.md).

Remaining resource blocker: rebuild the combined image on an adequately provisioned build host after final integration, then measure actual-VPS resources. Actual-VPS access, representative qualified inputs, independently frozen budgets, dedicated cgroup accounting at concurrency 1 and 2, and ingestion/database headroom remain required before deployment approval.

## Scientific validation and release state

No synchronized ECG with adjudicated beats, PSG with independently timestamped opportunities, or airflow/capnography/qualified effort cohort was available for this work. There are **no measured product accuracy numbers**, retained-coverage estimates, subgroup results, calibrated wrist probabilities or promotion approvals. Freeze a person-disjoint policy before viewing held-out data; fit preprocessing/quality thresholds, feature selection and calibration on training/development people only. The repository reference harness provides the evaluation path; vendor agreement can only be secondary evidence.

| Feature/model state | Code/unit evidence | Integration evidence | Device/overnight/reference | Publication/deployment |
|---|---|---|---|---|
| Verified raw model input | JVM adapter and adversarial tests | Receipt registry/queue integration candidate; exact-head suite in final ledger | Missing qualified device receipt | Shadow-only; not deployed |
| wav2sleep four-stage challenger | Real released checkpoint execution on macOS and Linuxamd64 CPU, deterministic repeat, gap rejection | Offline Linux package/install checked; combined JVM image incomplete and VPS pending | No device acquisition or PSG qualification | Shadow-only; not canonical/deployed |
| Compact feature challenger | Training, disjoint calibration, unknown and identity regressions | Synthetic child-worker inference | No real trained cohort/feature assembler/overnight evaluation | Shadow-only; not canonical/deployed |
| Other learned respiration/staging adapters | Contract and selected synthetic tests only | Model-specific missing contracts/dependencies remain explicit | No qualified target/reference execution | Inventory/shadow; not canonical/deployed |

Code completeness, acquisition readiness, scientific validation, deployment readiness and canonical promotion are separate statuses. The implementation does not close the documented external gates.
