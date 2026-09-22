# VPS-only compute handoff

## Status and exact scope

**PARTIAL IMPLEMENTATION — final hosted mode is NOT_READY.** This branch fixes ownership and
raw-upload orchestration boundaries. It does not complete the requested removal of phone
physiology. No production setting was enabled and no sensor qualification was relaxed.

- Branch: `feat/vps-only-compute`.
- Worktree: `/Volumes/Untitled/WHOOP NARA-vps-only-compute`.
- Server-pipeline base: `cfb94434b1b4ed4dba587e5c4e7af405e782e560`, the inspected local
  `fix/server-pipeline` tip. Its merge into remote main was **not established**; this is not a
  claim to have built a remotely merged release.
- Implementation: `0c5a0c2` (`Persist scoped physiology ownership and decouple raw upload from scoring`).
- The original `WHOOP NARA-pr16` checkout, dirty UI work, and attached files were preserved.
- No hosted migration, deployment, production-data read, model promotion, device installation,
  remote push, or physical experiment was performed.

Inputs were the attached `01_DEEP_AUDIT.md`, `02_PRODUCTION_BUILD_SPEC.md`,
`evidence/local_compute.md`, and `evidence/server_compute.md`, reconciled against the newer
server-pipeline source and `HANDOFF_server.md`. Their hashes and candidate evidence are recorded
in `/Volumes/Untitled/vps-only-compute-evidence.7jZrF2/verification.md`.

## Implemented here

### Inventory and ownership

[The registry](docs/compute/metric-ownership.json) inventories 27 families and 80 outputs,
including every current `ServerScoreMetric`, live inferred HR, current/spot HRV, PPG HR,
sessions, baselines, context, coaching and insights. Each row includes phone producer paths,
required inputs, a real server implementation/entrypoint where one exists, output units and
details, read routes, consumers, cutover state and validation gaps. Unimplemented contracts
and producers are marked as such, not populated with invented runtime evidence.

The Swift and Kotlin `ServerMetricOwnership` implementations separate durable ownership from
the availability of today's result. Claims are scoped to project, account and canonical device;
they store the exact claimed metric set, algorithm, input revision and available manifest hashes.
A claim requires the existing canonical-availability gate and a computed, revision-bearing
publication. This preserves the inherited retained-v1 rule and signed-approval rule for newer
versions; it does **not** establish new scientific qualification for retained v1.

Null, pending, failed, revoked, empty historical days and paused reads cannot remove a claim.
Each value must still pass current canonical authorization. Missing owned values remain null;
real zero is preserved. Read failures retain cached revision metadata and explicitly mark the
presentation stale, with a separate `server_read_failed` transport reason.

Enrollment repository reads restore claims across relaunch, fence owner/project/source/token/
device transitions, and do not let the last fetched day redefine ownership. Existing correctly
scoped cache rows can seed the ledger; unknown or different-project/device caches cannot.
The Android Today adapter reads persisted ownership even when reads are paused, and its Rest
tile consumes `daily.rest` instead of reconstructing a score from sleep efficiency. Absolute
skin temperature is no longer replaced by temperature deviation.

The global `overlayLive` bit no longer controls producer suppression. The daily kernel still
runs because its complete output set includes unported workouts, history and baselines.
**No local physiological producer has been removed by this change.**

### Raw upload admission

`SyncEngine` drains `cloudPush` before local rescore and gives it separate admission based on
the captured runtime identity and exact durable upload-job token. It does not call
`preparePreferenceProjection`, `runPreferenceProjection`, or `capturePreferenceExportAdmission`
as a raw-upload prerequisite. `hasRunnableWork` recognizes independently owed raw upload.

`CloudPushWorker` still checks captured database ownership, source, endpoint, transport
admission, durable selections and exact receipts. A newer raw token cannot be settled by an
older attempt. Health and widget exports retain their existing derived-data barrier; they
have **not** been migrated to canonical result-revision admission.

This does not claim capture/upload performance, process-kill recovery or real network receipts
from the app tests. Those tests use the real app and SQLite orchestration with a synthetic
transport-stage driver. The existing BLE/direct periodic transport path remains unchanged.

## Verification and limits

The external verification receipt pins completed runs to their source commit. Reproduction:

```sh
node Tools/compute/check-cutover.mjs
node Tools/compute/check-cutover.mjs --require-final # expected failure: NOT_READY
swift test --package-path Packages/WhoopStore --filter Server
bash Tools/compute/run-app-checks.sh

JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  bash Tools/server-score-contract/run-mobile-decoders.sh \
  /Volumes/Untitled/vps-only-compute-evidence.7jZrF2/real-route-envelopes
```

Completed code-commit gates include 81 Swift server/cache/ownership tests, 21 production Kotlin
codec/selection/ownership tests, and 40 focused app tests for identity races, persistence,
missingness, raw-stage ordering, held preference work and exact token settlement. The macOS
test host and iOS/watch generic simulator build pass at `0c5a0c2`; the receipt records their logs.

`scoring-service/scripts/test-server-pipeline.sh` applied all 117 migration files to a disposable
local database, exercised real SQL and the actual enrolled Edge handler, and emitted eight
unchanged envelopes consumed by both production phone decoders. It checks missing/shadow/
approved/sleep-only/revoked/manifest-mismatched/other-device states. Synthetic approval fixtures
are not sensor/reference qualification. Neither worker-binary argument was supplied in this run:
this is SQL/API/decoder evidence, **not** fresh worker or deployed-VPS acceptance.

Known unsuccessful gates are retained, not concealed:

- The original full macOS test target does not compile: `ExploreRangeGatingTests` references
  missing `widened` and `readingCaption` members. The additive focused target does not change
  or exclude files from the original target.
