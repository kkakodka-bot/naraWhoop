# Physiology v2 final verification

Recorded 2026-09-18 in `/Volumes/Untitled/WHOOP NARA-physiology-v2`, branch `feature/physiology-algorithms-v2`, based exactly on `5caa31689da0023e111beb36850d3f81d67e1be2`. This report supersedes intermediate test counts, not the historical [baseline record](verification-baseline.md).

## Delivery and readiness

The source implementation covers acquisition identity/provenance, shared five-minute HRV, full-day sleep/state accounting, abstaining respiration, durable server revisions/publication, native selected-source readback, shadow model adapters and reference/promotion tooling. The requirement map is [implementation-plan.md](implementation-plan.md).

| Dimension | Evidence-bounded status |
| --- | --- |
| Implemented | W0–W5 source, migrations, interfaces, fixtures, native views and offline tools integrated and independently reviewed |
| Functionally verified | Native packages, Android unit/runtime tests, app compilation, JVM, actual disposable PostgreSQL, Edge and Python gates below |
| Hardware-soaked | **NOT_READY**: no phone/strap run, locked-phone overnight soak, battery measurement or supported-device compression round trip |
| Reference-validated | **NOT_READY**: no synchronized target ECG/PSG/respiratory cohort or held-out target evaluation |
| Model/VPS qualified | **NOT_READY**: no reviewed activation, target Linux model environment or actual VPS capacity measurement |
| Deployed/promoted | **NOT_DONE**: no push, merge, deployment, selection change or cohort enrollment |

Checked packets retain identity and packet-local adjacency but do not prove a subsecond acquisition clock or cross-packet continuity. Thus current historical inputs may correctly yield unavailable HRV/RSA, not invented five-minute coverage. All eight model manifests remain `metadata_only`, shadow, and `canonical_outputs_allowed: false`. Canonical defaults retain `frwhoop-server-1`; v2 computes `frwhoop-physiology-2` shadow results. The rollback requires the actual retained v1 binary/image, not relabeling the v2 binary.

## Source commits

- `20ca717`: native acquisition, shared algorithms, caches, selected-source UI and twin fixtures.
- `534a670`: server orchestration, additive migrations, inventory, raw verification and transactional tests.
- `0fa6309`: shadow inference, correction comparison, environment/resources and reference/promotion tools.

Final inference implementation and all eight matching adapter digests: `b4a73a764a99ed00386af4bb3dd6a99a3baf9ee72b76aaed54366c28d4c0e77e`. Each inventory's disabled/shadow/canonical-false flags and digests were independently rechecked before committing.

The following final documentation-only commit does not alter tested implementation. No downloaded checkpoints, raw health data, database files, build outputs, credentials or test logs are included. The original `/Volumes/Untitled/WHOOP NARA-pr16` tracked worktree remains unchanged, with its existing untracked documents/build directory preserved.

## Executed gates

Counts are per invocation, not unique cross-platform tests. A reported count includes skips; executed passes are shown separately. Shared fixtures and repeated database cases must not be added together as independent scientific samples.

| Gate | Result | Retained evidence |
| --- | --- | --- |
| Swift StrandAnalytics | 1,921 passed; no failures/skips | `B/swift-analytics-release.log` |
| Swift WhoopStore | 591 reported: 590 passed, 1 fixture skip | `B/swift-store-release.log` |
| Swift WhoopProtocol | 731 reported: 730 passed, 1 corpus skip | `B/w0-final-protocol.log` |
| Swift NoopPush | 27 passed; no failures/skips | `B/w0-final-push.log` |
| Android full debug unit tests | 5,681 reported across 697 suites: 5,675 passed, 6 fixture skips; no failures/errors | `B/android-final-physiology-details-full-rerun.log`; XML `B/android-final-details-results.lUFfeD` |
| Android full debug APK | Build passed; no install/launch | Same log; artifact hash below |
| JVM copied analytics kernel | 802 reported across 103 suites: 797 passed, 5 fixture skips; no failures/errors | `B/service-release.log`; XML `B/service-release-results.59A1VK/kernel` |
| JVM service and distribution | 128 reported: 60 ordinary tests passed, 68 database cases skipped without DB environment; `installDist` passed | Same log; XML `B/service-release-results.59A1VK/service` |
| Actual PostgreSQL integration | All 68 database cases passed across 9 suites; no skips/errors | `B/pg-final-inventory.log`; `S/tmp/physiology-queue.EAQnrv` |
| Official Supabase PostgreSQL full chain | All 82 migrations applied; queue/publication/archive/RLS/shadow-selection and legacy-continuation smoke checks passed | `S/full-chain-final.6TFrpw` |
| Edge | 61 passed; no failures | `B/w0-final-edge.log` |
| macOS app | `Strand` build passed, code signing disabled; no launch | `B/xcode-macos-release.log` |
| iOS Simulator app | `NOOPiOS` generic simulator build passed, code signing disabled; no install/launch | `B/xcode-ios-release.log` |
| Python inference | 52 passed; no failures/skips | `S/inference-complete-requirements.log` |
| Reference/promotion benchmark harness | 64 passed; no failures/skips | `S/physiology-bench-requirements-final.log` |
| Linux kernel process-tree primitives | Synthetic child/grandchild CPU/memory probe passed in a cached, network-disabled Node container; not Python/Octave/model execution | `S/cgroup-linux-kernel-probe.log` |
| Localization scanner tests | 47 passed | `B/i18n-release-tests.log` |
| Documentation/source hygiene | Passed; 2,206 files and unchanged 24-site baseline at invocation | `B/doc-comment-release.log` |
| Whitespace | `git diff --check` passed | Final local source check |

