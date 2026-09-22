# PR 14 sync investigation

## Scope and disposition

Baseline: PR 14, `293fd6b84aa8f3e86f18cfab35933206aa53403d`, verified through GitHub on September 15, 2026. Local follow-up branch: `fix/pr14-sync-reliability`. The original research checkout and the existing phone-build checkout were left intact. Changes here affect the shared iOS/macOS BLE implementation; Android has not been changed or qualified.

The reported symptoms are a WHOOP on firmware **50.41.1.0**, a connection that appears to stop working after about two hours, and a last-sync label fifteen hours old. There is no current failure transcript or instrumented phone run attached to this investigation. The exact cause of that incident is therefore **UNKNOWN**. The defects below are verified in source and covered by focused local tests; that is not proof they caused this particular incident or that the phone is now fixed.

## Findings

| Finding | Evidence and likely effect | Disposition |
|---|---|---|
| Reconnect can leave no pending operating-system work | A fast failure fell back to a process timer. A bond-loop pause tried to reconnect while `connected` was still true, then its later attempt fell inside the ten-minute floor. Suspension could prevent any further retry until foreground. This predates PRs 8–12; the related PR 6 is still open. | Submit the retry immediately with CoreBluetooth's start-delay option; preserve the existing cooldown and intentional-disconnect guards. Park the first bond-pause retry after teardown. |
| A cancelled transfer can still affect the next connection | PR 9 moved ingestion to an actor, but disconnect and abort only reset manager state. PR 14 serializes frames but does not invalidate in-flight side effects. | Give every session an identity. Invalidate it synchronously on abort, disconnect, and deadline; drop stale frames and fence callbacks again after returning to the main actor. |
| Two triggers can start overlapping sessions | PR 14 awaits actor setup before setting the manager's busy flag. Another trigger can enter during that suspension, or disconnect can invalidate the link before setup returns. | Reserve a session synchronously before creating its task; recheck the reservation and connection after setup; bound a blocked start. |
| The idle timeout does not cover the actual local-work phase | PR 14's pause hook ran after decode and diagnostics. Timeout teardown also waited behind the very operation it was meant to stop. | Pause before decode/diagnostics. Fence delivery immediately on deadline, independently of queued cleanup. Tag deadlines so obsolete timers cannot stop a later session. |
| Submitted ACKs are reported as successful ACKs | `send()` could silently reject a write; the chunk counter still advanced. A later ATT write error did not identify the failed history operation. | Count chunks on successful CoreBluetooth completion. Track confirmed writes in submission order, including non-history writes and the initial handshake. A failed history write stops that session and requests reconnect. Completion waits for outstanding history writes. |
| Repeated parsing adds work before ACK | Every data record was fully parsed in `ingest` just to determine whether it was metadata, then parsed again at commit. | Use the existing family-aware type reader for classification; retain full CRC-validated parsing for metadata and records at commit. |

ATT completion proves transport delivery, not that the strap accepted the trim semantically. New diagnostic lines report pending writes and successful ATT latency. Subsequent history, cursor movement, and durable rows remain necessary evidence of forward progress.

## Which PR introduced what?

- **PR 8:** introduced an unsafe timestamp-frontier skip. A maximum saved timestamp does not prove every older row exists. PR 14 disables this shortcut by default; keep that fix.
- **PR 9:** introduced actor-ingress ordering and lifecycle hazards. PR 14 repairs FIFO ordering; this follow-up repairs cancellation and start admission.
- **PR 10:** addresses expensive restoration work and a missed retry at the event floor. No new transport regression was established in this review.
- **PR 11:** removes quadratic diagnostic redaction and adds bounded silent recovery. Keep it.
- **PR 12:** speeds archive conversion, coalesces log updates, and resumes history after store bootstrap. Keep it.

The merge graph overlaps: PR 8's merge includes PR 9, whose history includes PRs 10 and 11. First-parent merge diffs alone cannot identify ownership. See the accompanying [regression audit](PR8_14_SYNC_REGRESSION_AUDIT_2026-09-15.md) for commit-level attribution.

