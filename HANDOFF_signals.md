# Sensor algorithms handoff

Status: implemented and locally verified with synthetic inputs. Physical acquisition, reference accuracy, OS soak, live delivery and target-VPS capacity are **NOT_MEASURED**. Production qualification/promotion is **NOT_READY**. Nothing was deployed, pushed, merged or model-promoted.

## Exact target

- Branch: `feat/sensor-algorithms`.
- Isolated worktree: `/Volumes/Untitled/WHOOP NARA-sensor-algorithms`.
- Implementation commit: `647b2ead564c112e37128a82b09723ab16c35bb2`.
- Base: completed local server-pipeline commit `cfb94434b1b4ed4dba587e5c4e7af405e782e560`.
- The requested remote merge could not be verified at task start: remote `main` was `34fc950`, with no published server-pipeline head/PR found. This work uses the completed local pipeline, not an asserted upstream merge. Confirm lineage before preparing an upstream PR.
- The original `WHOOP NARA-pr16` dirty checkout and supplied untracked audit/spec/evidence files were preserved.

## Delivered behavior

| Area | Implemented boundary |
|---|---|
| Capability registry | Bounded owner/device/source inventory, current catalogue versus capture metadata, raw/projection counts, event occupancy, units/channels, explicit unknown rates/gaps/qualification. Synthetic fixture mode opens no database. |
| Five-minute HRV | Original CRC-checked words and installation identity bound to independently observed endpoints/continuity; zero words retain rejected identity and no span. PPG interval variability stays separate from ECG NN; `sdnn_5m_ms` is not daily imported SDNN. |
| Android IMU | Captured-account multiplexing of continuous/session files, durable monotonic membership IDs, destination progress, exact origin-bearing `imf1` archives, replay-safe upload. Explicit user deletion tombstones cannot poison later uploads; missing files without a tombstone fail closed. Bounded scan progress is normal continuation, not failure backoff. |
| Apple IMU | Existing continuous/session acquisition/upload path preserved. No new device commands or background guarantees. |
| PPG HR | Production phone extraction paths no longer derive it. The VPS has a deterministic, proof-gated adapter with time coverage, optical/motion checks and `vps_estimate` provenance. Genuine device HR remains separate. |
| IMU and temperature | Source/clock/units-bound deterministic motion summaries and on-body skin-temperature median/dispersion. Known off-body evidence overrides optical/temperature eligibility. |
| Window results | Five-minute HRV/PPG/IMU/temperature attempts; blocked 15-minute SpO2 attempts. Stable identity, duration, source/proof, revisions, timestamps, coverage/quality and reasons; closure and late-evidence invalidation use existing fenced work. |
| API/mobile caches | Existing authenticated score RPC adds diagnostic windows. Unqualified numeric values are removed; explicit reasons/revisions survive real Edge handling and both typed caches. Existing canonical dashboard selection is unchanged. |
| Optional models | Existing isolated admission/rights/assets/reference gates retained. No model assets downloaded or activated. Failure cannot confer qualification or block deterministic scoring. |

SpO2 always reports `supported_calibrated_source_not_validated`. Diagnostic raw red/IR or candidate bytes are not saturation. The new deterministic outputs are also shadow-only until their own reference/promotion gates pass; a successful engineering decoder is not physiological validation.

## Read these contracts

