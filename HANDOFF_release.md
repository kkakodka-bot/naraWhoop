# FRWHOOP integrated phone-test candidate handoff

The executable source and release artifacts in this document are bound to frozen source commit `33a38c5167afec5beeadd700be714e89fa25fb57`. This handoff is not an authorization to deploy, apply production migrations, merge `main`, or install either application on a physical phone.

## Release decision

The integrated repository candidate is on `release/integration`. Its frozen executable source is:

| Identity | Value |
| --- | --- |
| Source/artifact commit | `33a38c5167afec5beeadd700be714e89fa25fb57` |
| Git tree | `ac214a04747732cbd0a7aa14208eddd8b0c360dd` |
| Source-content SHA-256 | `df99a359acb0a94bed3088a23d5aeea2e1b50482e53ec41efcb7d33fa6f0ffbf` |
| Source file count | 3,781 |
| Frozen source status | clean before and after source-bound gates |
| Artifact root | `/Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57` |
| Documentation-only branch tip | the commit containing this handoff; recorded after commit in `/Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57/release/finalization.json` |

`33a38c5` is the final executable candidate SHA and the identity embedded in the worker and mobile artifacts. The final branch tip will advance only for this release record; a commit cannot contain its own identity, so the exact documentation-only tip and handoff hash are recorded after commit in `release/finalization.json` without relabeling artifacts as having been built from it.

Repository integration, disposable-schema validation, actual local route/decoder integration, Android build/tests, selected-v1 and shadow-v2 image construction, Edge/deployment bundles, and the final local capacity measurement have completed. The candidate is **not operational**: neither worker image has been published or deployed, the seven pending migrations have not been applied to production, the Edge bundle has not been deployed, no target-VPS heartbeat has been observed, and no app has been installed on a physical phone. The issue reports that selected v1 has no fresh hosted heartbeat and the running v2 shadow image predates the current heartbeat contract. This session did not re-query or mutate the target, so deployed identities, roles, digests, and heartbeat progress remain UNVERIFIED/BLOCKED pending authorized target capture.

The measured release admission is `CONDITIONAL_CANARY_ONLY`: 10 active owners, 20 devices, four physiology worker processes, a 60-second publication p95 SLO, and the declared database connection budget below. The 1,000-owner local scheduler result failed that SLO and must not be described as supported fleet capacity.

## Exact integration inputs

`git fetch --prune origin` completed at `2026-09-22T13:56:54Z`. No matching remote heads existed for the five requested local branches, so the clean, complete local branch worktrees were the available integration inputs. Every workstream has merge base `cfb94434b1b4ed4dba587e5c4e7af405e782e560` with `fix/server-pipeline` and descends from that lineage.

| Workstream | Branch | Inspected tip | Worktree status | Merge base | Input handoff SHA-256 | Merge commit |
| --- | --- | --- | --- | --- | --- | --- |
| Server base | `fix/server-pipeline` | `cfb94434b1b4ed4dba587e5c4e7af405e782e560` | clean | same commit | `HANDOFF_server.md` `393a1e3fff722747b8870bcea8884d08c8461beb352e7a8f92e11ba997b40684` | branch base |
| Multi-user | `feat/multiuser-scale` | `0eac19cce495e761dc3d832dd1cfd8a07221c61d` | clean | `cfb94434b1b4ed4dba587e5c4e7af405e782e560` | `HANDOFF_multiuser.md` `dd112c19d4f4a914961550874daf36bd2522267572b5369ff414ee62e7e63638` | `8d20d0eb8fb531a1c57db0cf56ee0ccfcd358a07` |
| Sensor algorithms | `feat/sensor-algorithms` | `198b99924a79148ff01833115fe2f47f2025bfa4` | clean | `cfb94434b1b4ed4dba587e5c4e7af405e782e560` | `HANDOFF_signals.md` `360d4cb6c6040af23989956bb182093ab0f48776e3bf05196ea33fbb4e290606` | `7c83261502fba7d61c038d8d8bcbb55e26ca049f` |
| BLE sync | `fix/ble-sync` | `af9468f7a48cc3fddeb33d7a3b983204af620ca6` | clean | `cfb94434b1b4ed4dba587e5c4e7af405e782e560` | `HANDOFF_ble.md` `bd2504c2bca8c89b5c56d0db00e66a160b7f94aa81733d22afd1263df208f48e` | `a27aa98d80dab1da754fb7dc0c22e09631ecdbde` |
| VPS-only compute | `feat/vps-only-compute` | `63ac35d0cab0644d197e8225d9fc97e1bd9446cf` | clean | `cfb94434b1b4ed4dba587e5c4e7af405e782e560` | source-tip `HANDOFF_compute.md` `eb8e1e09018759cbb75a2d7b5ba3a191c5d1936c128593981ffdfa30682e456f` | `e2b654e9465d1c0f9650f3a1105af75d23db5a88` |

The integrated `HANDOFF_compute.md` was updated during reconciliation and hashes to `12fa7d036dbe2328f8eac8d874fd42c204462b1dd75e1c0f36e79f11f72672ff`. Its source branch handoff records repository acceptance as PASS while keeping deployment, physical-device, sensor-reference, and soak claims separate.

The governing documents were read from the preserved original checkout:

| Document | SHA-256 |
| --- | --- |
| `01_DEEP_AUDIT.md` | `31ebb324d9eb270a260a5c227a9c1fb11cfdb82eb0a29cca29ead86bcdeac149` |
| `02_PRODUCTION_BUILD_SPEC.md` | `e509675f89fc3b12c685019f1c3f1712f54021b0bc895968dd3a06811b4f9e51` |
| `09_ACCEPTANCE_RUNBOOK.md` | `b6a1f25263e2651c01b2b82f8e9feef66f03392e8c5d990b461145d8650d2281` |

The original `/Volumes/Untitled/WHOOP NARA-pr16` checkout and its unrelated user work were not reset, cleaned, stashed, overwritten, or used for integration edits. Integration ran in `/Volumes/Untitled/WHOOP NARA-release-integration`. Input/fetch/worktree receipts are under `planning/input-audit/` in the artifact root.

## Merge order and contract resolutions

The required order was used, with merge commits: multi-user, sensor algorithms, BLE sync, then VPS-only compute. The raw remerge conflict record is `planning/merge-remerge-diffs.txt` (SHA-256 `83d8137aefe78b06acf290816940808677e9425ccc49ad54dc87e7d3986acb3a`, 71,358 bytes). The normalized decisions are in `planning/conflict-resolutions.json` (SHA-256 `f6c77f70799eedb964705fbb157f03c42bbe382904d1c687618675357966fbc1`).

The resolutions were:

- **Multi-user:** clean merge. Fleet lifecycle, fair scheduling, admission limits, quotas, and connection budgets were retained.
- **Sensor scoring poller:** retained closed sensor-window enqueue and bounded fleet polling. Neither scheduler path replaced the other.
- **Raw object identity:** manifests retain `source_id`, originating physical `device_id`, and canonical device identity. Owner/canonical-device authorization is checked while object keys remain bound to the originating physical device. Bounded object filters were retained.
- **Migration catalogs:** appended both workstream sequences. No sequence was discarded or duplicated.
- **Android ACK/pruning:** retained the exact accepted-prefix ACK and destination-scoped frozen progress. Immutable receipt selection is rechecked before ACK. A bounded additional pass continues until both raw and continuous-IMU inventories are exhausted.
- **Android raw lanes:** durable `bleRawBatch` rows are processed before continuous-IMU archive fallback without dropping either lane. The platform ingestion registries now include both `bleRawBatch` and `bleRawMember`; all three registry copies are byte-identical.
- **Apple capture and compute retirement:** raw capture/upload remains independent of local physiological and derived-export gates. Final-hosted mode disables local PPG physiological derivation while retaining raw waveform capture/upload and direct wearable observations.
- **Consumers:** persisted ownership is metric-scoped and revision-bearing. Widgets, watch, screens, HealthKit, Health Connect, shortcuts, and exports admit only authorized immutable server results or explicit missing states.
- **Resources/runtime:** raw, session, disposition, and database resources close on all paths. Pipeline bind-data and tmpfs modes remain mutually exclusive.
- **Compute migrations:** proposed compute timestamps `20260921110000` and `20260921111000` collided with multi-user identities. Because neither compute migration had been applied, they were renamed before application to `20260921121000` and `20260921122000`. Applied history was not rewritten.
- **Mobile decoder contract:** strict production Swift and Android response decoders were retained. The Android harness imports real app sources rather than a duplicate projection. Negative envelope mutations must be rejected.
- **Selected-v1 integration fixture:** the disposable test database alone receives the required ingest secret for the unchanged `internal.assert_ingest_secret` guard. No production authorization check was weakened.
- **Android release inspection:** the approved aapt2 writes its version on stderr and emits `sdkVersion` in badging. The release inspector now requires the exact reviewed stderr version with empty stdout, parses the real SDK field, and rejects altered, mixed-channel, or nonzero output. The earlier `cf38b5c` artifacts were invalidated and rebuilt from `33a38c5`.

