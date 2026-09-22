# Phone sync failure and repair — September 15, 2026

## Confirmed cause

The installed firmware is 50.41.1.0. The phone received historical chunks, but its PPG table already had primary key `(deviceId, ts, recordIndex)` from research migration `v45-v26-record-index`. The PR14 writer still used `(deviceId, ts)` and omitted the required record index. SQLite rejected the statement, rolling back the entire mixed history chunk. Persist-before-ACK correctly withheld the ACK. The same trim repeated while live heart-rate writes continued; rebuilding the unchanged writer could not repair this database incompatibility.

This directly explains the observed fifteen-hour historical stall. The differing research migration is outside PRs 8–12; those PRs are not established as its cause. The initial transport fixes addressed separate races and did not resolve this storage failure.

## Changes

- Add a transactional v46 migration to adopt the record-identity schema. Already-upgraded phone tables are preserved in place. Legacy tables retain every stored byte and SQLite rowid (needed by upload cursors), with unknown record identities represented by -1.
- Carry the decoder's existing record index into waveform persistence and reads. Deduplicate using the full key; disable timestamp-only skipping for this stream.
- Count actual inserted sensor records, including PPG-only chunks. Duplicate replays do not spend retention-sweep budgets.
- Reuse parsed history for rejection classification, preserving existing CRC and archive semantics.
- Repair WHOOP5 proprietary subscriptions after bonding through existing reconnect/keepalive reconciliation, with a thirty-second retry floor.
- Preserve storage failures in the timeout UI, fix the actor-bootstrap reservation race, and retain one timing summary per session without enabling verbose packet logs.
- Batch a chunk's informational logs, layout updates, and counters into ordered main-actor delivery. Delivery is awaited and checked against the active session; failure messages and rejected bytes remain intact. Cursor persistence and ACK submission now have separate timers, with ACK submission explicitly excluding ATT confirmation. This change is implemented for build 334; the build-332/333 measurements below predate it.
- The build-335 follow-up reserves scoring admission before the first suspension, retains a pending forced-pass handoff, and prevents downstream settlement while a score is active or queued. Its validation and handset acceptance are pending below.
- Use a lazy stack for the Live screen's log rows, retaining the complete log, exports, and scroll behavior. This avoids eagerly creating thousands of row views; it is not a proven explanation for Test Centre delays.

## Validation before handset installation

- WhoopProtocol: 732 tests, zero failures; two skips (optional external corpus and separately executed benchmark).
- WhoopStore: 538 tests, zero failures, including an opt-in write/replay test on a private SQLite backup of the actual phone database. Seven additional sensor-progress tests passed afterward.
- App BLE/backfill suites: 180 tests, zero failures.
- Informational batching adds four regression tests covering observation/order equivalence, failure and rejected-byte preservation, session invalidation, and separate awaited-delivery/cursor/ACK timing. The focused run passed 63 tests; the final broader app run passed **184 tests, zero failures** (`/private/tmp/whoop-followup-app-final-tests.log`).
- Original rows and rowids in the copied database matched byte-for-byte after migration and mixed inserts: 19,619 waveform rows, 641,903 HR rows, 712,901 RR rows, and 589,738 rows each of gravity and skin temperature. Only synthetic test rows were added to the disposable copy.
- Local release parsing benchmark: median 11.81 ms before / 6.47 ms after for 2,000 records. This is a CPU-stage result, not a handset BLE throughput measurement.

Private logs, preferences, packet captures, and databases remain outside the repository. No user database reset or manual phone database edits were performed.

The 184-test result predates the scoring-admission and lazy-log follow-up intended for build 335. That follow-up's tests, build, and handset acceptance are pending at this revision.

## Physical verification

Signed iPhone build 332 was installed in place, without resetting its container. iOS restored the connected peripheral at 17:07:12 PDT and began offload at 17:07:16, before the explicit foreground launch at 17:07:45.

