# VPS-only compute handoff

Repository acceptance: **PASS**. `node Tools/compute/check-cutover.mjs --require-final` exits 0
and reports `finalHosted: READY`, 27 families, 80 outputs, no blocked families and all twelve
fresh executed gates passing. The complete result is
[`docs/compute/evidence/final-cutover.json`](docs/compute/evidence/final-cutover.json).
This is repository readiness, not a deployment or independent sensor-validation claim.

## Source and integration

Branch: `feat/vps-only-compute`, worktree `/Volumes/Untitled/WHOOP NARA-vps-only-compute`.
The original dirty `WHOOP NARA-pr16` UI checkout and user files were preserved.
Final implementation/frozen verification commit: `bf46ef7ff0d6d9d29776fc9388f4a3fcd9290680`.
Implementation/test/build content SHA-256:
`e0f31809ab16ec706f26985c3cee242df51ac0a4446d2e69595a8db3d0e3601f` (3,709 files).
Later handoff/receipt-only commits do not change this source digest.

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
The eight numeric-capable families are `night_hrv`, `current_hrv`, `sleep`, `respiration`,
`recovery`, `strain_energy`, `oxygen` and `temperature`. Availability still depends on each
result's input, quality and canonical authorization. PPG-derived HR, spot/workout/live analysis,
stress, illness, cycle/circadian and the other explicit-state families are not represented as
finished numeric producers or silently replaced with phone calculations.

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
  Apple export schema 1 distinguishes `current_result` from `historical_result`; failed/cached
  CSV reads have empty numeric cells and explicit read state. Android preserves canonical zero
  while explicitly reporting Health Connect's unsupported HRV-zero export instead of coercing it.
  Provider acquisition, file commit, and Health delete/save boundaries recheck full admission,
  including same-result-revision read failures, account switches and device changes.
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
| Ancestry/baseline repairs | `6de19b9`, `1cdc4b9`, `bef0914`, `ee536ed`, `50fb6e3`, `f0bff69`, `7a48a12`, `351f8c4`, `77896a3`, `4a3a32f`, `50f8c97` |
| Read-route parity | `6b9cf91`, `a3281a3`, `4e8e9e5`, `692eaf9`, `097d5fc`, `a898798`, `35dd6b2`, `43cadf4` |
| Production publication | `3950663`, `d7e1d2e`, `76bfa05` |
| Live/session contracts | `74751c8`, `692eaf9`, `14d15ad` |
| Consumer migration | `4b857f4`, `50eada3`, `1570bf9`, `bcd1128`, `fa74ec7`, `d4096fa`, `31f5478`, `112c734`, `dd960bb`, `e4d9c85`, `98aa326`, `485ef49` |
| Producer retirement | `f648704`, `ebe61d6`, `c978884`, `c4a1a22`, `41da8be`, `0f79dfa`, `115bb04`, `06ab99f`, `d7964bd`, `07a2fe8` |
| Instrumentation/verification | `906454f`, `06eb4cf`, `88338dd`, `3f674de`, `25ae26c`, `f2c4980`, `613c6a7`, `1695f75`, `560b63c`, `dd2c5ea`, `ebb5fc1`, `2d45021`, `80b3697`, `bf46ef7` |

## Baseline failures and their classification

Initial requested checks and same-environment comparisons are retained under
`/Volumes/Untitled/compute-final-evidence.CTm7Bm`; prior-run evidence was not promoted to this source.

| Initial command / gate | Recorded result | Evidence file in that directory |
| --- | --- | --- |
| `node Tools/compute/check-cutover.mjs` | Registry 27/80 and ownership parity passed; all 27 final dispositions blocked | `baseline-cutover.log` |
| Same command with `--require-final` | Failed final gate | `baseline-final.log` |
| `swift test --package-path Packages/WhoopStore --filter Server` | 81 tests, zero failures | `baseline-swift-server.log` |
| `bash Tools/compute/run-app-checks.sh` | 40 tests, zero failures | `baseline-app-checks.log` |
| Entire additive app target | 82 tests, 13 failures including two unexpected | `baseline-expanded-app.log` |
| Complete macOS target | Explorer missing `widened`/`readingCaption` compile failure | `baseline-full-macos.log` |
| Android application after configuring existing SDK | Unit compilation blocked by inherited PPG identity/decoder test symbols | `baseline-android.log` |

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
- Full-suite timing exposed an inherited shared-resource cooldown leak: the last BLE lifecycle
  test activates the real 15-second bulk cooldown. Health fixture setup passed after 15.360 seconds
  but failed when reached after 14.848 or 14.228 seconds. The resource-policy file is byte-identical
  to `cfb9443`; neither policy nor production admission was changed. `50f8c97` makes the fixture
  await actual admission with a 30-second failure bound, and adds cooldown/timeout regressions.
  The deliberately adjacent BLE/fixture/Health/export chain passed 35 tests, including the real
  cooldown wait. All receipts from `80b3697` were preserved externally and superseded.