`B` = `/Volumes/Untitled/physiology-build`; `S` = `/Volumes/Untitled/physiology-v2-baseline.ROUXBD`. Logs and disposable data remain outside the source checkout; no caches or user data were deleted.

APK: `android/app/build/outputs/apk/full/debug/app-full-debug.apk`, SHA-256 `a781bf5ec52023d1149a19a94950e88fba95bbf17a6f7a042090fedfcf4dc006`.

Android's three JaCoCo method-size checks passed without increasing their budgets. `analyzeRecentOnCpu` is 55,683 instrumented bytes against the existing 55,700-byte budget, leaving **17 bytes** of budget headroom. The extracted persistence helper is 6,497/12,000 bytes. This narrow main-method margin is a maintenance constraint, not an unexecuted gate.

The ordinary service invocation intentionally does not claim the skipped database cases. The separate real-PostgreSQL invocation executes every one. The 82-migration check used cached official `public.ecr.aws/supabase/postgres:17.6.1.127`, image digest `sha256:be60aee15997daca475b710b734bc6bfe52cd544dcd7e9fd2ff58210b6747d83`, initialized platform roles/extensions, and the non-superuser `postgres` migration role. Its container had no network, published ports or host binds; smoke transactions rolled back, leaving zero fixture users. All 82 copied migration hashes were compared with final source. This is database-level evidence, not the complete Auth/Storage/PostgREST stack or a deployed environment. Full-chain test containers are stopped and retained; the disposable kernel-probe container was automatically removed after completion.

## Exceptions, failed checkpoints and evidence limits

The full localization audit still **fails on pre-existing findings**: 3 Android and 46 Apple unregistered literals, each independently checked against the starting commit. No task-added findings, missing required translations, format mismatches or expanded baseline allowance were accepted. Focus/extra-locale/translation ratchets passed. Evidence: `B/i18n-release.log` and `B/i18n-baseline-comparison-release.log`. This is not a whole-repository all-green claim.

WhoopStore's skip requires an explicitly provided disposable phone-database copy; WhoopProtocol's skip requires `WHOOP_R20_CORPUS`. The five kernel and corresponding Android skips require unavailable HRV/recovery/reference fixtures; Android's sixth requires the raw optical corpus. No skipped reference comparison is called validation.

The first final Android invocation failed on a missing `TextButton` import in the new Health links before tests ran. The import was fixed and the entire test/build command rerun successfully. Earlier numerical-test fixture issues, incomplete in-progress interfaces and source-oracle mismatches are superseded by the complete final runs; production recovery arithmetic was not changed to satisfy those tests. Apple builds retain warnings and are not warning-free certification.

UI additions reuse existing typography, colors, cards and navigation; they do not redesign the interface. Source review confirmed real destinations, unavailable/loading/sign-in/configuration paths, owner/day selection, and no local scalar/sparkline fallback in server mode. Tests cover DTO/source-state behavior. There was no visual click-through, accessibility-device audit, physical app run or smoothness measurement; build success does not establish those outcomes.

## Reproduction commands

Use the repository's existing toolchains: Xcode 26.3/Swift 6.2.4, OpenJDK 17, repository Gradle wrappers, a provisioned disposable Android SDK, PostgreSQL and Deno. The initial missing SDK/Deno setup was resolved on the external volume; no production system was changed.

