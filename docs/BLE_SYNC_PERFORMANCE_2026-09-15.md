# BLE history sync performance audit

Date: 2026-09-15. Baseline: PR #14 head `293fd6b84aa8f3e86f18cfab35933206aa53403d`.
The original research checkout was left untouched. This work uses an isolated checkout.
No strap commands, app installation, firmware changes, or physical tests were performed for this audit.

## Findings

### Keep the PR #11 and #12 performance fixes

The issue's initial claim that transport alone explained the latency was explicitly corrected:
the original phase counters omitted rejected-frame logging and archival. An inter-chunk gap includes
local work and queueing; it does not measure radio throughput alone.

The retained issue comments report these earlier phone observations. They were read during this audit,
not repeated here:

| Build | History seconds advanced / wall seconds | Rate | Evidence limit |
| --- | --- | --- | --- |
| 340, before PR #11 | 272 / 383 | 0.71 | Backlog grew during this window |
| 342, PR #11 | 1,222 / 319.2 | 3.83 | Short locked-phone observation |
| 342, extended window | 4,036 / 1,234.3 | 3.27 | Restarts and repeated trim separately observed; cause unresolved |
| Immediately before PR #12 | 743 / 193.9 | 3.83 | Comparison window |
| 344, PR #12 | 1,687 / 319.8 | 5.28 | About 38% faster in this short comparison |

Sources: [PR #11 correction and initial verification](https://github.com/kkakodka-bot/naraWhoop/issues/7#issuecomment-5671730264),
[extended verification](https://github.com/kkakodka-bot/naraWhoop/issues/7#issuecomment-5671919174),
[PR #12 verification](https://github.com/kkakodka-bot/naraWhoop/issues/7#issuecomment-5672068772).
The extended profile attributed 87.5% of sampled CPU time to the main thread. The subsequent comparison
reported reduced CPU samples after archive conversion and log invalidation changes. These records
support keeping the fixes; they do not prove overnight reliability or explain the current 15-hour stall.

### PR #11 redaction improvement reproduced locally

A Swift/Foundation microbenchmark ran the exact old and new possessive-device-name regex against a
synthetic log prefix followed by a hex token. Both patterns preserved the input. Each table cell is
one elapsed invocation on the development Mac, including regex setup; these are not handset timings
or an end-to-end sync benchmark.

| Hex characters | Before PR #11 | PR #11 |
| --- | ---: | ---: |
| 512 | 3.528 ms | 0.185 ms |
| 2,048 | 40.829 ms | 0.115 ms |
| 4,280 | 180.185 ms | 0.259 ms |
| 8,192 | 656.293 ms | 0.474 ms |

The unanchored greedy pattern retried suffixes of a long hex token. The new token-boundary assertion
and possessive quantifier prevent that quadratic scan. PR #11's bounded silent-offload retry only adds
one retry; no evidence here identifies PR #11 as the new failure's origin.

### Redundant record decoding remained in PR #14

Before this change, `Backfiller.ingest` fully parsed every frame to ask whether it was metadata.
`finishChunk` parsed those records again, and `rejectedHistoricalRecords` parsed mapped historical
records a third time. Large optical and IMU records therefore repeatedly paid for CRC checks and
decoded arrays before one chunk could advance.

This patch uses the existing family-aware `frameTypeName` prefilter in `Backfiller.ingest`. Ordinary
records remain buffered unchanged for commit-time decoding. Metadata still passes through the full
parser and `classifyHistoricalMeta` integrity check before START, END, or COMPLETE can change state.
The prefilter recognizes WHOOP 4 type 49 and WHOOP 5 types 49 and 56 using the same type-name mapping
as the parser. Type 56 has no field schema in this revision: the old and new paths both retain it as
an unclassified frame instead of acting on an assumed layout. Tests preserve that existing behavior;
real type-56 field support needs separate wire evidence. The filter removes one redundant full parse
per non-metadata frame. No new radio-rate claim is made.

The second parse in reject classification remains a follow-up opportunity. It should receive the
already-parsed frame while preserving CRC rejection and raw archival behavior exactly.

### The idle watchdog started protecting local work too late

PR #14 called `onChunkCommitBegin` only after decode, several awaited diagnostic callbacks, and the
R-R census. Those operations still consumed the radio-idle timeout. Empty END chunks never paused
the idle timer despite performing a cursor write.

This patch begins commit protection immediately after validating the END payload, before decode or
diagnostic callbacks, including empty chunks. All existing failure exits resume the idle watchdog
through `onChunkCommitAborted`. A separate commit deadline remains necessary to bound stuck local
work; increasing the radio-idle timeout alone would hide the distinction.

## Remaining throughput work

1. **Move reject archival off the main actor.** The production `rejectedSink` still awaits
   `MainActor.run`, where `RawHistoryArchive.archive` performs conversion, file writes, synchronization,
   and occasional whole-archive eviction/rewrite. Use one serial archive owner and return only the
   result/counters to the main actor. Durable archival must still finish before the trim ACK.
2. **Move optional diagnostic presentation after the critical work.** Reject logs can format up to
   eight complete frames per chunk, and log redaction/persistence still runs on the main actor.
   Preserve the raw evidence and accurate failure messages while coalescing presentation work.
3. **Distinguish write submission, ATT completion, and firmware progress.** A submitted ACK is not a
   confirmed write. Measure each separately and correlate it to a session/chunk before deciding whether
   the next delay belongs to storage, the app scheduler, CoreBluetooth, or the strap.
4. **Keep unsafe timestamp-range skipping disabled.** Maximum timestamp alone does not prove every
   earlier record was persisted. Out-of-order chunks must continue through row-level duplicate handling.
5. **Measure before changing transport settings.** Nothing in this audit establishes a safe alternate
   opcode, connection parameter, larger chunk size, or high-frequency mode for firmware `50.41.1.0`.

## Verification and next physical measurement

`BackfillIdleWatchdogTests` now covers a decoder held for 1.3 seconds against a 1-second radio-idle
window with a separate 5-second commit deadline; balanced pause/abort hooks for insert, archive, raw,
IMU, and cursor failures; an empty END failure; and record/corrupt-metadata preservation for both
families, including legacy parity for the unmapped type-56 metadata fields. Integration test execution is recorded in the companion sync
audit and final task report. Source-level changes and synthetic tests do not establish device acceptance.

A sustained phone run should record notification arrival, queue depth and age, decode duration,
durable-write duration, ACK submission and ATT completion, next-chunk arrival, disconnect reason,
process launch/restoration, and per-stream historical frontiers. Separate newest persisted history
from last successful offload time. Include locked/background periods beyond two hours and compare
backlog seconds removed per wall second. The current 15-hour report remains unexplained without a
fresh trace showing the first point at which progress stops.