Post-merge reconciliation commits include `dac91b3` (migration/schema/orchestration integration), `e1c80c7` (metric-scoped revision-bearing caches and explicit missingness), `7647ddb` (real Android decoder source binding), `244dd26` (strict negative envelope mutations), `e1e4836` (registry parity), and `cf38b5c` (test-only ingest-secret fixture), followed by `33a38c5` (fail-closed reviewed Android artifact inspection). The full first-parent history between base and frozen source is preserved in Git; intermediate hardening/artifact-tooling commits are `2356a6e`, `6e04626`, `556d8e0`, `6acc711`, `d10f7da`, `0df1db7`, and `e10d4c9`.

These resolutions preserve owner/device/source isolation, revision and lease fencing, immutable result identities, qualification and manifest validation, shadow/canonical separation, independent raw upload, exact ACK/pruning boundaries, explicit missingness, Android recovery and frozen receipt identity, continuous-IMU parity, and fleet connection budgets.

## Migration manifest and schema reconciliation

The immutable manifest is:

```text
/Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57/migrations/artifacts/migration-manifest.json
file SHA-256: 6c54aa047fbdb2e7da2b1412d06a69e5b82603c8501c3c061559cd5b57205ac2
manifest fingerprint: c7c6348df709c28422a97ac19354d499fb784727ef94ab7edcd665264f171293
schema-source fingerprint: 910a1c74a760b496028d7c2c58c009f45e29f9643fd2c279c278156f9a23d4c5
```

It records all 124 filenames, stable identities, file hashes, ordered dependencies, source workstreams, collision/rename state, fresh-install behavior, and upgrade behavior. It was generated twice byte-identically. There are 117 reviewed hosted-applied identities and seven pending identities. Across all 124 migrations, the source-workstream totals are 117 server-pipeline, four multi-user, one sensor, zero BLE, and two compute migrations.

The hosted baseline receipt records project `sgoyxzcagqyxexmsidtk`, 117 full source identities, 110 native-ledger rows, and highest known applied identity `20260921104000_server_unrepresentable_clock.sql`. Six historical duplicate-timestamp pairs (12 identities) remain distinct by complete filename and hash:

- `20260918010000_physiology_revisions.sql` / `20260918010000_production_scoring_durability.sql`
- `20260918030000_physiology_hrv_dependencies.sql` / `20260918030000_production_scoring_review_repairs.sql`
- `20260918040000_production_projection_debt.sql` / `20260918040000_rr_packet_provenance.sql`
- `20260918050000_physiology_calendar_ownership.sql` / `20260918050000_production_scoring_history.sql`
- `20260918060000_physiology_wear_dependencies.sql` / `20260918060000_production_scalar_projections.sql`
- `20260918070000_physiology_legacy_boundary_continuation.sql` / `20260918070000_production_aux_identity_provenance.sql`

The seven pending migrations, in required upgrade order, are:

| Order | Migration | Workstream | SHA-256 |
| --- | --- | --- | --- |
| 1 | `20260921110000_installation_retirement.sql` | multi-user | `352dd120144c07ef3f9f37bf5b6f90a336957d1f2a39f95281621bbc56b7234b` |
| 2 | `20260921111000_wearable_lifecycle.sql` | multi-user | `9ed18ae85c98d1eb28f4b9d646b2b91278cead273f72f88c6305147bafa08583` |
| 3 | `20260921112000_fleet_scheduler.sql` | multi-user | `52743cf103be90ef53815a519e3d49e0cf6bfdeacb3be2a39a6588e2ff3e9a37` |
| 4 | `20260921113000_fleet_admission_retention.sql` | multi-user | `c393e5236880709ebcf01b7e1390d5b5a8925647b31f03864e4100f524c13369` |
| 5 | `20260921120000_sensor_acquisition_windows.sql` | sensor | `aeb8a076e4d04a88ba0f16fb3744627259a4fbe82fd0113be77f6eb6341fde93` |
| 6 | `20260921121000_final_hosted_compute_contract.sql` | compute | `4f19d77777d1da06f5a3be1683fd03264f8563a4b0fa104d2a80dd9fc74d300a` |
| 7 | `20260921122000_compute_session_requests.sql` | compute | `14efd30ff5754a779ee300e86be08ce2db8bd6c4aa3b3e8a96bc97abf8b773a1` |

Three disposable schema chains passed:

| Chain | Result | Applied | Preserved fixture data | Final database fingerprint |
| --- | --- | --- | --- | --- |
| Fresh install | PASS | 124/124 | n/a | `2d476625729296d2caa03ca00cb834ecc7a0efad8fd48b21cb417bbc28c434ab` |
| Populated install | PASS | 124/124 | populated verification fixture | same |
| Hosted-ledger upgrade | PASS | 117 baseline + 7 pending | 2 users, 2 devices, 2 installations, 1 raw object, 2 raw samples, 1 immutable result; account/enrollment revision 2 | same |

The final inventory reports 129 RLS tables, 226 policies, 200 triggers, 18 selected functions, six result routes, four queues, 155 critical grants, 80 metric definitions, and 27 families. Fresh, populated, and representative-upgrade definitions converged exactly. The final schema dump hashes to `eab7ff3cb26b415f4f43d9b4eef5ced0c007613d6139e34499b1c28a65de32b1`; its canonical core hashes to `6b66f3a8e87f9975ef52ebf64cd98f662fbca0404c55fe06ead4f63db7b2976d`; the function/grant/trigger/queue/result-route/RLS inventory hashes to `9c7d9ffc7d6ae5a7f09d4b832bee484094f84df65f8a09d7cc5da3b14c0a0124`.

No production migration was applied. Before any authorized production apply, capture the exact target ledger, complete database backup, bucket/config identity, and a restore-drill receipt. Never rename, replay, or down-rewrite an already-applied migration. Use reviewed forward repair or a complete compatible restore if rollback is required.

## Real end-to-end chain

`bash scoring-service/scripts/test-server-pipeline.sh` passed from the frozen source. It exercised real disposable SQL, the actual enrolled Edge score handler, the exact selected and shadow worker entrypoints, immutable publication and canonical selection, and the production Swift and Android decoder/cache admission paths. It did not substitute a mocked response envelope.

The chain was:

```text
synthetic native capture fixture
→ durable input/raw-object receipt
→ full Supabase schema and projection
→ revisioned scoring work
→ exact worker entrypoint
→ immutable result
→ qualified selected feature/version
→ actual account and enrollment Edge routes
→ production Swift and Android decoders
→ revision-bearing ownership cache
→ consumer admission checks
```

Results:

- One real SQL/Edge integration test passed.
- Swift decoded 25 actual Edge envelopes and persisted 25 canonical selections.
- Android decoded the same 25 actual Edge envelopes and persisted 25 canonical selections.
- Both production decoders rejected null-owned-value, altered-owned-value, legacy-only-response, and sleep-only nested-leak mutations: eight cross-platform rejections.
- Paired account and enrollment responses were included. Shadow, missing approval, revoked qualification, manifest mismatch, pending device, other-device missing, explicit missing, sleep-only, and approved v2 cases were exercised.
- Sensor HRV, raw PPG, and IMU/temperature fixture replays were included. They are synthetic functional evidence, not independent physiological or hardware qualification.

