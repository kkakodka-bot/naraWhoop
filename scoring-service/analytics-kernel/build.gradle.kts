// :analytics-kernel — the scoped Kotlin analytics twin as a PLAIN JVM module.
//
// Extraction strategy (single-source, mechanically verifiable):
//   * The scoped analytics/protocol/pure-data files are COPIED BYTE-VERBATIM from the Android app
//     tree (../android/app/src/main/java/com/noop/...) into build/synced-main by the syncKernelMain
//     task below. The Android app module remains the single source of truth for every formula —
//     nothing is forked, nothing is edited. The explicit KERNEL_*_FILES lists ARE the scope
//     contract: adding a file there is a deliberate, reviewable act.
//   * The com.noop.data Room entities the kernel touches are replaced by hand-written plain DTOs
//     in src/main/kotlin/com/noop/data/ (annotations dropped, field lists verbatim). DtoParityTest
//     diffs each DTO's field list against Entities.kt mechanically.
//   * The scoped twin tests are copied BYTE-VERBATIM from ../android/app/src/test/... and run
//     UNMODIFIED on the JVM — they are the parity oracle (FRWHOOP migration locked decision #2).
//
// Scope (locked): RR/HRV pipeline + sleep staging/sleep score. Charge/Effort/Rest and insights
// engines are NOT synced. Anything importing android.* / androidx.* is excluded by construction
// and guarded by the verifyKernelScope task.

plugins {
    kotlin("jvm")
}

kotlin {
    jvmToolchain(17)
}

// ─────────────────────────────────────────────────────────────────────────────
// Scoped source lists (the extraction contract)
// ─────────────────────────────────────────────────────────────────────────────

val androidMain = rootProject.file("../android/app/src/main/java/com/noop")
val androidTest = rootProject.file("../android/app/src/test/java/com/noop/analytics")
val androidTestResources = rootProject.file("../android/app/src/test/resources")

/** Union dependency closure of (AnalyticsEngine.analyzeDay + HRVReadiness + HrvFreqDomain) and every
 *  com.noop.analytics type the scoped tests reference (imports AND same-package references — the
 *  tests live in the same package, so word-level matching decides). Computed over top-level
 *  declarations with comments/strings stripped. 25 files. Includes the day-window glue (DayCycle,
 *  LocalDayWindows) that only tests reference.
 *
 *  W2 includes CurrentHrv and its test to verify its shared five-minute measurement contract.
 *  SpotHrvReading / RrEmissionStats remain excluded live-only helpers; no server publication is
 *  introduced for those display/instrumentation paths. */
val kernelAnalyticsFiles = listOf(
    "AnalyticsEngine.kt",
    "AnalyticsModels.kt",
    "Baselines.kt",
    "DayCycle.kt",
    "GuidedCaptureProgress.kt",
    "HRVReadiness.kt",
    "HrvAnalyzer.kt",
    "HrvWindow.kt",
    "HrvSeries.kt",
    "PhysiologyQuality.kt",
    "RespirationEstimator.kt",
    "CurrentHrv.kt", // W2: shared five-minute contract, tested byte-identically with the app.
    "HeartRateWindows.kt",
    "HrvFreqDomain.kt",
    "HypnogramCoverage.kt",
    "LocalDayWindows.kt",
    "PrimarySessionRestingHR.kt",
    "RecoveryForecast.kt",
    "RecoveryScorer.kt",
    "ScoreConfidence.kt",
    "SleepStageTotals.kt",
    "SleepOpportunityDetector.kt",
    "SleepStageVocabulary.kt",
    "SleepStager.kt",
    "SleepStagerTrace.kt",
    "SleepStagerV2.kt",
    "StagerCache.kt",
    "StepsCounter.kt",
    "StrainScorer.kt",
    "WakeMotionRefinement.kt",
    "WorkoutDetector.kt",
)

/** Pure protocol types the kernel references (DeviceFamily, ParsedFrame, Whoop4SkinTemp /
 *  skinTempCelsius). No BLE, no android.bluetooth. */
val kernelProtocolFiles = listOf(
    "RrPacketProvenance.kt",
    "Crc.kt",
    "Whoop5RR.kt",
    "DeviceFamily.kt",
    "ParsedFrame.kt",
    "Streams.kt",
)

/** Pure com.noop.data files synced whole (zero Room imports, verified): OuraRespScale (no imports),
 *  DeviceBrandCatalog (java.text only), V18AuxCodec (no imports; declares V18AuxRow). */
