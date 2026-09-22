# VPS-only compute handoff

## Source and integration

Branch: `feat/vps-only-compute`, worktree `/Volumes/Untitled/WHOOP NARA-vps-only-compute`.
The original dirty `WHOOP NARA-pr16` UI checkout and user files were preserved.
Final verification source and receipt summary will be recorded below after the frozen-source runs.

The starting HEAD was `9b62c68ac1ea35fdad48008ffd02e3090dd98265`. Both `0c5a0c2` and
`9b62c68` are ancestors. Fetching `origin` found remote main
`34fc950f03199b9d26e5019311394cb49cc34c7c`; the other configured repository had the same main.
The local `fix/server-pipeline` tip and exact merge base remain
`cfb94434b1b4ed4dba587e5c4e7af405e782e560`. No newer server-pipeline commits were available to
reconcile. No fetched remote contains that local pipeline tip: this is an integrated local
candidate, not a claim that the pipeline was remotely merged or deployed.

The audit, shared production specification, both compute evidence files, ownership registry,
prior handoff and `HANDOFF_server.md` were read before implementation. No production deployment,
migration, model promotion, remote push, physical-device installation or production-data read
was performed.

## Implemented contract

All 27 families and 80 outputs in `docs/compute/metric-ownership.json` have independent final
dispositions, concrete producers, input/output contracts, consumers and validation sources.
Eight families can select qualified numeric results; the other nineteen publish explicit
server-owned states until complete qualified producers exist. This is not a claim that all
families now produce numbers. Missing details are not filled with invented DTO defaults.
Reference algorithms remain available for tests/research but cannot run in shipped hosted mode.

- Account JWT and installation enrollment routes share the actual SQL selection/Edge serializer.
  Authorization includes project, owner, source, canonical device, day/window, timezone, algorithm,
  configuration, manifest, input and result revisions. A pending device has explicit null-device
  states, never a fabricated UUID or a claim on another device.
- Numeric admission requires retained-legacy authorization plus its manifest, or the existing
  signed-reference approval with both manifests. Revocation, read failure, expiry, shadow,
  manifest mismatch and owned null never enable local fallback. Sleep-only authorization cannot
  leak embedded HRV, respiration or temperature.
- The production worker invokes `ComputeContractPublisher`. Deterministic scoring, optional
  model execution and archive/publication retry remain independently operable. Immutable
  missing-state publications retain real database identities and input/calendar revisions.
- Durable session requests preserve owner/device/source, event bounds, timezone, input revision,
  algorithm/configuration and consent. Offline drafts remain tied to their original owner and
  local device until canonical registration. Retry reuses the same ID/body; edits create revisions.
  Time-sensitive decisions expire and are deduplicated before haptic/coaching consumption.
- Phone screens, historical panels, widgets, Live Activities, watch scores, HealthKit,
  Health Connect, shortcuts and exports consume revision-bearing canonical results or explicit
  missing states. Legacy unrevisioned glance caches are retained as bytes but not admitted.
  Health export preserves unknown sleep gaps and never relabels skin temperature as core temperature.
- BLE, protocol integrity, raw waveform/provenance, durable buffering, direct device HR, timestamps,
  timers, user inputs, retry and raw upload remain local. Upload admission is independent of rescore
  and preference projection. Fresh-account BLE bootstrap/restoration bind database ownership before
  capture metadata is written.
- Hosted-mode retirement covers daily scoring, PPG/RR-derived HR, HRV, sleep, recovery, workouts,
  stress/frequency analysis, baselines, illness/context, cycle/circadian, coaching, biofeedback,
  import reconstructions, source-screen averages, medication responses and auxiliary estimates.
  Existing locally derived history remains historical provenance, not a current measurement.

The detailed API is in `docs/compute/final-hosted-contract.md`. Instrumentation inventories contain
399 Swift entrypoints and 225 Android guards. Swift numerical entrypoints fail loudly if called in
final hosted mode; optional/admission boundaries return explicit absence before numerical work.
Android installs its immutable hosted policy before application providers. Production preferences
cannot opt out. Reference-mode overrides are test-only.