- Final review found Android installed hosted enforcement in `onCreate`, leaving the earlier
  provider-startup boundary unprotected. `07a2fe8` installs it as the first operation in actual
  `attachBaseContext`, retaining the idempotent later installation. The native regression invokes
  the real attach method and a real ContentProvider callback before `onCreate`: optional HRV is
  denied with zero executions, and the intentional deep-HRV negative control throws before its
  body with zero admitted executions and one recorded forbidden attempt. Its class-loader
  isolation preserves the positive-path counters without resetting production policy/counters.
  `bf46ef7` requires both startup cases and both runtime markers. All prior receipts were
  superseded again; the interrupted `50f8c97` analytics run is retained as FAIL, not a passing gate.
- New implementation compile mistakes were corrected before final receipts. Old widget/watch
  tests now exercise real canonical receipt admission and explicitly reject legacy unscoped data.
  The final supporting-package run caught one branch-introduced stale assertion (`result-17` after
  the fixture changed to the real `compute:17` identity); `1695f75` repaired it. All earlier frozen
  receipts were superseded and every required gate rerun, even for unchanged platform source.
- The old standalone `Tests/ServerScoreReadbackNative/run.sh` source-list harness fails on both
  `cfb9443` and this branch because its stubs/source list omit enrollment dependencies. It is not
  used as decoder acceptance: those production test classes execute in the complete real app
  target, and the optional actual-worker envelope test was also executed there. The exact current
  synthetic worker fixture was staged byte-for-byte beside the test host to avoid removable-volume
  file-access blocking. Its workout collection is empty, so it does not certify populated workout
  interoperability. The required SQL/Edge/canonical-decoder chain separately executes real routes.

## Verification protocol and current-run evidence

`Tools/compute/check-cutover.mjs --require-final` requires twelve executed gates. Receipts bind the
clean source SHA, a content hash covering implementation/tests/build inputs, exact command, exit
status and log hash. Source changes invalidate receipts. Android requires actual executed unit
tasks with `--rerun-tasks`; macOS requires the complete `Strand` scheme without test filters.
The Android receipt also captures five freshly executed native JUnit reports, verifies their
case counts, absence of failures/skips, zero-inference markers and hashes. The actual database
pipeline must exercise persisted canonical selection in both production mobile decoders,
including eight mutation-negative controls; decoding legacy fields alone cannot pass.
Static assertions and executed evidence are reported separately. No global completion flag can
hide an incomplete family.

The following receipts contain the exact command arrays, working directory, timestamps,
source hashes and log hashes. Reported test counts include explicitly listed existing skips;
they must not be described as executed sensor-reference tests.