- An expanded run of the additive target also failed broader preference tests: source-discovery/
  permit cases in `ScoringPreferenceAppTests`, and three accepted-successor barrier assertions
  in `ScoringPreferenceContainmentTests`. A former raw-runnable expectation was updated to the
  new contract. Passing the changed-path subset is not a full-suite pass; the other failures
  were not established as regressions or baseline failures by a same-environment base rerun.
- The first iOS simulator build failed compiling watch assets because Macintosh HD was out of
  space. A retry at `0c5a0c2` with `TMPDIR=/Volumes/Untitled/vps-only-compute-tmp.4PD4pD/`
  succeeded, including watch assets. No unrelated files were deleted. This is build evidence,
  not physical iOS/watch execution or consumer-revision acceptance.
- Android `:app:compileFullDebugKotlin` was blocked because the Android SDK was not installed/
  configured in this environment. The standalone Kotlin checks do not compile Compose,
  Android lifecycle/storage adapters, or the complete application.

## Acceptance matrix

| Requested gate | Current evidence/state |
| --- | --- |
| No phone physiological calls in final hosted mode | **NOT_IMPLEMENTED / NOT_READY**. No complete call instrumentation; local producers remain reachable. |
| Raw upload independent of local analytics | **PARTIAL**. App orchestration/token tests pass; physical capture, real app receipts and kill/retry acceptance remain unmeasured. |
| Account/enrollment and platform ownership parity | **PARTIAL**. Shared Swift/Kotlin ledger/selection behavior is tested. Account readers still use the historical snapshot route. |
| Same result revision on every screen/widget/watch/export | **NOT_READY**. Enrollment scalar state is not a complete revision-bearing consumer cache; exports remain legacy. |
| Late inputs, edits, DST/travel, devices and baselines update all consumers | **NOT_READY**. Base server replay exists; this candidate has no end-to-end all-consumer proof. |
| Sensor/reference qualification | **NOT_MEASURED**, unchanged. HRV continuity and optical/calibration gates remain intact. |

The registry checker verifies source paths, enum coverage, platform ownership maps and daily
dependency closure. `--require-final` fails for all incomplete families. It is not runtime
instrumentation and cannot establish zero mobile inference.

## Remaining implementation, in dependency order

1. Confirm the agreed merged server-pipeline head before integration. Reconcile later changes
   without transplanting this checkout's evidence onto another source revision.
2. Route both app account readers through the same validated physiology selection/serialization
   contract as enrollment. The server has `server_scoring_for_day` and
   `server_scoring_for_device_day`, but app account paths still read
   `get_server_score_snapshot_v2`. Preserve explicit selected-device and project fences; do not
   fabricate historical snapshot revisions from physiology envelope fields.
3. Complete canonical publication for the historical worker's metric/context/day-cycle/workout
   producers and every required detail/series. They are wired at the base but remain a distinct
   shadow contract. Preserve snapshot-consistent checkpoints and dependency-aware replay for
   late observations, profile/baseline edits, sleep/workout edits, DST, travel and device changes.
4. Add real VPS PPG-to-HR input adaptation and production invocation. The verified object reader
   alone does not qualify optical channels/clocks; historical scalar input still includes
   phone-derived PPG HR. Preserve device-HR versus inferred-HR provenance. Remove phone PPG HR,
   RR-to-HR fallback and physiological smoothing only after equivalent consumed results exist.
5. Add durable, owner/device/session-scoped spot HRV, incremental workout effort, biofeedback and
   coaching request/result paths. Server decisions need expiry/deduplication; offline capture
   keeps working but must not compute replacement physiology.
6. Move current HRV, stress/frequency analysis/events, illness, cycle/circadian, sleep composites,
   baselines and insights into canonical server results. Migrate old/new screens, charts, both
   widget paths, watch publication, HealthKit/Health Connect and exports together at a known
   immutable result identity. Remove Android widget Rest recomputation as part of that work.
7. Split and retire the local producers family by family after producer, qualification,
   selection, complete detail contract and consumer closure are proven. Add call instrumentation
   at all phone inference entrypoints and exercise every lifecycle/session/import/edit path.
   The central daily-kernel gate alone is not sufficient.
8. Obtain independent qualification and authorized deployment/device evidence. Run physical
   capture/upload recovery, background soaks, platform route parity and controlled CPU/memory/
   battery comparisons. These require additional evidence, not changes to thresholds.

Items 2–7 are unfinished engineering, not merely unavailable production-test credentials.

## Cutover and rollback boundaries

| Family/group | Current cutover | Permitted failure/rollback behavior |
| --- | --- | --- |
| Existing selected HRV/respiration/sleep envelope fields | Persistent enrollment rendering claims; partial consumer coverage | Retain same-scope authorized cached result as stale, or explicit missing state. Keep claim after failure/revocation. A prior server version still needs canonical selection and authorization. |
| Historical/context/workout/baseline outputs | Shadow/legacy transition; no producer removal | Keep explicitly inventoried legacy paths until complete server/consumer closure. Never relabel a shadow result canonical. |
| PPG-derived HR, spot/live session inference and other unported outputs | Local producers retained; final mode blocked | Finish actual VPS producer and request/result contract first. Do not replace absent sensor input with plausible values. |
| Widgets/watch/Health exports | Not fully migrated | Do not bypass their existing derived-export admission using the new raw-upload admission. |

There is no hosted migration to roll back. Ownership persistence is additive; do not delete its
claims or toggle reads off to restore local output for an owned metric. Reverting to the old
global-overlay release would reintroduce the audited failure modes and is not an approved
final-mode rollback. No broad database/cache clearing or rewriting of historical provenance is
part of this branch.