- The failed trim advanced. At **17:17:43**, the strap sent `HISTORY_COMPLETE`: **1,033 confirmed chunks**, **zero pending writes**, and **337,694 actual newly inserted sensor rows** in a **10 minute 27 second** pass.
- An immediate follow-up completed at 17:17:44. The persisted last-sync timestamp advanced from the stale value to that completion.
- The post-completion phone database passed `quick_check`. Gravity and skin temperature each gained **57,516 rows**, advancing their newest timestamp by **58,669 seconds** to 17:17:34. PPG gained **1,876 rows**. These are durable database checks, separate from the app's aggregate session tally.
- Measured local chunk handling p50/p99 was **34/399 ms**; decode **3/74 ms**, insert **4/26 ms**, diagnostics **0/110 ms**, and cursor/ACK submission **0/97 ms**. Median interval between chunk-handler starts was **508 ms**. These do not isolate radio latency, and percentiles must not be subtracted to estimate it.
- At **17:18:07**, the latest downstream journal pass settled all four stage tokens in **22.484 seconds**; `syncJob` was empty and the rescore-owed flag was false. Actual rescore duration was **21.774 seconds**. A settled upload token alone does not prove a remote upload occurred; an unconfigured exporter also settles its job.

The user then reported seeing old “failed rescore / still owed” entries. They were historical entries, and the open diagnostics panel did not reload when the newer pass finished. A small follow-up refreshes it after the journal changes, labels current work **Pending now**, and labels historical debt **pending after pass**, preserving old error notes. Build 333 carries this display fix with the same verified sync repair.

Build 333 subsequently completed **535 newly inserted sensor rows in three confirmed chunks**, followed by an empty completion at **17:26:22**. Its local processing p50/p99 was **15/38 ms** while a resumed cold scoring pass was active. That cold pass reused 0/9 cached days and completed in **116.923 seconds**; the trailing warm pass reused 8/9 and completed in **13.852 seconds**, after which the rescore-owed flag was false. A later automatic pass completed **12 confirmed chunks at 17:37:38**, followed by further completions at **17:37:39**; last-sync advanced again, scoring debt cleared, and the latest warm scoring duration was **15.026 seconds**. These continued successes predate the informational batching change and cannot establish its speedup.

### Installed build 334

The batching and split-timer implementation was built from source commit `51d7d75`, signed as **11.1.1 (334)**, installed in the same app container, and launched successfully. The subsequent build-335 follow-up adds source changes for scoring admission and lazy log presentation; the measurements in this section remain specific to installed build 334.

- At **17:44:58**, history completed with **nine confirmed chunks**, **2,527 newly inserted sensor rows**, no pending writes, and no commit in flight. A records-bearing follow-up added **56 rows**, then an empty follow-up completed at **17:45:02**.
- The nine-chunk pass measured local processing p50/p99 **155/855 ms**, cursor persistence **0/2 ms**, and ACK submission **65/454 ms**. These new timers separate storage from callback scheduling; neither measures ATT confirmation latency.
- At **17:46:36**, another two-chunk pass saved **549 new rows** and completed, followed by an empty completion. Local processing was **19/20 ms**, cursor persistence **0/0 ms**, and ACK submission **12/13 ms**. The persisted last-sync timestamp advanced again.
- At **17:52:00**, a later pass completed **57 confirmed chunks** and **1,847 new sensor rows**. Local processing p50/p99 was **529/9,600 ms**, informational diagnostics **0/4,010 ms**, cursor persistence **0/5 ms**, ACK callback **163/4,609 ms**, decode **1/22 ms**, and insertion **1/63 ms**. Batching therefore did not eliminate the observed long local delays. These separate percentile distributions must not be added to manufacture a per-chunk breakdown.
- The small passes differ in startup/cache state and sample size. They verify continued syncing and functioning instrumentation, not a controlled percentage speedup from batching. No new persistence failure appears in these retained logs.

The build-334 cold scoring pass reused **0/9** cached days and took **433.293 seconds**. Its measured preparation and scoring-loop segments were **63.113** and **211.435 seconds**; those do not cover the complete pass or identify main-actor occupancy. After that cold pass completed, both a forced and a post-offload trigger appeared before either next completion. The two subsequent passes reported **25.285** and **29.587 seconds**, each reusing **8/9** days. The final copied preferences show `rescoreOwed=false` and last-sync **17:52:05**.