| Gate and exact command receipt | Result on the frozen source |
| --- | --- |
| [swift-protocol](docs/compute/evidence/swift-protocol.json) | PASS: 767 reported, two existing skips, zero failures |
| [swift-store](docs/compute/evidence/swift-store.json) | PASS: 819 reported, one private copied-phone-DB skip, zero failures |
| [swift-support](docs/compute/evidence/swift-support.json) | PASS: NoopLocalAccess 14, NoopPush 99, OuraProtocol 209, PolarProtocol 25, StrandDesign 79, StrandImport 263 (one private Xiaomi fixture skip); zero failures |
| [swift-analytics](docs/compute/evidence/swift-analytics.json) | PASS: all 2,224 tests, zero failures or skips; 1,276.495 seconds of XCTest execution, including long-history late-input replay |
| [swift-zero-inference](docs/compute/evidence/swift-zero-inference.json) | PASS: five tests, zero failures or skips, 2.932 seconds; eighteen optional refusals, fourteen fail-loud subprocess probes, operational transport/UI helpers and a real reference-mode control |
| [server-jvm](docs/compute/evidence/server-jvm.json) | PASS: 1,106 kernel tests (five private-reference skips), 552 service tests, zero failures/errors; fresh actual-Swift exporter two tests/13 cases; clean build/installDist |
| [server-pipeline](docs/compute/evidence/server-pipeline.json) | PASS: 119 migrations, eight actual worker invocations, 22 real Edge envelopes and persisted canonical selections per platform, eight rejected negative controls, 28 decoder unit tests |
| [ios-final-runtime](docs/compute/evidence/ios-final-runtime.json) | PASS: 32 real app-host runtime/consumer tests; all four hosted-path execution counters zero |
| [android-app](docs/compute/evidence/android-app.json) | PASS: APK plus 6,223 reported / 6,217 executed tests, six existing reference skips, zero failures/errors; 760 suites, 48 executed Gradle tasks; 19 strict native/contract tests across five captured XML reports |
| [ios-build](docs/compute/evidence/ios-build.json) | PASS: generic iOS app and embedded targets |
| [watch-build](docs/compute/evidence/watch-build.json) | PASS: explicit generic watchOS build |
| [macos-tests](docs/compute/evidence/macos-tests.json) | PASS: complete unfiltered suite, 2,689 reported, twelve existing fixture/host skips, zero failures |

The full analytics suite uses optimized Debug with explicit `-assert-config Debug`, not unchecked
optimization. Debug assertions were verified enabled. No full-suite test filter or skip was added.
The hosted runtime receipt executes production app paths in a macOS app host with the shipped
final-hosted policy enabled; it does not claim an iPhone hardware run.

Zero-inference evidence separates refusals from execution. The Apple app-host scenarios require
zero physiological executions across launch/lifecycle, raw upload, sleep edits/device changes,
workouts and live/spot/biofeedback screens. The package suite separately exercises eighteen
optional-producer refusals and fourteen deliberately forbidden numerical calls in fresh failing
subprocesses. Timers/formatting/raw provenance remain operational; a reference-mode control must
actually execute its numerical oracle. Android's positive runtime paths require zero admissions
and zero forbidden attempts; the intentional provider-startup negative control instead records
one forbidden attempt, with zero admitted executions and rejection before the numerical body.
The Android summary and strict XML preserve that distinction rather than claiming every test
has a zero forbidden-attempt count.

Consumer evidence includes actual shared Apple widget/watch builders, persisted snapshots,
Health quantity units/times/metadata and delete/save ordering, real ZIP/shortcut file writes,
and provider/admission failure boundaries. Android executes the production decoder/repository,
persisted ledger, widget save/load, ZIP writer and Health Connect adapter with a recording provider.
Both platforms test account/device changes, same-revision read failure, revocation, owned null
and valid zero. The actual SQL/Edge chain separately verifies sleep-only nested-field exclusion,
shadow/manifest/authorization rejection, historical empty days and persisted selection.

Physical Health provider delivery is separate from these repository adapter tests. The default
receipt JSON files, adjacent logs and captured runtime XML are the authoritative reproduction
commands and evidence, not a claim transferred from a previous source revision.

Additional frozen-source checks: the explicitly requested WhoopStore `--filter Server` run
passed 100 tests; `run-app-checks.sh` passed 40; checker unit tests passed 12. The isolated
`SyncRenderChecks` scheme reported nine cases, seven executed and two existing manual/AX-host
skips, zero failures. The actual current-worker envelope round-trip passed one app-host test;
its source and staged fixture both hash to
`3c4998b98dca7a5590892d3c1c50814416815b2c00c590dc46dcbce3e3945ff2`.
Its workout collection remains empty, so it is not populated-workout interoperability evidence.
These extra command logs are retained under the external evidence root with prefix `final-bf46ef7-`.
The committed `docs/compute/evidence/supplemental-checks.json` records their exact commands,
counts, source identity and adjacent log hashes, including the identical worker-fixture hashes.

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