Repository/disposable integration coverage also includes two users, two devices per user, two installations for one user, overlapping two-phone delivery for one wearable, provisional-to-confirmed reconciliation, account retirement/fresh installation, late input, duplicate delivery, worker restart, lease expiry, stale completion rejection, qualification revocation, manifest mismatch, null and valid zero, unsupported HRV timing, unavailable SpO2, DST/travel/edits/baseline replay, and injected network/B2/worker faults. The fresh lifecycle gate passed one test with 11 steps and zero failures; its summary is `multiuser/multiuser-validation-summary.json` (SHA-256 `4f26db997dadd4e3124fc7872869316a3a8dd13b830c55cca4457a88ef388ba2`). The exact 18-scenario mapping and limits are in `validation/e2e-scenario-coverage.json` (SHA-256 `1c15e62bf1160ac33136fbec8f44362ea574d32038e9ec7f99c51d92f0e45fed`), whose independent hash/reference validation hashes to `fc00a5078c328ac6e419d523d95d651b01389cd0e93ff5cb75bfe1f6c96cdf42`. These are synthetic disposable-local scenarios; injected faults do not prove physical behavior or a real target outage.

## Final-hosted computation boundary

The integrated contract keeps BLE, protocol parsing, raw waveform/provenance, durable buffering, direct wearable observations, user input, rendering, and upload/retry on the phone. All physiological feature extraction, inference, baselines, composite scoring, and derived histories are server-owned in final-hosted mode.

Current source-bound local evidence shows:

- Apple zero-inference focused suite: 5/5 passed. Optional producer paths refuse before numerical work; forbidden entrypoints fail loudly; the reference-mode control still executes.
- Apple full analytics: 2,224/2,224 passed, zero failures/skips.
- Apple final-hosted app-host runtime: 35/35 selected tests passed, including launch/lifecycle, raw upload, device/account changes, sleep edits, workout/live/spot/stress/biofeedback paths, canonical consumers, and exports. This is a macOS app host, not a physical iPhone.
- Android full-app tests include the actual pre-`onCreate` provider boundary, final-hosted runtime, raw upload, canonical consumers, widget persistence, Health Connect adapter, ZIP/export, and missing/revoked/zero-result paths.
- A server-owned missing, failed, stale, revoked, unqualified, shadow, or manifest-mismatched result never enables a local physiological fallback.
- Consumer admission requires known immutable result and input revisions with owner/source/canonical-device scope. Account and enrollment routes share the selection contract.

Final integrated acceptance from `node Tools/compute/check-cutover.mjs --require-final --evidence-dir /Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57/gates` is **PASS**. It exited 0 against all twelve fresh receipts, reported `finalHosted: READY`, 27 families, 80 outputs, ownership parity, and no blocked registry family. The log is `compute/check-cutover-final.log` (SHA-256 `f60bf6e6acc4cc7aa47d8c82db16e395b61f2680d226675987f6241dd2ac78f4`); the validated summary is `compute/check-cutover-summary.json` (SHA-256 `f5e34117374465b98124b8822e3d5b97440660503b77ae1a9552d1093704abe8`).

## Build and test results

The receipt JSON files in `gates/` contain exact argv arrays, working directory, timestamps, source hashes, exit status, and log SHA-256. The table gives the command directly where compact and names the exact command receipt where the invocation is long. The commands and material outcomes are:

| Gate / command | Result |
| --- | --- |
| `bash scoring-service/scripts/test-server-jvm.sh` | PASS: 217 reports, 1,687 tests, 0 failures/errors, 5 explicit private-reference skips. Evidence archive `pipeline/server-jvm-evidence.tar.zst`, SHA-256 `af136706ec1ede79065c9cd4914c499c8fc719bec54ba6d682293e277b743fd1`, 105,975,872 bytes. |
| `bash scoring-service/scripts/test-server-pipeline.sh` | PASS: actual SQL/Edge/workers plus production Swift/Kotlin decoders; 25 real envelopes and 25 persisted selections per platform; 8 mutation rejections. |
| `swift test --package-path Packages/WhoopProtocol --scratch-path /private/tmp/fra6/apple-final-33a38c5/protocol --jobs 4` | PASS: 769 reported, 2 existing skips, 0 failures. |
| `swift test --package-path Packages/WhoopStore --scratch-path /private/tmp/fra6/apple-final-33a38c5/store --jobs 4` | PASS: 836 reported, 1 existing private-fixture skip, 0 failures. |
| `bash Tools/compute/run-support-package-checks.sh` | PASS; support packages completed with their explicit existing fixture skips. |
| `swift test --package-path Packages/StrandAnalytics --scratch-path /private/tmp/fra6/apple-final-33a38c5/analytics --jobs 4 -Xswiftc -O -Xswiftc -assert-config -Xswiftc Debug` | PASS: 2,224 tests, 0 failures/skips. |
| Analytics command with `--filter PhoneInferenceRetirementTests`; exact argv in `gates/swift-zero-inference.json` | PASS: 5 tests, 0 failures/skips. |
| `bash Tools/compute/run-final-hosted-checks.sh` | PASS: 35 selected production app-host tests, 0 failures. |
| `xcodebuild -project .derived/compute-checks/ComputeChecks.xcodeproj -scheme NOOPiOS -destination generic/platform=iOS -derivedDataPath /private/tmp/fra6/apple-final-33a38c5/ios-derived CODE_SIGNING_ALLOWED=NO build` | PASS: clean generic iOS app/embedded-target build. |
| `xcodebuild -project .derived/compute-checks/ComputeChecks.xcodeproj -scheme NOOPWatch -destination generic/platform=watchOS -derivedDataPath /private/tmp/fra6/apple-final-33a38c5/watch-derived CODE_SIGNING_ALLOWED=NO build` | PASS: explicit generic watchOS build. |
| Complete unfiltered macOS test command; exact argv in `gates/macos-tests.json` | PASS: 2,702 tests, 0 failures, 12 explicit fixture/provider skips. |
| Android debug gate: `android/gradlew --project-dir android -Pksp.incremental=false :app:assembleFullDebug :app:testFullDebugUnitTest --rerun-tasks --console=plain --no-daemon --max-workers=2 --project-cache-dir /Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57/android/gradle-project-cache` | PASS: 764 suites, 6,282 declared, 6,276 executed, 0 failures/errors, 6 explicit optional fixture/corpus skips. Five required native reports ran 31 cases with no skips/failures. |
| Android release: `android/gradlew --project-dir android -PstagingRelease -PnoopSourceRevision=33a38c5167afec5beeadd700be714e89fa25fb57 -Pksp.incremental=false :app:assembleFullRelease --rerun-tasks --console=plain --no-daemon --max-workers=2` | PASS: 49 tasks; signed `fullRelease` staging APK. |
| Selected-v1 focused DB integration; exact environment/output in `workers/v1/logs/legacy-db-focused.log` and result identity in `workers/v1/focused-test-summary.json` | PASS: 6/6 on all 124 migrations. The fixture secret is test-only; schema guards remain unchanged. |
| Selected-v1 builder suites; exact environment/output in `workers/v1/logs/builder-unit-tests.log` and `workers/v1/logs/full-builder.log` | PASS: 12/12 builder tests; full builder analytics 746 tests with 5 reference skips and service 28/28, no failures/errors. |
| Static/release/adversarial Node and Python matrix; exact argv arrays in `validation/static-test-matrix.json` | PASS: 189 bounded tracked-source Node tests; 14 isolated release-inspector regressions; legacy builder 12; hosted/runtime/pinned-client Python 33. |
| `npx --yes deno test --allow-read supabase/functions/tests/capacity_evidence_test.ts` plus declared-interpreter syntax/compile checks | PASS: 7 Deno tests, 56 shell scripts, and 103 Python files. The first Deno invocation omitted the required read capability; a broad shell parse used bash for one zsh script. Both invocation errors are retained, and the exact suites passed with their required capability/interpreters. |
| `node --test infra/vps/scripts/scorer-image-release.test.mjs` | PASS: 42/42. |
| `python3 -m unittest infra.vps.tests.test_scoring_deploy` | PASS: 12/12. |
| Optional model repository suite; exact cwd/argv in `validation/static-test-matrix.json`, status/skip inventory in `workers/optional-model-status.json` | PASS WITH EXPLICIT SKIPS: 70 tests, 0 failures, 4 skips because pinned NeuroKit/Walch sources are absent. Model deployment remains BLOCKED/UNCONFIGURED. |
| `node --test Tools/release/generate-migration-manifest.test.mjs`; exact record in `migrations/logs/manifest-tests.log` | PASS: 6/6; both byte drift and ordering/file-set/hosted-baseline drift fail closed. |
| `node Tools/compute/check-cutover.mjs --require-final --evidence-dir /Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57/gates` | PASS: exit 0; `finalHosted=READY`; 12/12 fresh source-bound receipts; no blocked family. |

