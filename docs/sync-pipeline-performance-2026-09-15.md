# Sync pipeline performance and freshness

Date: 2026-09-15. Checkout: `fix/pr14-sync-reliability`, following `fd8bf7c`.
This audit separates observed phone behavior, source-verified costs, and unmeasured speed improvements.

## What actually stopped this phone

**VERIFIED from the phone log:** firmware 50.41.1.0 delivers history, but the first chunk at trim
`116037` fails SQLite insertion. At 16:41:49 and again at 16:43:41, the PPG waveform INSERT uses a conflict
target that does not match the table's current key. Both sessions end with zero confirmed chunk ACKs.
The second timeout then incorrectly calls the failure experimental empty history.

The evidence is `/private/tmp/whoop-sync-followup-evidence/strapLog.tail.json`. The invalid query rolls
back the decoded-row transaction before ACK. Fixing its identity/key handling is the first throughput
requirement: speeding BLE cannot drain a chunk that storage always rejects. The paired storage and
timeout fixes preserve the current chunk on the strap instead of acknowledging unsaved data.

## Where one chunk spends time

```text
CoreBluetooth callback on main actor
  -> reassemble frames; synchronous FIFO handoff
  -> BackfillActor buffers until validated HISTORY_END
  -> background task parses records and extracts streams
  -> collect ordered informational logs and counter updates
  -> SQLite transaction: decoded streams + durable downstream work
  -> rejected-frame archive, raw outbox when enabled, session IMU when present
  -> await session-fenced informational batch on main actor
  -> SQLite trim cursor
  -> submit ACK on main actor
  -> CoreBluetooth completion; firmware may send the next chunk
```

`Backfiller.finishChunk` is the critical path. It must keep persistence before ACK. Increasing the
number of uncommitted chunks, acknowledging early, or skipping older timestamps is not a safe speed
improvement. A maximum saved timestamp does not establish that older records are complete.

Rejected-frame warnings flush before their archive operation, and failure paths flush preceding
information before delivering their error. The batch is awaited, preserves observation order, and
checks the active session before and after entering the main actor. It is not a detached logging
task. Commit-watchdog and durability ordering remain unchanged.

## Bounded improvements

| Change | Source evidence | Expected effect and limit |
| --- | --- | --- |
| Reuse already parsed frames for rejected-record classification | `Backfiller.finishChunk` already builds a `ParsedFrame` array; rejection formerly parsed mapped history again | Implemented here. Removes one full decode/CRC pass for those records. The historical metadata integrity gate and raw archive decisions remain unchanged. Local benchmark below measures CPU only. |
| Include PPG-only writes in historical progress | `StreamStore` inserts PPG HR/waveforms, but its legacy eight-count tuple excludes them; `Backfiller.chunkTally` uses only that tuple | Implemented with the storage repair: actual newly inserted sensor-record counts are returned separately from the legacy tuple. PPG-only productive passes now advance continuation progress; duplicate replay still counts zero. Retention budgets also count successful inserts instead of attempted writes. |
| Serialize rejected-frame file work away from the main actor | The rejected sink uses `MainActor.run`; archive append/eviction performs synchronous disk operations there | Reduces notification/UI scheduling delays when records are rejected. Keep a single file owner, await durable completion before ACK, and coordinate replay/eviction with that owner. Improvement is unmeasured on this phone. |
| Batch informational delivery before ACK | Earlier builds awaited separate main-actor hooks for per-chunk logs, layout updates and counters; later phone samples showed multi-second local processing despite short decode/insert stages | Implemented in `51d7d75` for build 334: ordered, awaited, session-fenced delivery consolidates those hops without dropping observations or failure context. Error delivery, rejected bytes, durable archive, cursor ordering, and watchdog behavior remain protected. A handset speedup has not yet been measured. |
| Separate cursor and ACK submission timing | Builds 332/333 combined the SQLite cursor write with the awaited ACK callback | Implemented: `cursorMs` measures `setCursor`, while `ackMs` measures ACK callback/submission including main-actor wait and excludes ATT confirmation. Commit-begin wait, notification arrival/FIFO age, ATT latency, and firmware continuation still need separate measurements. |
| Reserve scoring admission before suspension | Build 334 checks `computing`, awaits store/fingerprint reads, then sets the reservation; phone logs show forced and post-offload starts before either completion | Build-335 follow-up moves the reservation before the first await, preserves the pending forced-pass handoff, and prevents premature downstream settlement. The final combined 261-test run passed; the overlap followed the cold pass and cannot explain its duration. |
| Lazily construct Live log rows | LiveLogCard uses an eager stack over up to roughly 5,000 retained rows inside a 200-point viewport | The follow-up changes that stack to `LazyVStack`, preserving complete rows, exports, IDs, and scroll callbacks. Test Centre has no equivalent full-log view; this change is not proven attribution for its delays. |
| Batch remaining row inserts if measured significant | RR, steps, sleep-state, PPG HR and waveforms use reused prepared statements per row; major scalar streams already use 100-row batches | Benchmark existing indexes and realistic mixed chunks before extending batching. Preserve RR sequence/order assignment, exact conflict keys, and transaction rollback. No benefit is claimed yet. |

