# Agent instructions: naraWhoop physiological analytics upgrade

This file accompanies `spec.md`. Use it for the implementation project, alongside the repository's existing instructions. It is not a replacement for `CLAUDE.md`, `docs/SCOPE.md`, existing nested guidance or BLE safety requirements. If adding it to a checkout that already has an `AGENTS.md`, merge the relevant scoped guidance instead of overwriting it.

## Mission

Implement the sleep/wake, naps, sleep-stage, five-minute HRV and respiratory-rate upgrade described in `spec.md`. Keep steps/calories, recovery-score redesign, apnea diagnosis, unrelated UI redesign and patient alerts out of scope. Existing motion features may be consumed without changing their algorithms.

Deliver reliable inputs and honest uncertainty before stronger models. Finish authorized implementation, fixtures, offline validation and reviewable changes. Do not claim accuracy, hardware success or deployment without evidence. Missing PSG/ECG/reference data blocks accuracy promotion, not implementation of adapters and the benchmark harness.

## Starting state

Research baseline: `kkakodka-bot/naraWhoop`, PR 16 head `5caa31689da0023e111beb36850d3f81d67e1be2`; main `34fc950f03199b9d26e5019311394cb49cc34c7c`; PR 15 head `331f339bda78cc739c849cf3a43e3ba4a8722696`. Both PRs were open when reviewed on 18 September 2026. Re-fetch current status and compare changes before coding. Do not silently build on an obsolete branch or assume the deployed version.

Read, once: `CLAUDE.md`, `docs/SCOPE.md`, `docs/CONTRIBUTING.md`, `scoring-service/README.md`, relevant migrations and `spec.md`. The fork has a Supabase/B2 receiver and Kotlin scoring service. Do not recreate the retired Node API. Never edit generated kernel copies under `build/synced-main`; the scoped kernel derives from Android sources.

Uploaded documents may be stale. In particular, do not assume `RrCorrection` exists because an attachment describes it, or assume a raw waveform model has continuous input because the strap contains optical sensors.

## Team structure

The lead owns the integration branch, contracts, work-package ordering and final evidence. Delegate bounded tasks with disjoint file ownership. Each implementation agent reports changed files, behavior, exact test commands/results and remaining risks. An independent reviewer must inspect code and counterexamples, not merely summarize the implementer's report.

| Agent | Ownership | Required output |
|---|---|---|
| Acquisition/provenance | PR 15 reconciliation, decoder/store/export, signal inventory | Packet-to-server fixtures, schema compatibility, canonical source/timing contract. |
| Server/persistence | Queue, leases, revisions, windows, result RPC/schema and archives | Concurrency/replay tests, atomic episode replacement, version/source promotion. |
| HRV/quality | Shared continuity/quality and five-minute estimators | Observed/corrected metrics, anomaly separation, baseline fixtures and reference comparison. |
| Sleep/context | Full-day episodes, sleep/wake/staging, missingness, manual edits | Four-stage plus unknown contract; nap/quiet-wake tests; model adapter. |
| Respiration/models | Respiratory baseline, raw signal adapters and learned candidates | Reproducible model manifests, coverage/error comparisons and failure isolation. |
| Independent auditor | Cross-cutting correctness, leakage, licenses and claims | Ranked findings with exact code evidence; adversarial regression cases; release recommendation. |

Share the DTO/quality/revision contracts before parallel edits. Complete W0 and W1 prerequisites first. W2 and W3 may then proceed in parallel against the agreed contract; waveform W4 depends on proven raw inputs. W5 promotion depends on target-reference evidence. Keep PRs focused enough to review independently.

## Non-negotiable invariants

