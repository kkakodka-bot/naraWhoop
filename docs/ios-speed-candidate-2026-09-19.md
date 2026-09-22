# iOS speed candidate: bounded optimization, not release acceptance

Base: PR #22, `279383a0ef505f43a318d1d67596cdd9c4bfe835`, rechecked open and non-draft. Work is isolated on `perf/ios-snappy-cloud-20260919`; the original checkout and connected phone's data are unchanged.

## Implemented

- Open and hydrate the account-owned score cache before archive preparation, local-history refresh or debt draining. Foreground cloud reads wait for that initial cache attempt. Failed storage does not invent a cache or reset data.
- Prioritize the selected day. Coalesce overlapping reads and receipt invalidations; retain invalidations while backgrounded. Bound per-day freshness and transient-failure backoff. Explicit user refresh bypasses freshness. Foreground polling remains because receipt events alone do not cover every scoring update.
- Reuse a cookie/cache-free control read session within an account generation. Account changes retire old sessions and fence results.
- Publish pending/offline/authentication/freshness status without invalidating unchanged score projections and derived chart caches.
- Hydrate bounded recent cache rows with at most one LRU write transaction instead of one per row. Exact immutable responses update metadata without rewriting payloads. Skipping eviction requires a namespace, writer-change and SQLite data-version proof; competing writes invalidate it.
- Move ordinary historical-chunk quarantine counters after ACK submission; evidence stays inside the preceding durable transaction. Reuse validated IMU decoding and sample routine ACK logs. Monotonic measurements now distinguish actual write submission from callback and post-ACK presentation time. FIFO wait and ATT completion are explicitly outside that sample.
- Gate optional V5/timestamp work under pressure. Keep one cancellable foreground post-offload tail, retain pending requests through cooldown, and preserve durable debt for OS-owned background opportunities. Foreground delay is an optimization, not suspended-process correctness.
- Remove unused root observations, isolate Sleep's body-clock observation, retain its already-derived model, reuse liquid paths/chart gradients, and avoid rendering the blurred Sleep fallback underneath a successfully loaded UIKit photo.

BLE still stages locally and acknowledges protocol chunks only after durability. Cloud-derived scores do not eliminate on-device BLE receipt, serialization, rendering or a bounded offline cache. Chunk boundaries and serial FULL commits must not be bypassed for speed.

## Evidence and acceptance

Current-source local runs (see the exact-code manifest for build identity):

| Suite | Result |
| --- | --- |
| WhoopStore | 728 counted; 727 passed, one existing disposable-phone-database fixture skip |
| Score readback | 119 counted; 118 passed, one optional generated-server-workout fixture skip |
| Readback settings | 4 passed |
| Lifecycle / finite lease / resource policy | 16 passed |
| StrandDesign | 72 passed |
| Hosted integration subset | 119 passed before the final startup admission follow-up; exact-code rerun recorded separately |

SQL trace tests demonstrate one write transaction for a 14-day cache hydration. The prior implementation's per-row writes are source-derived baseline evidence, not a physical disk-I/O benchmark. Repeated-read tests demonstrate request admission, not measured Internet latency.

The connected cell is iPhone 16 / iOS 27.0 (24A435). Installed app: 11.1.1 (354), distinct from this candidate. Cached preferences identify the WHOOP 5/MG family and firmware 50.41.1.0; this is not fresh firmware attestation or proof of the exact variant. The current-public-iOS and oldest-supported-hardware cells remain unverified.

Evidence is collected in a private local directory (`nara-ios-speed-private.*`, mode 0700), with only a sanitized manifest eligible for public sharing. Keep subsequent locked-screen, overnight, restoration and soak artifacts there under an anonymized cell/run identifier. Raw traces/preferences may contain private data and must not be attached to public PRs.

Instruments could list the phone but could not attach by current reported PID or app name. Those attempts are not valid traces. No app installation, phone database copy/reset, account mutation, or server deployment occurred.

## Open gates and limitations

- Both corrections from the [afterward audit](../anti-slop/audit-001-2026-09-19.md) were approved and applied: the macOS missing-image fallback remains, and Sleep refresh does not serialize local work behind network readback. Rendered theme/pixel/accessibility checks remain `NOT_MEASURED`.
- Device launch/scroll/frame pacing, CPU, RSS, battery, thermal behavior, sync throughput, locked/overnight/72-hour soak, and genuine system restoration remain `NOT_MEASURED`. No percentage speedup or all-phone smoothness guarantee is supported.
- Startup IMU preparation/full local refresh still needs comprehensive pressure admission. Decorative animation loops are not yet connected to the shared resource budget; their existing Reduce Motion/LPM gates remain.
- Idle upload capability checks, bounded streaming compression, SQLite upload-journal migration, server phase redesign and remaining original PR #22 acceptance items are not resolved by this batch.
- The base's integrity CI passed, but base CI was not all green (macOS/toolchain, analytics, localization and Python checks had failures). Base evidence does not transfer to this candidate; exact-candidate CI must run separately.
- iOS schedules background opportunities at its discretion. This is not indefinite execution. Ordinary Bluetooth recovery after user force-quit is not promised. Before first unlock, protected data may be unavailable; preserve debt and retry on eligible wakes.

Release status: **NOT_READY**. A successful unsigned build or local test suite is not physical, deployed-server or release acceptance.
