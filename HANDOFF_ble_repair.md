# BLE repair handoff

BLE is implemented in this same repair effort and integrated with VPS source. Original BLE tip `e2cb1f8ab15d302f07f416b8d017ae4b33003ac3` and subsequent Apple/Android capture, StandardHR archive, Oura and native cache fixes descend from reviewed common base `76f2d70f621de91268e295ebcb6c6da29162991f`.

Combined candidate `405ee1b6a6238e7f4c77e2e2f8274d01f524e5f2` has passed the narrow operational candidate checks; the stale capture/oracle expectations and native harness comparisons are repaired. Final matched artifacts, both local computed-result chains and independent reviews passed. Full supported producer parity and physical acceptance remain incomplete. The original incident remains OPEN. [Shared handoff](HANDOFF_repair.md), [server handoff](HANDOFF_server_repair.md) and [single acceptance ledger](docs/server-repair/acceptance.json) distinguish source/runtime proof from physical acceptance. Historical8d artifacts remain NOT_CANARY_READY.

## Implemented behavior

- Scoped WHOOP live batches commit exact raw archive, decoded rows and cloud debt in one FULL SQLite transaction. Raw failure rolls back decoded rows/debt. Historical local commit-before-ACK remains intact. Preclock bytes remain archive-only, with no manufactured decoded clock or waveform qualification.
- Capture drains use bounded snapshots, explicit per-device standard-HR counts and cooperative expiration checks. First-item local coalescing is 200 ms as an engineering default. Real callback/lifecycle/restoration opportunities own one original finite two-second budget; arrivals cannot extend it. Generic standard-HR callbacks retain captured owner/generation, and retired writers retry only their original stores.
- Swift fresh scalar delivery has a 300-second original-timestamp window, at most 128 rows/64 KiB, an independent receipt-backed cursor and domain-separated UUID. Weighted admitted turns revisit HR/gravity while other fresh, mutable, raw and historical lanes retain service. Partial legacy inventory no longer hides registered devices. Prepared bodies survive process death and preserve exact receipts.
- Android implements the same fresh UUID/body golden, independent durable progress, exact bounded pending bytes and owner/endpoint fences. Retry survives source retention, rowid reuse and process restart. Ordinary history still owns its complete cursor and pruning. Device scheduling and retained cycle failures commit together. The live relay coalescer is three seconds; WorkManager remains an eventual scheduler.
- The Apple durable queue now recovers transient credential refresh debt and renews genuinely expired signed intents without changing immutable identity. Repeated unchanged-credential/fresh-URL rejection remains bounded. Ready transfer/control work can progress during healthy capture/history with bounded slots.
- A small Apple request may use one ordinary URLSession attempt inside an observed opportunity. The same journal owns ordinary/background task mapping, negative/disjoint logical IDs, receipts and pruning. Absolute deadline expiration retires the exact attempt before background fallback; lost-process tasks replay retained bytes. Old OS-owned background tasks are never duplicated to obtain a latency claim.
- Android distinguishes known signed URL expiry from account authorization rejection; it retains bytes and obtains a new intent on a bounded retry. Storage PUT error bodies are not materialized. Real nonexpired rejection remains a failure.
- Test Centre exports fixed-memory application interval histograms, maximum duration, every outcome, unfinished work and missing clock/overflow counts. Quantiles are explicitly bounds over valid-clock completed intervals including failures. Events and earlier processes are excluded; this cannot stand in for BLE-to-durable, total OS latency or rendered display evidence.

- Generic Huami/FTMS/Oura callbacks now atomically retain exact opaque bytes, decoded eligible scalars and cloud debt with captured owner/device/session/sequence. Host receipt time remains explicitly unverified event time. Raw capture is not a physiological adapter.
- StandardHR original receipts remain byte-identical. Final-hosted RR projection is excluded; a bounded durable scan adds raw archive debt for already-projected historical receipts, with stable owner/session/sequence progress, transaction rollback and receipt-pruned idempotency. Fresh upload remains independently runnable.
- Android resumes only the same held capture instance after both durable and retained projection drains; retirement/replacement and cloud-wake errors cannot cause a wrong-scope restart. Local queue capacity and process-loss before commit remain explicit limits.
- Final-hosted Oura derived HR/sleep calls are guarded. Raw words/contact/direct HR still work. Native offline and same-hash caches apply SQL129-compatible read eligibility without altering original archive evidence.