The previously reported Android baseline blockers were investigated in the same environment. Inherited test-harness keystore, startup/schema/receipt, and identity/decoder fixture failures were repaired without changing production encryption or weakening final-hosted admission. The complete application suite now passes. The six remaining skips are inventoried optional reference/private-corpus cases and are not called executed or passed.

Artifact-production command records are preserved with the artifacts:

- `pipeline/server-gate-commands.json` records the complete server environment, actual commands, the bounded failed environmental attempt, and the final reproducible pipeline command.
- `migrations/logs/manifest-generation-first.log`, `manifest-generation-second.log`, `manifest-tests.log`, `fresh.runner.log`, `populated.runner.log`, and `hosted-upgrade.runner.log` begin with the exact working directory, environment, and command for every manifest/schema chain.
- `workers/v1/logs/buildx-command.txt` (SHA-256 `bbdbeb8ff7b0aaded4a2b70061042978a2fb082e83a192e636b0124495d359ff`) and `workers/v2/logs/buildx-command.txt` (`402a60e075c5167f3d958f4cae097036287b8096c05787ba6906239be90ce6f5`) contain the exact executed OCI build commands; their adjacent build logs and release summaries contain the results and digests.
- The exact signed iOS archive invocation is at the start of `ios/logs/archive.log`; the directly observed export invocation is preserved in `ios/export-command.txt` (SHA-256 `99b14d1264f0815613792f725420308eb315981c5916e87ce26a464c7848a75c`). `ios/export-metadata/ExportOptions.plist`, `ios/logs/export.log`, and `ios/ipa-build-metadata.json` bind the export settings, result, signature, and IPA identity.
- `android/android-verification.json` records the exact release-build argv and artifact inspection results.
- Edge and deployment bundles were produced and verified twice with `node Tools/release/edge-source-bundle.mjs prepare|verify` and `node Tools/release/deployment-source-bundle.mjs prepare|verify`; the exact input/output identities are in their four adjacent `logs/*.log` files. Aggregate-manifest prepare and verification argv arrays are in `release/release-manifest-summary.json`.

The bundle commands are reproducible exactly as follows; repeat preparation substitutes `source-bundle-repeat` for `source-bundle` and the same verifier command:

```sh
SRC='/Volumes/Untitled/WHOOP NARA-release-integration'
ART='/Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57'
SHA='33a38c5167afec5beeadd700be714e89fa25fb57'
node Tools/release/edge-source-bundle.mjs prepare --repo-root "$SRC" --commit "$SHA" --output "$ART/edge/source-bundle"
node Tools/release/edge-source-bundle.mjs verify --bundle "$ART/edge/source-bundle" --expected-bundle-sha 9d8b3c69450c3e389e20ca87d04725fd6beacc7ad0727fbd2ec24c23120bdc05
node Tools/release/deployment-source-bundle.mjs prepare --repo-root "$SRC" --commit "$SHA" --output "$ART/deployment/source-bundle"
node Tools/release/deployment-source-bundle.mjs verify --bundle "$ART/deployment/source-bundle" --expected-bundle-sha 688535f3571d666af1d0ddcd7237b2a83bc8fabfec99af8b62aa635f533ed5a6
```

The selected-v1 focused and full-builder invocations omitted from the compact table were:

```sh
python3 scoring-service/legacy-baseline/build.py \
  --repository /Volumes/Untitled/frwhoop-server-33a-scratch/baseline-repo \
  --context /Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57/workers/v1/focused-context

cd /Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57/workers/v1/focused-context/scoring-service
export JAVA_HOME=/opt/homebrew/Cellar/openjdk@17/17.0.16/libexec/openjdk.jdk/Contents/Home
export PATH="$JAVA_HOME/bin:$PATH"
export TMPDIR=/Volumes/Untitled/frwhoop-server-33a-scratch/tmp/v1-focused
export GRADLE_USER_HOME=/Volumes/Untitled/frwhoop-server-33a-scratch/gradle-v1-focused
export PHYSIOLOGY_TEST_DATABASE_URL=postgresql://supabase_admin:isolated-v1-33a-only@127.0.0.1:32807/physiology_queue_test
/usr/bin/time -p ./gradlew --no-daemon --max-workers=1 :service:test --tests com.frwhoop.scoring.LegacyQueueIntegrationTest

cd '/Volumes/Untitled/WHOOP NARA-release-integration'
export TMPDIR=/Volumes/Untitled/frwhoop-server-33a-scratch/tmp/v1-full
export DOCKER_CONTEXT=colima-frwhoop-integration
/usr/bin/time -p python3 scoring-service/legacy-baseline/build.py \
  --repository /Volumes/Untitled/frwhoop-server-33a-scratch/baseline-repo \
  --context /Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57/workers/v1/build-context \
  --build --image frwhoop/selected-v1:33a38c5 \
  --release-sha 33a38c5167afec5beeadd700be714e89fa25fb57 --platform linux/amd64
```

Port `32807` and its disposable database were removed after the run; reproduction requires a fresh `physiology_queue_test` database with the recorded `cron.database_name` and `pg_net.database_name` startup configuration. The focused log hashes to `4c83d99be14d673c680ec711a9d9776f000cc729a9b8db789aae328db65bf015`; the full-builder log hashes to `b7bbdb4638f32bfba923f57c288d824795d5fed162ac5c6d326a758e7d501e83`.

## Capacity decision

The authoritative report is `capacity/capacity-measurement-summary.json` (SHA-256 `84be3011a02ae195f31e410495509cb8ff354667f8a20c4d0e94607a2a147de0`). The committed launch policy is byte-identical to `capacity/launch-capacity.json` (SHA-256 `2ae722f093476f9143c93dad4eb260b5fe049857b6883dabc9dc6619c9f09bae`), and the complete capacity evidence inventory hashes to `67aeaaa0b8cea765961ba2ce7e1d349c19fa9417aad182fc896b77e0f53d45d5`. The run used a dedicated four-CPU, 8 GiB local Colima VM, captured in `capacity/environment-colima-status.json` (SHA-256 `2561964fc06a5d0a6e1f28f89048452c1f5d0a76fd6f7c8d1a3d3f7a0036ca55`). PostgreSQL ran inside that VM; the four actual JVM workers ran as local Darwin processes outside it. Scheduler measurements use PostgreSQL scheduling plus scalar invalidation with synthetic 3 ms/20 ms work; the actual-worker run uses synthetic scalar inputs and four real JVM worker processes. They do not measure B2, the optional model, full sensor computation, network outages, production, or target-VPS capacity.

The exact scheduler command was:

```sh
set -o pipefail
export DOCKER_CONTEXT='colima-frwhoop-integration'
export JAVA_HOME='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home'
export PATH="$JAVA_HOME/bin:$PATH"
export TMPDIR='/private/tmp/frwhoop-capacity-33a.SZ1Fu2/scheduler'
export PIPELINE_TEST_PG_TMPFS='true'
export PIPELINE_TEST_REMOVE_CONTAINERS='true'
export PIPELINE_TEST_MULTIUSER='1'
export PIPELINE_TEST_FILTER='measured concurrent fleet scheduler: live, backfill, failure, revisions and expired workers'
export PIPELINE_TEST_CAPACITY_COHORTS='10,100,750,1000'
bash scoring-service/scripts/test-server-pipeline.sh 2>&1 | tee '/Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57/capacity/logs/scheduler.log'
```

### Scheduler cohorts, four workers