The server gates used Java 17 at `/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`,
`PG_BIN=/opt/homebrew/opt/postgresql@18/bin`, and
`GRADLE_USER_HOME=/Volumes/Untitled/compute-final-tmp.TV9zWX/server-gradle.wU8jfr`.
`TMPDIR` and Java's `-Djava.io.tmpdir` both point to the external scratch above.
Docker context was `colima-rfo-readiness` (`DOCKER_HOST` unset). The pipeline used
`PIPELINE_TEST_BIND_DATA=1`, a newly created empty VM path `/tmp/nara-compute-pg.xpqsbn`,
`PIPELINE_TEST_V1_BINARY=/Volumes/Untitled/compute-final-tmp.TV9zWX/final-baseline.IeXQI5/baseline/scoring-service/service/build/install/service/bin/service`,
and `PIPELINE_TEST_V2_BINARY` pointing to this checkout's `scoring-service/service/build/install/service/bin/service`.
Reproduction must allocate a new empty bind directory, not reuse initialized PostgreSQL data.
The retained v1 provenance records frozen source `5caa31689da0023e111beb36850d3f81d67e1be2`
and `canonical_math_changed=false`; its provenance SHA-256 is
`41363a48806de32a7d1f3386a641d75539a37d4a07eaa81536b1c132b6dea9b8`.
The v2 worker was rebuilt clean from the exact frozen source above.

Final server artifacts are `server-jvm.OOAjIS`, `server-pipeline.O4D9qM` and
`canonical-runner-mutations.y4ZhSG` under external scratch. The fresh actual-Swift 13-case
corpus manifest hash is `e3881b6d05d26fba6faf77fcc5e7450ce56555c5e560843c01d1b6b13bb0a658`.
The committed `docs/compute/evidence/server-jvm-details/summary.json` indexes 213 fresh JUnit
reports, the Swift export log/manifest and packaged source identity with per-file hashes.
The final pipeline rerun executed all seven decoder Gradle tasks and all 28 unit tests rather
than counting an earlier up-to-date result; its real route/worker tests also executed again.
Archive credentials were intentionally absent: only the B2 archive lane was disabled;
deterministic PostgreSQL publication and independent retry tests ran. Disposable services were
stopped after testing. None of these local synthetic receipts attests a deployment.

User-authorized space recovery moved, without discarding contents, the inactive `server-jvm.jI5T9f`
and `server-jvm.e99a82` directories from the Darwin temp directory to
`/Volumes/Untitled/compute-final-evidence.CTm7Bm/relocated-server-tests.dwNzpj/`.
The directly linked inactive synthetic PostgreSQL directory `physiology-queue.Irk9Mt` was also
preserved under `relocated-postgres.CDj3we/`. Its 1,970 files (153,044,596 bytes) retained identical
pre/post tree hashes; shutdown and absence of open files were verified. `RELOCATION.md` beside it
records recovery details. Other clusters and user files were not moved.
The completed, task-owned Apple adapter products were moved intact from
`/private/tmp/nara-apple-adapters-products.aJdILe` to the same basename under external scratch,
after verifying the test process had exited and no files were open (529 MB recovered).
Only the idle daemon in the task-owned server Gradle cache was stopped after its final tests;
shared caches and unrelated processes were not stopped.

Two complete macOS attempts hit real `ENOSPC` during different SQLite WAL tests on the nearly
full internal disk; their logs/receipts remain under the external evidence root as
`final-80b3697-macos-diskfull*`. No test was weakened. A new task-owned 8 GiB APFS sparsebundle,
`/Volumes/Untitled/compute-apple-scratch.rqjMk0/AppleTestScratch.sparsebundle`, provides scratch
at `/private/tmp/nara-compute-scratch.fOxEWR` during testing. Both previously failing tests passed
unchanged there before the complete rerun. After testing, the volume was detached normally with
no open file handles; the backing image and all its contents are preserved. The signed executable
stays internal; compilation caches and the scratch volume's backing storage remain external. The additional unknown-origin
`/private/tmp/nara-jvm-artifacts.akZUMA` directory was not moved or deleted.
To reproduce, attach that image with `hdiutil attach -nobrowse -mountpoint` to an empty owned
directory and pass the mount path as `COMPUTE_TEST_SCRATCH` in the recorded macOS command.

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
