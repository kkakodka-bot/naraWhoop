# Missing readings: September 18 follow-up

Release follow-up: after this audit, the user approved the Supabase upload repair.
The [deployment record](supabase-deployment-20260918.md) documents receiver version 7,
all five applied migrations, real upload recovery, and the separate client archive
defect found afterward. The audit snapshots and pre-release statuses below are retained.

The installed app's missing metrics have several distinct causes. The upload failure is now diagnosed from production logs. The beat-timing adapter and calibrated SpO2 implementation are still missing. Fixing uploads or scheduling does not by itself provide those measurements.

## Revisions and scope

- Original audit baseline: `5caa31689da0023e111beb36850d3f81d67e1be2`.
- Original physiology implementation: `5250912e5647108c548afa31b048ee4f4f6df133`.
- Starting PR 21 revision for this follow-up: `aa1ac2aba5947e05d29d2340e34c391b99677742`.
- Repair worktree: `WHOOP NARA-frequent-vitals`, branch `fix/frequent-vitals-20260918`.
- Phone: NARA 11.1.1 build 350, installed and launched on the connected iPhone. Existing application data was preserved.

Production inspection used the user's supplied credentials, read-only DigitalOcean and Supabase management requests, and explicit read-only PostgreSQL transactions. No server deployment, production write, restart, credential change or merge occurred during this investigation.

## What the live evidence establishes

The phone reported 276 measured five-minute HR windows and 46 low-motion windows. Its recent windows had 99–100% HR samples. These are dense HR observations; low-motion eligibility is a separate condition.

Build 350 identifies the failed upload stream as `rrPacketProvenance`. The phone sends it to the hosted Supabase receiver. Deployed receiver version 6 was updated at 2026-09-18 22:17:17 UTC.

In a bounded production-log query, 98 of the latest 100 receiver errors were packet-provenance upserts failing with statement timeout. All 100 matching PostgreSQL timeout entries identified SQLSTATE `57014`, `scoring_dirty_projection()` line 11, its first dynamic `FOR` query. The deployed function matches the repository's earlier calendar-ownership migration. The receiver database role has an eight-second statement timeout.

The database held 5,770 original packet receipts. A 5,000-record packet batch received at 23:39:49 UTC remained in the WAL without an ACK. The copied phone had another 10,583 packet receipts beyond that cursor. Its older R-R interval lane had advanced from 5,000 to 10,000, with another 274,845 rows pending at the captured snapshot. Transport rows are not counts of unique consecutive beats.

At 2026-09-19 01:58 UTC, all 11 inspected physiology work items for this device were pending. The latest published result was computed at 22:40:42 UTC; the physiology heartbeat's `last_poll_at` was null. This does not demonstrate an operating continuous scorer. Container state and its actual environment remain unverified without SSH access; heartbeat `started_at` alone is not proof of a running process.

The DigitalOcean VPS was active with 4 vCPUs and 8 GiB RAM. Over the three hours ending approximately 01:54 UTC, sampled CPU non-idle averaged 8.89% and peaked at 15.54%; available RAM stayed above 5.35 GiB and root-disk free space above 132.83 GiB. This rules out sustained resource exhaustion in those samples, not brief spikes or application defects. The failing hosted-Supabase transaction is separate from VPS resource capacity.

Two object-storage PUT failures were also observed. Their cause has not been established.

## Findings and repairs

