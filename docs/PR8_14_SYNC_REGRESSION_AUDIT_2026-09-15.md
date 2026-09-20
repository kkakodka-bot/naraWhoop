# WHOOP sync audit: PRs 8–14

Baseline: PR #14 head `293fd6b84aa8f3e86f18cfab35933206aa53403d`. Inspected committed references separately from the unrelated dirty research checkout. No strap commands, firmware writes, resets, re-pairing, or live device acceptance were performed by this audit.

## Attribution

The original historical-transfer stalls **predate PRs #8 and #9**. [Issue #7](https://github.com/kkakodka-bot/naraWhoop/issues/7) reports three idle exits on PR #6 build 335 with the BLE link still connected. Its follow-ups report #11 improving historical catch-up to approximately 3.8–4.1 times elapsed time, then #12 reaching 5.28 times in a short run. The issue also records unexplained process relaunches and repeated trims. Those observations do not establish the cause of the user's current two-hour disconnection or stale firmware-50.41.1.0 sync.

The changes below are code defects or limitations with concrete triggering sequences. They are not a retrospective diagnosis of that phone without its runtime evidence.

## Commit map

| PR | Commit | Relevant changes |
| --- | --- | --- |
| #8 | `48da0d9` | Merges tier-1 changes and #9; own branch `519234f..b58bf4e` adds timestamp range skip, IMU improvements, raw-capture default. |
| #9 | `ec3343a` | Moves ingestion into `BackfillActor`; includes nested #10 and #11. |
| #10 | `30e96cc` | Background rescore policy and retry after the event floor. |
| #11 | `a49fa16` | Removes expensive redaction/logging work and adds bounded silent retry. |
| #12 | `34fc950` | Archive hex parsing, coalesced log invalidation, shared store bootstrap and deferred sync resumption. |
| #14 | `293fd6b` | Defaults timestamp range skip off; serializes pipeline control/frame ingress; pauses watchdog during part of chunk commit. |

## Findings at the PR #14 baseline

### VERIFIED: #8 could skip unseen historical rows

`Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift` skips a stream when its chunk maximum timestamp is at or below a persisted maximum. A maximum is not proof that every earlier natural key exists. Disordered chunks, a clock correction, and additional R-R ordinals within an existing second can therefore be skipped even though they contain new data; `Backfiller` can still advance the cursor and acknowledge the chunk.

PR #14 defaults the optimization off and restores normal SQL conflict handling. Explicitly enabled preferences still select the unsafe optimization. Its presence does not explain a transport ACK error by itself.

### VERIFIED: #9 lost teardown ownership of the offload worker

Before #9 the drain checked `BLEManager.backfilling` after each ingest and dropped the queue when that flag cleared. After #9, disconnect/abort clears only manager state; the worker checks its separate `Backfiller.isBackfilling`. Already queued chunks can therefore continue committing and invoke callbacks after the old link has ended. Before #14, resetting `draining` during a suspended ingest could also create overlapping drains.

PR #14's single `AsyncStream` consumer fixes the overlapping drain and per-frame unstructured Task ordering. It does not itself fence old callbacks against a new link/session. This change adds synchronous session reservation/invalidation, generation-tagged ingress, stale-queue rejection, and guards on worker callbacks. The manager must recheck the generation inside its main-actor callbacks immediately before BLE/UI effects. An already executing durable insert may finish; its old ACK must not reach a new link.

### VERIFIED: #14 start admission could overlap across awaits

`requestSync` checks the gate before starting an unstructured Task. `beginBackfill` then awaits actor initialization before setting `backfilling`. Two triggers can both pass the initial gate. A disconnect during initialization can also leave a stale task starting a session after link teardown. The manager repair reserves the session synchronously, blocks additional admission, and checks the same link/session after awaits.

### VERIFIED: #14 watchdog did not cover the whole processing interval

The commit-start callback was after detached decode and diagnostic/UI callbacks. Idle expiry could therefore queue a timeout during decode, then wait behind the same ingest until it had already submitted an ACK. The commit deadline also awaited serialized teardown, so an unresolved insert prevented it from terminating manager state. A generation-scoped deadline must fence callbacks immediately and may let persistence finish independently. The processing hook needs to cover decode and diagnostics as well as insert/archive work.

### VERIFIED: submitted ACK counts were not write confirmations

At the baseline, `ackHistoricalChunk` increments progress after invoking `send`, including when `send` declines to write. `Backfiller.lastAckedTrim` also tracks callback submission. Actual CoreBluetooth write success is a separate event. Manager accounting must distinguish requested, submitted, confirmed, failed, and outstanding writes, and must associate callbacks with the connection that submitted them. Neither an ATT write confirmation nor a completed local insert proves the strap has advanced to a fresh historical timestamp.

### VERIFIED: existing tests overstated their coverage

The original FIFO test appended `insertOrder.count + 1` and decoded every frame to the same row; it could not detect reordered payloads. The original test named “commit longer than idle window” waited 1.5 seconds with a five-second deadline. Revised pipeline tests use distinct payload identities and an explicitly suspended insert, covering old-session callback suppression, queued stale frame rejection, a cancelled start reservation, and an old timeout arriving after a new session starts.

## Remaining evidence and implementation limits

- Device identity, clock, and range setter events now serialize behind ingestion, avoiding mutation during an in-flight chunk. Callers still create some setter Tasks without a connection generation. A delayed setter from an earlier connection can need further fencing, particularly when switching devices.
- `Backfiller.lastAckedTrim` retains its submission meaning unless separately changed; consumers must not present it as a confirmed strap cursor.
- No reviewed change establishes continuous overnight BLE execution, the cause of process termination, or acceptance on firmware 50.41.1.0. Required live evidence includes disconnect/error reason, restored versus new launch, last historical frame time, requested/submitted/confirmed ACKs, outstanding writes, latest persisted historical timestamp, and battery/thermal/app-lifecycle conditions over a long locked-phone run.
- This audit records implementation and targeted test intent. The parent task's final test/build report is the authority for checks actually executed after all integrated changes.
