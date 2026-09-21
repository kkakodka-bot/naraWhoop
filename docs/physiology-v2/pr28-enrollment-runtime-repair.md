# Tester enrollment runtime repair

The PR 27 integration creates the application runtime from the password-session identity. Tester codes instead create a separate installation enrollment credential. An enrolled tester consequently received a guest runtime, with capture and presentation disabled, while the root displayed the strap-link gate. The gate's sign-out button cleared the password session rather than enrollment.

The phone incident confirmed a server registration receipt for the same `my-whoop` identity as the paired-device registry. An owner/source-scoped database remained present, while the broken runtime had opened a separate unassigned database. Preferences and both database/WAL pairs were copied before repair; no phone database was removed or reset.

The runtime now recognizes validated enrollment identity and replaces its model on enrollment changes. Enrollment reopens its existing owner/source directory. The account-owner metadata upgrade requires the exact stored enrollment owner and installation witness, and refuses conflicting endpoint ownership. Capture and durable uploads use the enrolled installation source and opaque token, with the existing ownership fences. Password-session credentials remain a separate authentication path.

The link gate explicitly confirms registration independently of score fetches. Sign-out clears enrollment and fences pending publication. Tester score scalars feed the current dashboard through a separate presentation field rather than fabricated account snapshot revisions. Null server results remain unavailable. Registered-device selection precedes score bootstrap.

Validation during implementation: 17 identity/storage package tests passed; 38 focused application tests passed; iPhone Release compilation passed. The full app test target has pre-existing compile failures in `ExploreRangeGatingTests.swift` and `ServerScoringRescoreSkipTests.swift`; those files were excluded for the focused app run. Final build and handset verification are recorded in the PR handoff. This change does not establish fleet latency, overnight continuity, or physiological validation.

## Build 363 follow-up

Physical follow-up found a retained upload completion with HTTP 401, `unauthorized`, and no fleet header. Capabilities used both credentials, but prepared background completion and intent renewal omitted the fleet credential. The upload queue now injects the current fleet credential at receiver-request dispatch, never on bucket PUTs and never into newly persisted job metadata. A journal flag permits one recovery of older authentication-paused receiver jobs without altering their immutable payloads or acknowledging them prematurely. Repeated genuine rejections remain paused.

The integration also omitted PR19's battery-rated-life assignment from the common family configuration method. Restored and service-detected MG connections could retain the WHOOP4 model. The common assignment is restored; a regression test seeds the wrong model and exercises this setup.

Build 364 focused verification: 42 battery/upload tests passed. The broader upload run exposed an existing incompatible test expectation that the now-supported unscoped enrollment HTTP adapter throws `staleOwner`; `testCloudPushTransportActuallyUsesScopedFileBackedRuntime` was excluded from the passing run, not changed. The two existing test-source compilation exclusions above remain. Physical upload completion, server publication, and rendered dashboard acceptance must be recorded separately from these tests.

## Sleep source and misleading pending-state follow-up

The reported displayed sleep boundaries match a preserved local `sleepSession` row under the locally derived WHOOP source, with no manual edit. At investigation time the enrolled server response had no nights, despite a completed computation revision. This is a source-selection mismatch, not evidence for shifting the detector by a fixed number of minutes. The enrollment adapter owned sleep scalar fields but omitted sleep-session ownership, allowing the account-snapshot renderer to reuse local boundaries.

Tester sleep now uses the existing enrollment-specific server renderer and owns session presentation. That renderer retains event time zones, opportunity versus asleep labels, canonical qualification, missing-epoch states and authenticated boundary-edit semantics. No personal dates, reported boundaries, account identifiers or tuning constants were added. Missing server episodes remain unavailable, not replaced with a local estimate. Password-account rendering remains separate.

Enrollment readback now publishes day states independently of account snapshots: completed empty data is `noData`, partial scalar data is `partial`, explicit revision/worker debt is `pending`, and failed/exhausted work is `failed`. No account snapshot revision is synthesized. Sleep scalar and temperature readers consume the enrollment-aware scalar accessor.

Verification: 21 focused repository-race and sleep-model tests passed on macOS, with the two existing test-source compilation exclusions noted above. Regression cases cover completed empty versus pending/failed results, ownership of session boundaries, rejection of local sleep fallback despite available scalar totals, and sign-out clearing. This source follow-up has not been installed on the phone or physically rendered. The known production durability schema/receiver mismatch remains a separate rollout blocker. A read-only profile check also found UTC calendar configuration; its synchronization and historical day assignment require separate repair/verification, not a one-phone SQL correction.