The existing [issue 7](https://github.com/kkakodka-bot/naraWhoop/issues/7) establishes that stalls preceded PRs 8 and 9. Its corrected phone observations report PR 11 improving catch-up from below real time to roughly 3–4 times real time, and PR 12's short run reaching 5.28 times real time. These are earlier reporter measurements, not measurements of this patch. They do not establish overnight reliability. The earlier claim that SQLite/decode timing ruled out local CPU stalls was explicitly corrected because diagnostic/archive time had been omitted.

## Why “last synced” can stay old while chunks arrive

The app stamps `lastSyncedAt` on `HISTORY_COMPLETE`. Productive passes that end by timeout can save rows and leave that completion timestamp unchanged. A fifteen-hour label alone therefore cannot distinguish “nothing was received” from “catch-up keeps getting interrupted.” Inspect the last durable historical sample, saved-row totals, last completion, and confirmed ACKs together. This patch retains the existing timestamp meaning.

## Background connection expectations

iOS supports long-lived BLE connections and pending reconnects through `bluetooth-central` and CoreBluetooth state restoration; both are already configured. There is no identified fixed two-hour cutoff in this code. Timers do not provide continuous execution when the app is suspended. See [Apple's background BLE guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html), the [system start-delay option](https://developer.apple.com/documentation/corebluetooth/cbconnectperipheraloptionstartdelaykey), and [current relaunch rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules).

The realistic target is automatic recovery while the app stays in the background, with prompt, small units of work when iOS wakes it. An uninterrupted process, an exact periodic wake schedule, or automatic recovery from every user force-quit state cannot be promised. Detailed OS constraints and the PR 6 comparison are in the [background audit](BLE_BACKGROUND_AUDIT_2026-09-15.md).

## Performance follow-ups

1. Move reject-archive disk work off the main actor through one serial archive owner, preserving fsync-before-ACK and coordinating eviction/replay. It still blocks the main actor in this patch.
2. Reuse already parsed records in rejection classification. This patch eliminates the first redundant record parse; classification still repeats parsing.
3. Move optional diagnostic formatting off the ACK critical path, without omitting raw retention or required persistence.
4. Measure history seconds gained per wall second, bytes/sec, queue delay, decode, archive, database, ACK submission, ATT completion, and retransmitted trim separately. A fast CPU microbenchmark does not establish faster radio transfer.

See the [performance investigation](BLE_SYNC_PERFORMANCE_2026-09-15.md) for measurements and proposed experiments. Do not parallelize trim ACKs or enable undocumented high-frequency/raw producer modes to chase speed.

## Remaining limits

- Fresh logs from the affected firmware/session are still needed to attribute the reported failure.
- A read-only device inventory found the paired iPhone and watch disconnected, so a current app log or live sync could not be inspected in this session.
- The actual CoreBluetooth reconnect, callback ordering, and locked-phone lifetime need physical qualification. No device was installed, reset, re-paired, or sent commands by this investigation.
- A hung storage operation can be fenced from sending a stale ACK, but cannot be forcibly made successful. Later ingestion remains serialized behind it; the pending-start deadline now exposes that condition.
- Clock/range identity updates are serialized with ingestion but do not yet carry their own connection generation. Delayed control tasks during a rapid switch between different straps deserve a separate test and follow-up.
- The timestamp-frontier optimization remains explicitly opt-in in PR 14. Users who manually enabled it should turn it off; this patch does not migrate that experimental preference.
- Tests exposed an existing metadata gap: WHOOP 5 type 56 has the canonical metadata name but no mapped fields in the current schema. It remains buffered without advancing history state, matching the baseline. The retained type 49 layout is supported. A matching firmware capture is required before assigning a type 56 layout; no speculative mapping was added.

## Physical acceptance still required

On the affected iPhone/strap, retain the existing database and pairing, record the exact installed commit, and capture a foreground catch-up followed by a locked-phone run longer than the reported two-hour window (preferably overnight). Include an out-of-range/reconnect cycle and a bond-cooldown case. Acceptance requires historical backlog to shrink, completed syncs to advance, saved rows/raw evidence to survive reconnect/replay, failed writes to remain visible, and reconnection without opening the app. Correlate any restart with OS termination/crash evidence. Do not mark those checks PASS from local tests or a short live session.

## Local verification

| Check | Result | Evidence |
|---|---|---|
| Focused macOS app tests, final source | **PASS: 169 tests, 0 failures** | `/private/tmp/whoop-sync-tests-final-confirmed.log`; `/private/tmp/whoop-sync-build/Logs/Test/` contains the XCTest result bundle |
| Generic iOS build, final source | **PASS** | `/private/tmp/whoop-sync-ios-final.log` |
| Whitespace/diff validation | **PASS** | `git diff --check` |
| Phone installation / firmware acceptance / overnight BLE | **NOT_MEASURED** | Paired devices disconnected; no deployment or physical operation performed |

Xcode 26.3 was used with generated `Strand.xcodeproj`, `CODE_SIGNING_ALLOWED=NO`, and the isolated build identifier prefix `dev.nara.syncaudit`. The test scheme set `NOOP_TEST_DISABLE_BLUETOOTH=1`; new manager tests also pass `startCentral: false`. Dependencies and build output are in `/private/tmp/whoop-sync-spm` and `/private/tmp/whoop-sync-build`. The iOS check builds the `NOOPiOS` scheme for `generic/platform=iOS`; it does not prove signing, installation, or device execution. An existing unrelated nil-coalescing warning in BLEManager remains.

The selected test classes cover actor FIFO/cancellation/snapshots, idle and commit deadlines, manager admission and confirmed ACK accounting, reconnect and bond-loop policies, hello outcomes, continuation, persistence failure/IMU safety, timeout reporting, empty syncs, downstream drain policy, and last-sync attribution. In particular, tests now prove payload order rather than counting calls, hold decoding beyond the idle deadline, prevent a late ACK from cancelling the next chunk's deadline, and preserve the baseline behavior of unmapped metadata.

The first integration runs exposed outdated cancellation/ACK assumptions in the existing tests and an incorrect synthetic type-56 support assumption. Those failures were investigated and recorded in the audits; the final run above covers their corrections. No production firmware layout was inferred from a synthetic fixture.