| Owners | Live p50/p95/p99 (s) | Backfill p50/p95/p99 (s) | Backlog drain | Peak DB CPU | Peak DB memory | Peak DB conns / active | Attempts/completed | Fairness | 60 s live-p95 SLO |
| ---: | --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| 10 | 1.216 / 1.333 / 1.335 | 1.858 / 2.447 / 2.495 | 130→0 in 1.587 s | 36.01% of one CPU | 176,055,910.4 B | 7 / 5 | 140/130 = 1.0769 | all 10 owners and both classes progressed | PASS |
| 100 | 1.490 / 1.762 / 1.785 | 1.906 / 3.000 / 3.095 | 400→0 in 3.087 s | 87.85% | 180,355,072 B | 7 / 2 | 410/400 = 1.0250 | all 100 owners and both classes progressed | PASS |
| 750 | 23.376 / 37.776 / 38.511 | 35.474 / 40.702 / 41.115 | 2,350→0 in 41.167 s | 108.22% | 203,214,028.8 B | 7 / 6 | 2,360/2,350 = 1.0043 | all 750 owners and both classes progressed | PASS locally |
| 1,000 | 49.826 / 80.753 / 82.220 | 74.506 / 84.373 / 84.908 | 3,100→0 in 85.277 s | 108.54% | 226,597,273.6 B | 7 / 6 | 3,110/3,100 = 1.0032 | all 1,000 owners and both classes progressed | **FAIL** |

Each cohort injected eight synthetic failure attempts and rejected one expired-lease completion and one late-revision completion. Live/backfill weighting was 3:1. Every backlog drained and every owner and work class progressed. The 750-owner local scalar scheduler cohort is the largest measured cohort meeting the 60-second live-p95 SLO; the 1,000-owner live p95 of 80.753 seconds exceeds it. The scheduler log hashes to `f4744fa7d3157788789b6478615c0c48fafe41d194e55d63807ea03b496716d4`, and its report hashes to `4f680ee0155d8ce6e4584ede977d69975451ad279ce179c6536ecf5fc68e7977`.

### Actual JVM workers

The exact first-attempt command against a fresh disposable database was:

```sh
set -o pipefail
export DOCKER_CONTEXT='colima-frwhoop-integration'
export JAVA_HOME='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home'
export PATH="$JAVA_HOME/bin:$PATH"
export TMPDIR='/private/tmp/frwhoop-capacity-33a.SZ1Fu2/worker-attempt-1'
export PIPELINE_TEST_PG_TMPFS='true'
export PIPELINE_TEST_REMOVE_CONTAINERS='true'
export PIPELINE_TEST_MULTIUSER='1'
export PIPELINE_TEST_FILTER='four actual physiology processes publish isolated live and backfill work under fleet budgets'
export PIPELINE_TEST_V2_BINARY='/Volumes/Untitled/WHOOP NARA-release-integration/scoring-service/service/build/install/service/bin/service'
bash scoring-service/scripts/test-server-pipeline.sh 2>&1 | tee '/Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57/capacity/logs/worker-attempt-1.log'
```

It passed without SQLSTATE `55P03` or a retry:

- 10 owners, 20 devices, four actual JVM worker processes, 27,001 HR input rows.
- 86/86 jobs completed; backlog 86→0 in 5.143 seconds; attempts/completed 1.0.
- Live p50/p95/p99: 1.792017 / 2.549752 / 2.662923 seconds.
- Backfill p50/p95/p99: 3.051903 / 4.044695 / 4.311731 seconds.
- All owners and both work classes progressed; per-owner completions ranged 8–14; max concurrent reservations 4; max reservations per owner 1.
- Peak database CPU 165.79% of one CPU, memory 445,225,369.6 bytes, 20 connections, 4 active connections.
- Peak worker CPU 1,012% of one CPU and combined RSS 1,823,539,200 bytes.
- Worker restart was not measured in this particular capacity fixture; lease expiry was covered by the scheduler fixture and the general integration suite.

The worker log hashes to `1a2dff6e0933a65dabbb3a0f634f6947b98a401f4e4121788efb599014380497`, and its report hashes to `3f1a00bccd5cdd7fe7ac27266ff4f3c92770e165e901fdfa617bc6f8c3fee55a`. The launch scope remains the smaller actual-worker cohort and requires a target canary because the 750-owner PASS is a local scalar scheduler measurement. The launch policy is:

```text
decision: CONDITIONAL_CANARY_ONLY
active owners: 10
devices: 20
physiology worker processes: 4
publication SLO: p95 <= 60 seconds after required input is durably accepted
database connection budget: 40
reserved database connections: 16
worker pool size: 4
declared processes including reserved optional model: 6
1,000-owner claim: UNSUPPORTED
target-VPS capacity: NOT_MEASURED
```

## Matched release artifacts

All completed artifacts below were built from `33a38c5167afec5beeadd700be714e89fa25fb57` and have not been published, deployed, or installed.

| Artifact | Identity | Status / rollback boundary |
| --- | --- | --- |
| Selected v1 worker | `workers/v1/oci/selected-v1.oci.tar`; 106,240,512 bytes; archive SHA-256 `9997f619cf26d29e0c916b790510ad6d4e73f63a2f429572e9c6ff59a8a188a5`; OCI manifest `sha256:8666c95b08cb77d5a80a3f7431441ddff23733cfcc2a470aed1ca4eab106100f`; config `sha256:bcd68246a99e988f396a8a053325ca97bafb00ceb0139924d917d91effa9ce25`; linux/amd64, 9 layers, no attestations; algorithm `frwhoop-server-1`; frozen baseline `5caa31689da0023e111beb36850d3f81d67e1be2`; source `33a38c5167afec5beeadd700be714e89fa25fb57`; heartbeat `physiology_worker_heartbeats-v1`. | BUILT_LOCAL_NOT_PUBLISHED. Candidate-byte reload copy is identical; it is not a prior-production rollback. |
| Shadow/history v2 worker | `workers/shadow-v2.oci.tar`; 107,558,912 bytes; archive SHA-256 `86f43f0c87ac7365f751a21b897f8e37cc0cdbf43d50c4d851802d00545c985e`; OCI manifest `sha256:3c729a0e00cd683d79b034a423557f2ade5f024933fcbf1180f35a1592653123`; config `sha256:84548ef28f2bc4af2f1b4e30bf739cb7836e96517dab5d54ec331acb4cecc9a0`; linux/amd64, 8 layers, no attestations; roles `frwhoop-physiology-2,frwhoop-server-2-history`; source `33a38c5167afec5beeadd700be714e89fa25fb57`; heartbeat `physiology_worker_heartbeats-v1`. | BUILT_LOCAL_NOT_PUBLISHED. Candidate-byte reload copy is identical; it is not a prior-production rollback. |
| Android app | `android/app-full-release.apk`; 24,720,757 bytes; SHA-256 `0b52273b03e41899464a7bd2e72c24982ecee06559f23626ea0aff6cb317825d`; package `com.noop.whoop.staging`; version `11.1.1-staging` / code 450; min 26, target 34; `finalHostedCompute=true`; v2 signature verified; certificate SHA-256 `4511d9037513f582e52a82ac03d8f928655d29e86a21245dce59a133a2fee3ab`. | BUILT_NOT_INSTALLED. Candidate-byte reinstall copy is identical; prior installed rollback is BLOCKED until captured. |
| iOS application | `ios/NARA-33a38c5-development.ipa`; 27,079,474 bytes; SHA-256 `08d2da6ed4ed0b10ceb115007ed94acca6aeec36b3a9728f7245079f740380f5`; version/build `11.1.1 (371)`; source revision `33a38c5167afec5beeadd700be714e89fa25fb57`; team `MJSVJG4DXR`; Apple Development certificate DER SHA-256 `fbeedea34a01683d036b6ff87ae43f84999bbfd8fb7be4eea9a05d47181b657b`; four bundle/profile/CDHash identities in `ios/inspection.json`; app group `group.com.rahulvijayan.nara.noop.staging`. | DEVELOPMENT_IPA_BUILT_NOT_INSTALLED. Strict inspection passed. Candidate-byte reinstall copy is identical; prior installed rollback is BLOCKED until captured. |
| Edge function bundle | `edge/source-bundle/edge-source-bundle.tar`; 296,448 bytes; SHA-256 `9d8b3c69450c3e389e20ca87d04725fd6beacc7ad0727fbd2ec24c23120bdc05`; 38 files; manifest SHA-256 `673f92a658393071873e61c2a1f751dd7b05c7db222a7d8a6dca60a8cfe73467`; functions: account-deletion, ingest-verify, push, reconcile, retention-sweep, scores. | PREPARED_AND_VERIFIED_TWICE, byte-identical. Prior hosted Edge bytes are BLOCKED/not captured. |
| Migration manifest/schema | manifest SHA-256 `6c54aa047fbdb2e7da2b1412d06a69e5b82603c8501c3c061559cd5b57205ac2`; manifest fingerprint `c7c6348df709c28422a97ac19354d499fb784727ef94ab7edcd665264f171293`; schema-source fingerprint `910a1c74a760b496028d7c2c58c009f45e29f9643fd2c279c278156f9a23d4c5`; final disposable DB fingerprint `2d476625729296d2caa03ca00cb834ecc7a0efad8fd48b21cb417bbc28c434ab`. | IMMUTABLE_LOCAL; production apply NOT_PERFORMED; rollback backup BLOCKED/not captured. |
| Deployment/tooling bundle | `deployment/source-bundle/deployment-source-bundle.tar`; 882,176 bytes; SHA-256 `688535f3571d666af1d0ddcd7237b2a83bc8fabfec99af8b62aa635f533ed5a6`; 84 files; manifest SHA-256 `c29282e5062fb40d6b16dfa4c19281dc6bbac2dc8759fd8bcf3f6b2be1975677`. | PREPARED_AND_VERIFIED_TWICE, byte-identical. |
| Aggregate release manifest | `release/release-artifact-manifest.json`; 23,064 bytes; SHA-256 `2a1a8177643f38a63b942e3d4e5673fb943bc46ed93c1cfabbc2700436270581`; semantic fingerprint `f9e01e1d5214883e2041ac592cf9c1f5ce6cfc34fae22597ea7b4e52a5ca7af3`; repeat prepare byte-identical; independent verification runs 1 and 2 both returned `ARTIFACT_MANIFEST_VERIFIED`. Summary SHA-256 `e925145596aca2ac8d3e0195eedb8b382b564400efbbd3767c331772c76c0288`. | Deployment `NOT_PERFORMED`, production migrations `NOT_APPLIED`, phone install `NOT_PERFORMED`, registry publication `BLOCKED`, and heartbeat verification `BLOCKED_UNTIL_AUTHORIZED_DEPLOYMENT`. |

