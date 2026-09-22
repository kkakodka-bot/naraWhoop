# BLE capture and background delivery

## Candidate and boundaries

- Branch: `fix/ble-sync`; worktree: `/Volumes/Untitled/WHOOP NARA-ble-sync`.
- Base: local `fix/server-pipeline`, `cfb94434b1b4ed4dba587e5c4e7af405e782e560`. The available remote main did not contain this branch; remote merge status was not established. No fetch/merge, push, deployment, hosted migration, enrollment, or physical-device operation was performed.
- The original dirty `/Volumes/Untitled/WHOOP NARA-pr16` checkout was preserved.
- Inputs: its `MD FILES/01_DEEP_AUDIT.md`, `02_PRODUCTION_BUILD_SPEC.md`, `04_CODEX_ISSUE_BLE_SYNC.md`, `evidence/ble_sync.md`, and `evidence/platform_constraints.md`.
- This is a local implementation candidate, **not physical background/release qualification**.

## Runtime and durability

```text
native callback -> frozen receipt owner/session -> bounded live queue
                         |                         |
                         |                    local transaction + upload debt
                         |                         |
history -> bounded chunk -> required raw + decoded commit -> strap safe-trim ACK
                                                   |
                                         runtime post-commit wake
                                                   |
                                 sealed upload selection -> authenticated receiver ACK
                                                   |
                              server projection observed -> displayed snapshot observed
```

Raw transport does not wait for local physiological projection. Health/widget derived exports retain their existing admission checks. A strap ACK means local required data committed; it is not a cloud ACK, completed projection, or fresh display.

### Android

- `BleRuntimeIntent` synchronously persists authorized namespace, source, physical address, model, and device. Ordinary process restart may create a new generation within that same namespace/source. Restoration revalidates enrollment, permissions, background preference, current account, and the active registry address/device before reconnect.
- The foreground service is sticky only for authorized acquisition. Cold Application creation no longer cancels the service that Android is restarting. Invalid restored targets stop the notification/service. Boot/update receiver starts are guarded; an OS-denied start is not bypassed.
- Notification/UI Disconnect persists stop. Permission/enrollment/account revocation blocks recovery. OS user-stop history blocks automatic recovery until a new explicit authorization. GPS workout start does not reauthorize a stopped strap.
- The runtime owns connection observation, persisted model/address, capture power preferences, post-commit upload wakes and a 30-second idle backstop (including older sources without the new debt marker). No `AppViewModel` upload timer is required. An account/source-bound 15-minute WorkManager backstop can request upload only; it never starts acquisition. WorkManager scheduling times are OS-controlled.
- Upgrading from a build without persisted authorization requires one explicit Connect/background-enable action. Launch is not treated as permission to undo a Disconnect. Recovery covers the audited WHOOP connection and its standard/custom channels; other-brand acquisition drivers and their recovery policies are not redesigned or qualified by this change.
- A live queue commits on count (64 custom packets / 30 standard packets), 256 KiB, or first-item age (750 ms). Failure retains the exact pending prefix and retries after 5 seconds during execution. Each queue is capped at 4096 packets / 8 MiB, including in-flight entries. Rejected new input is counted and acquisition/recovery is paused visibly; accepted pending entries are not evicted. Explicit reconnect after freeing storage clears that pause. Diagnostic counters themselves cannot be guaranteed writable on a full disk.
- Receipt records freeze namespace, generation, source, device, connection session, ordinal, wall/monotonic receipt time and exact bytes. Delayed writes use the original repository and identity. Same-link registry/serial adoption changes only future receipts. Stale GATT callbacks and queued commands are fenced to the original connection. History sessions freeze identity, recheck after cursor IO, and recheck again on the GATT handler before submitting ACK.
- Live capture continues while history is draining. No new capture-mode toggle, aggressive history request, or command-arbitration bypass was introduced.
- Additive Room **46 -> 47** adds `bleRawBatch` / `bleRawMember`. Required framed custom traffic, including unknown/unmapped records and continuous-IMU frames that actually arrive on this path, is retained separately from the rotating diagnostic archive. Standard HR keeps its existing exact notification receipts. Historical raw, decoded rows and upload debt share one transaction before safe trim.
- Raw evidence capacity is 128 MiB of compressed payload plus conservative row/member charges (512/128 bytes). SQLite pages/WAL, other signal tables and existing recorder stores require additional disk space. No unacknowledged raw evidence is pruned for capacity. Raw batches are <=1 MiB unpacked / 4096 frames; a historical chunk is <=8 MiB / 4096 frames.
- Durable custom commits with matching owner/session/family/clock basis and offset coalesce for at most ten seconds. The first upload selection seals the object in the same transaction; later capture cannot alter retry bytes. This preserves fast local durability without routinely creating one raw network object per sample. The existing raw binary/object format and receipt checks are used, not a new server schema.
- Android's legacy continuous-IMU file-store multiplexer is **not** redesigned here (Issue 4 coordination remains). This candidate preserves new delivered framed IMU evidence in the required raw lane; it does not prove typed IMU projection parity or retro-upload of old continuous-store files.