The current full-frame FIFO avoids launching one unstructured task per history record. Do not replace
it with parallel chunk commits: strict ordering prevents a later ACK from trimming beyond an earlier
failed save. The existing confirmed-write queue also distinguishes submission from transport success;
transport success alone does not prove the strap advanced its history cursor.

## Fast data on app opening

**VERIFIED in source:** `StrandiOSApp` requests `.foreground` history sync immediately on scene
activation. It uses a 90-second attempt floor, with a retry at that floor; manual sync bypasses it.
The timer baseline is 15 minutes. Productive backlog sessions can continue immediately, up to the
bounded 24-pass cap, instead of waiting for that timer.

Those intervals are not measured throughput limits. Keeping the ordinary background drain healthy
reduces how much history is waiting when the app opens. An already accumulated oldest-first backlog
still takes time to transfer. The repaired build completed the observed backlog in 10 minutes
27 seconds, but callback timestamps and local phase summaries cannot establish a maximum radio rate.

There is a second delay after data is saved: `postOffloadBurstInProgress` deliberately holds expensive
scoring/export until the backlog reaches its terminal decision. `refreshAfterCompletedBackfill`
then refreshes a 120-day repository window before the downstream drain. Preserve this coalescing;
running a full rescore on every chunk competes with ingestion. If the first-screen delay remains,
measure its current-day read and the wide refresh separately, and show the last valid cache and live
readings while a bounded current-day refresh runs. Do not mark a partly transferred night complete.

### Verified scoring admission race

Build 334's cold pass reused 0/9 cached days and took **433.293 seconds**, with measured preparation
**63.113 seconds** and scoring-loop work **211.435 seconds**. After it completed, forced and post-offload
triggers appeared before either subsequent completion. Those two passes reused 8/9 days and reported
**25.285** and **29.587 seconds**. The final copied preferences show scoring debt clear and last-sync
**17:52:05**. The overlap occurred after the cold pass, so it does not explain that pass's 433 seconds.

The old main-actor admission method suspended between checking `computing` and setting it. Actor
isolation does not prevent another caller entering during an await. The build-335 follow-up reserves
admission before the first suspension, keeps the forced-pass handoff visible, and makes SyncEngine
leave work owed while a score is active or queued. It retains the captured-token settlement rule.
Local validation passed as recorded below; handset verification is recorded in the storage repair report.

The narrow UI check found that SyncStatusPanel renders at most eight journal rows and reloads its store
data on a status revision. Test Centre's optional full-export scans are gated by active diagnostic modes,
which were off in the copied preferences. A separate Live screen eagerly built the full log-row stack;
its lazy-stack change removes that source of eager view work without dropping log data. A profiler could
not attach, so neither this UI path nor overlapping scoring is established as the cause of the long
main-actor callback delays.

## Freshness fields are not interchangeable

- `lastSyncedAt` means receipt of `HISTORY_COMPLETE`, not the timestamp of the newest saved sample.
- `sync.lastWriteOkAt` is currently also updated only in that completion branch. A stale value cannot
  independently prove that no rows were committed during productive timeouts.
- `latestHRSampleTs` takes the maximum across measured and PPG-derived HR for a device. The measured
  table also receives live HR, so it cannot prove that the historical backlog is caught up.
- The WHOOP 5 data-range response remains diagnostic-only (`feedsSync: false`) in this version. Do
  not enable it as a completion gate without validating its fields on the actual firmware.

Useful measurements are per-session newly inserted records, earliest/latest historical capture
timestamps, confirmed ACKs, trim advancement, and actual completion. Report connection age separately.

The diagnostics panel now refreshes after the downstream drain persists its jobs/journal and labels
current debt **Pending now**. Each historical entry says **pending after pass**, preserving the original
entry and error note. A remaining reporting follow-up is to give the engine explicit completed,
deferred, superseded, and failed outcomes: its current Boolean result can label a planned background
deferral or a changed job token as `failed: rescore`. The status refresh does not change that
classification, scheduling eligibility, or the stored journal history.

## Validation and benchmark

The timeout presentation fix passed **9 app tests, zero failures** using the real state-update method.
Evidence: `/private/tmp/whoop-sync-timeout-followup-tests.log`, and
`/private/tmp/whoop-sync-build/Logs/Test/Test-Strand-2026.09.15_16-51-27--0700.xcresult`.

