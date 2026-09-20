# Sync throughput evidence — 2026-09-15

## Conclusion

The verified phone follow-up completed history successfully after the database compatibility repair. Signed build 332 at commit `44a47e0` completed its first pass in **10 minutes 27 seconds**, with **1,033 confirmed chunk writes**, no pending writes, and a refreshed last-sync timestamp. The failing build had repeatedly stopped on the first chunk's local database statement. The exact reported two-hour lifetime failure remains unproven.

The analysis used host copies and read-only database access. The phone follow-up below records the separately performed signed installation and the app's ordinary automatic history sync. Private logs, identifiers, raw packets, and biometric values are excluded from this report.

## Before repair: measured wasted work

Inputs: `strapLog.tail.json`, three retained generations in `strapLog.generations.json`, `preferences-1.plist`, and `whoop.sqlite`, under `/private/tmp/whoop-sync-followup-evidence/`.

- Six recorded sync starts encounter the same `ppgWaveformSample` conflict-target error at the same history cursor. The actual table key includes `recordIndex`; the older insert does not.
- Each attempt then receives four repeated END markers and withholds their ACKs. This is necessary while those records remain uncommitted.
- Five attempts have retained terminal events. They last **70, 71, 71, 73, and 74 seconds**, totaling **359 seconds**. The first persistence failure occurs within **0–4 seconds** of each request. **348 seconds** of those sessions elapse after the exception, without history advancing.
- The last repeated END precedes timeout by **60–61 seconds**, matching the idle deadline. A deterministic local failure is therefore being converted into a long apparent transport stall.
- Both terminal events in the newest tail explicitly report **zero confirmed chunks and zero pending writes**. Standard heart-rate persistence succeeds during the same window: the BLE link and the historical save failure are separate conditions.
- Connection test mode is disabled in the copied preferences. There are no per-phase or ACK ATT-latency samples in these fresh logs. Second-resolution log timestamps cannot establish millisecond decode or database latency.

Reconnecting repeatedly cannot repair an incompatible SQL statement. The existing invariant must remain: an unsuccessful durable save must not advance the strap cursor or submit its chunk ACK. **Inferred delayed-onset explanation:** the incompatible insert executes only when a chunk contains waveform records. Earlier v18-only chunks can succeed, then the first v26-bearing chunk can expose the mismatch. That can resemble a delayed BLE failure; it does not establish a fixed two-hour cause.

## After repair: observed phone completion

Sources: `after-install-1.tail.json` through `after-install-19.tail.json`, corresponding `preferences-after-install-*.plist`, and `after-install-db/summary.json`, in the same private evidence directory. The build identity is `44a47e0`, signed build 332. Times below are phone-local log times on September 15.

- **17:07:12:** CoreBluetooth restored the connected peripheral and re-armed notifications. Automatic history began at **17:07:16**, before the separately recorded explicit foreground launch at 17:07:45. This verifies one restoration event; screen-lock state and multi-hour reliability were not established.
- The same pass advanced through logged chunk indices 58, 158, 289, 419, 597, 819, and 1,033. No persistence, cursor-write, or ACK-submission failures appear in the retained snapshots. Un-timestamped `strap:` controller-reset messages within the offload are replayed historical console records, not current host disconnect events.
- An intermediate copied SQLite database already contained **31,476 additional gravity rows**, **31,476 additional skin-temperature rows**, and **1,084 additional waveform rows**. Gravity and temperature source-time frontiers had advanced **8 hours 44 minutes 39 seconds**. Those historical-only lanes establish durable catch-up independently of the live HR/RR streams, whose maximum timestamps must not be used as backfill proof.
- **17:17:43:** `HISTORY_COMPLETE` ended the first pass: **1,033 ATT-confirmed chunks**, **zero pending writes**, and no commit in flight. The store-backed session tally reports **337,694 inserted sensor rows**, including **57,516 gravity** and **57,516 skin-temperature** rows. Elapsed request-to-completion time was **627 seconds**.
- **17:17:44:** a follow-up pass completed with one empty chunk. The persisted last-sync timestamp advanced to that completion, resolving the stale completion label in this observed run.

