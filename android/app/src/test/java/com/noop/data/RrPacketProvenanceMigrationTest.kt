package com.noop.data

import java.sql.DriverManager
import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RrPacketProvenanceMigrationTest {
    @Test fun deviceRekeyPreservesReceiptBytesAndDeletionIsOwnerScoped() = runBlocking {
        DriverManager.getConnection("jdbc:sqlite::memory:").use { db -> db.createStatement().use { sql ->
            WhoopDatabase.RR_PACKET_PROVENANCE_MIGRATION_SQL.forEach(sql::execute)
            val p = com.noop.protocol.RrPacketProvenance.checked(com.noop.protocol.RrPacketProvenance.bytes(
                "aa011800010022e12f12000000000000f153650000003c0200040002700d85e7")!!)!!
            for (owner in listOf("from", "other")) sql.execute("INSERT INTO rrPacketProvenance VALUES('$owner','${p.packetId}',${p.ts},${p.sensorTs},${p.recordIndex},'${p.rawHex}',5,1,'${p.decoderVersion}','${p.clockVersion}',1,0,2)")
            val devices = mutableMapOf("from" to PairedDeviceRow("from","WHOOP","5.0 MG",null,
                sourceKind="liveBLE",capabilities="hr,hrv",status="active",addedAt=1,lastSeenAt=1))
            fun mutate(query: String, vararg args: String) = db.prepareStatement(query).use { stmt ->
                args.forEachIndexed { i, value -> stmt.setString(i+1,value) }; stmt.executeUpdate(); Unit
            }
            val dao = Proxy.newProxyInstance(DeviceRegistryDao::class.java.classLoader,arrayOf(DeviceRegistryDao::class.java)) { _, method, arguments ->
                val args = arguments!!
                when (method.name) {
                    "pairedDevice" -> devices[args[0] as String]
                    "upsertPairedDevice" -> { val row=args[0] as PairedDeviceRow; devices[row.id]=row; Unit }
                    "deletePairedDeviceRow" -> { devices.remove(args[0] as String); Unit }
                    "reKeyRrPackets" -> mutate("UPDATE OR IGNORE rrPacketProvenance SET deviceId=? WHERE deviceId=?", args[1] as String,args[0] as String)
                    "deleteRrPacketsFor" -> mutate("DELETE FROM rrPacketProvenance WHERE deviceId=?",args[0] as String)
                    else -> if (method.name.startsWith("reKey") || method.name.startsWith("delete")) Unit else error(method.name)
                }
            } as DeviceRegistryDao
            val registry = DeviceRegistry(dao,object : DeviceRegistry.Transactor {
                override suspend fun <R> run(block: suspend () -> R): R = block()
            })
            fun receipts(owner: String): List<Pair<String,String>> = db.prepareStatement("SELECT packetId,rawHex FROM rrPacketProvenance WHERE deviceId=?").use { stmt ->
                stmt.setString(1,owner); stmt.executeQuery().use { rows -> buildList { while(rows.next()) add(rows.getString(1) to rows.getString(2)) } }
            }
            assertTrue(registry.adoptSerialIdentity("from","serial"))
            assertTrue(receipts("from").isEmpty()); assertEquals(listOf(p.packetId to p.rawHex),receipts("serial"))
            registry.deleteDeviceData("serial")
            assertTrue(receipts("serial").isEmpty()); assertEquals(listOf(p.packetId to p.rawHex),receipts("other"))
        } }
    }

    @Test fun additiveCompanionNeverManufacturesLegacyIdentity() {
        DriverManager.getConnection("jdbc:sqlite::memory:").use { db -> db.createStatement().use { sql ->
            sql.execute("CREATE TABLE rrInterval(deviceId TEXT,ts INTEGER,rrMs INTEGER)")
            sql.execute("INSERT INTO rrInterval VALUES('d',1700000000,1000)")
            WhoopDatabase.RR_PACKET_PROVENANCE_MIGRATION_SQL.forEach(sql::execute)
            sql.executeQuery("SELECT count(*) FROM rrInterval").use { it.next(); assertEquals(1,it.getInt(1)) }
            sql.executeQuery("SELECT count(*) FROM rrPacketProvenance").use { it.next(); assertEquals(0,it.getInt(1)) }
            val p = com.noop.protocol.RrPacketProvenance.checked(com.noop.protocol.RrPacketProvenance.bytes(
                "aa011a00010023592f12000000000000f153650000003c03000400000002c74eaa5b")!!)!!
            val insert = "INSERT OR IGNORE INTO rrPacketProvenance VALUES('d','${p.packetId}',${p.ts},${p.sensorTs},${p.recordIndex},'${p.rawHex}',5,1,'${p.decoderVersion}','${p.clockVersion}',1,0,3)"
            sql.execute(insert); sql.execute(insert)
            sql.executeQuery("SELECT count(*),rawHex FROM rrPacketProvenance").use {
                it.next(); assertEquals(1,it.getInt(1)); assertEquals(p.rawHex,it.getString(2))
            }
        } }
    }
}
