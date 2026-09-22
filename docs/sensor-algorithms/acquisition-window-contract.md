# Acquisition evidence and frequent window contract

Implementation version: `capture-evidence-1`, `npb1-raw-decoder-2`, `qualified-raw-features-1`, `sensor-windows-1`.
Qualification status: no physical cohort or physiological reference is qualified by this change.

## Separate clocks

| Stage | Implemented behavior | What it does not establish |
|---|---|---|
| Acquisition | Preserve original interval words and waveform samples, source, origin and raw archive identity. Hardware/firmware/OS-at-capture belongs in the acquisition evidence. | Packet count, receipt time and requested mode are not a sample clock. |
| Delivery | Existing durable append/object paths; Android adds continuous plus session IMU membership and exact `imf1` archives. | No continuous background-network guarantee on either OS. ACK does not prove physiological validity. |
| Analysis | Closed UTC five-minute windows for HRV, PPG HR, motion and skin temperature. PPG also records 30-second quality summaries. SpO2 attempts use 15-minute windows and always return a blocked reason. | No claimed hardware rate follows from the analysis stride. |
| Result | Existing lease/revision-fenced publication. Each poll admits at most 16 closed-day updates; late evidence, revocation and raw availability changes dirty affected days. | Five minutes is the window target, not a measured end-to-end latency SLA. |

Calendar ownership fences the full window. Closed-day tick processing revises an otherwise idle active day when a new boundary closes, and performs a final close after midnight; completed days do not requeue indefinitely. Dirty-input/retry processing still uses the existing fair queue and publication fences. The current worker can revisit the full bounded day/context; see the capacity report before sizing a fleet.

## Qualification boundary

`sensor_acquisition_contracts` stores immutable, SHA-256-bound bytes for one owner, device, kind and `[start,end)` five-minute scope. Only an independently authorized database operator may issue or revoke evidence; `service_role` can read but cannot insert, update or delete it. Mobile ingestion has no self-qualification RPC. Revocation is one-way; a corrected receipt is a new immutable version. Neither this code nor its tests issue a live receipt.

The JSON contains:

- Schema and kind; exact owner/device/window; `qualification=verified_capture_metadata`.
- Capture, independent-clock and reference-capture artifact SHA-256 values.
- Hardware, firmware, OS/version, app build, capture mode, source installation and session at capture.
- An independently validated clock identifier/method and positive uncertainty no greater than 2 ms for these adapters.
- Kind-specific sample/interval identities, units, channel layout and quality evidence.

Digests bind reviewed artifacts; they are not signatures of clinical accuracy or evidence that a reference file has been inspected. The operator review, private artifact custody and reference-validation plan remain required. The table is deliberately separate from model/feature promotion authorization. A current device catalogue firmware value cannot fill missing capture metadata.

Supported adapters are narrow. Other sources return explicit reasons, not an inferred conversion:

- Beat timing: WHOOP 5/MG historical PPG interval words are re-decoded from CRC-checked original packets. Each word, including zero, remains identified by packet digest/ordinal and installation. Independently observed endpoint IDs/times and continuity groups are required. Interval duration must agree with its original units within 2 ms; duplicates, conflicts, overlapping spans, changed source and partial packets reject. Zero words have no span and retain rejected endpoint identities. No packet-receipt timestamp or mean HR supplies beat timing. WHOOP 4, standard BLE RR and ECG acquisition adapters are not newly qualified.
- PPG HR: exact owner/source-bound object hashes and record identities, one qualified optical channel, wavelength/ADC units, independently established 24 Hz/24-count one-second mapping, and aligned quiet-motion evidence. The supported adapter needs at least 90% observed time, no gap over 30 seconds, no flatline or excessive clipping, and at least 240 accepted one-second estimates across its 30-second quality segments. These are engineering abstention rules, not reference-validated clinical thresholds. Current phone acquisition paths no longer synthesize HR from PPG; genuine device HR remains separate.
- IMU: six axis-major columns of 100 signed counts with independent 100 Hz mapping, positive acceleration/gyroscope scales and `m_s2`/`rad_s` units. Emit acceleration magnitude/dispersion and gyro RMS; do not infer orientation, activity truth or calibration from the record shape.
- Temperature: source-bound scalar digest, supported captured firmware/hardware mapping to centi-Celsius, on-body evidence and plausible skin-surface values. Emit median/dispersion. Point observations do not claim continuous-duration coverage. Known off-body events/context override optical and temperature eligibility.
- SpO2: always `blocked / supported_calibrated_source_not_validated`. No red/IR ratio, arbitrary PPG channel or diagnostic byte candidate is turned into saturation.

