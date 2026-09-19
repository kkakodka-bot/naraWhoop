import java.security.MessageDigest

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
        fileTree(rootProject.file("analytics-kernel/src/main/kotlin")) { include("**/*.kt") },
        fileTree(projectDir.resolve("src/main/kotlin")) { include("**/*.kt") },
        projectDir.resolve("build.gradle.kts"),rootProject.file("analytics-kernel/build.gradle.kts"))
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
