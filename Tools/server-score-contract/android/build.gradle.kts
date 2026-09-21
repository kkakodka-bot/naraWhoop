plugins {
    kotlin("jvm") version "2.1.0"
    application
}
repositories { mavenCentral() }
kotlin { jvmToolchain(17) }
dependencies {
    implementation("org.json:json:20240303")
    testImplementation("junit:junit:4.13.2")
}
sourceSets {
    main {
        kotlin.srcDir("../../../android/app/src/main/java")
        kotlin.include("DecodeContract.kt", "com/noop/push/ServerScoreCacheCodec.kt", "com/noop/push/ServerScoreModels.kt",
            "com/noop/push/ServerVitalSelection.kt", "com/noop/push/ServerHrvSeries.kt", "com/noop/push/ServerRespirationSummary.kt")
    }
    test {
        kotlin.srcDir("../../../android/app/src/test/java")
        kotlin.include("com/noop/push/ServerScoreCacheCodecTest.kt")
    }
}
application { mainClass.set("DecodeContractKt") }
tasks.test { useJUnit() }
