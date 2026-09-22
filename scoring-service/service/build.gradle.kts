plugins {
    kotlin("jvm")
    application
}

kotlin {
    jvmToolchain(17)
}

application {
    mainClass.set("com.frwhoop.scoring.ScoringApplicationKt")
}

dependencies {
    implementation(project(":analytics-kernel"))
    implementation("org.postgresql:postgresql:42.7.4")
    implementation("com.zaxxer:HikariCP:5.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.json:json:20240303")
    implementation("org.slf4j:slf4j-simple:2.0.13")
    implementation("com.github.luben:zstd-jni:1.5.6-3")

    testImplementation("junit:junit:4.13.2")
}

tasks.withType<Test>().configureEach {
    useJUnit()
    // Migration-only edits must rerun the real database tests.
    inputs.files(fileTree("../../supabase/migrations") { include("*.sql") })
    // Root's pinned actual-Swift vectors must invalidate cached JVM parity results.
    inputs.files(fileTree("../../Tests/Fixtures") { include("context-metrics-swift-v1.json") })
    providers.environmentVariable("W4_SWIFT_AUX_FIXTURE_DIR").orNull?.let { path ->
        inputs.dir(path)
        environment("W4_SWIFT_AUX_FIXTURE_DIR",path)
    }
    maxParallelForks = 1
}

tasks.named<Test>("test") {
    // The external Swift corpus has its own mandatory, non-skipping gate.
    exclude("**/WholeDaySwiftParityTest.class")
}

tasks.register<Test>("wholeDaySwiftParity") {
    group = "verification"
    description = "Compare actual-Swift whole-day selections and outputs; missing/stale corpus fails."
    testClassesDirs = sourceSets["test"].output.classesDirs
    classpath = sourceSets["test"].runtimeClasspath
    include("**/WholeDaySwiftParityTest.class")
    val corpus = providers.environmentVariable("W4_SWIFT_DAY_FIXTURE_DIR")
        .orElse(file("../../Tests/Fixtures/w4-whole-day-swift-v1").absolutePath)
    environment("W4_SWIFT_DAY_FIXTURE_DIR", corpus.get())
    inputs.files(fileTree(corpus.get()))
    // Source hashes are checked against the current dirty Swift worktree on every invocation.
    outputs.upToDateWhen { false }
}

tasks.named<JavaExec>("run") {
    dependsOn(":analytics-kernel:compileKotlin")
}

tasks.register<JavaExec>("replayDay") {
    group = "application"
    description = "Enqueue a fenced user/device/day replay and run one bounded worker pass."
    classpath = sourceSets["main"].runtimeClasspath
    mainClass.set("com.frwhoop.scoring.ScoringApplicationKt")
    args("--replay-day")
    dependsOn(":analytics-kernel:compileKotlin")
}
