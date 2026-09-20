# Background BLE lifetime review — September 15, 2026

## Outcome

There is no identified two-hour cutoff in the WHOOP BLE code. The reported fifteen-hour sync stall has a concrete local-storage cause in the phone evidence: the installed database has the research PPG primary key `(deviceId, ts, recordIndex)`, while the rebuilt writer still targeted `(deviceId, ts)`. The insert fails, the chunk transaction rolls back, and safe-trim correctly withholds the ACK. That explains stalled history independently of background radio lifetime. It does not establish why an earlier connection appeared to die after two hours.

This review inspected `fd8bf7c` and the follow-up working tree. It adds a bounded proprietary-notification repair and four policy tests. No phone launch, installation, radio command, background soak, or Xcode run was performed by this review. The root investigation owns database repair and combined verification.

## Existing foundations

- `project.yml` and `StrandiOS/Resources/Info.plist` declare `bluetooth-central`.
- `BLEManager.init` constructs a central with the stable restoration identifier `com.openwhoop.ble.central` on iOS.
- `StrandiOSApp.init` constructs `AppModel`; restoration does not wait for a user to open the Devices screen.
- The standing-connect code submits a pending CoreBluetooth request during the disconnect/failure callback. The earlier patch replaced process-timer retry delays with the system's connection-start delay.
- `willRestoreState` restores a peripheral delegate, framing family, service discovery, and store bootstrap.
- `StorePaths.defaultDatabasePath` applies `completeUntilFirstUserAuthentication` to the database directory and existing SQLite sidecars. Protection-setting errors are currently ignored; the actual on-device attributes still need verification.
- Historical chunks retain persist-before-ACK ordering. Downstream scoring has durable work records and separate background scheduling.

## What Apple supports

Background-central mode allows Bluetooth events to wake a suspended app. It does not make its process permanently runnable. Apple describes short event-processing windows, preservation of pending connections and subscriptions, and indefinite pending connection requests. Therefore the app should leave work owned by CoreBluetooth and complete each local handoff promptly. App timers provide no independent wake guarantee. [Core Bluetooth background guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)

Current TN3115 distinguishes ordinary suspension/removal from user actions. A relevant pending Bluetooth event is required for restoration. Bluetooth power changes in Settings can prevent relaunch; after reboot the first passcode unlock matters. The September 2025 update adds an iOS 26 AccessorySetupKit requirement to specified force-quit, Control Center, and Airplane Mode cases. The present code does not integrate AccessorySetupKit. This is an optional pairing-architecture project, not a switch that makes today's connection permanent. [Apple TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)

iOS 17 offers system auto-reconnection through `CBConnectPeripheralOptionEnableAutoReconnect` and an updated disconnect callback. Adopting it would require one owner for reconnect decisions and respecting `isReconnecting`, intentional disconnection, and existing bond cooldowns. Adding the option without changing those paths risks duplicate reconnect policy. The current standing-connect approach remains supported. [Auto-reconnect option](https://developer.apple.com/documentation/corebluetooth/cbconnectperipheraloptionenableautoreconnect)

A Live Activity is not an overnight execution guarantee. Apple documents expanded iOS 26 Bluetooth privileges while one is active, but an Apple engineer explicitly distinguishes a visible lock screen from a locked, dark screen for scanning behavior. Do not introduce an artificial Live Activity just to keep the process alive. [Core Bluetooth overview](https://developer.apple.com/documentation/corebluetooth), [Apple engineering clarification](https://developer.apple.com/forums/thread/815189)

## Concrete remaining gaps

### 1. Proprietary notification failure could persist indefinitely — repaired locally

WHOOP 5/MG characteristics are stored in `whoop5NotifyCharacteristics`. Before this change, `enableLiveNotifications` reconciled only WHOOP 4 custom channels and standard heart-rate/battery channels. `didUpdateNotificationStateFor` logged a failed proprietary subscription without recovery. The previous ACK patch also correctly moved history write completions out of the handshake path, removing an incidental proprietary retry.

If a proprietary subscription failed or stopped, standard HR or battery reads could still update `lastDataAt`. The general link watchdog would see activity while history remained silent. A later history request could receive an ATT completion without receiving its history notifications.

The local patch now reconciles proprietary subscriptions from the shared post-bond, keepalive, and connection-refresh path. It checks the current connected peripheral, the characteristic's owner, and encrypted-bond state; skips already-active subscriptions except for restoration; and uses a monotonic thirty-second per-characteristic retry floor. Resetting connection characteristics resets retry state. There is no retry started recursively from a failure callback. Four added policy tests cover recovery, stale/unbonded rejection, retry spacing, and restoration behavior. Physical notification recovery remains unmeasured.

### 2. History readiness precedes confirmed subscriptions — follow-up

The WHOOP 5 handshake publishes `historyReady` and schedules history after a fixed 1.5-second delay. It does not wait for proprietary notification confirmations. A slow subscribe or restoration cycle can therefore consume the first request without a working receive path. A supported improvement is a connection-scoped readiness state: record discovered required channels, wait for their successful notification callbacks, then schedule the existing history request once. A deadline should expose failure and permit bounded recovery. Determine required channels from retained captures; do not guess firmware behavior or gate on optional channels.

### 3. Local commit lifetime is not protected explicitly — proposal

The standard-HR scene flush obtains a finite UIKit background task. The historical decode/store/archive/ACK handoff does not. Suspension during this handoff can strand an otherwise healthy chunk until another wake; termination requires replay. This is a possible lifetime failure mode, not the cause proven by the current phone log.

A finite assertion can protect a short chunk handoff: acquire before local commit, release on confirmed ACK, held ACK, timeout, or disconnect. On expiration, fence the session before allowing any delayed ACK and end the assertion. Do not advertise it as renewable unlimited runtime; multiple tasks share finite system resources. This needs lifecycle tests and physical expiry coverage before integration. [UIKit background-task contract](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:))

### 4. Restoration and discovery need tighter connection identity — follow-up

`willRestoreState` chooses the first restored peripheral and seeds bonded/encrypted flags even when it is only a pending connection. Service and characteristic discovery failures only log and return. These paths deserve an explicit restored-identity selection and bounded handshake/discovery recovery, with genuine authentication distinguished from remembered state. This is most relevant to restoration or multiple devices; it is not established as the current single-strap failure.

## Measurements needed to explain the two-hour observation

Record process launch/restoration identity, scene transitions, pending connection ownership, subscription state, last proprietary notification, last durable history sample, last completed sync, failed store operation, and confirmed ACK latency. Keep history progress separate from standard-HR/battery activity. Correlate termination with device crash, watchdog, or jetsam evidence; silence alone does not identify an OS kill.

Run a locked-screen soak beyond two hours, preferably overnight, with the existing database and pairing preserved. Include one out-of-range return and system restoration; distinguish those from user force-quit. Report history seconds gained per wall second, stall duration, reconnect duration, unchanged/replayed trim counts, CPU and memory, and backlog age. Device acceptance requires automatic resumed progress and durable rows after each interruption. Policy tests and a successful build do not establish those outcomes.

## Installed-build follow-up

The user confirmed that the affected iPhone is normally left in the background, not force-quit. Build 332 restored its connected peripheral and began sync before an explicit foreground launch, then completed a 1,033-chunk catch-up. This verifies that restoration worked in that run; it does not establish a two-hour locked-screen soak. See the [phone verification report](sync-storage-repair-2026-09-15.md) for completion and durable-row evidence.