The optional model worker has no release image. Its repository suite passed with four explicit missing-dependency skips, but activation, an immutable qualified Linux wheel/dependency bundle, target-VPS resources, and reference qualification are absent. Its deployment status is BLOCKED/UNCONFIGURED.

The combined worker summary is `workers/release-summary.json` (SHA-256 `09328991e67b343e4ed5cd40d765aa0961642c2cc797dc38275e6beca60fd9c5`); selected-v1 is `workers/v1/release-summary.json` (`0ea1033ab78cca3bc5bbc6e3c24815adc5bcd526c76953b0e415631dc1f59621`); shadow-v2 is `workers/v2/release-summary.json` (`12c5473246a0d99bcf77a7651dd4a11067a241279fcffba7fdf63e4a2166c33b`); and the prior-production rollback status is `workers/rollback/operational-rollback-status.json` (`b281bb340e5664b8e89bb50b6c6b3c57946ba8ce0c736375b7e354266394895d`). All remain local and unpublished.

A final read-only aggregate verification after the capacity run again returned `ARTIFACT_MANIFEST_VERIFIED` with semantic fingerprint `f9e01e1d5214883e2041ac592cf9c1f5ce6cfc34fae22597ea7b4e52a5ca7af3`; `release/verify-final.log` hashes to `98f48ee82716b367bf8a2a05fc207225e3a95d1e734752423f6b8fb290bcc99a`.

## Operational blockers

The candidate must not be called operational until all of the following have recorded exact identities and receipts:

1. Current selected-v1 and shadow-v2 container IDs, registry RepoDigests, image config digests, source SHAs, algorithm roles, deployment UUIDs, process UUIDs, and fresh advancing heartbeat/poll/publication times.
2. Authorized registry publication of the exact local OCI artifacts, with registry manifest digests equal to the local OCI manifest digests.
3. Authorized target binding: VPS IP, SSH port, pinned host-key line/fingerprint, deploy public-key fingerprint, hosted project/database/Edge identities, and reviewed secrets/config presence without dumping values.
4. Complete pre-change database, bucket, config, Edge, worker, and mobile rollback artifacts, each hashed and compatibility-reviewed.
5. Authorized application of exactly the seven pending migrations and deployment of the exact Edge/worker artifacts.
6. Fresh role-specific heartbeat proof: v2 only in shadow/history roles and v1 as the selected producer; progressing polls and an exercised publication/readback path. Container existence or an old process heartbeat is insufficient.
7. Target-VPS capacity measurement and an authorized 10-owner canary before any expansion.

## Required external inputs and authorizations

Before any target or phone action, the operator must supply and record: the authorized target VPS IP and SSH port; exact pinned SSH host-key line and fingerprint; deploy public-key fingerprint; hosted project, database, and Edge identities; immutable registry references for both worker digests; reviewed secret/config presence without exposing values; tester and user identity; installation/source and canonical-device identities; wearable model and firmware; route type; Android serial; provisioned iOS UDID; and compatible signed prior rollback artifacts. Applying the seven production migrations, publishing or deploying either worker, deploying Edge, starting the canary, and installing either app each require explicit authorization. Missing values keep the corresponding step BLOCKED.

## Deployment order

No step below was performed in this integration session.

1. Capture and review the current target state: phone project/route bindings, hosted and self-hosted database/Edge identities, full migration ledger and hashes, worker identities/roles, registry digests, app builds/signers, configuration presence, and exact compatible rollback artifacts.
2. Take and verify a full database/bucket/config backup and complete a restore drill. Bind the receipt to the target and pre-change schema fingerprint.
3. Publish the exact selected-v1 and shadow-v2 OCI bytes to the authorized registry. Verify registry manifest and config digests match this handoff. Do not deploy mutable tags.
4. Produce and verify the deployment-bound aggregate manifest with immutable registry references and pinned target SSH identities.
5. Plan the migration against the captured hosted full-identity ledger. Apply exactly the seven pending migrations in manifest order under explicit production authorization. Re-run function/grant/trigger/queue/result-route/RLS inventory and compare the final schema fingerprint.
6. Deploy the exact Edge bundle and verify account/enrollment score-route parity through both production response paths.
7. Deploy v2 shadow/history first. Confirm its role labels, source SHA, deployment/process UUIDs, current heartbeat contract, advancing polls, and inability to become canonical without explicit qualification/promotion.
8. Deploy selected v1. Confirm `frwhoop-server-1`, source SHA, deployment/process UUIDs, heartbeat, advancing polls, queue claim, immutable publication, selection, account/enrollment readback, and client admission.
9. Run a target-VPS smoke and the conditional 10-owner/20-device/four-worker canary. Check the 60-second live p95 SLO, backfill progress, fairness, retries, resource ceilings, and 40-connection budget with 16 reserved.
10. Only after the server chain is healthy, install the matched apps on authorized test phones and execute the physical protocol below. Do not expand beyond measured capacity.

## Rollback order

1. Stop canary expansion and client distribution. Preserve raw input, upload debt, immutable results, selected identities, and all diagnostic evidence.
2. If one worker lane is faulty, stop only that lane and restore its separately captured, compatible, exact prior image by immutable digest. Keep v2 shadow and v1 selected roles explicit. Never substitute an unknown `latest` image.
3. Restore the separately captured prior Edge bundle and route/config identities if Edge behavior regresses. The repeat candidate bundle is only a byte-identical candidate restore, not proof of the pre-deployment state.
4. Do not rewrite or down-replay applied migration history. Use a reviewed forward repair when compatible; otherwise restore the complete pre-apply database/bucket/config backup under the tested restore plan.
5. Roll mobile clients back only to captured, signed, contract-compatible prior artifacts. The candidate-byte APK/IPA copies reload this candidate and are not prior-version rollback artifacts.
6. If no compatible server remains, show explicit unavailable/stale server state while capture/upload continues. Never restore local physiological inference, weaken qualification, clear ownership, fabricate values, or promote shadow output as a rollback shortcut.

## Phone installation instructions

These are instructions for a later explicitly authorized physical-phone session. No installation occurred while preparing this candidate.

### Common preflight

