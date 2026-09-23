# Shared contract: continuous capture → durable ingestion → VPS → visible result

Version: recovery-contract-1, 2026-09-22. Required by both implementation issues. Reconcile names with the actual integrated schema; do not create duplicate contracts merely to match this document's illustrative names.

## 1. Operating principle and scope

Restore the existing system through measured, targeted repairs. Do not rewrite the whole stack or replace the existing durable spool with a volatile streaming socket. Continuous means current eligible data progresses without waiting for a historical drain, a large row count, local scoring, or an app reopening. Protocol packet boundaries and bounded immutable microbatches remain.

All physiological inference belongs on VPS workers: PPG-to-HR, beat/HRV analysis, respiration, sleep/staging, stress, recovery/readiness/strain, personal baselines, temperature analysis, IMU-derived features and downstream physiological models. The phone still performs BLE, framing/validation, lossless decoding, provenance/time bookkeeping, durable storage, compression, auth, retry, receipt validation, cache/display and ordinary UI/timer math. Direct device-reported HR is not locally inferred HR. Edge/database integrity and authorization work is not physiological inference.

No silent feature removal to achieve zero local inference. An existing supported capability must have a working server producer and consumer. Genuine hardware/reference limitations remain explicit; unfinished implementation cannot be relabeled unsupported.

## 2. Establish one actual candidate

Resolve these separately:

| Identity | What to establish |
|---|---|
| Source | Actual integration tip; frozen executable source; changes between them; PR #22 follow-up ancestry; clean/dirty worktree boundaries |
| Phone | Installed bundle/build, embedded source/configuration identity, OS, signing/background entitlements, device/firmware, exact upload/read project |
| Ingest | Edge revision and capability flags; actual database destination; raw storage namespace; verification/index consumer |
| Database | Full migration filenames, hashes, collision/supersession mapping, required functions/triggers; not timestamp count alone |
| Compute | Exact immutable image digest/source, entrypoint/mode, database binding, algorithm selection, queue, heartbeat contract, assets/config hash |
| Consumer | Enrolled and account read routes, actual envelope schema, qualification and per-family ownership, native decoder/cache/render revision |

Obtain the user-named Mac receipts from that machine when accessible. Verify their hashes and executable provenance. Do not call unavailable files inspected. A branch-tip/document hash is not proof of the running image. Preserve dirty work and never overwrite applied migration history.

Read-only diagnosis may use normally configured authorized tools. Do not dump credentials, full environment, presigned URLs, patient values or public stable patient identifiers. Do not search for or repurpose unrelated credentials. Missing access, approval or protected workflows are stop conditions for that action, not reasons to bypass controls.

## 3. Boundary ownership for the two chats

| Boundary | Owner | Required collaboration |
|---|---|---|
| Wearable protocol, capture, BLE lifecycle, local journal, mobile upload/auth | A | Preserve agreed raw/receipt schema; ask B before changing server contracts |
| Raw verification/indexing, server migrations, queue consumers, B2 server lifecycle | B | Provide old/new compatibility fixtures to A |
| Algorithm input adapters, worker/runtime, publication/selection | B | Specify actual capture requirements; A must not invent sensor metadata |
| Native score client/decoder/cache/UI, widgets/watch/exports, ownership removal | B | A verifies raw-upload independence; coordinate shared AppModel/SyncEngine changes explicitly |
| Shared trace/contract | B maintains; both review | One version and one acceptance ledger; no competing schemas |
| Combined release/deployment | B coordinates after both branches integrate | A participates in device/lifecycle review; no independent production deployments |

## 4. Durable state machine and identity

Track acquisition, transport and computation as separate states. Use existing equivalents where available:

`received → locally_durable → upload_prepared → uploaded → raw_verified/indexed → canonical_input_ready → window_eligible → queued → claimed → computed → published → API_accepted → cached/rendered`

An upload may be raw-durable while decoding or scientific qualification is pending. Do not collapse object PUT, verified indexing, canonical projection and model readiness into one `complete` flag. A receipt must state exactly what it acknowledges.

Every immutable batch/segment retains:

- Project/environment, owner, installation, physical wearable and capture-session/generation scope. Physical wearable identity is independent of uploading phone.
- Raw schema/codec version, payload digest, byte count, source sequence/within-record ordinals, original record identities and bounds.
- Device family and capture firmware/configuration; original sensor clock, wrap/reset semantics, UTC mapping and uncertainty. Current catalogue firmware is not historical capture evidence.
- Event time and receive time separately; upload/replay time must not replace event time.
- Proven units/channels/sample rate and observed mask where known; unknown metadata stays unknown.

Deduplicate physical records across retries and authorized phones using proven source identity. Do not deduplicate solely by whole-second timestamp or concatenate possibly duplicated optical bursts. Mutable current account/device identity must never rewrite queued work.

**Durability invariant A:** wearable trim/safe-progress ACK follows the exact local durable transaction and cursor fence, not RAM append. It must not wait for cloud availability.

**Durability invariant B:** release of cloud-outbox retention/cursor advancement follows the exact authenticated server receipt required for that payload. Typed pending responses are not receipts. Pruning must also honor any remaining raw/decoder obligations. No early ACK, broad range inference or deletion of unknown records to make throughput pass.

Delivery is retryable/at least once with idempotent effects. Do not promise magical exactly-once networking. Stale callbacks, completions, leases and generations cannot mutate a replacement account/device scope.

## 5. One trace that locates the first broken boundary

Add an allowlisted structured trace, not verbose patient payload logging. Retain detailed private evidence separately from the sanitized handoff.

| Field group | Required contents |
|---|---|
| Provenance | Run ID, app source/build, worker digest, Edge/schema/contract version, pseudonymous source scope, batch/record digest |
| Capture | Sensor event bounds, clock uncertainty, receive monotonic time, notification count, sample counts by modality, actual units/rate |
| Durability | Local transaction/cursor, commit time, ACK generation/sequence, failures/storage/protected-data state |
| Mobile admission | Lifecycle/wake kind, current grant expiration, queue depth/oldest age, denial reason, upload prepare/schedule/start/end |
| Auth | Credential type, expiration metadata, refresh outcome, HTTP status/reason; NEVER token or URL contents |
| Cloud | Raw receipt, verified/indexed receipt, canonical input revision/watermark, missing/quarantined records and age |
| VPS | Selected algorithm/queue/worker process, claim/lease/attempt, start/end, input contract/hash/coverage, error class, output disposition |
| Publication/read | Immutable result revision, qualification/feature manifest, event-through/computed-at, selected API response hash, decoder/cache/render revision |

Use monotonic clocks for within-process durations and synchronized timestamps with uncertainty for cross-host measurements. Keep event age distinct from queue waiting time and compute time. Measure wearable-event → BLE-receipt/source age separately: uploading a fifteen-minute-old history record in five seconds is not fresh end-to-end capture. A queued five-minute window is not five minutes of latency if it was not yet eligible.

Do not invent a queryable CoreBluetooth per-callback execution-grant token/deadline. Distinguish explicit UIKit/BGTask expiration callbacks from conservatively bounded work during BLE event handling; record an unknown actual deadline as unknown.

Diagnostics must expose separate ages for newest sensor event, local durability, cloud raw/indexed data, selected published result and visible revision, plus **oldest outstanding** debt. A newest-only watermark hides holes and old backlog.

Classify the first missing transition before modifying code. A failed worker and a valid `insufficient_coverage` output are different outcomes. Global counts/heartbeats cannot establish that this user's selected capability progressed.

## 6. Proposed initial latency targets

These are engineering targets to establish and measure, not observed performance or universal OS promises. Freeze the actual canary targets before collecting acceptance data; document any change and rationale rather than moving goals after failure.

| Boundary | Initial target | Measurement condition |
|---|---|---|
| BLE receive → durable local append | p95 ≤250 ms | Real capture at supported rate; no unsafe per-sample fsync assumption |
| Locally durable live input → upload attempt | p95 ≤5 s | Runnable/eligible execution; includes sparse arrival cases |
| BLE receive → required cloud durability receipt | p95 ≤10 s | Healthy connected canary; foreground and locked background reported separately |
| Eligible input/window → selected VPS publication | p95 ≤10 s | Real target VPS, small admitted canary workload, queue time included |
| Publication → active-screen display | p95 ≤3 s | Foreground notification/read path; not an invisible suspended UI guarantee |
| Accessory return → notification recovery | p95 ≤30 s target | Supported relaunch/connection state, measured radio/advertising conditions |