| ID / severity | Requirement and evidence | Reproduction and impact | Narrow repair and regression evidence | Status |
|---|---|---|---|---|
| AV1 / P1 | Accepted packet data must remain processable. `scoring_dirty_projection()` inlined complete-row JSON conversion into the device join. | Production timeout evidence above. A local 5,000-packet batch with a larger synthetic same-owner fleet reproduced the same eight-second timeout and exact trigger location. Upload retries remained stuck on the same batch. | Migration `20260918220000` materializes changed rows and deduplicates typed owner/device identities before joins. Full semantic comparison and old/new invalidation remain intact. Original 29-device insert: 1,544 ms; repaired: 200 ms. Repaired larger fleet: 198 ms. | Fixed in source; not deployed |
| AV2 / P1 | Continuous arrivals must allow successful scoring without accepting stale revisions. | Earlier real-PostgreSQL claim/arrival/finish reproduction completed zero of 20 overlapping runs. | Migration `20260918210000` and `ScoringInputGate` provide a separate, bounded per-owner/device input gate. Contending projections roll back and retry before ACK. 305 HTTP publications completed with arrivals attempted during every run; 306 input rows and 305 immutable outputs/outboxes remained. | Fixed in source; not deployed |
| AV3 / P1 | Optional models must not prevent independent deterministic publication. | A model timeout could consume the whole input-gate lifetime before publication. | Pass the remaining budget immediately before inference, reserve 15 seconds for publication, abstain when exhausted, and cap HTTP publication time. Slow/expired-budget tests retain deterministic outputs. | Fixed in source |
| AV4 / P1 | Object ACK must follow required projection persistence. | `completeObject` marked a manifest ready before writing its signal window; duplicate completion could ACK without retrying the missing window. | Project before ready; repair existing ready manifests before duplicate intent/completion ACK. Tests fail projection, preserve archived bytes, retry identically and verify exactly one window. Include the actual manifest device in completion ACK. | Fixed in source |
| AV5 / P1 | Five-minute HRV requires an operational qualified input adapter. | `PhysiologyQuality.checkedPackets` never supplies `verifiedSpan`; `HrvWindow` computes coverage only from verified spans. Real-packet tests explicitly expect unverified timing. | Retain original evidence and abstention. A source-specific, experimentally qualified beat-clock/continuity adapter is still required; synthetic spans cannot establish hardware timing. | **Remaining** |
| AV6 / P1 | Respiratory estimates require usable timing and signal evidence. | `RespirationEstimator.fromIntervals` requires verified spans and timing precision at most 20 ms. Actual WHOOP adapters cannot meet this contract. | Same source qualification dependency as AV5, followed by synchronized respiratory-reference testing. Do not infer a waveform from mean HR or lower the gate. | **Remaining** |
| AV7 / P1 for the requested feature | Frequent calibrated SpO2 requires a qualified saturation source. | `AnalyticsEngine` deliberately returns null; the experimental byte-82 field is not calibrated saturation. | Establish a verified device-provided measurement or optical channel semantics and calibration. UI now explains the missing input rather than implying more nights will solve it. | **Remaining** |
| AV8 / P2 | Awake-rest respiration must have an implemented context path. | `DayScorer` previously supplied only qualified sleep contexts. | Add complete known-awake coverage plus existing low-motion eligibility. Unknown/off-body/sleep overlap excludes rest. Preserve timing abstention; keep awake results out of the nightly statistic. Five context tests and actual-scorer synthetic integration cover this path. | Fixed in source; real timing remains unavailable |
| AV9 / P2 | Failures must identify the stream and processing stage without exposing health data. | Clients discarded stream context; receiver returned generic `push_failed`; fixed-version errors lost diagnostics on 1.0 batches. | Trusted local stream, allowlisted stage, random correlation UUID, exact request protocol version, and safe object-lane errors on both clients. HR-success/packet-failure and retry/cursor tests preserve isolation and privacy. | Fixed in source; client installed |
| AV10 / P2 | Measurement availability and freshness must remain separate. | `newer_input_pending` hid the respiratory measurement's rejection reason; “motion-matched” described only quiet qualifying seconds. | Preserve both reasons, null values and stale provenance. Explain unverified timing, pending snapshots and SpO2 capability; label low-motion coverage accurately. | Fixed in both clients; iPhone installed |
| AV11 / P1 operational gap | The requested 24/7 server service must actually poll and publish. | Live database shows no poll heartbeat, pending work and no newer result since 22:40 UTC. | Inspect worker logs, version and database binding; repair the confirmed runtime cause, then verify sustained polling/publication. A DigitalOcean API token does not provide the missing private SSH key. | **Remaining; deployment/access required** |
| AV12 / P1 caught during repair | Acknowledged record counts must not hide duplicate-key overwrites. | Fresh review reproduced a 251-record append batch with duplicate keys across chunk boundaries: 251 ACKed, 250 stored, first value overwritten. | Validate every mapped PostgreSQL conflict key across the complete batch before quota/WAL/archive/projection. Reject duplicate numeric aliases and invalid mapped records with 422; preserve distinct R-R sequence identities. Independent reproduction confirms zero writes on rejection. | Fixed before release |

No new P0 was confirmed. These findings do not replace the original independent audit; they extend it with source and live operational evidence.

## Storage, retries and isolation

The receiver now divides append projection work into bounded statements while retaining the original immutable wire-batch identity. It archives the original batch and saves an ACK only after every projection chunk succeeds. Partial failure leaves the WAL and client cursor pending; retry uses the same natural keys. Duplicate projected natural keys must be rejected across the entire wire batch before chunking.