## Reviewable commits by phase

These are principal integrated commits; `git log --reverse 9b62c68..HEAD` is the complete sequence.

| Phase | Principal commits |
| --- | --- |
| Ancestry/baseline repairs | `6de19b9`, `1cdc4b9`, `bef0914`, `ee536ed`, `50fb6e3`, `f0bff69`, `7a48a12`, `351f8c4`, `77896a3`, `4a3a32f` |
| Read-route parity | `6b9cf91`, `a3281a3`, `4e8e9e5`, `692eaf9`, `097d5fc`, `a898798`, `35dd6b2` |
| Production publication | `3950663`, `d7e1d2e`, `76bfa05` |
| Live/session contracts | `74751c8`, `692eaf9`, `14d15ad` |
| Consumer migration | `4b857f4`, `50eada3`, `1570bf9`, `bcd1128`, `fa74ec7`, `d4096fa`, `31f5478`, `112c734` |
| Producer retirement | `f648704`, `ebe61d6`, `c978884`, `c4a1a22`, `41da8be`, `0f79dfa`, `115bb04`, `06ab99f`, `d7964bd` |
| Instrumentation/verification | `906454f`, `06eb4cf`, `88338dd`, `3f674de`, `25ae26c`, `f2c4980` |

## Baseline failures and their classification

Initial requested checks and same-environment comparisons are retained under
`/Volumes/Untitled/compute-final-evidence.CTm7Bm`; prior-run evidence was not promoted to this source.

- Explorer's absent helpers and incomplete 2W/3W widening were inherited compile/behavior defects;
  repaired without removing the existing tests.
- Broader preference/capture fixtures lacked the capture witness or prepared writer now required by
  the reconciled base. Fixtures now establish those before inserting history. Missing-writer,
  wrong-owner and retired-runtime negative tests remain. Fresh JWT BLE bootstrap had the same
  actual ownership-order defect and was repaired in production code.
- Upload protocol fixtures depended on physical thermal pressure. Queue resource-budget injection
  now follows the same admission boundary while production defaults remain `.shared`; explicit
  critical-pressure tests remain. An obsolete cached-ACK test reproduced the same two failures on
  `cfb9443`: unknown-device legacy ACKs require terminal pause and explicit owner-scoped resolution,
  not automatic retry. Exact bytes, digests, cursors and receipts are asserted across relaunch.
- Apple workout upload assumed an Android-only route column, and receipt monotonic clocks lost the
  decimal-string wire contract. Both defects were byte-identical to the base and were repaired.
- All 197 prior analytics assertion failures were reproduced on the base: 55 expanded, 3 zone,
  134 history, 4 context and 1 current-HRV. The qualified-oracle transition retains original
  historical artifacts, input hashes and complete native DTO hashes. See
  `docs/compute/qualified-oracle-transition.md`. No RR, optical or SpO2 gate was relaxed.
- Android SDK was found/configured on the external volume. Full-app testing exposed inherited
  JVM AndroidKeyStore harness and startup/schema/receipt fixtures; test-only keystore substitution
  leaves production encryption unchanged. A standalone Kotlin check is not counted as an app build.
- Apple launch/tooling failures included internal disk exhaustion, external-volume app access,
  test-host signing, framework placement and source-fixture reads. Compiler caches stay external;
  only the ad-hoc signed test executable is staged internally. Source fixtures are freshly staged
  with verified hashes. Test scratch can use `COMPUTE_TEST_SCRATCH` on the external volume.
- New implementation compile mistakes were corrected before final receipts. Old widget/watch
  tests now exercise real canonical receipt admission and explicitly reject legacy unscoped data.

## Verification protocol and current-run evidence