1. Record tester, user, installation/source, canonical wearable, phone hardware, OS, wearable model/firmware, route type, and start time. Use redacted fixture identifiers in shared evidence.
2. Record the currently installed package/bundle version, build, embedded source SHA, signer/team, app group, local data-preservation choice, and exact prior signed rollback artifact. If no compatible prior artifact is available, mark rollback BLOCKED before installation.
3. Verify the completed aggregate release manifest twice and verify every local file hash. Confirm source revision `33a38c5167afec5beeadd700be714e89fa25fb57` and final-hosted mode in the app metadata.
4. Keep upgrade and fresh-install cases separate. Do not clear app data during the upgrade case. For the fresh-install case, use a separate test installation/source identity and follow explicit account-retirement semantics.

### Android

```sh
ART=/Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57
EVIDENCE_DIR=/path/to/authorized-physical-evidence
: "${ANDROID_SERIAL:?set the authorized Android device serial}"
mkdir -p "$EVIDENCE_DIR/android"
shasum -a 256 "$ART/android/app-full-release.apk"
java -cp "$ART/android/tools/apksigner.jar" \
  /Volumes/Untitled/WHOOP\ NARA-release-integration/Tools/release/VerifyApk.java \
  "$ART/android/app-full-release.apk"
adb devices -l > "$EVIDENCE_DIR/android/adb-devices.txt"
adb -s "$ANDROID_SERIAL" shell dumpsys package com.noop.whoop.staging \
  > "$EVIDENCE_DIR/android/installed-before.txt"
adb -s "$ANDROID_SERIAL" install --replace "$ART/android/app-full-release.apk" \
  > "$EVIDENCE_DIR/android/install.txt" 2>&1
adb -s "$ANDROID_SERIAL" shell dumpsys package com.noop.whoop.staging \
  > "$EVIDENCE_DIR/android/installed-after.txt"
```

Expected APK hash and certificate are the Android artifact row above. After installation, confirm version code 450, version `11.1.1-staging`, package `com.noop.whoop.staging`, permissions, battery restrictions, background policy, and enrollment route before starting capture. Record device authorization for every `adb` action.

### iOS/watch

Use the finalized development IPA after authorization and after capturing the installed prior-version rollback artifact:

```sh
ART=/Volumes/Untitled/frwhoop-release-33a38c5167afec5beeadd700be714e89fa25fb57
EVIDENCE_DIR=/path/to/authorized-physical-evidence
: "${IOS_DEVICE_UDID:?set a provisioned authorized iOS device UDID}"
mkdir -p "$EVIDENCE_DIR/ios"
IPA="$ART/ios/NARA-33a38c5-development.ipa"
shasum -a 256 "$IPA"
python3 /Volumes/Untitled/WHOOP\ NARA-release-integration/Tools/release/inspect_ipa.py "$IPA" \
  > "$EVIDENCE_DIR/ios/ipa-inspection.json"
TMP=$(mktemp -d /private/tmp/frwhoop-authorized-install.XXXXXX)
ditto -x -k "$IPA" "$TMP"
xcrun devicectl list devices > "$EVIDENCE_DIR/ios/devices-before.txt"
xcrun devicectl device info apps --device "$IOS_DEVICE_UDID" \
  --bundle-id com.rahulvijayan.nara.noop \
  --json-output "$EVIDENCE_DIR/ios/installed-before.json" \
  --log-output "$EVIDENCE_DIR/ios/installed-before.log"
xcrun devicectl device install app --device "$IOS_DEVICE_UDID" \
  "$TMP/Payload/NOOP Staging.app" > "$EVIDENCE_DIR/ios/install.txt" 2>&1
xcrun devicectl device info apps --device "$IOS_DEVICE_UDID" \
  --bundle-id com.rahulvijayan.nara.noop \
  --json-output "$EVIDENCE_DIR/ios/installed-after.json" \
  --log-output "$EVIDENCE_DIR/ios/installed-after.log"
```

The inspection must verify the main app source SHA and all four bundles' version/build, team/profile, CDHash, application groups, HealthKit entitlement where required, and profile expiry/device admission. The main app carries the source-revision metadata; the three embedded extensions report a null source-revision field, so do not claim each extension embeds the SHA. Confirm the watch app and complication bundle are present and paired. Xcode Devices and Simulators or Apple Configurator may be used instead of `devicectl`, but retain an exact installation receipt. Remove the temporary extraction only after evidence capture. Do not use the ad-hoc sideload helper as proof of an Apple development/distribution signature.

## Physical-device test protocol

For every case, record the candidate SHA/image digests, app build, phone/wearable hardware and firmware, OS, user/device/source/installation IDs, route, power/network conditions, start/end time, outcome, log/evidence paths, and limitations. Correlate the first broken stage across native receive, durable commit, ACK, upload/object receipt, projection/input revision, queue/lease/run, worker identity, immutable result, selection, account/enrollment response, decoder/cache, and screen/widget/watch/export.

### Test topology

- At least two users and two canonical wearables per user.
- Two installations for one user.
- Two phones observing/uploading overlapping data for one wearable.
- A provisional wearable identity that becomes confirmed.
- A retired account followed by a fresh installation for another authorized test context.
- Both account JWT and enrollment-code score routes.
- Selected v1 plus v2 shadow/history, with no implicit algorithm substitution.

### Capture, durability, and recovery

1. **Foreground BLE:** pair/connect, collect ordinary live packets and historical backfill, and prove native receive → durable row/object staging → exact ACK. Confirm direct wearable HR remains visible while no local PPG-derived metric runs.
2. **One packet then silence:** deliver one live packet and stop transmission. Prove bounded durable commit and sparse flush without waiting for another packet.
3. **Locked phone:** lock without routine reopening. Exercise permitted background collection/upload and record OS deferrals separately from failures.
4. **Android recovery:** evict/kill the process, reboot, test first unlock, toggle Bluetooth, revoke/restore permission, exercise low power, and separately record user force-stop behavior. Verify the frozen receipt/source identity survives and old callbacks cannot publish under a new owner/device.
5. **iOS recovery:** exercise background/foreground transitions, BLE restoration, Bluetooth toggles, reboot/first unlock, permission changes, and low power. Verify capture metadata is owner-bound before data is accepted.
6. **Device switch with delayed I/O:** switch wearables while old callbacks and staged uploads remain. Every old byte must retain its original user/source/device/session identity.
7. **Backfill plus live:** run a large history transfer while live traffic continues. Confirm airtime coordination, fair upload, bounded live latency, and no lost/double ACK.
8. **Offline backlog:** interrupt network, then B2/object storage, then worker/VPS independently. Verify local/cloud queues retain data within declared capacity, recover exactly, do not duplicate canonical results, and expose backpressure/oldest age.

### Raw and sensor lanes

1. Capture and upload raw PPG independently of local inference and independently of scalar projection success. Verify immutable object identity, SHA-256, owner/source/physical-device key, canonical device mapping, receipt, and pruning only after the exact accepted boundary.
2. Capture continuous IMU through both durable `bleRawBatch` and archive-fallback paths. Verify neither lane starves or deletes the other and both exhaust before the worker sleeps.
3. Exercise five-minute HRV timing, unsupported timing, off-body/quiet-wake/movement/corrupted-optics states, and explicit missing reasons. A functional fixture is not a reference qualification.
4. Exercise every supported temperature reading with units/method and provenance. Do not relabel relative optical markers as degrees Celsius.
5. Keep SpO2 unavailable/blocked unless required physical channels, calibrated hardware, synchronized reference, and qualification protocol are present. Never substitute a nightly summary or fabricate a numeric pass.

### Compute, identity, and result admission

1. Exercise late input during computation, duplicate delivery, worker termination/restart, lease expiry, and stale completion. A new worker must recover expired work; the old worker must be unable to publish.
2. Revoke qualification and alter the approved manifest. Verify canonical selection is removed or marked unavailable, both account/enrollment routes agree, and no local fallback runs.
3. Verify null and valid zero remain distinct in screens, widgets, watch, HealthKit/Health Connect, shortcuts, and exports.
4. Confirm v2 shadow/history results never become canonical without explicit signed qualification/promotion. Confirm selected v1 absence is an operational failure, not permission to substitute v2 or phone computation.
5. Overlap two-phone uploads. Confirm one logical observation, preserved original receipts, distinct same-second packets, and deterministic canonical-device association.
6. Retire user A with pending data, then create user B's fresh installation. Confirm no row, callback, cache, result, raw object, or upload debt is reassigned.

