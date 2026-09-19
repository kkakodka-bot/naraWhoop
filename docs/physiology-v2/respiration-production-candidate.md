# Respiratory production candidate: engineering contract

Starting PR #21 head: `27156ff257115acd1d345d27c7e52f107899a8c9`.
This is an implementation report, not respiratory-reference qualification. All v2 results remain shadow.

## Immutable implementation identities

| Identity | Value |
| --- | --- |
| Deterministic method | `resp-spectrum-acf-2` |
| Preprocessing | `plausible-masked-linear-detrend-hann-2` |
| Quality policy | `resp-quality-2` |
| Computation mode | `windowed_retrospective` |
| Learned checkpoint | None used by this deterministic method |

These version labels must be bound to the final source/manifest digest by the release manifest. Labels alone do not authorize promotion. A learned adapter needs its own checkpoint digest and input contract; it cannot inherit deterministic qualification.

## Input availability and rejection

The RSA adapter accepts original ECG NN intervals from 250–3000 ms or PPG IBI from 250–2500 ms, before interpolation. These are conservative engineering bounds, not diagnostic thresholds. Both original endpoints, shared beat identity, continuity group, acquisition spans, and clock/decoder provenance must be verified. Duration mismatch beyond RR quantization, mixed timing, conflicting identities, source/firmware changes inside a window, malformed spans, and coarse packet-only timestamps fail closed. Corrections cannot supply missing acquisition time. Adjacent rows with a rejected shared beat or any gap are not interpolated across. Extreme repeated alternation is retained as rhythm ambiguity, not clean high HRV or respiratory modulation.

Time-aligned motion evidence must cover at least 90% of a window. Missing motion evidence is not stillness. `Contamination` carries the observed fraction, explicit contamination, known quality-rejection reasons, and evidence version. Production `ContaminationSpan` values must describe actually observed time: aggregate fractional coverage cannot be expanded into fully observed subwindows. Any known overlapping motion/contact/optical-quality contamination is preserved and excludes its affected data/window. Unavailable contact or optical evidence is not represented as measured clean evidence.

Current WHOOP history receipt paths preserve original packet words but do not establish verified beat acquisition spans; they remain `timing_unverified` for RSA. Mean heart rate is never an RSA substitute. The raw-object reader currently reports `timingVerifiedForWaveforms=false` and `channelSemanticsVerified=false` for the NPB1 payload. Therefore raw PPG modulation and IMU respiration are not activated from that payload. A qualified adapter needs proven channel identity, physical units, waveform sample rate, timestamp precision, synchronization, missingness masks, and validated signal extraction. Integer packet timestamps and unidentified ADC channels do not satisfy that contract.

## Estimation and coverage

The transparent baseline uses masked 4 Hz RSA resampling, linear detrending, Hann-window spectrum and autocorrelation. Upsampling does not expand the supported bandwidth: RSA limits derive from original interval spacing. Out-of-range rates remain unavailable with retained spectral evidence; no rate is clamped. A resolved weak fundamental below a dominant second harmonic produces `harmonic_ambiguity`; the method does not silently report the doubled peak. The engineering harmonic screen still requires held-out harmonic-error validation and can abstain on complex true physiology.

Nightly summaries require at least 1800 accepted seconds, three accepted windows, 50% union-of-accepted-time coverage, and 10% accepted coverage in each temporal third of the sleep period. One short window or a dense early island cannot represent a night. Awake-rest summaries remain separately attributed and require 120 accepted seconds. All scalar summary values are unavailable when qualification fails. Accepted-time coverage, per-third coverage, sorted accepted-window estimates, and explicit rejection reasons remain available as diagnostics. Exact duplicates do not inflate time or window counts; conflicting results and mixed source/device/firmware/algorithm provenance abstain.

Window autocorrelation and minimum accepted-window autocorrelation are signal evidence, not calibrated confidence probabilities. Conservative fusion rejects misaligned or disagreeing eligible channels and never multiplies confidence for correlated channels. The sorted estimate distribution is not a respiratory-reference distribution or an independent-sample confidence interval.

## Regression evidence and release limits

Focused Swift and shared JVM tests cover synthetic rates, unsupported bandwidth, observed-time gaps, timing/semantics, rejected shared endpoints, motion and quality evidence, impossible IBI, source changes within/across windows, malformed timing, correction over missing acquisition, tiny continuity gaps, extreme alternation, dominant second harmonics, one-window nights, early-only nights, duplicate windows, and mixed firmware. Service runner tests cover contamination span localization and non-expansion of partial evidence. Run these again on the exact release head; intermediate working-tree results are not release-head evidence.

No synchronized airflow, capnography, or validated respiratory-effort reference recordings paired with target-device inputs were supplied for this task. MAE, RMSE, bias, limits of agreement, within-2-breaths/minute rate, retained coverage, and per-participant/subgroup/motion/perfusion/harmonic strata are therefore **not measured**. A person-level train/development/held-out split, training-only threshold selection, and a promotion policy frozen before held-out evaluation are required. Vendor agreement is secondary evidence only. No device or overnight-soak acceptance or VPS benchmark is claimed by these unit tests.

Primary methodological context: respiratory variation can modulate PPG frequency, amplitude, and intensity, and accuracy must be considered alongside signal retention; see [Pimentel et al., 2017](https://peterhcharlton.github.io/publication/pimentel-2017/). That literature motivates modality-aware qualification, not an accuracy claim for this implementation. Public datasets may help method development but do not replace target-device acquisition validation.