- [Acquisition, clocks, windows, output and failure contract](docs/sensor-algorithms/acquisition-window-contract.md)
- [Capability registry and executable inventory](docs/sensor-algorithms/capability-registry.md)
- [Device/reference validation plan](docs/sensor-algorithms/reference-validation-plan.md)
- [Capacity report and resource limits](docs/sensor-algorithms/capacity.md)
- [Optional model gates and pinned repository assets](docs/sensor-algorithms/model-evaluation.md)
- [Native Android byte-to-receiver reproduction](supabase/functions/tests/README.md#android-local-synthetic-imu-evidence-sensor-algorithms)

## Schema and operational boundaries

The unapplied migration is `supabase/migrations/20260921120000_sensor_acquisition_windows.sql`, SHA-256 `aeb8a076e4d04a88ba0f16fb3744627259a4fbe82fd0113be77f6eb6341fde93`. All 118 catalogued migration source hashes verify locally.

It adds operator-issued immutable acquisition contracts, one-way revocation/invalidation, raw arrival/withdrawal dependencies, an owner-safe diagnostic read wrapper, bounded closed-window revision scheduling, and null temporal coverage for new/updated raw waveform receipts. It does not grant clients access to the private work queue or permission to issue acquisition evidence. Historical catalogue coverage is not bulk rewritten and remains unqualified advisory data.

No hosted schema ledger, live data, credentials, feature defaults, promotion signatures, model selection or deployments were changed. Future rollout needs an explicit reviewed migration/release plan against the actual target ledger; this handoff does not authorize applying the migration or registering evidence. Preserve raw files/outboxes/receipts and immutable results during any later rollback review.

Android membership database main-file admission is capped at 128 MiB, not total device disk usage. Raw files, WAL and metadata are separate. Discovery still reads/sorts registered headers before the 16-segment decode slice. Compaction, long backlog battery/latency, real compression, physical acquisition and multi-day soak remain unmeasured. No ACK-triggered pruning was added.

## Verification evidence

All evidence below is local and synthetic unless stated otherwise. Test counts overlap and must not be summed into a unique-test total.

- Android normal production/all-test-source compilation and focused transport/PPG tests: 140 passed, no exclusions/skips. Additional coordinator/cursor/worker/cache regression selection: 59 passed. The final Kotlin cache hardening also passed the 12-test pure cache project.
- Swift protocol: 769 total, 2 fixture skips, zero failures. Swift cache/vital regression selection: 39 passed; XML in `Packages/WhoopStore/.build/server-signal-cache-tests.xml`.
- macOS app PPG-path selection: 21 passed. Two pre-existing stale app tests were excluded by a build setting for that run (`ServerScoringRescoreSkipTests.swift`, `ExploreRangeGatingTests.swift`); this is not a full app-suite claim. Artifact: `/Volumes/Untitled/nara-ppg-tests.lG7Rqw/Logs/Test/Test-Strand-2026.09.21_18-00-13--0700.xcresult`.
- Incoming exact Android-generated continuous/session `imf1` and same-second kind-4 NPB1 bytes crossed real local PostgreSQL/PostgREST/signed object HTTP. Owner/source/origin/digests survived injected index failure, server-only recovery and duplicate retry. Expanded Edge run: 105 tests and 27 native steps passed. Documented pinned/frozen receiver command: 20 tests and 3 steps passed. Proof: `/Volumes/Untitled/android-imu-p1-tests.tINUMH/edge-pg-c3e520c4336dae/android-imu-receiver-proof.json`, SHA-256 `94f3e72e2207b1742ae3a9122b23581c89567df39f5b88b5e552b5bb60ce1082`. This receiver harness applies the exact coverage-normalizer prefix, not all of migration 120000; the separate SQL suites apply the full migration.
- Disposable PostgreSQL focused suite: 165 passed, zero skipped, including receipt permissions/revocation, source binding, actual raw decoding/scoring/publication, owner read isolation, closure revisions, late archive withdrawal and explicit unknown incoming coverage. Evidence: `/Volumes/Untitled/sensor-tools.Xxvng2/physiology-queue.2n7fzu`.
- Sensor/raw decoder/inventory unit selection: 26 passed twice with forced rebuilds after repairing the executor handoff race. Evidence: `/Volumes/Untitled/sensor-tools.Xxvng2/sensor-focused-one.vxKKz4` and `sensor-focused-two.nLktCW`.
- Full PostgreSQL migration catalogue to real Edge handler to Swift/Kotlin cache: 11 actual HTTP envelopes passed on each platform, plus 12 Kotlin cache tests. Final pinned-artifact replay: `/Volumes/Untitled/sensor-tools.Xxvng2/server-pipeline.PkhzLt` (the cache unit task reused its unchanged successful output from `server-pipeline.SuUeHl`; both actual decoder executables ran again). Synthetic worker artifacts are replayed unchanged except for destination lease/run tokens; their hashes are recorded in `decoders/sensor-*-replay-evidence.json`. This is linked artifact replay, not a deployed worker/phone round trip.
- Infrastructure source/release and migration-contract tests: 53 passed; all 118 migration hashes verified. Python local synthetic capacity helper: 2 tests passed. Its timing/RSS is not a VPS benchmark.

The broader clean-source run passed at implementation commit `647b2ead564c112e37128a82b09723ab16c35bb2`: 1,682 JVM tests total, **1,677 passed, 5 skipped, zero failures/errors**, across 216 suites. Kernel: 1,106 total/5 skipped; service including database tests: 576 passed/no skips. The fresh current-source Swift comparison-corpus exporter passed 2 tests. `installDist` passed; the script verified identical requested and packaged commit bytes and wrote `jvm-source-cleanliness.txt`.

Evidence: `/Volumes/Untitled/sensor-tools.Xxvng2/server-jvm.KPJtyf`; full disposable SQL data/logs: `/Volumes/Untitled/sensor-tools.Xxvng2/physiology-queue.c1y5rC`; exact worker/acquisition/API exports: `/Volumes/Untitled/sensor-tools.Xxvng2/sensor-fixtures-pinned`. The packaged implementation fingerprint is `608f4f79443923c8c21571efc27170f9edc4589326775451f490a2a61c72ac8a`.

The five skipped agreement/reference-data cases are `HrvGoldAgreementTest`, `HrvFreqAgreementTest`, `HrvOpticalRobustnessTest`, `RealDataRundownTest` and `RecoveryAgreementTest`. They are not reference-validation evidence. The later handoff-only commit does not change these tested implementation files.

The compiled inventory CLI also ran in fixture mode and reported schema 2, `synthetic_fixture`, `hardware_measurements=false`, `signal_values_exported=false`, `waveform_activation_allowed=false`, and reference/VPS status `NOT_MEASURED`.

## Reproduction

Use Java 17, the repository Gradle wrapper, local PostgreSQL and the checked-in tools. These commands create disposable local infrastructure; do not aim them at hosted databases.

```sh
# Actual current Swift corpus, kernel/service tests, disposable SQL, installDist,
# and packaged-source identity. Run from a clean committed source tree.
SENSOR_TEST_OUTPUT=/absolute/external/evidence/sensor-fixtures \
  bash scoring-service/scripts/test-server-jvm.sh

# Replay those exact worker artifacts through real SQL/Edge and both cache decoders.
PIPELINE_SENSOR_FIXTURES=/absolute/external/evidence/sensor-fixtures \
PIPELINE_TEST_PG_TMPFS=true PIPELINE_TEST_REMOVE_CONTAINERS=true \
  bash scoring-service/scripts/test-server-pipeline.sh

# No database or device required for the synthetic registry.
cd scoring-service
INVENTORY_FIXTURE=true ./service/build/install/service/bin/service --inventory-signals
```

Set `JAVA_HOME`, `PG_BIN`, `GRADLE_USER_HOME` and `TMPDIR` for the local environment as needed. `PIPELINE_TEST_PG_TMPFS` uses a bounded 768 MiB disposable database in memory; the cleanup option removes only the two containers made by that invocation. Logs and exported test artifacts remain outside those containers. During this task only failed disposable test containers were removed, never unrelated containers or user data.

## Remaining acceptance gates

1. Confirm the intended merged server-pipeline lineage before upstream integration.
2. Authorized real hardware captures with independently measured clock/rate/channel/unit/source evidence on each supported firmware/OS cohort.
3. ECG NN/HR, physical motion and calibrated skin-reference comparisons, held-out participant/device evaluation and reviewed quality thresholds. SpO2 needs its own supported calibrated source or validated optical method.
4. Actual iOS/Android locked-phone/background/offline/retry/owner-switch and multi-day capture/storage soak, including battery cost and durable receipt/cache readback.
5. Intended-VPS image load test with concurrent ingestion, cold/warm caches, failures and backlog drain. No capacity-supported user count or five-minute delivery SLA is established here.
6. Explicit authorization for any later schema deployment, evidence registration, model evaluation or feature-specific promotion. No model or diagnostic measurement becomes canonical from these test results.