```sh
export JAVA_HOME='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home'
export GRADLE_USER_HOME='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/gradle'
export TMPDIR='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/tmp'
export JAVA_TOOL_OPTIONS='-Djava.io.tmpdir=/Volumes/Untitled/physiology-v2-baseline.ROUXBD/tmp'
export ANDROID_HOME='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/android-sdk'
export ANDROID_USER_HOME='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/android-user'

# From scoring-service:
./gradlew --no-daemon --max-workers=2 :analytics-kernel:test :service:test :service:installDist
bash scripts/test-physiology-queue.sh

# From android:
./gradlew :app:testFullDebugUnitTest :app:assembleFullDebug --continue --rerun-tasks --no-daemon --max-workers=2 --project-cache-dir '/Volumes/Untitled/physiology-v2-baseline.ROUXBD/android-project-cache'

# From repository root (repeat for each changed package):
swift test --package-path Packages/StrandAnalytics --scratch-path '/Volumes/Untitled/physiology-build/analytics-swift' --jobs 2
swift test --package-path Packages/WhoopStore --scratch-path '/Volumes/Untitled/physiology-build/swift-store' --jobs 2
swift test --package-path Packages/WhoopProtocol --scratch-path '/Volumes/Untitled/physiology-build/swift-protocol'
swift test --package-path Packages/NoopPush --scratch-path '/Volumes/Untitled/physiology-build/swift-nooppush'
xcodegen generate
env TMPDIR='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/tmp' xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath '/Volumes/Untitled/physiology-v2-baseline.ROUXBD/xcode-macos' -clonedSourcePackagesDirPath '/Volumes/Untitled/physiology-v2-baseline.ROUXBD/xcode-packages' -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
env TMPDIR='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/tmp' xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' -derivedDataPath '/Volumes/Untitled/physiology-v2-baseline.ROUXBD/xcode-ios' -clonedSourcePackagesDirPath '/Volumes/Untitled/physiology-v2-baseline.ROUXBD/xcode-packages' -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
python3 Tools/doc_comment_lint.py
python3 Tools/i18n_audit.py --ci origin/main
python3 -m unittest discover -s Tools -p test_i18n_audit.py

# From supabase/functions (cached Deno 2.9.6):
env NPM_CONFIG_CACHE='/Volumes/Untitled/physiology-build/npm' npx --yes deno test --allow-all tests/

# From repository root, using the isolated pinned functional environment:
env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH='scoring-service/inference:Tools/physiology-bench:/Volumes/Untitled/physiology-v2-baseline.ROUXBD/neurokit-source' WALCH_SOURCE='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/walch-source' MPLCONFIGDIR='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/matplotlib' TMPDIR='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/tmp' /Volumes/Untitled/physiology-v2-baseline.ROUXBD/inference-guard-env.30teEF/bin/python -m unittest discover -s scoring-service/inference/tests -v
env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Tools/physiology-bench /opt/homebrew/opt/python@3.10/bin/python3.10 -m unittest discover -s Tools/physiology-bench/tests -v

# Separate Linux kernel primitive probe, using the already-cached image:
docker run --rm -i --network none --cpus 1 --memory 512m --entrypoint node node:22.15.0-bookworm-slim - < scoring-service/inference/tests/cgroup_kernel_probe.js
```

The exact full-chain runner, SQL smoke files, image identity, per-migration output and hashes are retained in `S/full-chain-final.6TFrpw`; the ordinary disposable-Postgres command is committed in `scoring-service/scripts/test-physiology-queue.sh`. Python functional dependencies/source revisions and reproduction commands are documented in [the inference README](../../scoring-service/inference/README.md). The final Python 3.10.18 environment is an isolated, no-pip view of existing pinned dependency bytes, including NumPy 2.2.6, without ambiguous duplicate installed metadata. `S/observed-feature-environment-resource-final.json` remains explicitly unqualified; a host dependency inventory is not a reviewed production environment. Production Python accounting on Linux and actual Octave execution remain NOT_RUN; the Node probe does not substitute for them.

## Independent review and remaining gates

Independent reviews inspected counterexamples and code, not only author reports. Fixed findings include rejected shared-beat endpoints, too-permissive RSA span tolerance, conflicting baseline revisions, unknown sleep-state accounting, past-only/event-time fencing, owner-scoped cache/request races, raw-byte verification, legacy override continuation, source-labelled UI fallback, five-minute series visibility, same-input correction sweeps, stage risk/coverage denominators, installed import-origin binding and RRest environment-asset handling. Final resource review added rejection of shared/unreadable/shadow-mounted cgroups and contradictory memory-accounting metadata. The selected memory metric is frozen with its resource policy; charged-memory peaks are not RSS. Each confirmed behavior defect has a regression or an executed integration check. The final reviewer independently reran five resource/policy controls, all passing, and reported no remaining confirmed defect in the reviewed changes.

Follow [external-acceptance.md](external-acceptance.md) for explicit authorization, exact-build hardware evidence, genuine clock/channel qualification, independently reviewed rights/environments, synchronized reference evaluation, target resource measurements, opt-in deployment and rollback. These external gates remain separate from implementation completion. No accuracy, clinical, acquisition-continuity or production-readiness claim is made from synthetic/local green tests.