## Historical development validation

Exact receipt paths and hashes: `docs/ble-repair/development-receipts.json`.

| Check | Result |
|---|---|
| Actual app capture host | 126 passed |
| WhoopStore | 889 tests, zero failures, one optional copied-phone fixture skipped |
| Standard-HR durability/crash | 46 passed |
| Resource/lifecycle | 44 passed |
| NoopPush fresh/history | 152 passed |
| Real GRDB/prepared receipt adapter | 43 passed, zero skips; historical build-371 SQLite was read-only |
| Cloud upload/auth/ordinary-session | 99 passed |
| Android push/actual Room | 146 passed, zero skips |
| Interval diagnostics | 4 passed |
| iOS simulator | Compile-only passed; no phone installation |

Old production behavior was reproduced with failing capture atomicity/drain, queue auth/URL, Swift backlog and Android backlog/URL tests before repair. Peer review found and fixed standard-device starvation, unfair short-wake lane rotation, legacy workout preflight and telemetry missingness issues. These are original BLE-branch development checks; later source-bound capture/archive/cache receipts and final combined checks are recorded separately in the shared ledger.

Reproduction: `Tests/PersistentSyncNative`, `Tests/StandardHRDurableCaptureNative`, `Tests/GenericCaptureNative`, `Tests/CloudUploadNative`, `Tests/ServerFixtureNative`, `Tests/SyncIntervalNative`, `Tests/BLEPushAndroid`, and the actual app-host capture suite recorded in its receipt. Android's existing explicit AndroidKeyStore boundary shadow is not proof of physical encrypted persistence.

## Remaining work and acceptance

`docs/ble-repair/CAPTURE_IMPLEMENTATION_AND_LIMITS.md` records actual source paths and clock/qualification limits. Huami, FTMS and Oura exact-raw persistence is implemented and tested on Apple/Android. Qualified server numerical adapters for those raw streams remain engineering work. Missing acquisition/scientific evidence is not unsupported hardware. No new sensor rate, optical wavelength, IMU equivalence, beat timing, SpO2, calibration or model qualification was fabricated.

Physical firmware/mode/modality rates, bytes/second and phone/wearable energy are NOT_MEASURED for this candidate. The 128 MiB outbox admission SUM remains a capacity concern to measure with realistic debt. The coalescing and slot limits are engineering limits, not observed latency/energy budgets.

Signed iPhone build373 is installed in place over build371 and launched on the original iPhone16 without uninstall, reset, re-signing or enrollment reset. App data-container identity was not captured before installation, so the receipt does not independently prove byte-for-byte container preservation. Remaining acceptance is: real numerical API/cache/UI readback with zero local physiological calls; ten-minute positive control; at least four elapsed locked hours; actual 24-hour and 72-hour soaks; range/permissions/reboot/first-unlock/force-quit negative controls; multi-owner/device isolation; and authorized target-VPS workload capacity. Total OS deferral belongs in user latency. The 1,000-user capacity claim remains unsupported.

## Rollback and authority

Old `33a38c...`/build371 and the common-base phone cannot decode freshAppend debt; older releases also lack the current durable journal/transport mapping. Do not downgrade, reset, uninstall, delete pending files or clear cursors to recover. A signed forward recovery build must retain the new fresh identity/progress, transport-kind/task-ID and Android pending-byte readers. Otherwise stop the candidate and preserve data until a compatible recovery artifact is reviewed. Server rollback must likewise preserve queues and immutable results; the old local-DB worker is not a compatible hosted selected-v1 rollback.

The user explicitly authorized the in-place iPhone build373 install and launch, which completed. No production migration, Edge/worker deployment, registry publication, Watch install, reset, promotion, remote message or main merge occurred. The remaining [exact matched deployment/rollback plan](docs/server-repair/deployment/review/MATCHED_DEPLOYMENT_APPROVAL_405.md) and [sealed inputs](docs/server-repair/deployment/review/approval-plan-seal.json) still require explicit authorization before server execution. Normal account/enrollment authentication and private registry access remain prerequisites.