### Time, edits, imports, and consumers

1. Exercise DST transition, timezone travel, late sleep edit, workout edit/import, and baseline replay. Verify event-time ownership and dependent recomputation; every consumer must agree on immutable result revision.
2. Exercise cold launch, enrollment, device change, BLE reconnect, foreground/background backfill, imports, workouts, spot HRV, live sessions, stress screens, diagnostics, widgets, watch publication/complications, HealthKit, Health Connect, shortcuts, and CSV/ZIP exports.
3. Verify server-owned missing/failed states never execute a local producer. Raw capture/upload and direct wearable observations must continue.
4. Verify Health exports preserve units, timestamps, unknown sleep gaps, delete/save ordering, and source/result revision. Skin temperature must not be presented as core temperature; unsupported HRV zero must remain explicit.

### Measurement and soak

Report p50/p95/p99 for sensor→receipt when sensor time is verified, receipt→local commit, commit→ACK, ACK→projection, queue wait, compute, publish→read, and read→display. Report valid coverage/yield, gap reasons, duplicate count, backlog age/recovery, retries, CPU/RAM, database connections, raw/compressed bytes, B2 operations, thermal state, phone battery, and wearable battery against a comparable baseline.

Run a 24-hour locked-phone/no-routine-reopen soak first. If its gaps are understood and within a declared bound, run the 72-hour release soak. Force-stop and OS-deferred periods remain explicit states in the denominator. Neither soak has been run for this candidate.

Independent synchronized ECG/beat-timing, respiration/PSG where relevant, temperature, and calibrated SpO2 references are required for physiological qualification. Repository fixtures and functional phone tests do not establish clinical accuracy.

## Readiness matrix

The status below is the end-to-end release status. Repository evidence is shown separately so a local PASS is not promoted into physical, reference, target-VPS, soak, or production proof.

| Capability | Status | Repository evidence | Missing evidence / required action |
| --- | --- | --- | --- |
| Foreground BLE | NOT_MEASURED | Swift protocol/store, Android app, and BLE durability suites pass | Supported physical phone/wearable run with receive→commit→ACK→upload evidence |
| Locked-phone BLE | NOT_MEASURED | Background lifecycle logic builds/tests | Real locked-phone/no-routine-reopen execution under supported OS/firmware |
| Android process recovery | NOT_MEASURED | Full app suite and recovery/frozen-receipt harness pass | Physical process eviction/reboot/first-unlock/force-stop cases |
| Sparse live flushing | NOT_MEASURED | Sparse/durable queue logic tested | One-packet-then-silence physical timing and battery evidence |
| Offline backlog recovery | NOT_MEASURED | Injected local network/B2/worker faults pass | Physical phone plus real target network/B2/VPS outage and recovery |
| Raw PPG | NOT_MEASURED | Raw-object route, registry, upload independence, and synthetic replay pass | Supported hardware capture, object/readback, and physical qualification |
| Continuous IMU | NOT_MEASURED | Durable batch/archive parity and exhaustion tests pass | Physical continuous capture/background/upload parity |
| Five-minute HRV | NOT_MEASURED | Timing/capability/missingness and synthetic replay pass | Verified physical beat timing and independent synchronized reference |
| Temperature | NOT_MEASURED | IMU/temperature envelope, units/provenance contracts pass | Supported physical measurement and reference qualification |
| SpO2 | BLOCKED | Explicit unavailable/missing contract passes; no numeric fallback | Required red/IR or verified device hardware, calibration, synchronized reference, held-out qualification |
| Sleep and respiration | NOT_MEASURED | Server result, edit/replay, decoder, consumer contracts pass | Physical longitudinal capture, PSG/respiration reference, device/background evidence |
| Composite scores | NOT_MEASURED | Immutable result/orchestration/account-enrollment/consumer chain passes | Matched deployed workers, phone readback, physical inputs, reference/product acceptance |
| VPS-only computation (repository cutover) | PASS | `--require-final` exited 0 across all 12 fresh receipts; `finalHosted=READY`; no local physiological producer executes in the repository runtime matrix | Hosted deployment and physical observation remain separate target-VPS/phone gates |
| Account/enrollment parity (disposable local) | PASS | Actual SQL/Edge responses and production Swift/Android decoders: 25 envelopes and selections per platform | Production observation remains separate |
| Production migrations and Edge deployment | BLOCKED | Three disposable schema chains and the source-bundle verifier pass | Production migrations are NOT_APPLIED; Edge deployment is NOT_PERFORMED and requires explicit authorization |
| Multi-phone behavior | NOT_MEASURED | Repository dedup/source/canonical-device/lifecycle scenarios pass | Two physical phones/one wearable plus overlapping real uploads |
| Fleet capacity | FAIL | 1,000-owner local live p95 80.753 s exceeds 60 s; backlog and fairness measured | Keep 10-owner conditional canary or improve/re-measure scheduler/worker/resources on target |
| Target-VPS operation | BLOCKED | Matched local OCI artifacts and deploy verification tooling exist | Authorized publish/deploy, target binding, schema/Edge apply, fresh role heartbeats, publication/readback |
| 24-hour soak | NOT_MEASURED | No transferable repository substitute | 24-hour locked-phone/background/battery run |
| 72-hour soak | NOT_MEASURED | No transferable repository substitute | 72-hour matched release soak after 24-hour gate |

The repository cutover result changes only the VPS-only computation row. Physical, sensor-reference, target-VPS, capacity, and soak classifications do not inherit that PASS.

## Remaining failures and bounded limitations

- The signed development IPA and offline aggregate manifest are complete. They remain uninstalled and undeployed; their candidate-byte copies are not prior-version rollback artifacts.
- Fleet capacity is FAIL at the requested 1,000-owner local target. The only declared launch scope is the measured 10-owner conditional canary; target-VPS capacity is not measured.
- The exact fresh capacity run's first actual-worker attempt passed without `55P03` or a retry. A separate earlier combined lifecycle/capacity diagnostic hit retryable `scoring_input_gate_busy`; it remains preserved outside the promoted capacity evidence. Fresh lifecycle and capacity gates passed.
- Optional model deployment is BLOCKED/UNCONFIGURED despite its repository suite passing. Four reference-source-dependent tests were skipped explicitly.
- Physical BLE, raw-sensor delivery, phone recovery, Health provider delivery, battery/thermal behavior, and 24/72-hour soaks are NOT_MEASURED.
- SpO2 is BLOCKED pending appropriate hardware, calibration, and independent reference qualification. No numeric pass exists.
- Prior production worker, Edge, database/bucket/config, Android, and iOS rollback artifacts are not captured. Candidate-byte copies cannot stand in for unknown pre-change artifacts.
- No registry publication, worker/Edge deployment, production migration, main-branch merge, or physical-phone installation was performed.

## Evidence index

Use the artifact-root relative files below as the final authority rather than transcribing values from this document:

- `planning/final-input-verification.json`
- `planning/conflict-resolutions.json`
- `planning/merge-remerge-diffs.txt`
- `migrations/artifacts/migration-manifest.json`
- `migrations/artifacts/migration-validation-summary.json`
- `migrations/artifacts/final-contract-inventory.json`
- `pipeline/server-jvm-summary.json`
- `pipeline/server-jvm-archive.json`
- `pipeline/server-pipeline-inventory.json`
- `multiuser/multiuser-validation-summary.json`
- `validation/e2e-scenario-coverage.json`
- `validation/e2e-scenario-coverage-validation.json`
- `validation/static-test-matrix.json`
- `capacity/capacity-measurement-summary.json`
- `capacity/launch-capacity.json`
- `capacity/environment-colima-status.json`
- `capacity/evidence-inventory.sha256`
- `workers/v1/release-summary.json`
- `workers/v2/release-summary.json`
- `workers/optional-model-status.json`
- `workers/rollback/operational-rollback-status.json`
- `android/android-verification.json`
- `android/rollback/rollback-status.json`
- `edge/source-bundle/edge-source-bundle-manifest.json`
- `edge/rollback/rollback-status.json`
- `deployment/source-bundle/deployment-source-bundle-manifest.json`
- `migrations/rollback/rollback-status.json`
- `gates/*.json` and their adjacent logs
- `release/release-artifact-manifest.json`
- `release/release-manifest-summary.json`
