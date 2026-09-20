# Physiology v2 verification baseline

Recorded 2026-09-18 for `feature/physiology-algorithms-v2` in
`/Volumes/Untitled/WHOOP NARA-physiology-v2`, starting at
`5caa31689da0023e111beb36850d3f81d67e1be2`. This is a starting-state record,
not acceptance of the upgrade or of physiological accuracy. No production
service, database, account, or device was accessed.

## Host and execution environment

| Item | Observed state |
| --- | --- |
| Host | Apple Silicon macOS; Swift target `arm64-apple-macosx26.0` |
| Swift | Apple Swift 6.2.4, swiftlang-6.2.4.1.4 |
| Xcode | 26.3, build 17C529 |
| Java | Homebrew OpenJDK 17.0.16 at `/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home` |
| Java discovery | `/usr/libexec/java_home -V` fails; explicit `JAVA_HOME` works |
| Gradle | Repository wrapper 8.7, distribution SHA-256 pinned in wrapper properties |
| Android | SDK absent at conventional location and environment variables unset; actual unit-test invocation confirms missing SDK |
| Edge | `deno` absent from PATH and `~/.deno/bin/deno` absent |
| PostgreSQL | `psql` and `initdb` 18.3 available |
| Docker | Running daemon reports 29.2.1 |
| Storage at start | Internal available 5.0 GiB; `/Volumes/Untitled` available 500 GiB |

Raw command logs, Gradle downloads, temporary files, and Swift scratch/cache
are under `/Volumes/Untitled/physiology-v2-baseline.ROUXBD`. Gradle project
outputs remain under the external-disk checkout. No caches were deleted.

## Commands and observed results

Run scoring commands from `scoring-service/` with:

```sh
export JAVA_HOME='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home'
export GRADLE_USER_HOME='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/gradle'
export TMPDIR='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/tmp'
export JAVA_TOOL_OPTIONS='-Djava.io.tmpdir=/Volumes/Untitled/physiology-v2-baseline.ROUXBD/tmp'
./gradlew --no-daemon --max-workers=2 :analytics-kernel:test :service:test
./gradlew --no-daemon --max-workers=2 :analytics-kernel:test
```

The combined required gate **failed at service compilation**, before service
tests could run:

```text
DerivedArtifactWriter.kt:29:30 Argument type mismatch:
actual type is 'com.frwhoop.scoring.b2.B2ObjectStore',
but 'com.frwhoop.scoring.b2.B2ObjectStore.PutClient?' was expected.
BUILD FAILED in 1m 9s
```

`B2ObjectStore` exposes a `putObject` method but does not implement its nested
`PutClient` interface; `DerivedArtifactWriter.livePut` assigns a store instance
to that interface. Log: `scoring-tests.log`.

The isolated kernel gate **passed** in 6 seconds: JUnit XML reports **746
tests, 0 failures, 0 errors, 5 skipped** (741 executed successfully). Log:
`kernel-tests.log`; XML: `scoring-service/analytics-kernel/build/test-results/test/`.
The following skips are unavailable external/local-only data, not validated
reference comparisons:

- `HrvFreqAgreementTest.lfHfRatioAgreesWithScipyReference`
- `HrvGoldAgreementTest.rmssdSdnnPnn50MatchTextbookReferenceOnGoldRr`
- `HrvOpticalRobustnessTest.gapAwareCutsMaeVsGoldOnRegularRhythmsUnderOpticalArtifacts`
- `RealDataRundownTest.realRundown`
- `RecoveryAgreementTest.recoveryMatchesReferenceFormulaAcrossCases`

The default agreement-fixture path is a developer-specific Windows path;
`noop.hrvGoldFixtures` can override it. Even with those fixtures, the existing
gold HRV test checks formulas against already-cleaned NN arrays. It does not
establish WHOOP beat detection, source selection, time coverage or ECG error.

From `android/`, with the same four environment variables:

```sh
./gradlew --no-daemon --max-workers=2 \
  --project-cache-dir '/Volumes/Untitled/physiology-v2-baseline.ROUXBD/android-project-cache' \
  testFullDebugUnitTest
```