`Tools/compute/check-cutover.mjs --require-final` requires twelve executed gates. Receipts bind the
clean source SHA, a content hash covering implementation/tests/build inputs, exact command, exit
status and log hash. Source changes invalidate receipts. Android requires actual executed unit
tasks with `--rerun-tasks`; macOS requires the complete `Strand` scheme without test filters.
Static assertions and executed evidence are reported separately. No global completion flag can
hide an incomplete family.

Preliminary integrated results (not substitutes for final receipts):

- All 2,224 StrandAnalytics tests passed, zero failures; 103-day late-input replay included.
- WhoopStore 819 tests, zero failures, one existing private copied-phone-DB skip.
- WhoopProtocol 767 tests, zero failures, two existing skips.
- All six supporting Swift packages passed; StrandDesign additionally tests expiry/authorization.
- Android actual APK plus 6,215 tests passed, zero failures/errors, six existing reference-data skips.
- Actual worker/SQL/account/enrollment/Swift/Kotlin chain produced and decoded 22 real envelopes.
- Generic iOS and explicit watchOS builds passed.
- Hosted app runtime/consumer tests passed with zero execution counters; added import/workout and
  sleep-adapter cases are included in the final rerun.
- Full macOS reached all 2,676 tests; the four remaining preflight failures were repaired (disk
  scratch, consent cleanup and an obsolete unqualified-baseline expectation). Final rerun pending.

Final source SHA, exact commands, counts and receipt paths: to be filled from the frozen run.
The committed receipt JSON files are the authoritative reproduction commands, not this prose.

Useful reproduction entrypoints:

```sh
node Tools/compute/check-cutover.mjs
node Tools/compute/check-cutover.mjs --require-final
swift test --package-path Packages/WhoopStore --filter Server
bash Tools/compute/run-app-checks.sh
bash Tools/compute/run-final-hosted-checks.sh
bash Tools/compute/run-support-package-checks.sh
node --test Tools/compute/*.test.mjs
```

Each final command is executed through `node Tools/compute/record-gate.mjs --gate NAME -- COMMAND`.
External SDK: `/Volumes/Untitled/physiology-v2-baseline.ROUXBD/android-sdk`; Java 17; external
Gradle cache and `/Volumes/Untitled/compute-final-tmp.TV9zWX` scratch. Local PostgreSQL/Edge runs
use disposable synthetic databases, never hosted schema changes. Colima uses a new task-owned
VM-root bind directory because the engine data volume is full; unrelated containers are untouched.

User-authorized space recovery moved, without discarding contents, the inactive `server-jvm.jI5T9f`
and `server-jvm.e99a82` directories from the Darwin temp directory to
`/Volumes/Untitled/compute-final-evidence.CTm7Bm/relocated-server-tests.dwNzpj/`.

## Integration, remaining external gates and rollback

Integrate migrations `20260921110000_final_hosted_compute_contract.sql` and
`20260921111000_compute_session_requests.sql`, shared Edge routes and the production worker before
releasing hosted-mode clients. Then integrate shared mobile contracts/ledgers, consumers and
retirement/instrumentation together. Do not cherry-pick only the phone retirement switches.
Conflict-sensitive files include `project.yml`, ownership/instrumentation JSON, shared score SQL/Edge
serialization, `ServerScoreRepository`, `Repository`, `AppModel`, `BLEManager`, Android
`AppViewModel`, importers, widget/watch snapshots and Health adapters.

Physical BLE interruption/kill recovery, target-VPS deployment/readback, real iOS/watch/Health
permissions and data delivery, background/battery soak, independent sensor references and model
promotion remain **NOT_MEASURED**. Synthetic authorization fixtures and local tests do not supply
scientific qualification or production authority. Reference-dependent existing skips are explicit.

Rollback must retain server ownership and raw capture. A previous server result/version can be
selected only if its exact identity and current authorization pass. Missing, stale, failed, revoked,
expired or unsupported results remain explicit server states; never restore phone inference or
clear ownership to manufacture fallback values. Preserve immutable results, offline requests,
raw retry debt and historical provenance. An older server lacking the new contract is unavailable
to a final-hosted client, not permission to score locally.
