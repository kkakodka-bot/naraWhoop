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