val kernelDataFiles = listOf(
    "OuraRespScale.kt",
    "DeviceBrandCatalog.kt",
    "V18AuxCodec.kt",
)

/** Test-centre helpers (main source set in the app) referenced by SleepStagerBandVetoTest. Pure:
 *  TestDomain has no imports; CaptureAccumulator imports only com.noop.analytics.AnalyticsEngine. */
val kernelTestcentreFiles = listOf(
    "TestDomain.kt",
    "CaptureAccumulator.kt",
)

/** The scoped parity oracle: every analytics test whose dependency closure stays inside the kernel
 *  surface. EXCLUDED (with reasons):
 *    - Issue547ImportInflationRepro.kt — tests WhoopRepository.mergeDaily (data-layer merge, not
 *      analytics; needs the Room repository). Still covered by the Android oracle.
 *    - Anything importing android.* / androidx.* / com.noop.data repository types / com.noop.ingest
 *      (repository contract tests, import tests, UI-adjacent tests) — not analytics formulas.
 *  90 top-level + 6 agreement tests = 96 files. */
val kernelTestFiles = listOf(
    "SleepEvidenceTest.kt",
    "SleepOpportunityDetectorTest.kt",
    "SleepStagerV2Test.kt",
    "AnalyticsEngineDayBoundsTest.kt",
    "AnalyticsEngineDaySliceTest.kt",
    "AnalyticsEngineHrOnlyDayTest.kt",
    "AnalyticsEngineProvidedSleepTest.kt",
    "AnalyticsEngineRestTraceContractTest.kt",
    "AnalyticsEngineSleepNeedFloorTest.kt",
    "BanisterBaselineTest.kt",
    "BanisterParityOracleTest.kt",
    "BaselineSeedingTest.kt",
    "BaselinesSigmaDaytimeTest.kt",
    "BoutCalibrationDiagnosticTest.kt",
    "BridgedNightGroupsTest.kt",
    "ChargeEffortRestScoringTest.kt",
    "DayBoutHrMaxAgreementTest.kt",
    "DayCaloriesTest.kt",
    "DayCycleResolverTest.kt",
    "DetectionFunnelTest.kt",
    "DeviceEraEpochTest.kt",
    "DuplicatePairRatioTest.kt",
    "EffectiveEffortTest.kt",
    "EffortMethodThreadingTest.kt",
    "EffortScoreFunnelTest.kt",
    "GuidedCaptureProgressTest.kt",
    "HrOnlyPhysiologyIsolationTest.kt",
    "HrvAnalyzerGateTest.kt",
    "HrvWindowTest.kt",
    "HrvIntegrationTest.kt",
    "HrvPacketAdapterTest.kt",
    "HrvSeriesTest.kt",
    "CurrentHrvTest.kt",
    "HeartRateWindowsTest.kt",
    "HrvAnalyzerRollingTest.kt",
    "HrvAnalyzerSampleOrdTest.kt",
    "HrvAnalyzerSdnnIndexTest.kt",
    "HrvArtifactDensityTest.kt",
    "HrvBaselineRecalibrationTest.kt",
    "HrvCollapseOverCountTest.kt",
    "HrvFreqDomainTest.kt",
    "HrvGapAwareTest.kt",
    "HrvOverCountGateTest.kt",
    "HrvRrCoverageTest.kt",
    "HypnogramCoverageTest.kt",
    "Issue259PreOnsetClampTest.kt",
    "LocalDayWindowsTest.kt",
    "MainNightConsistencyTest.kt",
    "ManualNapTest.kt",
    "MotionCorroboratedWakeTest.kt",
    "NightlySpo2RawTest.kt",
    "NightsSinceNewestValidNightTest.kt",
    "OuraRespScoringExclusionTest.kt",
    "PrimarySessionRestingHRTest.kt",
    "RecentHrvCoverageTest.kt",
    "RecoveryIndexActivityBalanceTest.kt",
    "RespRateGapAwareTest.kt",
    "RespRateRsaTest.kt",
    "RespirationEstimatorTest.kt",
    "RestNeedTest.kt",
    "RhrBinGateDiagnosticTest.kt",
    "RrCoverageVerdictTest.kt",
    "ScoreConfidenceCacheSigTest.kt",
    "SkinTempAnalyticsTest.kt",
    "SleepEditDurabilityTest.kt",
    "SleepMotionLineTest.kt",
    "SleepStageVocabularyTest.kt",
    "SleepStagerActiveBridgeTest.kt",
    "SleepStagerBandVetoTest.kt",
    "SleepStagerCacheFingerprintTest.kt",
    "SleepStagerDaytimeGuardTest.kt",
    "SleepStagerDetectMemoTest.kt",
    "SleepStagerFragmentMergeTest.kt",
    "SleepStagerHrConfirmTest.kt",
    "SleepStagerHrOnlyAnchorTest.kt",
    "SleepStagerHrOnlySpineTest.kt",
    "SleepStagerHrOnlyTraceTest.kt",
    "SleepStagerNightContinuationTest.kt",
    "SleepStagerOffWristTest.kt",
    "SleepStagerPhase2Test.kt",
    "SleepStagerRemFunnelTest.kt",
    "SleepStagerRespEvidenceTest.kt",
    "SleepStagerSparseGravityTest.kt",
    "SleepStagerTraceTest.kt",
    "SleepStagerWindowEndpointTest.kt",
    "Spo2CandidateNightlyTest.kt",
    "Spo2CeilingNightlyTest.kt",
    "StepsAnalyticsTest.kt",
    "StepsCounterTest.kt",
    "StrainBanisterDenominatorTest.kt",
    "StrainRestingHrTest.kt",
    "StrainSampleDurationTest.kt",
    "VendorRespRateTest.kt",
    "VitalCarryStalenessTest.kt",
    "Vo2maxCaloriesTest.kt",
    "WakeMotionRefinementTest.kt",
    "WorkoutDetectorTest.kt",
    "agreement/HrvFreqAgreementTest.kt",
    "agreement/HrvGoldAgreementTest.kt",
    "agreement/HrvOpticalRobustnessTest.kt",
    "agreement/RealDataRundownTest.kt",
    "agreement/RecoveryAgreementTest.kt",
    "agreement/RrVersionRundownTest.kt",
)