This **failed before executing tests** in 26 seconds: `SDK location not found`.
Log: `android-tests.log`. This is a host setup blocker; it does not justify
omitting Android acceptance after a disposable SDK is provisioned.

From repository root:

```sh
python3 Tools/doc_comment_lint.py
python3 Tools/i18n_audit.py --ci origin/main
```

Source hygiene **passed**: 2,143 files, 24 existing baselined sites. Log:
`doc-comment-lint.log`. The i18n audit **failed** on 3 Android and 47 Apple
unregistered literals; focus-locale checks and translation ratchets passed.
Log: `i18n-audit.log`. These source files were unchanged by the physiology
implementation at invocation. Examples include Android NARA update/widget
strings, Apple NARA branding, `CloudPushView`, and medication-screen copy.
Do not expand a baseline allowance to make these findings disappear.

From `Packages/StrandAnalytics/`:

```sh
TMPDIR='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/tmp' \
CLANG_MODULE_CACHE_PATH='/Volumes/Untitled/physiology-v2-baseline.ROUXBD/clang-module-cache' \
swift test \
  --scratch-path '/Volumes/Untitled/physiology-v2-baseline.ROUXBD/swift-analytics' \
  --cache-path '/Volumes/Untitled/physiology-v2-baseline.ROUXBD/swift-cache' \
  --jobs 2 --filter CurrentHRVTests
```

This invocation fetched GRDB 6.29.3 and **failed during compilation**, before
tests, on an incomplete in-progress W0 interface: `StreamStore.swift:525`
referenced `PpgWaveformSample.recordIndex`, while that protocol type did not
yet provide it; line 888 similarly supplied an unsupported initializer
argument. Log: `swift-current-hrv.log`. The W0 author received the exact
failure. W0 storage edits arrived while dependencies were fetching, so this
is explicitly **not a pristine baseline failure** and must be rerun after
the W0 checkpoint. The host's Swift toolchain itself is available.

## Existing test surface and what it proves

| Surface | Useful existing evidence | Limit |
| --- | --- | --- |
| JVM analytics kernel | Byte-copied Android analytics and tests; scope guard; DTO field-list parity | Explicit source/test lists omit `CurrentHrv`, `SpotHrvReading`, and some app/data integration tests; new source files need deliberate inclusion |
| Service unit tests | Mapper, payload, archive, ordering and day-boundary cases | Queue tests inspect SQL substrings; completion test compares two `Instant`s. Neither executes concurrent PostgreSQL transactions |
| Swift packages | Native formula, decode, GRDB migration and storage tests | Must rerun changed packages; package tests do not compile app-target caches/views |
| Android app unit tests | Full Kotlin app and Room schema compile/test surface | Cannot be replaced by the scoped kernel gate |
| SleepPSG | Four-stage confusion/metrics, participant-wise ablations, exact recipe-port comparisons | Stages PSG-supplied windows; no end-to-end detection, naps, publication, or WHOOP R-R reference in `sleep-accel` |
| SleepBench | Replays database/reference projections | Manual/vendor labels are secondary agreement, not primary PSG truth |
| Edge suite | `cd supabase/functions && deno test --allow-all tests/` | Not run in this baseline: Deno unavailable |

Current `CurrentHRVTests` also expect a non-null value from roughly 24–30
seconds of intervals. Their historical expectations therefore cannot be
accepted as the new 300-second coverage policy. Add tests for the new policy
instead of treating preservation of every old expected value as success.

The baseline CI workflow inventory is authoritative over stale prose:
`swift-packages.yml` runs affected package/tool builds and tests;
`android.yml` runs `assembleFullDebug` and `testFullDebugUnitTest`;
`source-hygiene.yml` and `i18n-coverage.yml` run static gates. The current
`tools-python.yml` has `Tools/**` path filters despite commentary claiming
otherwise. App-target Apple compilation is not a normal PR gate and must be
executed locally for changes to those targets. No CI run was dispatched.

