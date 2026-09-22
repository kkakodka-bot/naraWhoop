# BLE background audit — 2026-09-15

Baseline: PR 14 head `293fd6b84aa8f3e86f18cfab35933206aa53403d`.
This review concerns the Apple BLE transport. No strap commands or physical hardware run were performed. Hosted macOS regression tests run with Bluetooth disabled.

## Findings

### VERIFIED: a fast reconnect failure could leave only an app timer

In the baseline, `BLEManager.scheduleReconnect` used `DispatchQueue.main.asyncAfter` after a connection failed in under two seconds (`Strand/BLE/BLEManager.swift:1197–1205`). The request had already failed, so CoreBluetooth held no pending connection during the 30-second wait. A background callback proves the process is executing at that instant; it does not guarantee execution until this timer fires.

The change submits the replacement connection immediately with `CBConnectPeripheralOptionStartDelayKey`. CoreBluetooth owns the cooldown. The ordinary first-drop path stays immediate; near-instant failures retain their 30-second floor. A request that is already connecting or connected is preserved.

### VERIFIED: the bond-loop pause could consume its only recovery opportunity

The baseline post-bond timeout detector called `standingConnectWhilePausedIfDue(justTripped: true)` before clearing `state.connected` (baseline lines 6498–6519). Its connected-state guard rejected that call. The later disconnect call was rejected by the freshly stamped ten-minute floor. A parked attempt that failed inside that floor had the same problem: both failure callbacks returned without leaving another request pending.

The initial post-bond retry now runs after disconnect teardown. Further paused attempts are submitted with the remaining ten-minute delay; they no longer require an additional foreground event. The cooldown is measured from the scheduled attempt, not the earlier submission time. Explicit user disconnect, device ownership, Bluetooth power, and bond-pause admission guards remain authoritative.

Open PR 6 (`bf63c3906441def8261b2f4a7c0b07deda87806c`) independently identifies the first-request ordering defect. Its patch was reviewed without merging. That patch uses a deferred initial-park flag and a maintenance wake; this change also covers consumed requests within the cooldown using CoreBluetooth's delay option.

Both reconnect defects predate PRs 8–12: `git log -S` traces the relevant code to `8e48582`. They are plausible explanations for an unattended connection failing to recover, not proof of what happened on the reported FW 50.41.1.0 strap.

### VERIFIED: background support already exists; no two-hour expiry was found

The app declares `bluetooth-central` in `project.yml`, creates the iOS central with a restoration identifier, restores peripherals in `willRestoreState`, and maintains subscriptions and pending connects. Its periodic history and keep-alive timers run in the app process. They cannot independently wake a suspended app. Incoming strap events also trigger rate-limited history syncs.

`SyncMaintenanceBackgroundScheduler` drains work for already-banked data. It does not itself read strap history. Its presence therefore does not guarantee that a disconnected or silent strap will sync on a fixed schedule.

PR 10 (`30e96cc`) defers expensive scoring during Bluetooth restoration and retries connect/foreground history requests that hit the 90-second floor. The reviewed diff does not introduce the two reconnect failures above.

## Apple platform evidence

- Apple's [Core Bluetooth background guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html) describes background event delivery, short execution windows (approximately ten seconds), timeout-free pending connects, and restoration of connections and subscriptions. Background mode does not grant an indefinitely running app process. No two-hour BLE cutoff is specified there.
- [CBConnectPeripheralOptionStartDelayKey](https://developer.apple.com/documentation/corebluetooth/cbconnectperipheraloptionstartdelaykey) passes a connection delay in seconds as an `NSNumber`. The local SDK declares availability from iOS 6/macOS 10.13, covering these app targets.
- Apple's [TN3115 restoration rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules), updated September 15, 2025, require a pending Bluetooth event/action for restoration. User force-quit, radio changes, and restart/unlock have distinct rules. The iOS 26 AccessorySetupKit footnote applies to the table's marked force-quit, Control Center, and airplane-mode cases; it must not be generalized into a claim that every restoration requires AccessorySetupKit. This repository has no AccessorySetupKit integration.
- [System automatic reconnection](https://developer.apple.com/documentation/corebluetooth/cbconnectperipheraloptionenableautoreconnect) is an optional future improvement on iOS 17/macOS 14. It uses the newer disconnect callback with `isReconnecting`; adopting it needs coordinated callback/teardown handling. It was not enabled by this change.
- Apple's [background strategy guidance](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app) leaves task scheduling to the system. A processing task is a best-effort continuation, not a guaranteed periodic BLE wake.

## Verification boundary

`BLEManagerReconnectPolicyTests` exercises immediate transport handoff with the actual CoreBluetooth delay key, fast-failure cooldowns, the post-bond detector transition, repeated consumed paused attempts, and user-disconnect/live-link guards. `BondLoopHardeningTests` retains the existing immediate-attempt floor and pause-admission coverage. These tests run without constructing a Bluetooth manager or touching a strap.

Physical acceptance remains **NOT_MEASURED**: screen-off operation beyond two hours, out-of-range return while suspended, OS termination/restoration, low-power mode, and an overnight run on FW 50.41.1.0. Record connection-error codes, lifecycle/restoration events, pending-connect submission time/delay, last history progress, committed rows, and ACK timing. A successful build or policy test does not prove radio delivery or firmware compatibility.