### Measured processing stages for the completed 1,033-chunk pass

| Stage | p50 | p99 |
| --- | ---: | ---: |
| END handler through ACK submission, including awaited callbacks | 34 ms | 399 ms |
| Diagnostics segment | 0 ms | 110 ms |
| Decode and rejection classification | 3 ms | 74 ms |
| Decoded-row insert and job recording | 4 ms | 26 ms |
| Cursor write and ACK-submission callback | 0 ms | 97 ms |
| Reject archive / raw batch / IMU segments, each | 0 ms | 0 ms |
| Interval between END-handler starts, including receive time and queueing | 508 ms | 2,309 ms |

Frames per chunk were p50 **60**, p99 **87**. These are terminal phase summaries; per-chunk phase records and ATT-latency detail remained disabled. A reported zero milliseconds is integer timer resolution, not proof that a stage consumes no time.

**Interpretation of this initial pass only:** ordinary local decode and insertion are short relative to the interval between completed chunks. The next measurement should separate inbound transfer, notification delivery, and FIFO waiting from ACK delivery and firmware continuation. Those boundaries are not separated by this trace, so calling the remaining interval a radio bottleneck would overstate the evidence. Within measured local stages, diagnostic work and cursor/ACK-submission callbacks have the largest reported p99 values. Reject archival is not demonstrated to dominate this successful run. Percentiles describe different sample distributions: do not subtract or add them to manufacture a percentage breakdown. Later small passes had substantially slower local processing, described below; the 34 ms median is not a general bound.

### Later small passes: intermittent local delays

Sources: the build-332 generation retained in `preferences-build333-1.plist`, plus the current build-333 tails in `preferences-build333-2.plist` and `preferences-build333-3.plist`. These are separate passes after the bulk catch-up, not additional samples from its 1,033-chunk distribution.

| Build / observed pass | Chunks | Local processing p50 / p99 | Decode p99 | Insert p99 | Diagnostics p99 | Cursor + ACK submission p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 332 / completed 17:19:33 | 3 | 2,292 / 5,373 ms | 0 ms | 4 ms | 678 ms | 1,174 ms |
| 332 / empty pass, ended 17:19:42 | 1 | 466 / 466 ms | 0 ms | 0 ms | 0 ms | 461 ms |
| 332 / timeout 17:24:38 | 5 | 6 / 11,516 ms | 1 ms | 10 ms | 2,001 ms | 1,915 ms |
| 333 / completed 17:26:22 | 3 | 15 / 38 ms | 2 ms | 3 ms | 11 ms | 0 ms |

The slow build-332 samples establish local delay between END processing and ACK submission even when decoding and insertion are short. The one-chunk empty pass isolates a 461 ms cursor/submission segment without a sensor-data insert. The build-332/333 timer combines the cursor write and the awaited ACK callback; it does not establish which one consumed that time. The five-chunk pass ended **79 seconds** after its request with **five confirmed chunks, zero pending writes, and no commit in flight**. That timeout is distinct from the repaired first-chunk SQL failure. Its cause is not isolated by the terminal summary.

Those captured builds await separate main-actor callbacks for the commit watchdog, per-chunk logs, layout publication, decoded-chunk counters, banked-row counters, and ACK submission. Some callback waits fall outside the named phase segments while remaining inside total processing time. This identifies callback scheduling and presentation work as a concrete optimization target. It does not prove that a particular screen or log view caused the delays. Connection test diagnostics were disabled. Archive, optional raw-batch, and IMU segments remained zero at the recorded millisecond resolution in these examples.

Scoring overlapped some slow passes, but cannot explain all of them: the 17:19:33 and 17:19:42 completions precede the first visible post-offload scoring trigger at 17:19:43–44, while the 17:23:19–17:24:38 attempt follows the last visible scoring completion at 17:21:56–57. The scorer's large day scan and the repository's merge already run in detached tasks; total scoring elapsed time is not a measurement of main-actor occupancy.