### Apple

- The first custom/standard item arms a non-postponable flush deadline (750 ms default). Sparse final packets no longer need another arrival, disconnect or screen. Failure retains pending data and rearms a bounded retry. Account retirement cancels intake/deadline and existing explicit drains remain.
- Device/session groups are frozen before asynchronous IO. A pre-clock packet cannot borrow a later connection session's clock. Successful local-commit callbacks occur after required raw writes, including raw-only/pre-clock batches. Required raw admission fails closed at 128 MiB pending compressed payload; existing verified-receipt pruning remains authoritative.
- Normal known-signal decoding, exact standard notification receipts, required unknown-history quarantine and optional research capture remain distinct. This does not enable an unsupported sensor mode or turn every diagnostic log into required data.
- Periodic transport now retains a trailing wake, including a commit arriving during an upload; default permitted-execution cadence is ten seconds. The SyncEngine raw lane uses owner/debt/transport admission before the backlog or local-physiology gates.
- CoreBluetooth restoration identifiers/delegates, standing reconnect, file-backed background URLSession and command arbitration are unchanged.

## OS constraints

Timers and workers are opportunities, not execution guarantees. A kill/suspension before a packet's local transaction can lose the bounded volatile tail; that interval must be counted as unknown unless strap history/sequence evidence proves recovery. Never report it as exactly-once capture. After commit, the outbox and immutable selection survive restart/retry within capacity.

iOS restoration relaunches are conditional on Bluetooth activity/restoration eligibility; force quit, reboot/first unlock and OS eviction are separate states. iOS 26 AccessorySetupKit changes relaunch eligibility only for appropriately set-up supported accessories. No actual WHOOP AccessorySetupKit setup/eligibility was established here, so no new force-quit/reboot promise is made. See [TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules) and [Apple background transfers](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).