1. BLE ingestion and durable local commit do not wait on network or model inference. Preserve ACK and raw retention semantics.
2. No unsupported WHOOP 5 legacy-unit conversion, mixed-transport beat train, deduplication by numerical interval equality, or manufactured subsecond timestamps.
3. No observed RMSSD difference without three consecutive accepted original beats. Preserve pair masks, original/corrected identities and gap reasons. Count corrections cumulatively across passes; correction cannot fill acquisition outages. Never substitute inverted mean HR for beat timing.
4. Signal quality, state/context and baseline deviation are independent. Keep measurement_valid separate from baseline_eligible. Sleep-model HRV features must not require a sleep classification first. Clean elevated HRV remains valid; ambiguous rhythm must not imply good recovery.
5. Missing signal is null/unknown, never zero/light sleep. Genuine zero RMSSD remains zero. Distinguish sleep_unstaged, supported by qualified binary sleep evidence, from state_unknown. Only the former contributes to sleep totals; a “not wake” predicate is insufficient.
6. RMSSD, SDNN, PPG-derived variability and ECG-derived NN variability retain their names, units, duration and modality. Imported vendor outputs are separate sources.
7. All derived outputs identify device, input revision, algorithm/checkpoint/preprocess/quality version, time coverage and computation mode. Replays are deterministic and idempotent.
8. Stale lease holders cannot publish, clear another lease or overwrite newer results. Renew running leases and claim only runnable work. New valid data remains processable after any number of successful revisions; waiting for data is not a failure storm.
9. Main-night groups, naps, manual boundaries/tombstones and generated episodes have explicit ownership. Rescoring cannot accumulate superseded sessions or erase manual edits. Cached results and in-flight requests are owner-scoped and cannot survive an account switch into another user's view.
10. No phone background timer SLA. Measure event-time coverage and end-to-end freshness; show stale data honestly.
11. No LLM in numeric measurement, stage assignment or quality gating. Heavy models remain shadow until validated.
12. Code, weights and datasets need separately documented rights and hashes. Do not copy restricted code assuming process separation removes obligations.

## Build and test workflow

Use the repo's current toolchain and workflows. Commands below are starting points, not permission to declare success without running them:

```bash
cd scoring-service
./gradlew :analytics-kernel:test :service:test
```

For changed Swift packages, run `swift test` in the relevant package on a supported host; for changed Android logic, run the relevant `testFullDebugUnitTest` targets. Follow repository app-build guidance for UI/app changes. For Edge modifications, run the required suite:

```bash
cd supabase/functions
deno test --allow-all tests/
```

Add meaningful behavior tests for the explicit defects in `spec.md`. Use disposable/local Postgres for migrations, RLS, concurrent leases, revision ordering and session replacement. SQL-string assertions alone cannot prove database semantics. Keep tenant isolation and authenticated user reads covered. Never reset linked production.

For Python inference, pin dependencies and seeds, validate native-rate-to-model adapters and reject unsupported channel/shape combinations. Test real reference fixtures as well as malformed/gapped data. Benchmark the actual target server with bounded threads and concurrency; do not assume a GPU. A failed model must not block independent metrics or other users.

Run shared numerical fixtures across Swift/Kotlin/server for deterministic fallback changes. Learned server models need stable output contracts, not forced byte parity with an older heuristic.

## Required adversarial cases

* Legacy versus widened PPG schema; multiple records per second; duplicate packet replay; source switch; unknown interval units; suspect clocks; out-of-order arrival.
* Two cleaned intervals inside an otherwise empty five-minute window; dropped middle beat; long dropout; equal consecutive intervals; true zero RMSSD; clean elevated variability; heavily corrected or ambiguous rhythm.
* Empty/gapped sleep input versus qualified sleep with unknown stage; mixed sleep/wake HRV windows; quiet awake in bed; phone-use annotation; afternoon nap; shift sleep; fragmented main night; DST/travel; manual edit/delete followed by late data.
* Weak RSA; harmonic confusion; unsupported respiratory rate; low perfusion/motion; wrong PPG wavelength; misaligned IMU; raw objects absent or corrupt.
* More than 300 successful revisions; failure retry exhaustion for one revision; new data after exhaustion; competing workers; expired/stolen lease; newer result before older retry; cross-midnight invalidation; archive failure and independent retry.
* Two devices for one user; two users; model promotion/rollback; cached stale result; sign-in/configuration absent while server mode is enabled.

## Scientific validation and reporting

Split participants before windows. Fit thresholds, normalization, feature selection and calibrators only on training/development data. Prevent future context leakage in online estimates and sequence overlap across evaluation splits. Keep PSG detection performance separate from staging in preselected sleep windows. Compare accuracy and retained coverage together, with participant-level uncertainty and intended-use subgroups.

Use ECG for HRV reference, PSG for stages, and synchronized respiratory reference for respiratory rate. Vendor agreement and parity tests are secondary evidence. Freeze the promotion policy before held-out evaluation. No invented reference labels, numerical performance claims or “validated” badges.

At each work-package handoff provide:

* What changed and why, with commit/files and migrations.
* Exact tests executed and results; distinguish not run, blocked and failed.
* Coverage/error/resource evidence and manifest versions where applicable.
* Open defects, unavailable inputs and the next concrete action.

Final report must separate **implemented**, **functionally verified**, **hardware-soaked**, **reference-validated** and **deployed**. Preserve a versioned rollback path. Do not promote a model automatically because it is newer, larger or matches a vendor's aggregate score.
