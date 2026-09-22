package com.noop.data

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import androidx.sqlite.db.SupportSQLiteDatabase

/** Index only. The immutable capture file remains the authority when this transaction is absent. */
@Entity(tableName = "localCaptureResource")
data class LocalCaptureResource(
    @PrimaryKey val captureId: String,
    val projectURL: String,
    val userID: String,
    val sourceID: String,
    val generation: String,
    val deviceID: String,
    val serverDeviceID: String,
    val producerID: String,
    val format: String,
    val formatVersion: Int,
    val relativePath: String,
    val fileSha256: String,
    val fileBytes: Long,
    val payloadBytes: Long,
    val recordCount: Int,
    val memberCount: Int,
)

@Entity(
    tableName = "localCaptureMember",
    primaryKeys = ["captureId", "recordOrdinal", "routeOrdinal"],
    foreignKeys = [ForeignKey(entity = LocalCaptureResource::class, parentColumns = ["captureId"],
        childColumns = ["captureId"], onDelete = ForeignKey.NO_ACTION)],
    indices = [Index(value = ["projectionState", "captureId"], name = "localCaptureMember_projection")],
)
data class LocalCaptureMember(
    val captureId: String,
    val recordOrdinal: Int,
    val routeOrdinal: Int,
    val encounterOrdinal: Long,
    val receivedAtMs: Long,
    val namespace: String,
    val sessionID: String,
    val bucket: Long?,
    val payloadOffset: Long,
    val payloadBytes: Int,
    val payloadSha256: String,
    val projectionState: Int = 0,
)

/** Root registers these additive statements with Room43; this file does not open or migrate a DB. */
object LocalCaptureSchema {
    val statements: List<String> = listOf(
        """CREATE TABLE IF NOT EXISTS `localCaptureResource` (
            `captureId` TEXT NOT NULL PRIMARY KEY, `projectURL` TEXT NOT NULL, `userID` TEXT NOT NULL,
            `sourceID` TEXT NOT NULL, `generation` TEXT NOT NULL, `deviceID` TEXT NOT NULL,
            `serverDeviceID` TEXT NOT NULL, `producerID` TEXT NOT NULL, `format` TEXT NOT NULL,
            `formatVersion` INTEGER NOT NULL, `relativePath` TEXT NOT NULL, `fileSha256` TEXT NOT NULL,
            `fileBytes` INTEGER NOT NULL, `payloadBytes` INTEGER NOT NULL,
            `recordCount` INTEGER NOT NULL, `memberCount` INTEGER NOT NULL)""".trimIndent(),
        """CREATE TABLE IF NOT EXISTS `localCaptureMember` (
            `captureId` TEXT NOT NULL, `recordOrdinal` INTEGER NOT NULL, `routeOrdinal` INTEGER NOT NULL,
            `encounterOrdinal` INTEGER NOT NULL, `receivedAtMs` INTEGER NOT NULL,
            `namespace` TEXT NOT NULL, `sessionID` TEXT NOT NULL, `bucket` INTEGER,
            `payloadOffset` INTEGER NOT NULL, `payloadBytes` INTEGER NOT NULL,
            `payloadSha256` TEXT NOT NULL, `projectionState` INTEGER NOT NULL,
            PRIMARY KEY (`captureId`, `recordOrdinal`, `routeOrdinal`),
            FOREIGN KEY (`captureId`) REFERENCES `localCaptureResource` (`captureId`)
                ON UPDATE NO ACTION ON DELETE NO ACTION)""".trimIndent(),
        "CREATE INDEX IF NOT EXISTS `localCaptureMember_projection` ON `localCaptureMember` (`projectionState`, `captureId`)",
    )

    fun create(db: SupportSQLiteDatabase) = statements.forEach(db::execSQL)
}