The parsed-reuse regression suite covers both families, corrupt CRCs, CRC-valid unmapped layouts,
exact rejected bytes/order, the pre-existing v26 archive exception, and a truncated parsed cache.
Its opt-in benchmark compares parse-plus-reparse with parse-plus-reuse on 2,000 fixed v18 frames,
including 100 CRC-corrupt frames, over five rounds. It asserts equal reject bytes, never a timing
threshold. Run with:

```sh
WHOOP_RUN_REJECTION_BENCHMARK=1 swift test \
  --package-path Packages/WhoopProtocol \
  --scratch-path /private/tmp/whoop-rejection-performance-build \
  -c release --filter RejectedHistoryTests
```

The release run passed **15 tests, zero failures**, including the benchmark. Median parse-plus-reparse
time was **11.81 ms**, compared with **6.47 ms** for parse-plus-reuse: approximately **45% less time in
this local parsing stage**. Five old/new measurements in milliseconds were 11.80/6.13, 11.81/6.52,
12.10/6.58, 11.94/6.38, and 11.61/6.47. Evidence: `/private/tmp/whoop-rejection-reuse-tests.log`.
These measure local parsing work, not Bluetooth throughput, phone energy use, background survival,
or user-visible freshness.

The full release protocol suite also completed with **732 tests, two skipped, zero failures**.
The skips were this explicitly opt-in benchmark (run separately above) and the external full optical
corpus check, whose `WHOOP_R20_CORPUS` input was not supplied. Evidence:
`/private/tmp/whoop-protocol-followup-tests.log`.

Four new informational-batching tests verify legacy observation order and safe-trim ordering,
rejected-byte/error preservation with no ACK on failure, discarded delivery after session invalidation,
and separate awaited information/cursor/ACK timing. The focused app run passed **63 tests**. The final
broader app run passed **184 tests, zero failures**; evidence:
`/private/tmp/whoop-followup-app-final-tests.log`. These are local correctness checks, not a measured
phone speedup from batching.

The subsequent scoring-admission follow-up passed **33 focused tests**, including four new async tests
that exercise the real analyzer and actual SQLite debt through admission and queued handoff. The final
combined BLE, sync, scoring, and background-policy run passed **261 tests, zero failures**. Evidence:
`/private/tmp/whoop-rescore-admission-tests.log` and `/private/tmp/whoop-build335-app-tests.log`.

## Device acceptance

Build 332 advanced the formerly failing trim and durably saved the backlog. Build 333 then completed
535 new sensor rows in three confirmed chunks plus an empty completion. Concurrent cold scoring took
116.923 seconds, followed by a 13.852-second warm pass and cleared debt. A later automatic 12-chunk
pass completed at 17:37:38, followed by further completions at 17:37:39 and a 15.026-second warm score.
The cold scorer still allowed the earlier BLE pass to process chunks at 15/38 ms p50/p99. Those results
predate batching in build 334. See [the storage repair report](sync-storage-repair-2026-09-15.md) and
[the timing evidence](sync-throughput-evidence-2026-09-15.md) for the bounded observations.

Build 334 was subsequently installed and completed a nine-chunk pass with 2,527 new rows, then
additional productive and empty passes. Its later two-chunk pass completed with local processing
p50/p99 of 19/20 ms. The split timers work on the handset and identify ACK callback delivery as
larger than cursor persistence in the startup pass. These small, unequal samples do not establish
a controlled before/after speedup; the detailed measurements and their limits are in the reports above.

Its later 57-chunk completion at **17:52:00** saved **1,847 new sensor rows** and measured local processing
p50/p99 **529/9,600 ms**, information delivery **0/4,010 ms**, ACK callback **163/4,609 ms**, cursor
**0/5 ms**, decode **1/22 ms**, and insertion **1/63 ms**. This demonstrates continued syncing and remaining
multi-second local delays after batching. Scoring debt later cleared, and last-sync advanced to 17:52:05.
The signed build-335 follow-up subsequently completed seven productive chunks, saving 1,756 rows,
then two chunks saving 90 rows, followed by an empty completion at 18:06:48. The seven-chunk local
processing p50/p99 was 36/75 ms; the follow-up was 12/31 ms. This verifies final-build history progress
but is not a controlled hardware comparison. See the storage repair report for scoring completion.

The same final build subsequently completed its cold scoring pass in 126.103 seconds, with one
observed start/completion pair and no overlapping start. The final database snapshot passed integrity
checking and contained no pending sync jobs; the rescore-owed flag was clear. This is one accepted
end-to-end local cycle. Remote export acceptance and multi-hour locked-screen reliability remain separate.

For the new batching build, measure sustained historical seconds
received per wall second, chunk decode/store/archive latency, ACK latency, and inter-chunk time.
Repeat under a locked screen and across reconnection. Only those measurements can establish the
achievable speed and whether history is already fresh when the user next opens the app.
A locked-phone soak exceeding two hours has not been run.
