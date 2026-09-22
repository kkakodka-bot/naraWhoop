package com.noop.data

/**
 * Plain-JVM twin of the enum declared in
 * `android/app/src/main/java/com/noop/data/PairedDevice.kt` (line 77). Verbatim — the constants'
 * names and order are the wire/storage contract. Extracted (not synced) because `PairedDevice.kt`
 * is a Room entity file; the enum itself is pure.
 */
enum class SourceKind { liveBLE, historyBLE, cloudImport, fileImport, ftms, huami, oura, activityFile }