After the build-333 process restart, a resumed scoring pass reused **0 of 9** cached days and completed in **116,923 ms**, with its completion line bracketed by host timestamps **17:27:00–01**. A trailing pass reused **8 of 9** days and completed in **13,852 ms**, bracketed by **17:27:14–15**. The copied preferences then show `rescoreOwed=false`. The fast three-chunk BLE pass in the table occurred during the cold scorer, so the roughly 117-second scoring duration did not itself prevent fast concurrent history processing. The latest warm-pass observation is roughly 14 seconds, replacing the earlier roughly 22-second observation as a recent completed-pass duration; neither is a guaranteed future runtime budget. Cache state and current data materially affect that duration.

The build-333 pass at 17:26:22 inserted **535 sensor rows**, then completed an empty follow-up. A later private snapshot, `preferences-before334.plist`, records another automatic **12-chunk completion at 17:37:38**, followed by further completions and an updated last-sync time at **17:37:39**. Scoring debt was clear, with a latest warm-pass duration of **15.026 seconds**. These are further observations of the storage repair before diagnostic batching.

**Implemented follow-up:** source commit `51d7d75`, installed as build 334, batches informational logs, layout publication, and counters into ordered main-actor delivery. Delivery is awaited and session-fenced, including a check after the actor hop. It preserves prior observations and error delivery, flushes archive warnings before archival, and preserves decoded/raw durability, cursor-before-ACK ordering, and the commit watchdog. `cursorMs` now measures cursor persistence separately; `ackMs` covers ACK callback/submission including main-actor wait and explicitly excludes ATT confirmation. The four new regression tests are included in 63 passing focused tests and 184 passing broader app tests.

### Build 334: measured split timers

Private snapshots `preferences-build334-{1,2,3,6,7}.plist` record successful completion after the batching build was installed and launched. The nine-chunk pass at **17:44:58** saved **2,527 sensor rows**; its records-bearing follow-up saved **56**, followed by empty completion at **17:45:02**. Another two-chunk pass at **17:46:36** saved **549 rows** and completed, followed by an empty completion. A later **57-chunk** pass completed at **17:52:00**, saving **1,847 new sensor rows**. Each recorded terminal transport state has zero pending writes and no commit in flight.

| Completed pass | Local processing p50 / p99 | Decode p50 / p99 | Insert p50 / p99 | Information delivery p50 / p99 | Cursor p50 / p99 | ACK callback p50 / p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 17:44:58, nine chunks | 155 / 855 ms | 5 / 178 ms | 12 / 37 ms | 1 / 131 ms | 0 / 2 ms | 65 / 454 ms |
| 17:46:36, two chunks | 19 / 20 ms | 1 / 2 ms | 3 / 4 ms | 0 / 0 ms | 0 / 0 ms | 12 / 13 ms |
| 17:52:00, 57 chunks | 529 / 9,600 ms | 1 / 22 ms | 1 / 63 ms | 0 / 4,010 ms | 0 / 5 ms | 163 / 4,609 ms |

The nine-chunk sample identifies substantially more time in ACK callback delivery than in cursor persistence. The later 57-chunk pass confirms that multi-second information-delivery and ACK-callback tails remain after batching, despite short measured cursor, insertion, and decode stages. These measurements still do not separate main-actor queue waiting from execution inside the callbacks. The two-chunk sample shows that short local processing remains possible, not that the longer delays have disappeared. These unequal passes differ in startup and cache state; they do **not** establish a controlled batching speedup. No usable CPU profile was obtained: the device profiler could not attach to the independently verified app process, so attribution to a particular UI function remains unknown.

### Build 334: scoring overlap and the bounded follow-up

The cold idle-triggered scoring pass completed in **433,293 ms**, reusing **0/9** cached days. Its reported preparation segment was **63,113 ms** and scoring-loop segment **211,435 ms**. They cover only parts of the pass and are elapsed measurements, not proof of main-thread CPU occupation. Its completion line falls between host timestamps **17:52:05–06**.

Both a **forced** trigger and a **post-offload** trigger appear between **17:52:06–07**, before either following completion. Two subsequent passes reused **8/9** cached days and completed in **25,285 ms** and **29,587 ms**, with completion lines bracketed by **17:52:31–32** and **17:52:35–37** respectively. `preferences-build334-7.plist` records `rescoreOwed=false` and last-sync **17:52:05**. This verifies overlapping scoring starts after the cold pass; it does not explain the preceding 433-second cold pass or establish which work delayed BLE callbacks.