## Shared fixtures to retain and extend

The following duplicate Swift/Android files were byte-identical by SHA-256
before edits:

| Fixture | Baseline SHA-256 | Extension needed |
| --- | --- | --- |
| `decoder_oracle.json` | `36b622fdb77b74627e6d665d647ab5616b917cb9b7a04587d68a6e82b2341506` | Preserve decoder values and batch shape; add packet identity/timing provenance where supported |
| `whoop5_rr_oracle.json` | `e09e4945aaedf778755975300c635512da64195576da32664fa41df22ba37395` | Carry known tick conversion into canonical source-selection fixtures |
| `schema_oracle.json` | `ab1a44cbb2696716575f0acb7a6e79b5a7badc2fd75acfdf8f3eb10397fb5c34` | Add additive schema changes and justified platform divergences |
| `r20_optical_oracle.json` | `98e10af0c85191e20a97657ba27afa4808ec758b09b76b4e5e8ba6710555a3e8` | Preserve framing/ADC facts without inventing wavelength semantics |

`android/app/src/test/resources/local_day_windows_oracle.json` is also read by
Swift via repository-relative lookup and copied into the server kernel. It
already pins DST/timezone boundaries. Extend it for full-day and following-day
dependency windows instead of weakening existing boundary cases.

`whoop5_rr_paired_capture.json` explicitly contains re-encoded/redacted frames:
R-R words/counts preserve observed values, while times/HR and other fields are
synthetic. It supports the stated paired transport/tick evidence; it cannot
prove original subsecond timestamps, uninterrupted coverage or true raw
waveform availability.

New shared fixtures should traverse actual Swift, Android and server entry
points and assert the same output contract: one owner/source, revision,
half-open UTC bounds, original observation identities, continuity/pair masks,
coverage denominators, maximum edge/interior gaps, observed versus corrected
metrics, abstention reasons and zero-versus-null semantics. Include duplicate
packet replay, equal numerical intervals, dropped middle beat, two intervals
inside an otherwise empty window, source switches, suspect clocks, clean
elevated variability, and cumulative corrections. Numerical parity alone is
insufficient if all three implementations share the same input defect.

## Acceptance evidence still required

1. Disposable SQLite tests for legacy and already-widened PPG schemas,
   multiple same-second records and replay; native/store/export/server
   source selection on the same packet fixtures.
2. Actual disposable PostgreSQL migrations and transactions: over 300
   successful revisions, unchanged-input retry exhaustion, new data after
   exhaustion, late commits, lease stealing/renewal, stale publication,
   two-device/two-user isolation, midnight dependencies, generated episode
   replacement, manual tombstones and independently retried archives.
3. Native/JVM quality-window and summary parity; full Android tests and
   app-target compilation. Both client caches must round-trip stages,
   probabilities, missingness, owner/device/version, and suppress delayed
   previous-account requests while offline.
4. Extend reference harnesses with independent full-day detection/nap labels,
   participant-before-window splits, context-overlap purging, train-only
   normalization/calibration, participant bootstrap intervals, coverage/error
   curves, clean-high-HRV strata, and respiratory harmonic/range cases.
   Report common-window errors and each model's native retained coverage.
5. Build manifest-validated shadow adapters and corrupt/gapped/wrong-channel
   fixture tests. Every manifest needs code/checkpoint/preprocessing/quality
   hashes, separate code/weight/data rights, allowed channels/rates/shape,
   mode/latency, deterministic seed/tolerance and resource limits. No
   checkpoint or target-reference dataset was downloaded for this inventory.
6. A frozen, versioned promotion policy and signed evaluation manifest;
   feature-specific opt-in/rollback, with no automatic model promotion.
   Actual VPS CPU/RAM/throughput/p95 measurements and physical full-night
   locked-phone/background/backfill soak remain external acceptance work.

Synthetic fixtures and green host tests establish implementation behavior.
They do not establish PSG/ECG/respiratory accuracy, device power behavior,
overnight reliability, or deployed status.
