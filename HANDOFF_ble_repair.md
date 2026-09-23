# BLE repair handoff

**Pre-canary update:**8d173cde artifacts are retained as exact historical identity evidence, not an approved candidate. Independent review reproduced unguarded Oura local inference; isolated repair `b164672310d1a3aaa6988532bdecea99b1e96bdc` passes its actual callback/reference tests. One-owner/device intake+baseline admission is also being implemented with additive migration128. Both changes require new integration, tests and matched builds before approval.

The WHOOP/custom and standard-HR capture paths now commit scoped data durably and give fresh cloud delivery bounded service while history remains owed. This is implemented and tested development source, not physical continuity acceptance. The original incident remains OPEN.

This branch starts at reviewed common base `76f2d70f621de91268e295ebcb6c6da29162991f`. Integrate it with VPS source `92c337a3168ed224bebfabc271fd4b5dd355b256`, then use one new combined SHA for migration/Edge/intake/workers/phones. The shared contract is `docs/server-repair/02_SHARED_CONTRACT.md`; the sole operational acceptance ledger is `docs/server-repair/acceptance.json` in the combined repair worktree. Development receipts below are evidence, not another acceptance ledger.

## Implemented behavior

- Scoped WHOOP live batches commit exact raw archive, decoded rows and cloud debt in one FULL SQLite transaction. Raw failure rolls back decoded rows/debt. Historical local commit-before-ACK remains intact. Preclock bytes remain archive-only, with no manufactured decoded clock or waveform qualification.
- Capture drains use bounded snapshots, explicit per-device standard-HR counts and cooperative expiration checks. First-item local coalescing is 200 ms as an engineering default. Real callback/lifecycle/restoration opportunities own one original finite two-second budget; arrivals cannot extend it. Generic standard-HR callbacks retain captured owner/generation, and retired writers retry only their original stores.
- Swift fresh scalar delivery has a 300-second original-timestamp window, at most 128 rows/64 KiB, an independent receipt-backed cursor and domain-separated UUID. Weighted admitted turns revisit HR/gravity while other fresh, mutable, raw and historical lanes retain service. Partial legacy inventory no longer hides registered devices. Prepared bodies survive process death and preserve exact receipts.
- Android implements the same fresh UUID/body golden, independent durable progress, exact bounded pending bytes and owner/endpoint fences. Retry survives source retention, rowid reuse and process restart. Ordinary history still owns its complete cursor and pruning. Device scheduling and retained cycle failures commit together. The live relay coalescer is three seconds; WorkManager remains an eventual scheduler.
- The Apple durable queue now recovers transient credential refresh debt and renews genuinely expired signed intents without changing immutable identity. Repeated unchanged-credential/fresh-URL rejection remains bounded. Ready transfer/control work can progress during healthy capture/history with bounded slots.
- A small Apple request may use one ordinary URLSession attempt inside an observed opportunity. The same journal owns ordinary/background task mapping, negative/disjoint logical IDs, receipts and pruning. Absolute deadline expiration retires the exact attempt before background fallback; lost-process tasks replay retained bytes. Old OS-owned background tasks are never duplicated to obtain a latency claim.
- Android distinguishes known signed URL expiry from account authorization rejection; it retains bytes and obtains a new intent on a bounded retry. Storage PUT error bodies are not materialized. Real nonexpired rejection remains a failure.
- Test Centre exports fixed-memory application interval histograms, maximum duration, every outcome, unfinished work and missing clock/overflow counts. Quantiles are explicitly bounds over valid-clock completed intervals including failures. Events and earlier processes are excluded; this cannot stand in for BLE-to-durable, total OS latency or rendered display evidence.

## Development validation

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

Old production behavior was reproduced with failing capture atomicity/drain, queue auth/URL, Swift backlog and Android backlog/URL tests before repair. Peer review found and fixed standard-device starvation, unfair short-wake lane rotation, legacy workout preflight and telemetry missingness issues. These are development checks; clean combined-source build/replay remains a separate gate.

Reproduction: `Tests/PersistentSyncNative`, `Tests/StandardHRDurableCaptureNative`, `Tests/GenericCaptureNative`, `Tests/CloudUploadNative`, `Tests/ServerFixtureNative`, `Tests/SyncIntervalNative`, `Tests/BLEPushAndroid`, and the actual app-host capture suite recorded in its receipt. Android's existing explicit AndroidKeyStore boundary shadow is not proof of physical encrypted persistence.

## Remaining work and acceptance

`docs/ble-repair/CAPTURE_IMPLEMENTATION_AND_LIMITS.md` records actual source paths and clock/qualification limits. Experimental Huami, FTMS and Oura universal exact-raw persistence remain engineering work. Missing acquisition/scientific evidence is not unsupported hardware. No new sensor rate, optical wavelength, IMU equivalence, beat timing, SpO2, calibration or model qualification was fabricated.

Physical firmware/mode/modality rates, bytes/second and phone/wearable energy are NOT_MEASURED for this candidate. The 128 MiB outbox admission SUM remains a capacity concern to measure with realistic debt. The coalescing and slot limits are engineering limits, not observed latency/energy budgets.

Required approved acceptance remains: matched signed installation without reset; real numerical API/cache/UI readback with zero local physiological calls; ten-minute positive control; at least four elapsed locked hours; actual 24-hour and 72-hour soaks; range/permissions/reboot/first-unlock/force-quit negative controls; multi-owner/device isolation; and authorized target-VPS workload capacity. Total OS deferral belongs in user latency. The 1,000-user capacity claim remains unsupported.

## Rollback and authority

Old `33a38c...`/build371 and the common-base phone cannot decode freshAppend debt; older releases also lack the current durable journal/transport mapping. Do not downgrade, reset, uninstall, delete pending files or clear cursors to recover. A signed forward recovery build must retain the new fresh identity/progress, transport-kind/task-ID and Android pending-byte readers. Otherwise stop the candidate and preserve data until a compatible recovery artifact is reviewed. Server rollback must likewise preserve queues and immutable results; the old local-DB worker is not a compatible hosted selected-v1 rollback.

No production migration, Edge/worker deployment, promotion, phone install/reset/launch, remote message or main merge is authorized by this implementation. Present exact combined artifacts and a matched deployment/rollback plan for explicit approval before those actions.