Android ordinary eviction is distinct from force-stop/Task Manager Stop. A persisted intent does not grant a foreground-start exemption or restore revoked permissions. See [background BLE](https://developer.android.com/develop/connectivity/bluetooth/ble/background) and [foreground-start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start).

## Observability

Apple `ProductionSync` signposts distinguish Receive, LocalCommit, upload preparation/scheduling/receipt, CloudAcknowledgement, ProjectionReady and DisplayFreshness. Android exposes six independent metadata-only slots in account-scoped `ble-pipeline-frontiers-v1`: `receive`, `local_commit`, `upload_attempt`, `cloud_ack`, `projection`, `display`; each has observed wall/monotonic time and optional source time. Receive diagnostics are rate-limited to one second. Missing source time is unknown, not fresh.

These are bounded diagnostic frontiers, not canonical data or receipts. Correlate raw membership/session metadata, durable upload selection/receipts and server result revision for a particular record. Projection/display source timestamps describe the represented result, not the most recent BLE sample. Display markers witness a view update/frame opportunity, not proof of painted pixels. Historical cursors, database counts and receipt frontiers remain separate.

## Local verification

Evidence directory: `/Volumes/Untitled/nara-ble-validation.hr55dT`. Build output was moved there after the internal system volume ran out of space; no unrelated files were deleted. The final successful logs below supersede earlier exploratory failures. Evidence belongs to this candidate worktree, not the original dirty checkout or an installed phone build.

| Check | Result | Evidence |
| --- | --- | --- |
| Android focused JVM/Robolectric tests | PASS: 71 tests, zero failures/errors/skips | `gradle-final.log`; worktree `android/app/build/test-results/testFullDebugUnitTest/` |
| Android full-flavor debug APK assembly | PASS | `gradle-final.log`; `android/app/build/outputs/apk/full/debug/` |
| Apple focused macOS-hosted tests | PASS: 24 tests, zero failures | `xcode-final.log`; `xcode/Logs/Test/` |
| Unsigned iOS Release compilation | PASS; not installed, signed or device-tested | `ios-build.log`; `xcode/Build/Products/Release-iphoneos/` |
| Whitespace/conflict check | PASS | `git diff --check` |
| Physical execution/recovery and latency targets | NOT_MEASURED | Protocol below; no handset evidence |

- Apple focused tests: capture durability, sparse deadlines, delayed scope changes, required raw before ACK, standard receipts, retry integrity, sync policy and raw transport while backlog/physiology is held.
- Android focused tests: queue deadlines/serialization/retry/capacity, real Room atomicity/reopen/source binding, raw coalescing/sealing, controlled transport retry/ACK, required unknown history before trim, delayed cursor/device-switch fencing, persisted recovery intent, migration chain and existing upload/source-adoption tests. The native database fixture pins an absent synthetic enrollment because Robolectric has no AndroidKeyStore; it does not mock Room or its write fence. The no-ViewModel receiver test exercises the actual queue, Room outbox and coordinator against an in-process controlled transport, **not** an OS-created service/WorkManager or real HTTP server.
- Inherited Android PPG test compilation was repaired narrowly: expose the existing unchanged migration SQL and give the encoding oracle a test-only reader. No wire/schema semantics changed for PPG.
- The Apple test target still has unrelated compile defects in `ExploreRangeGatingTests.swift` and `ServerScoringRescoreSkipTests.swift`; focused runs explicitly exclude those files. A broader `ScoringPreferenceContainmentTests` run encountered pre-existing fixture/projection failures (`unvalidated` rather than `complete`) and was stopped; only the new raw-admission case is included in the focused result. This is not a full-suite pass.
- An exploratory Android `W2AndroidAccountRuntimeTest` run had AndroidKeyStore fixture failures and its legacy no-directory assertion failed. Do not count that suite as passing.

Reproduce from this worktree (JDK 17 and Android SDK configured):

```sh
cd android
./gradlew :app:testFullDebugUnitTest \
  --tests com.noop.ble.LiveCaptureQueueTest \
  --tests com.noop.data.BleRawDurabilityTest \
  --tests com.noop.push.PushCoordinatorTest \
  --tests com.noop.ble.BackfillDrainGateTest \
  --tests com.noop.data.WhoopDatabaseMigrationChainTest \
  --tests com.noop.push.PpgIdentityBinaryTest \
  --tests com.noop.data.PpgRecordIdentityMigrationTest \
  --tests com.noop.ble.SourceCoordinatorAdoptionTest \
  :app:assembleFullDebug --no-build-cache --console=plain
```

From the worktree root, using Xcode 26.3 (17C529) and the XcodeGen project:

```sh
xcodegen generate
xcodebuild test -project Strand.xcodeproj -scheme Strand -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- \
  'EXCLUDED_SOURCE_FILE_NAMES=ExploreRangeGatingTests.swift ServerScoringRescoreSkipTests.swift' \
  -only-testing:StrandTests/CaptureDurabilityTests \
  -only-testing:StrandTests/SyncDrainPolicyTests \
  -only-testing:StrandTests/ScoringPreferenceContainmentTests/testRawUploadRunsDuringHistoryBurstWithUnvalidatedPhysiology
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The recorded Xcode runs additionally used `-derivedDataPath /Volumes/Untitled/nara-ble-validation.hr55dT/xcode`.

## Physical qualification protocol — NOT_MEASURED

Use a dedicated enrolled test account and controlled receiver, with exactly pinned candidate SHA/build, phone model/OS/OEM, strap model/firmware, permission and power settings. Record source/session identities without publishing credentials. Preserve stopped/coordinated database and outbox backups before fault injection. Never test disk-full or forced resets against a user's primary capture.

| Case | Procedure and required evidence |
| --- | --- |
| Sparse live-only, no UI owner | Deliver one standard/custom packet then silence; verify exact durable bytes/identity and a controlled receiver ACK. On Android destroy Activity/ViewModel while leaving acquisition eligible; do not finish history to trigger upload. |
| Locked phone | 24 hours screen-off/no routine reopen, then a 72-hour release soak. Compare phone/strap sequences, bytes, duplicate canonical keys, gaps and each independent freshness stage. |
| Backlog fairness | Drain an old historical backlog while injecting continuing live traffic. Both durable and cloud frontiers must advance; no command collisions or trim past uncommitted evidence. |
| Ordinary process eviction | Kill the process without force-stop, before commit and after commit separately. Measure/declare the pre-commit volatile tail; verify exact post-commit replay and authorized Android service reconstruction without UI. |
| Force-stop / user quit | Android force-stop and Task Manager Stop; iOS app-switcher quit. Record expected cessation/OS eligibility separately. No workaround should defeat user intent. Explicitly reopen/re-authorize before expecting recovery. |
| Reboot / unlock | Reboot and record before-first-unlock versus after-unlock. Verify only eligible authorized recovery, account/source/registry matching, and preserved committed backlog. |
| Radio / range | Bluetooth off/on, out of range/return, strap reboot and a same-device reconnect. Verify old-GATT fencing, fresh session identity and standing reconnect without aggressive history churn. |
| Network outage | Two hours offline; repeat Wi-Fi-only policy transitions. Compare exact retained bytes and replay IDs after network returns; reject malformed/mismatched ACKs and duplicates safely. |
| Disk / quota | Inject transaction failure and fill the declared test quota. No safe trim for uncommitted history; no pending-raw eviction. Verify retained retry prefix, visible pause/rejected count at exhaustion and explicit recovery after freeing space. |
| Device / account switch | Hold IO and HTTP response, switch A -> B, then release. Old data/ACKs remain A-owned; B cannot consume or settle A's generation. Repeat source replacement and enrollment revocation. |
| Low power / OEM policy | iOS Low Power Mode, Android Doze/Battery Saver/background restrictions and at least one representative OEM. Record deferred execution rather than fabricate latency passes. |
| Permission / stop | Revoke BLE permission and background preference; notification Disconnect; sign-out. None may automatically reconnect until valid authorization returns. GPS-only workout start must not undo Disconnect. |

Measure callback-to-local-commit and receipt-to-cloud-ACK p50/p95/p99, reconnect distributions, strap/phone battery, CPU/RSS/thermal state, backlog depth/oldest age and server/display lag. Proposed p95 <1 s local and <30 s ACK apply only to permitted, online execution with a healthy receiver; **neither is measured here**. Projection readiness and sensor/algorithm validity are separate downstream acceptance gates. No uninterrupted-background, production-ready or sensor-capability claim follows from these local tests.