/** Test resources the scoped tests load from the classpath. */
val kernelTestResourceFiles = listOf(
    "sleep_evidence_oracle.json",
    "sleep_group_selection_oracle.json",
    "hrv_window_oracle.json",
    "heart_rate_windows_oracle.json",
    "respiration_oracle.json",
    "local_day_windows_oracle.json",
)

// ─────────────────────────────────────────────────────────────────────────────
// Sync tasks (byte-verbatim copies; the Android tree stays the single source)
// ─────────────────────────────────────────────────────────────────────────────

val syncedMainDir = layout.buildDirectory.dir("synced-main")
val syncedTestDir = layout.buildDirectory.dir("synced-test")
val syncedTestResourcesDir = layout.buildDirectory.dir("synced-test-resources")

val syncKernelMain = tasks.register<Copy>("syncKernelMain") {
    description = "Copies the scoped analytics/protocol/pure-data sources byte-verbatim from the Android app."
    doFirst { delete(syncedMainDir) }
    into(syncedMainDir)
    from(androidMain.resolve("analytics")) {
        kernelAnalyticsFiles.forEach { include(it) }
        into("com/noop/analytics")
    }
    from(androidMain.resolve("protocol")) {
        kernelProtocolFiles.forEach { include(it) }
        into("com/noop/protocol")
    }
    from(androidMain.resolve("data")) {
        kernelDataFiles.forEach { include(it) }
        into("com/noop/data")
    }
    from(androidMain.resolve("testcentre")) {
        kernelTestcentreFiles.forEach { include(it) }
        into("com/noop/testcentre")
    }
    // Fail loudly if the Android tree moved (a stale silent copy is the worst outcome).
    doFirst {
        (kernelAnalyticsFiles.map { androidMain.resolve("analytics/$it") } +
            kernelProtocolFiles.map { androidMain.resolve("protocol/$it") } +
            kernelDataFiles.map { androidMain.resolve("data/$it") } +
            kernelTestcentreFiles.map { androidMain.resolve("testcentre/$it") })
            .forEach { f ->
                if (!f.isFile) throw GradleException("kernel source missing from Android tree: $f")
            }
    }
}

val syncKernelTests = tasks.register<Copy>("syncKernelTests") {
    description = "Copies the scoped parity-oracle tests byte-verbatim from the Android app."
    doFirst { delete(syncedTestDir) }
    into(syncedTestDir)
    from(androidTest) {
        kernelTestFiles.forEach { include(it) }
        into("com/noop/analytics")
    }
    doFirst {
        kernelTestFiles.map { androidTest.resolve(it) }.forEach { f ->
            if (!f.isFile) throw GradleException("kernel test missing from Android tree: $f")
        }
    }
}

