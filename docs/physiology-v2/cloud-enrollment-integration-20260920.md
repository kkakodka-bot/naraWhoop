# Cloud enrollment integration audit — 2026-09-20

## Scope and lineage

The deployed physiology/collection baseline is `a39a0d46e3ce74fa8c5aee646e3cbb481f6525a3`.
The user's existing `codex/enrollment-identity-2026-09-19` foundation was preserved unchanged in
its original worktree and snapshotted as `76dece2` before integration. The integrated candidate
is on `fix/cloud-enrollment-integration-20260919`.

Earlier physiology audit baseline: `5caa31689da0023e111beb36850d3f81d67e1be2`;
original algorithm implementation: `5250912e5647108c548afa31b048ee4f4f6df133`.
This integration changes identity, onboarding, capture ownership, upload authorization, and
readback. It does not change physiological thresholds, promote learned models, or prove accuracy.

## Findings and repairs

These are source/behavior counterexamples, not claims that a live privacy incident occurred.
Root verified the archive and ownership paths and real SQLite regressions; a final independent
review found no unresolved P0/P1 among the reported enrollment blockers.

| Severity | Requirement and evidence / reproduction | Impact | Narrow fix and regression | Status |
|---|---|---|---|---|
| P0 | `BLEManager.rejectedHistoryArchive` and Android `RawHistoryArchive` selected one global legacy file. Enroll an empty store then replay a serialized frame left by the previous scope. | Old unowned observations could become the new account's data. | Namespace archives by owner, source, logical device and physical peripheral; never auto-replay the legacy file. `RawHistoryArchiveReplayTests`, Android `RawHistoryArchiveIdentityTest` use real frames/SQLite and wrong-device controls. | Fixed |
| P1 | Apple `CloudCaptureScope` could pin an initial unavailable credential permanently. Make the first Keychain read unavailable, then return a valid credential. | Enrollment/collection could remain blocked for the process lifetime. | Defer immutable scope assignment until a valid credential; refuse store opening until then. `CloudCaptureScopeTests`, `CloudEnrollmentTests`. | Fixed |
| P1 | `SourceCoordinator` generic BLE paths could start without enrollment and persist queued callbacks after sign-out. | Unauthenticated collection or writes after revocation. | Gate every source, disconnect on revocation, fence awaited/queued writes with a privacy generation. `SourceCoordinatorCloudGateTests` and experimental driver tests. | Fixed |
| P1 | `AppModel.wireSourceCoordinator` checked nil before an await only. Two activation calls could both pass. | Duplicate coordinators and duplicated connections/capture. | Recheck after the store await on the main actor. Final independent source review; focused app suite. | Fixed |
| P1 | Legacy upload/scoring credentials selected identities independently; fleet authorization did not prove the person or installation. | Data/readback could use a different owner from the UI account. | Reuse personal source-bound enrollment for both services; verify capability echoes, registration, selected-device identity and database ownership. Edge auth/device tests, repository race tests, live-schema transaction trial. | Fixed in candidate |
| P1 | Temporary Android secure-storage failure could be treated as missing enrollment and delete/replace identity. | Lost enrollment and stalled background collection. | Preserve credentials on transient errors, retry initialization, do not pin an absent scope. `PushEnrollmentStoreTest`, `EnrollmentDataScopeTest`. | Fixed |
| P2 | Onboarding and upgrades could complete with only local pairing. | User reached the app before cloud device linkage existed. | Require a scoped server device-registration acknowledgement; persist confirmation for offline resumes. Apple repository/gate tests; Android `DeviceLinkStoreTest`, `OnboardingCompletionTest`. | Fixed |
| P2 | The latest-device-only cache discarded device A after A→B→A offline switching. | Previously fetched results disappeared. | Query exact owner/device cache; real SQLite `ServerScoreCacheTests` and repository A/B/A regression. | Fixed |
| P2 | An unavailable feature in the new SQL response omitted `device_id` and `algorithm_version`. | Swift could reject the entire response, including qualified metrics. | Include identity on unavailable features; mixed-qualified/unqualified PostgreSQL regression. | Fixed |
| P2 | `RawDataSessionStore` read global legacy metadata after enrollment. | Old sessions/comments could appear or block new capture. | Scope metadata by owner/source and reload after activation; session store and scope tests. | Fixed |
| P2 | Operator `create-tester` created Auth records before validating code configuration. Invalid pepper/expiry left partial users. | Retrying could create confusing account state. | Validate configuration before writes; reject pepper whitespace. Zero-admin-call counterexamples in `manage.test.mjs`. | Fixed |
| P2 | `WhoopSerialIdentity.mayAdopt` rejects generic/bare legacy IDs, which the server scopes per installation. | Replacement-phone continuity of legacy wearable history remains incomplete. | Keep old history separate until physical serial and prior ownership can be proven; add a reviewed migration and replacement-device test before automatic reconciliation. | Remaining; unsafe to infer ownership |
| P2 | No multi-phone overnight soak, Android hardware enrollment, or physiological reference cohort was run for this candidate. | Source tests cannot establish hardware reliability or accuracy. | Run the named physical and reference gates; retain missingness/abstention until inputs qualify. | Remaining acceptance gate |
| P3 | Upstream build/privacy prose describes an offline-only app. | Documentation could conflict with hosted behavior. | Updated fork scope, terms, privacy preamble and enrollment guide; upstream historical sections remain identified as such. | Bounded repair |