Source inspection verifies a scoring admission race in build 334: `analyzeRecent` checked `computing`, then awaited store/fingerprint access before setting it. Two callers could pass that check before either reserved the scorer. The build-335 follow-up moves the reservation before the first await, keeps the pending forced-pass handoff visible, and blocks premature downstream settlement. The observed overlapping triggers occurred **after** the 433-second cold pass, so this race does not explain that cold-pass duration. Handset speedup and elimination of the long callback delays remain unverified.

Evidence: private `install334-result.json`, `launch334-result.json`, and `preferences-build334-{1,2,3,6,7}.plist`; signed build log `/private/tmp/whoop-phone-repair-build334.log`.

### Build 335 validation

Four additional async regressions exercise the real analyzer across suspended preflight and queued handoff, including preservation of the actual SQLite job token and blocking downstream work. The focused run passed **33 tests**. The combined BLE, sync, scoring, and background-policy run passed **261 tests, zero failures** (`/private/tmp/whoop-build335-app-tests.log`). Independent review found no blocking issue. The new source also changes the Live log viewport to lazy row construction; it retains all log data and export behavior. Scoring formulas are unchanged.

Signed **11.1.1 (335)**, built from source commit `2c499f4`, was installed and launched successfully. CoreBluetooth restored the connected peripheral at **18:06:19**. At **18:06:46**, a seven-chunk pass completed with **1,756 new sensor rows**, zero pending writes, and no commit in flight. A two-chunk pass added **90 rows** and completed at **18:06:47**, followed by an empty completion at **18:06:48**. The persisted last-sync timestamp advanced to that final completion.

The seven-chunk pass measured local processing p50/p99 **36/75 ms**, diagnostics **0/0 ms**, decode **3/59 ms**, insert **6/23 ms**, cursor persistence **0/1 ms**, and ACK submission **22/35 ms**. The later two-chunk pass measured **12/31 ms** total. These are successful final-build observations, not a controlled performance comparison. Evidence: private `install335-result.json`, `launch335-result.json`, `preferences-build335-{1,2,3}.plist`, and signed build log `/private/tmp/whoop-phone-repair-build335.log`.

Final build-335 checks: the cold scoring pass reused **0/9** days and completed in **126.103 seconds**. The retained log has one post-offload scoring start followed by one completion, with no overlapping start in this observed pass. The copied preferences show `rescoreOwed=false`. At **18:08:55**, the latest journal pass settled all four stage tokens in **126.987 seconds**, with no error note and no remaining stages owed. A fresh phone database snapshot passed `quick_check` and its `syncJob` table was empty. As above, token settlement alone does not prove a remote upload or HealthKit write occurred. Evidence: private `preferences-build335-4.plist` and `build335-db/summary.json`.

The installed executable was built from `2c499f4`; subsequent amendments add this verification record only. No push was performed.

## Remaining limits

The user confirmed an iPhone left in the background, not swiped closed. The two-hour lifetime report is not explained by a proven fixed cutoff. Apple supports event-driven background Bluetooth and restoration, not a permanently running app. A locked-phone soak exceeding two hours, range-loss, and recovery testing have not been completed. Warm scoring observations ranged from roughly 14–15 seconds in build 333 to roughly 25–30 seconds for the overlapping build-334 passes; cold passes took roughly 117 and 433 seconds. These observations cross the existing twenty-second background policy threshold and do not establish a fixed runtime budget. A future long rescore can still be deferred to a processing task, separately from BLE ingestion. Old journal entries can label such deferral as failure because the engine currently returns only a Boolean outcome. Cloud PPG transport currently omits recordIndex; this BLE repair preserves local data and does not change the cloud wire contract. Android retains its existing waveform key; the shared schema oracle records that divergence explicitly.

See the companion [throughput evidence](sync-throughput-evidence-2026-09-15.md), [pipeline review](sync-pipeline-performance-2026-09-15.md), and [background lifetime review](ble-background-lifetime-2026-09-15.md).