val syncKernelTestResources = tasks.register<Copy>("syncKernelTestResources") {
    description = "Copies the test resources the scoped tests load from the classpath."
    doFirst { delete(syncedTestResourcesDir) }
    into(syncedTestResourcesDir)
    from(androidTestResources) { kernelTestResourceFiles.forEach { include(it) } }
}

/** Scope guard: the synced tree must contain NO android./androidx. usage and no references to the
 *  Room data layer (WhoopRepository / WhoopDao / WhoopDatabase / DeviceRegistry*). This is the
 *  mechanical half of acceptance check #2 — the DTO layer is what makes it pass.
 *
 *  One grandfathered reference: Baselines.kt names `android.content.SharedPreferences.Editor`
 *  (fully-qualified, no import) in the device-side recalibration helper; it compiles against the
 *  minimal stub in src/main/kotlin/android/content/. Any OTHER android reference fails the build. */
val verifyKernelScope = tasks.register("verifyKernelScope") {
    description = "Asserts the synced kernel has no Android/Room/repository dependencies."
    dependsOn(syncKernelMain, syncKernelTests)
    doLast {
        val roots = listOfNotNull(syncedMainDir.get().asFile, syncedTestDir.get().asFile)
        val importRe = Regex("""^import\s+(android\.|androidx\.|com\.noop\.data\.(WhoopRepository|WhoopDao|WhoopDatabase|DeviceRegistry|DeviceRegistryDao|PairedDeviceRow|DeviceStatus|MetricSeriesRow))""")
        val androidRefRe = Regex("""\bandroid(x)?\.""")
        val grandfathered = Regex("""android\.content\.SharedPreferences\.Editor""")
        val grandfatheredFiles = setOf("Baselines.kt", "HrvBaselineRecalibrationTest.kt")
        val offenders = mutableListOf<String>()
        roots.forEach { root ->
            root.walkTopDown().filter { it.isFile && it.extension == "kt" }.forEach { f ->
                f.readLines().forEachIndexed { i, rawLine ->
                    val line = rawLine.trim()
                    if (importRe.containsMatchIn(line)) {
                        offenders += "${f}:${i + 1}: $line"
                    } else if (androidRefRe.containsMatchIn(line) &&
                        !line.startsWith("*") && !line.startsWith("//") &&
                        !(f.name in grandfatheredFiles && grandfathered.containsMatchIn(line))
                    ) {
                        offenders += "${f}:${i + 1}: $line"
                    }
                }
            }
        }
        if (offenders.isNotEmpty()) {
            throw GradleException(
                "kernel scope violation — forbidden references found:\n" + offenders.joinToString("\n")
            )
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Source sets
// ─────────────────────────────────────────────────────────────────────────────

sourceSets {
    main {
        kotlin.srcDir("src/main/kotlin") // hand-written DTOs
        kotlin.srcDir(syncedMainDir)     // synced twin sources
    }
    test {
        kotlin.srcDir("src/test/kotlin") // kernel-side guard tests (DTO parity, …)
        kotlin.srcDir(syncedTestDir)     // synced parity-oracle tests
        resources.srcDir(syncedTestResourcesDir)
    }
}

tasks.named("compileKotlin") { dependsOn(syncKernelMain, verifyKernelScope) }
tasks.named("compileTestKotlin") { dependsOn(syncKernelTests, syncKernelTestResources, verifyKernelScope) }
tasks.named("processTestResources") { dependsOn(syncKernelTestResources) }

dependencies {
    // org.json is part of the Android platform, so the twin sources use it without declaring it;
    // on a bare JVM it must be an explicit main-scope dependency (AnalyticsEngine, SleepStageTotals,
    // HypnogramCoverage).
    implementation("org.json:json:20240303")
    testImplementation("junit:junit:4.13.2")
}

tasks.named<Test>("test") {
    description = "Runs the scoped twin tests UNMODIFIED on the JVM (the parity oracle) plus the kernel guard tests."
    testLogging {
        events("passed", "failed", "skipped")
        showStandardStreams = false
    }
    // Fixture-backed agreement tests skip via assumeTrue when their local fixtures are absent.
}

tasks.register("parityGate") {
    group = "verification"
    description = "Alias for :analytics-kernel:test (scoped JVM parity oracle)."
    dependsOn(tasks.named("test"))
}
