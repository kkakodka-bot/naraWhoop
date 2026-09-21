import java.security.MessageDigest
import java.io.ByteArrayOutputStream

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
}

sourceSets.test {
    resources.srcDir(rootProject.file("../android/app/src/test/resources"))
}

val physiologySourceFingerprint by tasks.registering {
    val repository=rootProject.projectDir.parentFile
    val sources=files(fileTree(repository.resolve("android/app/src/main/java/com/noop/analytics")) { include("**/*.kt") },
        fileTree(repository.resolve("android/app/src/main/java/com/noop/protocol")) { include("**/*.kt") },
        listOf("data/OuraRespScale.kt","data/DeviceBrandCatalog.kt","data/V18AuxCodec.kt",
            "testcentre/TestDomain.kt","testcentre/CaptureAccumulator.kt").map {
            repository.resolve("android/app/src/main/java/com/noop/$it") },
        fileTree(rootProject.file("analytics-kernel/src/main/kotlin")) { include("**/*.kt") },
        fileTree(projectDir.resolve("src/main/kotlin")) { include("**/*.kt") },
        fileTree(projectDir.resolve("src/main/resources")) { include("**/*") },
        projectDir.resolve("build.gradle.kts"),rootProject.file("analytics-kernel/build.gradle.kts"),
        rootProject.file("build.gradle.kts"),rootProject.file("settings.gradle.kts"),rootProject.file("gradle.properties"),
        rootProject.file("gradle/wrapper/gradle-wrapper.properties"),rootProject.file("gradle/wrapper/gradle-wrapper.jar"))
    val destination=layout.buildDirectory.file("generated/physiology/physiology-source.sha256")
    inputs.files(sources).withPathSensitivity(PathSensitivity.RELATIVE)
    outputs.file(destination)
    doLast {
        val hash=MessageDigest.getInstance("SHA-256")
        for(source in sources.files.sortedBy { it.relativeTo(repository).invariantSeparatorsPath }) {
            hash.update(source.relativeTo(repository).invariantSeparatorsPath.toByteArray(Charsets.UTF_8))
            hash.update(0.toByte()); hash.update(source.readBytes()); hash.update(0.toByte())
        }
        destination.get().asFile.apply { parentFile.mkdirs(); writeText(hash.digest().joinToString("") { "%02x".format(it) }) }
    }
}
sourceSets.main { resources.srcDir(layout.buildDirectory.dir("generated/physiology")) }
tasks.named("processResources") { dependsOn(physiologySourceFingerprint) }

// installDist has no /app/release.sha. Bind its JAR to the checked-out source rather than
// accepting a runtime-provided file or trusting SCORING_WORKER_SOURCE_REVISION alone.
val scoringSourceRevision by tasks.registering {
    dependsOn(physiologySourceFingerprint)
    val repository = rootProject.projectDir.parentFile
    val destination = layout.buildDirectory.file("generated/physiology/scoring-source-revision.txt")
    val declared = providers.gradleProperty("scoringSourceRevision")
    inputs.property("declaredRevision", declared.orElse(""))
    outputs.file(destination)
    outputs.upToDateWhen { false } // HEAD and Git index changes are not ordinary Gradle source inputs.
    doLast {
        fun git(vararg arguments: String): String? {
            val output = ByteArrayOutputStream()
            return try {
                val result = project.exec {
                    workingDir(repository)
                    commandLine("git", *arguments)
                    standardOutput = output
                    errorOutput = ByteArrayOutputStream()
                    isIgnoreExitValue = true
                }
                if (result.exitValue == 0) output.toString(Charsets.UTF_8).trim() else null
            } catch (_: Exception) { null }
        }
        val head = git("rev-parse", "--verify", "HEAD")
        val requested = declared.orNull
        if (requested != null) {
            require(Regex("[0-9a-f]{40}").matches(requested)) { "scoringSourceRevision must be an immutable revision" }
            require(head == null || head == requested) { "scoringSourceRevision differs from checked-out HEAD" }
        }
        val revision = head ?: requested
        val sourcePaths = physiologySourceFingerprint.get().inputs.files.files.map {
            it.relativeTo(repository).invariantSeparatorsPath
        }.sorted()
        val clean = head == null && requested != null || head != null &&
            git("status", "--porcelain", "--untracked-files=all", "--", *sourcePaths.toTypedArray()) == ""
        val packaged = if (clean && revision != null) revision else "source_identity_unavailable"
        destination.get().asFile.apply { parentFile.mkdirs(); writeText("$packaged\n") }
    }
}
tasks.named("processResources") { dependsOn(scoringSourceRevision) }

tasks.register<JavaExec>("algorithmManifests") {
    dependsOn("classes")
    classpath=sourceSets["main"].runtimeClasspath
    mainClass.set("com.frwhoop.scoring.scoring.ProductionAlgorithmManifest")
}

tasks.named<JavaExec>("run") {
    dependsOn(":analytics-kernel:compileKotlin")
}

tasks.register<JavaExec>("replayDay") {
    group = "application"
    description = "Score one user/day from Postgres (Phase 3 replay gate)."
    classpath = sourceSets["main"].runtimeClasspath
    mainClass.set("com.frwhoop.scoring.ScoringApplicationKt")
    args("--replay-day")
    dependsOn(":analytics-kernel:compileKotlin")
}