HRV is labelled `ppg_ibi`, not ECG NN. `sdnn_5m_ms` is a five-minute statistic, never imported daily SDNN. Original RMSSD, corrected RMSSD, duration, accepted adjacent pairs, correction burden, decoder/clock versions and gaps remain distinguishable. Valid zero variability is retained. Unknown motion/contact/detector quality remains unknown; it is not relabelled clean.

## Output and cache boundary

The immutable worker payload adds `signal_windows`. Every window carries a deterministic ID, owner/device, kind/modality/unit, duration/stride, input/result revision, computed/publication/observed-through times, provenance, source/evidence, quality/preprocessing versions, coverage/gaps and an explicit measurement status/reason. `observed_through` is the last observed endpoint/sample, not the end of a requested window. Unknown coverage is JSON null; an available numeric zero is not missingness.

These windows are diagnostic shadow output. The existing score RPC appends them without changing canonical selection, removes numeric `values`, marks internally successful analysis `unqualified / not_reference_validated`, exposes its separate `analysis_status`, and compares result/required revisions for freshness. Unsupported input remains unavailable with its own reason. Stale windows retain their old revision and are explicitly stale, never silently current.

iOS and Android persist the existing raw server snapshot and expose typed diagnostic windows. Their decoders check owner/device, schema/algorithm, exact UTC duration, positive matching revisions, required-revision freshness, explicit nullable evidence fields, bounded numeric coverage and `values:null`. Shadow windows cannot authorize canonical dashboard metrics. The existing display/feature gate is unchanged; this issue does not introduce a new UI.

## Bounded work and failure

The reader selects at most 1,024 active contracts and 8 MiB of contract bytes using SQL metadata admission, newest first. Larger scopes return an explicit acquisition budget reason with the retained subset. Referenced raw metadata is limited to 2,048 manifests; the independent model discovery default remains 256. Each raw proof references at most eight objects, 300 mapped one-second records and 8 MiB each of compressed/uncompressed bytes.

Raw extraction has one daemon executor, one bounded completion-handoff slot, explicit admission that rejects work behind an active extraction, at most two seconds of synchronous wait, interruption and an LRU of 2,048 successful small feature summaries. Cache hits do not need executor admission. Keys bind the proof and only its referenced immutable manifest identities. Changed source/key/hash/shape/size invalidates reuse; unavailable or withdrawn objects cannot hit a prior successful key. Newest receipts are attempted first. Busy/unavailable/time-budget paths return reasons and deterministic scoring continues. No raw buffers are retained in the feature cache. A non-cooperative network read can occupy the one daemon until its underlying timeout; it cannot create an unbounded executor queue.

Model admission/execution stays in the existing separate bounded process path. No assets are downloaded and no activation, promotion, rights approval or evaluation accuracy is asserted here.

New or updated raw waveform indexes retain record counts but have null expected/missing record counts and temporal coverage until independently qualified elsewhere. Historical catalogue claims are not bulk rewritten by this migration and remain unqualified advisory metadata. The inventory reports event occupancy separately from verified waveform coverage.

## Validation boundaries

Synthetic tests exercise actual protocol/NPB1 bytes, production readers/decoders/scorer, disposable PostgreSQL publication/read RPCs, the real Edge handler and native cache decoders. The cross-harness replay preserves the exact worker artifact and only substitutes the destination lease/run token; evidence records its original SHA-256. This is linked local artifact replay, not a physical device-to-deployed-VPS acceptance run.

Required next evidence: authorized capture/reference cohorts, locked-phone/background and outage soak on each OS, real private object delivery/readback, target-image VPS load/capacity measurement, and a reviewed promotion decision if any future numeric output is to become canonical. No such action is authorized by this implementation.