The corresponding source race is verified: the build-334 admission check precedes awaited store/fingerprint reads, while setting `computing=true` comes later. The build-335 follow-up reserves admission before suspension, retains the pending forced-pass handoff, and prevents SyncEngine from settling downstream work while scoring is active or queued. Four new real-analyzer async tests cover these boundaries. The focused run passed 33 tests; the final combined run passed 261 tests, zero failures. See the storage repair report for handset verification.

The Live screen's log list also now uses `LazyVStack` instead of eagerly creating up to roughly **5,000** rows for a 200-point viewport. It retains all log rows, exports, IDs, and scrolling callbacks. This is a source-backed reduction in eager view work, not proven attribution for Test Centre stalls: Test Centre itself has export buttons rather than the full live log, its diagnostic readouts were inactive in the copied preferences, and SyncStatusPanel reads at most eight journal entries. No handset speedup from this follow-up is established.

**Still missing:** separate commit-begin waiting, remaining unclassified callback waiting, notification arrival/FIFO age, ATT completion latency, and firmware continuation measurements. The new timers do not fill those boundaries. The exact two-hour disconnection or lifetime cause remains unproven.

### Build 335: initial handset verification

Signed build 335 from source `2c499f4` installed and launched successfully. The phone restored its connected peripheral at **18:06:19** and completed a **seven-chunk** pass at **18:06:46**, saving **1,756 rows**. A two-chunk follow-up saved **90 rows**, then an empty completion at **18:06:48** advanced the persisted last-sync time. Terminal states had no pending writes or commit in flight.

The seven-chunk pass measured local total p50/p99 **36/75 ms**, diagnostics **0/0 ms**, decode **3/59 ms**, insert **6/23 ms**, cursor **0/1 ms**, and ACK callback **22/35 ms**. Inter-chunk timing was **767/1,065 ms**. The two-chunk follow-up measured total **12/31 ms**. The new build completes history with low observed local delay in these samples; the small samples and differing runtime conditions do not establish an isolated speedup from either the admission fix or lazy log rows. Scoring completion is tracked separately in the storage repair report.

The final cold score completed in **126.103 seconds**, with 0/9 cached days, one observed start/completion pair, and no intervening scoring start. At **18:08:55**, the downstream journal settled its stage tokens. The final copied database passed `quick_check`, contained no pending `syncJob` rows, and the preferences showed `rescoreOwed=false`. This validates one complete final-build cycle, not a multi-hour locked-screen run or an isolated performance effect.

## Earlier FW 50.41.1.0 packets: measured successful path

Input: 64 sealed journals under the original workspace's `.derived/device-wire-evidence-pre-retry-20260913-1519/`. Capture interval: September 12, 22:59 UTC, through September 13, 09:06 UTC. These are **older app sessions**, not the current repaired build. The journals contain 58,960 notifications; 58,589 carry the firmware label `50.41.1.0`, and 371 have no firmware label yet. Header, record, and payload SHA-256 values were checked during replay; statistics below use checksum-valid protocol frames.

| Observation | Samples | Median | 99th percentile |
| --- | ---: | ---: | ---: |
| START → END, nonempty chunks | 752 | 361 ms | 4,230 ms |
| Data frames per nonempty chunk | 752 | 60 | 86 |
| Data bytes per nonempty chunk | 752 | 7,440 B | 8,796 B |
| Source-time span of v18 records in a chunk | 751 | 60 s | 60 s |
| END → next START without intervening COMPLETE | 665 | 105 ms | 1,375 ms |
| END → opcode-23 success response, within paired triplets | 664 | 103 ms | 1,100 ms |
| Opcode-23 success response → next START, same triplets | 664 | 0.91 ms | 42.77 ms |
| Repeated identical END payload interval | 35 | 2,282 ms | 5,916 ms |

