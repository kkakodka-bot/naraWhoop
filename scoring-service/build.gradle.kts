// FRWHOOP server scoring service — plain JVM Gradle build.
//
// Two modules:
//   :analytics-kernel — the scoped Kotlin analytics twin, extracted from the Android app
//                       (android/app/src/main/java/com/noop/analytics/) as BYTE-VERBATIM synced
//                       sources plus a hand-written plain DTO layer (Room annotations dropped).
//                       No Android plugin, no Android SDK, no Room — runs on a bare JDK 17.
//   :service          — the score-on-arrival poller/writer (JDBC + PostgREST RPC).
//
// This build is deliberately NOT entangled with android/'s build: it has its own wrapper and
// never applies an Android plugin, so `docker build` needs nothing but a JDK 17 image.

plugins {
    // Kotlin plugin version is declared once here and applied per-module.
    kotlin("jvm") version "2.1.0" apply false
}

allprojects {
    group = "com.frwhoop"
    version = "0.1.0"
}
