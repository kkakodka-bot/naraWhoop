# Sensor capability registry

The executable registry is `SignalCapabilityRegistry` inside the existing scoring service. It is an inventory, with no publication or qualification authority. A successful report means the authorized catalogue was read. It does not mean a sensor or metric is qualified. No live owner/device inventory or physical acquisition was run for this change.

## Reproduce without hardware

```sh
cd scoring-service
./gradlew :service:installDist
INVENTORY_FIXTURE=true ./service/build/install/service/bin/service --inventory-signals
```

The JSON marks every observation `synthetic_fixture`, includes four fictional device/platform cohorts and exports no person identifiers or measured physiology. Fixture mode opens no database even if `DATABASE_URL` is present. Combining fixture mode with an owned inventory scope fails.

An authorized bounded database report uses the same command, with `INVENTORY_FIXTURE` unset, explicit `INVENTORY_USER_ID`, `INVENTORY_DEVICE_ID`, `INVENTORY_DAY`, and optionally both `INVENTORY_START` and `INVENTORY_END` as whole-second UTC instants. It opens a repeatable-read, read-only transaction, checks device ownership, applies calendar ownership and rolls back. The date plus its preceding context is bounded to 76 hours. Narrower requests cannot borrow unrelated calendar periods. The command limits each scalar query to 1,000,000 source/second bins, 64 sources and 10,000 raw catalogue rows; exceeding a bound fails instead of returning a partial report. Each statement has a 15-second timeout. Save owned reports outside git; they contain scoped health metadata and identifiers.

## Evidence fields

| Field | Meaning |
|---|---|
| `current_catalogue_advisory` | Current device family/firmware and, when linked, current installation platform/app version. These are not historical capture facts. |
| `*_at_capture`, `capture_mode` | Capture-bound family, hardware revision, firmware, phone platform/OS version, app version/build and mode. Missing retained metadata is explicit `unknown`. |
| `source_installation_id` | Source retained by scalar projection or object manifest. Different sources get separate cohort entries, even for the same physical device. |
| `row_count`, `rows_per_requested_second` | Projection event density. Multiple records in one second remain multiple records. |
| `occupied_second_fraction`, `maximum_empty_second_run` | Whole-second event occupancy and empty-bin run inside the requested intervals, including their edges. Not waveform coverage or native sample rate. |
| `catalogue_sample_rate_hz`, `sample_count` | Stored object claims. `sample_count` may count packed records, not physical waveform samples. |
| `observed_sample_count`, `verified_sample_rate_hz`, `observed_time_fraction`, `verified_maximum_gap_seconds` | Null until actual bytes plus a capture-bound server acquisition proof establish samples, time mapping and continuity. The inventory does not fetch/qualify bytes. |
| `candidate_channels`, `declared_encoding_units` | Stored names/encoding only. Qualification and calibrated physical units remain separate. |
| `raw_stream_catalogue` | Objects grouped by stream and source. Record counts may overlap across objects, including session/continuous IMU, and cannot be summed into observed duration. |

The `raw_objects` array retains identity, digest provenance, format, stored decoder/version timestamps and counts. `ready`, `server_verified` or `decode_verified_at` is reported with its limited scope; none alone establishes wavelength, axis mapping, clock or calibration. Retention safety requires the existing exact-object receipt path, not this inventory. Source and raw-object identifiers remain sufficient to trace the authorized private report to receipts without exporting signal values.

## Cohort qualification ledger

| Capability | Capture evidence required | Current registry outcome |
|---|---|---|
| WHOOP 4 interval stream | WHOOP 4 firmware-at-capture, original packet identity, supported millisecond units, beat endpoints/clock uncertainty, cross-packet continuity, ECG comparison | `unqualified` when observed; no WHOOP 5 conversion or transport splice |
| WHOOP 5/MG historical interval stream | Original retained words including zero gaps, tick conversion, exact packet/word endpoint mapping, capture/source binding, continuity and ECG comparison | `timing_coverage_unverified` without separate server acquisition proof |
| Standard BLE HR/R-R | Raw notification/session/ordinal, device transport semantics and independent beat clock; arrival clock alone is insufficient | `unqualified`; original receipts separately inventoried |
| Raw PPG / VPS HR | Verified object bytes, sample ordinal clock/rate, channel/wavelength, units, gaps, contact/motion quality and paired HR/beat reference | `unqualified`; a nominal 24-count record does not establish 24 Hz |
| Raw six-axis IMU | Object origin/identity, actual samples per axis, timing, physical units/ranges, orientation, overlap and optical alignment | `unqualified`; 600 i16 values per record is an encoding fact, not six-axis timing proof |
| Skin temperature | Raw scalar mapping per firmware, emission density, worn/contact state and calibrated skin-surface reference | `unqualified`; skin and core temperature remain separate |
| SpO2 | Supported calibrated source, or a validated optical method with qualified channels/calibration and oxygenation reference | `blocked`; red/IR means, diagnostic byte candidates and arbitrary single PPG channels are insufficient |

The registry reports WHOOP 4 and WHOOP 5/MG independently. MG naming does not establish accessible ECG. No production cohort is added to a qualification allowlist. Server-owned acquisition receipts are the separate authority for exact raw inputs and windows; an inventory report cannot create those receipts.

Acquisition, BLE delivery, cloud durable receipt, VPS analysis and result publication have separate clocks. The implemented window target is non-overlapping UTC `[start,start+300)` attempts. Delivery follows actual supported acquisition and OS availability. A five-minute attempt can publish a null value with a reason, and late delivery revises affected inputs. Neither a phone timer nor an upload cadence defines hardware sampling.

Source basis: the supplied `sensor_algorithms.md` audit at baseline `7daa66a02c9c469361cf4e68d50d8743e0177173`; [`algos docs/spec.md`](../../algos%20docs/spec.md); the current `SignalInventoryReader`, `VerifiedRawObjectReader` and projection migrations. The audit attachment lives in the original `WHOOP NARA-pr16/MD FILES/evidence` workspace; the source files remain the executable contract.