The gate does not block BLE/local SQLite acquisition. It can reject server projection commits temporarily, for at most the bounded worker lifetime. It uses a different lock from HTTP publication to avoid a self-deadlock. Actual input revisions, ownership checks, lease tokens, stale-worker fences and archive-outbox persistence remain mandatory. Later committed input legitimately makes a whole-day result stale again.

Migration 22 replaces a trigger function; it does not rewrite measurement rows. The PostgreSQL regressions cover metadata-only replay without revision increments, semantic changes invalidating old and new owner/device/time ranges, deletion and device-less cross-midnight edits. No device database restoration or deletion was performed.

## Verification and limits

- Swift analytics selected real-packet/HRV/respiration tests: 20 passed. Positive numerical cases use explicitly synthetic verified timing; they are not successful WHOOP measurements.
- Swift push package: 35 passed.
- Swift respiratory readback: 8 passed.
- macOS app diagnostic-message tests: 2 passed; app source compiled.
- Android affected UI/readback/transport/coordinator tests: 57 passed; a subsequent focused diagnostics/HTTP run passed 20 tests after the protocol follow-up. These counts overlap.
- Focused server context/budget/publication tests: 24 passed.
- Disposable PostgreSQL integration: 100 passed, no skips, including the expanded projection regression. PostgreSQL 18.3 locally; production is 17.6.
- Edge: 87 passed after the complete-batch duplicate-key guard; standalone `deno check push/index.ts` passed. A fresh reviewer separately ran the 24 affected receiver/object cases and typecheck.
- iOS build 350 built, installed and launched. Its persisted error attributed the failing packet stream. This is bounded device evidence, not an overnight acquisition or battery soak.
- A fresh reviewer independently checked the repaired gate, budgets, protocol versions, object retries, client null/stale handling, awake-rest isolation, projection migration and cross-chunk duplicate-key guard. Their additional real-PG check retained 5,000 distinct same-second packet IDs, preserved replay revisions and old/new date invalidation, and rejected a gate-blocked deletion without changing rows.

No target-reference ECG/PSG/respiratory/SpO2 validation, overnight soak, continuous-load acceptance, newly deployed Supabase recovery or VPS scoring deployment is established. No learned model was promoted. `ScoringApplication` still supplies no operational waveform `JobAssembler`; model configuration alone cannot make missing waveform timing or channels valid.

Evidence logs and private serialized inputs are retained outside Git under `physiology-build`, `physiology-audit/tmp` and `readings-investigation-20260918/private`. No tokens, raw health fixtures or application databases belong in the PR.

## Deployment boundary

The original instruction prohibited deployment. The reviewed source/PR and phone build are separate from a production release. Before enabling the new scoring gate, deploy its compatible receiver and object retry repair. Apply missing reviewed migrations, verify receiver capabilities and packet-batch progress, then roll out the continuously running scorer with the correct database. Verify sustained polling/publication and independent archive retry afterward.

| Capability | Implemented | Unit tested | Integration tested | Device tested | Overnight soaked | Reference validated | Deployed |
|---|---|---|---|---|---|---|---|
| Safe upload diagnostics | Yes | Yes | Local receiver/retry | iPhone 350 error attribution | No | N/A | Phone only |
| Projection performance/retries | Yes | Yes | Disposable PG + receiver | Existing failure observed | No | N/A | No |
| Bounded continuous scoring | Yes | Yes | Disposable PG + local HTTP adapter | No | No | N/A | No |
| Five-minute sampled/low-motion HR | Yes | Prior shared fixtures | Prior scorer/readback | Dense phone history observed | No | No | Phone; server follow-up pending |
| Qualified five-minute WHOOP HRV | Math and evidence retention | Yes | Synthetic timing only | No valid timing path | No | No | Incomplete |
| Qualified WHOOP respiration | Math + sleep/awake context | Yes | Synthetic timing only | No valid timing path | No | No | Incomplete |
| Calibrated WHOOP SpO2 | No qualified source | Abstention | No | No | No | No | No |
| Learned waveform models | Shadow scaffolding | Harness tests | No operational input adapter | No | No | No | No promotion |

Recommendation: **needs another engineering pass** for the requested physiological availability. The upload and queue repairs can proceed to controlled integration testing after explicit release approval; they do not make all four metrics available every five minutes.
