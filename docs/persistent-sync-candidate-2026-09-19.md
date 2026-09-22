# Persistent sync candidate: not release-cleared

Source: PR #22, `codex/production-sync-2026-09-18`, audited and re-fetched head
`2f26b62ae685ddbcec4c539f7c5d806ce72f60cf`. The head had not moved before implementation.
Work was isolated from the original dirty checkout. PR #21 was not merged; the wrist-intent
semantics of `397a190b6f93c75501dda80e378a91493830a667` were adapted without duplicating its
already-present durability changes.

## Implemented locally

- One connection-request owner, iOS automatic reconnect option, modern disconnect callback,
  generation-bound peripheral delegates, and intentional-disconnect/account fences.
- Account/device-filtered restoration attaches before archive bootstrap. Failed restoration
  clears its reservation; radio recovery clears notification readiness. Both supported service
  families share one filtered scan. Discovery/notification errors have two retries then reconnect.
- Off-wrist release preserves current screen/continuous intent; successful submission alone
  changes the armed flag. Wrist-on does not recreate an intent that was closed off-wrist.
- A finite historical-chunk UIKit completion assertion with expiration fencing and exact-once
  cleanup, through matching ATT completion. This is not a background keepalive.
- `commitHistoricalChunk` commits decoded rows, existing dirty/debt journals, exact recovery
  evidence/raw metadata, and scope-keyed cursor in one FULL SQLite transaction. Ordinary chunks
  bypass retention/pruning. External research raw/IMU chunks retain the previous safe path.
- Optional batched presentation follows ACK authorization/submission on the ordinary path.
- Shared history/thermal/LPM admission and recovery hysteresis at worker entry points and cloud
  lanes. Existing bounded uploads continue under admission throttling; revoked consent and
  critical heat cancel them. BLE commit/ACK are not blocked by the bulk gate.
- Saved typed HTTP outcomes, terminal pauses, one refresh allowance, Retry-After, persisted
  full-jitter backoff, explicit exact-byte resume, and duplicate-response accounting fences.
  Renewal failures preserve status/code and pause; invalid receipts never authorize cleanup.
- One reused account control session and one long-lived network observer. Transfer byte estimates
  are set. Connection labels distinguish pending/restoring/subscribing and cloud terminal pauses.

## Local evidence and boundaries

| Suite | Result | Boundary |
|---|---|---|
| Connection owner, lease, pressure native | 15 passed | Synthetic macOS, no Bluetooth daemon |
| WhoopStore | 716 tests, zero failures, one skip | Disposable stores; phone-copy fixture absent |
| Historical transaction subset | 9 passed, included above | Legacy 3 commits versus new ordinary 1; FULL WAL and reopen integrity |
| NoopPush | 82 passed | Includes admission-before-scan and between-lane tests |
| Cloud queue/outcomes native | 49 passed | Fake transport; fail-closed credential/SyncEngine stubs |
| Hosted app focus | 72 passed | Debug macOS, hermetic host, Bluetooth disabled |
| Local receiver/object suite | 72 tests and 55 steps passed | Loopback PostgreSQL/PostgREST, pinned Deno 2.5.6; existing synthetic sender exports |

Source hashes and build SHA belong in each run artifact. A working-tree test result is not
automatically exact-commit evidence. The candidate must be frozen and its Release build/CI rerun.
Three older hosted fixtures were corrected against the audited source: cloud debt is not scoring
debt; non-store quarantine must succeed before IMU/ACK; first persistence failure fences later
packets until a fresh session. The audited baseline was source-compared, not executed for those cases.

Reproducible native commands:

```sh
zsh Tests/PersistentSyncNative/run.sh /external/artifacts/native
zsh Tests/CloudUploadNative/run.sh /external/artifacts
swift test --package-path Packages/WhoopStore
swift test --package-path Packages/NoopPush
```

## Open implementation and acceptance gates

This is a partial implementation, not completion of the production-sync specification.

| Requirement | Remaining work |
|---|---|
| 1–5: lifecycle/restoration/GATT | Full scripted central/peripheral adapter coverage, restored-candidate failure matrix, absent-callback handling without timer-only progress, hardware latency. A delegate proxy cannot prove native callback provenance when Core Bluetooth reuses objects. |
| 5: required notification profile | Existing WHOOP 5 notification set retained; no physical captures establish a smaller required set. No experimental profile was guessed. |
| 6: realtime release | Physical stop/ATT failure, reconnect-off-wrist, device-switch and explicit continuous-capture matrix incomplete. |
| 7: lease | UIKit expiration during real suspension and complete manager-level race matrix unmeasured. |
| 8: chunk durability | External raw/IMU fsync consolidation; process-kill crash injection across every ACK/ATT boundary; on-device fsync counts and latency. Synthetic rollback is not power-loss proof. |
| 9: critical path | Complete callback/FIFO/transaction-wait/next-chunk correlation, matched before/after traces, main-actor contention measurements. No dedicated executor decision yet. |
| 10: resource policy | FIFO age/depth, lifecycle deadline, storage/network and queued-byte inputs; coverage of every maintenance loop and 2-second physical stop gate. |
| 11: retries | Initial capability/intent control requests do not yet share the complete durable response ledger; complete truncated-response/expiry/reboot matrix and a user-facing resolution action remain. |
| 12–14: payload/compression/journal | Bounded streaming immutable segments, real negotiated iOS compression, 1-vs-3 benchmarks, SQLite upload/progress/quota metadata, stable indexed outbox and set-based pruning remain unimplemented. |
| 15: scheduling | Earliest actual retry/debt wake and discretionary maintenance scheduling need completion and measurement. |
| 16: server | Async verification/debt/receipt polling redesign, deterministic verified keys/copy intents, orphan reconciliation and operational metrics remain unimplemented. No deployment performed. |
| UI | Full unified pause/progress/remaining-age and last-verified-receipt model remains incomplete. |
| Automated stress | 10,000-chunk simultaneous cloud chaos, full ENOSPC/process-death matrix, and backlog-independent RSS not executed. |

All physical release scenarios and performance thresholds are **NOT_MEASURED**: locked backlog,
three overnight runs per supported cell, 30 range cycles, locked Bluetooth recovery, genuine system
termination/restoration, offline recovery, network transitions, thermal/LPM controls, reboot,
force-quit negative control and 72-hour soak. Instruments, MetricKit, matched battery/throughput,
RSS, ACK p99, and deployed exact-receipt/account-isolation evidence are not available.

The connected phone was read-only inspected: iPhone 16, iOS 27.0 (24A435), installed NARA 11.1.1
build 354. Cached app preferences indicate WHOOP 5/MG and firmware 50.41.1.0, not a fresh strap
attestation. This installed build is not the candidate. No candidate was installed and no phone
database was copied, replaced, reset, or migrated. Device/account identifiers and health values
must not be included in public run artifacts.

## Platform limitations

Core Bluetooth provides event-driven wakes and pending connection requests, not indefinite
execution. Normal restoration is not promised after user force-quit. After reboot, protected
account storage may be unavailable until first unlock. Background URLSession and BGTask timing
remain discretionary. Local compilation and deterministic tests do not establish locked-screen,
radio, thermal, battery, production-server or oldest-supported-device acceptance.

Release disposition: **NOT_READY**. Missing evidence remains missing, not a waived PASS.
