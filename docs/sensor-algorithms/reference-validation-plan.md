# Device and reference validation plan

Status: `NOT_MEASURED`. The fixtures prove software behavior only. This plan introduces no accuracy thresholds and authorizes no device commands, participant recruitment, production access or promotion.

## Capture cohorts and chain of evidence

Build a prospective matrix with WHOOP 4 and WHOOP 5/MG separated by hardware revision and firmware at capture, on iOS and Android, with at least two authorized owners, two devices and two independent installations. Record strap identity, device/firmware, phone model/OS, app version/build/commit, source installation, mode/settings, wall/monotonic/sensor clock relations and supported producer state before each capture. Repeat a cohort after firmware, decoder, clock policy or placement changes; today's catalogue cannot fill historical metadata.

For each cohort retain awake rest, quiet wake/reading, activity, sleep, charging, off-body, disconnect/reconnect, locked-phone/background, low-power and offline-backlog periods. Record actual observed rates/channels and gaps with bytes and independently recorded clock alignment. A command acknowledgment establishes command delivery only. Do not use undocumented/destructive sensor controls. Bound experiment duration and storage before starting; preserve raw records and exact archive receipts before pruning.

Trace each acceptance run from raw packet/object digest through durable local identity, cloud receipt, qualified decoder/proof, attempted window, result/reason/revision, authenticated score API and each native cache. Include out-of-order delivery, source/firmware switch, same-second PPG packets, conflicting replay, overlapping session/continuous IMU and account switch. Verify acquisition and ACK continue during network/model failure. Observe window event time separately from BLE receipt, local commit, cloud receipt, computation and publication.

## Reference comparisons

| Output | Paired reference and required checks |
|---|---|
| Five-minute HRV / pulse-interval variability | Simultaneous ECG with adjudicated R peaks and an eligible NN reference. Measure beat precision/recall, endpoint timing error, clock drift, RMSSD/SDNN bias, MAE and limits of agreement by accepted duration. Compare PPG pulse intervals to ECG NN as different modalities. Keep zero RMSSD, clean high variability, missing middle beat and correction burden visible. |
| PPG-derived HR | Synchronized reference heart rate/ECG on identical windows. Analyze flatline, clipping, motion, low perfusion, wear and channel disagreement; report error together with accepted-time coverage. Direct device HR and server-derived HR retain separate provenance. |
| IMU | Calibrated motion/reference logger with documented clock, axes, scale and orientation; static/gravity, known rotations/movement and overlapping recordings. Validate per-axis samples, drift, gaps and optical alignment. Do not treat activity-model agreement as physical unit calibration. |
| Skin temperature | Calibrated skin-surface reference at documented placement, ambient conditions and equilibration, with worn/contact annotations. Validate the raw-to-unit mapping, repeatability, drift and gaps. Intraday median/dispersion and overnight baseline have separate labels. No core-temperature claim. |
| SpO2 | A separately reviewed supported calibrated saturation source, or qualified optical channels and calibration with an appropriate synchronized oxygenation reference. Remains blocked until a protocol, rights and reference evidence are reviewed. No synthetic saturation values or guessed transfer function. |
| Respiration | Synchronized airflow/capnography or independently validated respiratory effort reference; evaluate rate errors, harmonics, unsupported rates, motion and coverage. Raw auxiliary respiration fields are not reference waveforms. |
| Sleep/wake, naps and stages | Independently scored PSG opportunities with synchronized 30-second labels, behavior/bed occupancy annotations where needed, quiet wake, naps, fragmented and shift sleep. Measure whole-day detection separately from staging within preselected sleep periods. Noncausal whole-night models are retrospective only. |

Split participants before generating windows. Keep repeated nights, devices, overlapping sequence context and augmentations from one participant in one split. Fit thresholds, normalization, artifact policies and calibrators only on training/development participants. Reserve an independent device/site cohort where feasible. Freeze the intended-use population, exclusions, primary metrics, subgroup error/coverage budgets and resource limits before opening held-out results. Determine cohort size by a reviewed precision/power analysis; two owners establish isolation feasibility, not physiological validity.

Report participant-level uncertainty and distributions, common-window accuracy and each method's native retained coverage, abstention reasons, duration and correction burden. Include skin tone/perfusion, age/intended population, movement, placement, firmware and pulse-irregularity strata where collected. Keep uncertain labels, unknown state and off-body periods explicit. Imported daily SDNN/vendor outputs are secondary comparisons, never five-minute ECG truth or RMSSD labels.

## Gate evidence

Store signed/versioned capture metadata, raw/reference digests, decoder/clock/units evidence, split assignments, frozen policy, code/checkpoint/preprocess/quality hashes, environment lock and evaluation outputs in an authorized evidence store. Use pseudonymous participant keys in reports; keep linkage separately controlled. Record code, weights and dataset rights independently. No accuracy promotion follows from a green replay, local test, synthetic benchmark, cached value or vendor agreement. Final statuses remain separate: implemented, functionally verified, hardware-soaked, reference-validated, target-capacity-qualified and deployed.