## Verification before rollout

Evidence logs live outside the repository under `/Volumes/Untitled/physiology-audit/`.

| Check | Exact invocation / evidence | Result |
|---|---|---|
| Edge | `deno test --allow-all supabase/functions/tests/`; `enrollment-edge-lead-tests.log` | 131 passed; agent typecheck also passed |
| Operator | `node --test Tools/enrollment/manage.test.mjs`; `enrollment-operator-final-lead.log` | 23 passed, root rerun |
| PostgreSQL | `bash supabase/tests/run-enrollment-postgres.sh`; `enrollment-postgres-lead.log` | Passed; root and fresh-review reruns |
| NoopPush Swift | `swift test --package-path Packages/NoopPush --scratch-path /Volumes/Untitled/physiology-build/enrollment-push` | 41 passed |
| Device cache | WhoopStore `swift test --filter ServerScoreCacheTests` | 8 passed |
| Apple app | Focused `xcodebuild test` for enrollment, scopes, push transport, backup origin, drivers, IMU/session/archive stores, score races, rescoring, source gates and device identity; `enrollment-apple-tests-6.log` | 106 passed |
| Android broad | `testFullDebugUnitTest` before final ACK/archive follow-up | 5,743 executed, zero failures, 6 existing skips |
| Android final affected | `testFullDebugUnitTest` filtered to affected enrollment/push/store/archive/onboarding tests, then `assembleFullDebug` | 222 passed, zero skips; APK built |
| iPhone build | `xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS' CURRENT_PROJECT_VERSION=361 build`; `enrollment-ios-build361.log` | Signed build succeeded; signature verified |
| Hosted schema trial | Both reviewed migrations in one transaction, top-level nested transaction controls removed, bounded locks, migration-history inserts, then `ROLLBACK`; `enrollment-hosted-trial.log` | Passed against actual hosted schema; no persistent trial changes |
| Phone preservation | Private DB/WAL/SHM/preferences copy from build 360 before installing | Stable sizes/timestamps; all 234 WAL frames validated; copied and normalized DB `quick_check=ok` |
| Final independent review | Working-file audit, Edge 19 cases, disposable PostgreSQL runner, `git diff --check HEAD` | Passed; no remaining confirmed P0/P1 in reviewed blockers |

The disposable PostgreSQL runner uses the relevant scoring fixture migration chain, not the entire
production migration history. The hosted rollback trial supplies separate current-schema evidence.
Android's final narrow rerun does not claim that the entire 5,743-test suite was repeated afterward.
There has been no Android hardware test, overnight soak, or reference validation for this integration.

## Storage, deployment and accuracy boundaries

Existing phone history is preserved; the new account store copies pairing metadata only. No history,
upload cursors, or acknowledgements are silently reassigned. Raw archives and IMU files have the
same account/install boundary, with physical-device isolation for rejected-frame replay. Retained
owner witnesses and generation fences prevent an account switch from inheriting old pending writes.

Old fleet-only clients intentionally stop at rollout. Both `push` and `scores` must deploy after both
migrations and secrets. Rollback must preserve source authorization or revoke installation tokens;
the older receiver does not understand the new token distinctions. Exact deployment and installation
receipts are recorded separately when those actions complete.

The existing VPS worker continues to compute revision-scoped eligible results. Cloud enrollment
cannot create missing R-R timing or calibrated red/infrared measurements. Five-minute HRV still
requires real qualified beat coverage; SpO2 is unavailable where the source has no verified input
and calibration. Learned model manifests remain shadow-only. There is no claim of improved clinical
accuracy, newly installed heavy models, or production readiness from these repository tests.

| Release gate | State at candidate freeze |
|---|---|
| Implemented | Yes, except explicit legacy continuity limitation |
| Unit-tested | Yes, affected suites above |
| Integration-tested | Disposable PostgreSQL/SQLite and hosted rollback trial |
| Device-tested | Signed build and preserved pre-update phone data; new enrollment still pending |
| Overnight-soaked | Not run |
| Reference-validated | Not run |
| Deployed | Pending separate rollout receipt |

Recommendation at candidate freeze: ready for controlled device testing, not production or model promotion.
