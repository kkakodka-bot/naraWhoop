# Server repair native consumer review

Worktree: `/Volumes/Untitled/WHOOP NARA-server-repair`.
Common base: `76f2d70f621de91268e295ebcb6c6da29162991f`.
Scope: source/build/local fixture evidence only. No phone installation, production mutation, physical readback, locked continuity, soak, or capacity acceptance.

## Corrections

- Android account-result HTTP 401 now compares the exact owner and rejected access token under the account controller lock before invalidation. A late rejection cannot clear a refreshed token or replacement owner.
- Current authorization failure removes public canonical/day/sleep results immediately. The public canonical flow is read by UI, Health Connect and export consumers, so clearing only the private session was insufficient.
- Retirement invalidates in-flight request generations and clears public results. Success and failed-read fallback recheck retirement, request identity and source identity at publication. Retired readers cannot restart polling or produce an ownership placeholder.
- Identity resets use the same publication lock. Existing polling resumes under a replacement source identity; delayed old responses remain fenced.
- Both native readers use a two-second foreground interval only while an actual response reports pending computation, capped at 60 seconds per pending episode. Repeated pending revisions do not extend that deadline. Completion, read failure and background state return to the existing idle intervals (Apple 15 seconds, Android 60 seconds). The Android lifecycle hook only signals result-reader foreground state.
- Android refreshes selected historical days as well as today. Session-request draining runs separately from result reads, so it cannot delay pending-result polling.
- Apple enrollment/account canonical reading now observes the existing scoring-input-settlement invalidation and performs an authenticated read. A durable input receipt is not treated as result completion. Production upload completion already invokes `refreshVisibleDays(reason: .invalidation)`; this now re-arms polling after the read.
- An actual Apple poll-loop regression exposed first-start self-cancellation: initial identity synchronization canceled the newly created polling task. Identity is now synchronized before creating that task.

## BLE workstream boundaries

`CloudAuthClient.kt` changed only to add conditional invalidation for canonical-result read authorization failures. It does not change credential refresh, upload debt, transport retry or enrollment behavior. `MainActivity.kt` changed only to forward resume/pause/dispose state to the server-result reader. These are server-consumer boundary changes and must be included explicitly when combining the BLE branch. No additional BLE acquisition feature edits were made.

## Validation

- Complete macOS application and all StrandTests sources compiled in the hermetic Bluetooth-disabled app host.
- Initial final-hosted suite: 35 passed, zero failures; actual runtime execution counters were zero through startup, foreground/background, preferences, diagnostics, workout, coaching, sleep edit and raw upload paths.
- W1AccountIsolation, W1ImuRetirement and CaptureDurability: 24 passed, zero failures, including the common-base blocked-IMU-index direct HR persistence and wrong-owner collector rejection regressions.
- Changed Apple readback/drain suite: 42 passed, zero failures. Its actual reader loop observed pending, requested a two-second delay, published the succeeding server response and returned to 15 seconds. Budget tests cover the 60-second limit, changed identity, failure, background and completed work.
- Android native/JVM selected suites: 35 passed after the final publication-lock synchronization refinement. Existing real decoder/cache/widget/export/Health adapters were used with synthetic transport and provider fixtures.
- Final-hosted app-host checks were rerun after the consumer changes: 35 passed with zero physiological executions.
- Complete iOS simulator application build passed. No simulator or phone installation was requested.

The retained receipt and exact native source manifest are `/Volumes/Untitled/server-repair-native-validation/native-validation-receipt.json` and `native-source-manifest.json` beside it. Copies of all passing logs and Android XML results are in the same directory. The manifest identifies source bytes from the common base plus uncommitted consumer changes; it is not a release artifact receipt.

Raw logs are `/private/tmp/server-repair-final-hosted-native.log`, `/private/tmp/server-repair-capture-native.log`, `/private/tmp/server-repair-readback-native.log`, `/private/tmp/server-repair-android-consumers.log`, and `/private/tmp/server-repair-ios-build.log`. XCTest result bundles remain under `.derived/compute-final-macos/Logs/Test` on the external workspace volume; app products are internal under `/private/tmp/nara-compute-products.9pV4Yt` and `/private/tmp/nara-server-repair-ios-products`.

## Independent review

The acquisition/science reviewer inspected these actual native changes. Findings fixed: historical pending-day polling, failed-read publication outside the retirement lock, and retired poll admission. A subsequent source check also serialized identity reset with that lock.

This reviewer independently inspected the positive baseline worker fixture. It is explicitly synthetic and preserves immutable SQL/worker/Edge identity, account/enrollment parity, two persistent-daemon publications and no physical acceptance claim. An overly broad nested-HRV authorization test exemption was narrowed to the actual supported resting/overnight HR fields; no-RR HRV, SpO2 and respiration remain explicitly null-checked. Execution of that full pipeline belongs to the science/runtime reviewers.

## Limits

There is no observed server completion event subscription. Pending-result catch-up bounds the read interval after pending work is observed; it is not proof of a three-second physical publication-to-render SLA. The target includes network/decoder/render time and must be measured on the approved combined phone artifact. A result that completes before any pending observation still relies on input invalidation or normal idle polling. Native tests cannot establish actual supported producer completeness or scientific qualification.