There are 809 opcode-23 `SUCCESS` responses. All 1,799 complete metadata frames use type 49: 812 START, 842 END, and 145 COMPLETE; none is type 56. Valid historical layouts are v18, v20, v21, and v26. This capture does not support changing type-56 decoding to address this incident.

**Interpretation:** on this older successful path, almost all time between END and the next START occurs before the command success response arrives. Once that response arrives, the next history chunk usually follows within roughly a millisecond. This supports examining the application's pre-ACK work before changing transport settings.

**Limits:** journal times are notification-callback times, not over-the-air timestamps. iOS can deliver callbacks in batches. Opcode-23 responses are correlated by connection and chronological END/response/START order; outbound command sequence bindings and CoreBluetooth ATT completion callbacks are absent. END → response therefore combines application processing, scheduling, outbound transport, firmware processing, and callback delivery. It cannot isolate database latency or BLE round-trip time. The archive contains separate connections, retries, and repeated historical records; do not turn its burst timings into a claimed sustained catch-up rate or current-build speedup.

## Optimization decisions from the evidence

1. **Storage compatibility and truthful progress: implemented.** The repaired writer preserves record identity, counts actual inserted sensor rows, and retains the no-ACK-on-failed-persistence invariant. The successful pass directly verifies recovery from the observed schema failure.
2. **Complete ACK-path timing: partial.** Ordinary terminal phase summaries were verified above. The build-334 implementation now separates cursor persistence from the ACK callback, with ATT confirmation explicitly excluded. Add bounded notification arrival, FIFO age, commit-begin wait, ACK ATT completion, and next-chunk arrival measurements to separate the remaining interval. Keep session/chunk identities; avoid formatting a verbose line for every frame.
3. **Parsed-record reuse: implemented.** Rejection classification now reuses parsed records. Local equivalence tests protect decoded rows and rejection behavior. The phone's decode timing is measured above, but no isolated before/after speedup is established.
4. **Informational diagnostic batching: implemented, hardware speedup unverified.** The initial bulk pass reports diagnostic p99 of 110 ms, but later small passes reach 2,001 ms, with local total processing reaching 11,516 ms. The new awaited batch reduces separate main-actor deliveries while retaining raw evidence, ordered observations, failure reporting, and session checks. Build 334 completed sync with the new path; its later 57-chunk pass still reaches diagnostic p99 of 4,010 ms and ACK-callback p99 of 4,609 ms, with cursor p99 of 5 ms. The available samples do not establish an isolated batching speedup or eliminate callback contention.
5. **Rejection archival: conditional follow-up.** The source still performs archive work on the main actor. A serial background owner could protect UI and BLE callback responsiveness, while preserving fsync-before-ACK and coordinating retention/replay. This pass's archive p99 is 0 ms, so it does not justify treating archive work as the active bottleneck.
6. **Duplicate-retention accounting: implemented.** Waveform and auxiliary retention budgets now advance by actual inserts, preventing duplicate-only replay from triggering the 604,800-row retention walk. The pre-repair database contained 589,738 auxiliary rows. Phone retention-sweep latency remains unmeasured; maintenance scheduling changes require that evidence.
7. **Scoring admission and lazy log presentation: implemented and locally validated.** Reserve the scorer before its first suspension and preserve queued-work ownership through settlement. Lazily construct the Live log rows while retaining the full data/export path. The combined 261-test run passed. These bounded source fixes have no verified isolated handset speedup yet and do not explain the earlier cold-pass duration or establish a two-hour lifetime fix.

Do not enable timestamp-frontier skipping: a saved maximum timestamp does not prove intervening records exist. Do not parallelize trim acknowledgements or weaken persistence ordering. No captured evidence here establishes a safe firmware command for larger chunks, a different radio interval, or a higher-rate producer mode.

## Acceptance measurements

The foreground catch-up and one automatic restoration are verified above. Continue with a locked-phone run exceeding two hours, preserving build/settings identity and durable database evidence. Compare unique historical source seconds durably added per wall second; bytes and chunk counts alone include replay. Report foreground and locked-phone runs separately, with phase timing, duplicate ratio, queue age, CPU time, failed writes, and reconnects. The completed 10-minute-27-second pass does not satisfy the multi-hour lifetime check.