Report p50/p95/p99, max, sample count, failures, timeouts, uncompleted work and missingness for every state. Do not silently exclude OS-deferred intervals or unfinished jobs; report total user-visible latency and the narrower app-controlled measurement separately. If the locked-background target is not achieved, record a failure/limitation and investigate—it does not become PASS by renaming the operating mode.

Window duration, capture cadence, upload cadence and result-refresh cadence are independent. Proposed five-minute HRV is a 300-second qualified observation window with a five-minute hop; record any provisional shorter estimate separately. Continuous PPG/IMU is permitted only where hardware/firmware support and actual energy measurements establish it. More VPS CPU cannot create unobserved samples.

## 7. Output and missingness contract

Each metric carries source type, unit, event/window bounds, data-through, input revision/hash, algorithm/adapter/config/model identity, quality/coverage, qualification, immutable result revision and status/reason. Reuse typed schema equivalents rather than free-form ambiguous strings.

Distinguish: available; waiting for acquisition/window; ingest delayed; verification/index pending; queued/computing; insufficient history/coverage; invalid quality; unqualified input; unsupported hardware; worker error; publication/selection error; client decode/auth error; stale last-good output.

Use per-family ownership. One unsupported sensor must not hide unrelated valid metrics. Preserve last-good authorized same-scope server results with explicit age; never let historical refresh clear today's ownership. Source authorization or algorithm/feature qualification revocation stops affected canonical display/export despite previously accepted cached ownership; retained historical evidence is not silently treated as still approved. Absolute temperature is not temperature deviation; direct HR is not PPG-estimated HR or resting HR; optical pulse intervals are not automatically ECG NN intervals.

## 8. Evidence and independent-agent checkpoints

Maintain one `acceptance.json` plus concise `HANDOFF_repair.md`. Every test/gate records exact source/artifact, command/protocol, environment, expected criterion, observed result, status and evidence path. Statuses: PASS, FAIL, BLOCKED, NOT_MEASURED, or NOT_APPLICABLE with reason. Include uncompleted tests and skipped reference fixtures. Keep source tests, synthetic tests, real local integration, deployed services, physical-device, scientific-reference and load evidence separate.

At these checkpoints spawn fresh reviewers or reviewers independent of the implementation author:

1. **Diagnosis:** at least two agents inspect lineage/runtime binding and the first failed trace boundary independently; reconcile disagreements against evidence.
2. **Before edits:** at least two review the proposed repair for durability/identity and lifecycle or algorithm-input invariants. Record explicit file ownership.
3. **After implementation slices:** independent fault-test and cross-boundary reviewers run regressions, including positive outputs. Fix material findings and rerun. Assertion-only/source-string tests cannot substitute for real boundary behavior.
4. **Before canary:** release/migration/rollback and queue/capacity reviewers verify exact combined artifacts, compatibility, budgets and stop conditions.
5. **After physical acceptance:** trace and lifecycle/energy reviewers inspect the actual capture-to-render evidence; scientific reviewer checks claims for changed methods. No agent may approve an unperformed test.

If subagents are unavailable, report that limitation and request separate review rather than asserting independence. Avoid endless report generation: reviewers must help establish or repair the first failure, not create paperwork-only gates.

## 9. Deployment and honest completion

Repository changes and safe disposable tests are the implementation scope. Production migrations, registry publication, worker/Edge deployment, model promotion, phone installation and patient-data operations require explicit authorization for the exact plan. Do not infer it from a request to write these prompts. Do not bypass protected branches or permission failures.

Before deployment: record rollback identities, retain old assets/worker configuration, verify additive schema and old-client compatibility, protect pending phone data, and define automatic stop criteria for wrong-scope data, lost receipts, nonadvancing selected outputs, rising debt and unacceptable phone resource use. Do not re-run initial VPS provisioning as a worker repair.

Once authorized, carry through deployment and physical proof; do not stop at a built artifact while claiming the original symptoms are fixed. If blocked, finish independent authorized work and state the precise missing action/access with a ready next step. Separate `CODE_VERIFIED`, `DEPLOYED_CANARY`, `DEVICE_ACCEPTED` and `PRODUCTION_SCOPE_ACCEPTED`.

The supplied report's four-worker/ten-owner local run and 750-owner scalar scheduler are not target-VPS waveform/model benchmarks. The 1,000-owner test failed. Keep a measured admission cap; broader capacity and medical accuracy remain separate qualifications.
