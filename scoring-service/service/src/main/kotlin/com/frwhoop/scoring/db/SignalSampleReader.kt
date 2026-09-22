package com.frwhoop.scoring.db

import com.frwhoop.scoring.scoring.UserDayBounds
import com.noop.analytics.UserProfile
import com.noop.data.EventRow
import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RespSample
import com.noop.data.RrInterval
import com.noop.data.StepSample
import com.noop.data.SkinTempSample
import com.noop.data.Spo2Sample
import com.noop.protocol.DeviceFamily
import java.sql.Connection
import java.util.UUID

/** Maps Postgres `noop_*` projection rows into the Kotlin twin's on-device entity shapes. */
class SignalSampleReader(private val db: PostgresClient,
                         private val auxiliaryObjects: AuxiliaryObjectReader = AuxiliaryObjectReader(null)) : ScoreInputProvider {

    data class DayInputs(
        val userId: UUID,
        val day: String,
        val deviceId: String,
        val tzOffsetSeconds: Long,
        val dayLo: Long,
        val dayHi: Long,
        val profile: UserProfile,
        val nightLo: Long,
        val nightHi: Long,
        val hr: List<HrSample>,
        val rr: List<RrInterval>,
        val resp: List<RespSample>,
        val gravity: List<GravitySample>,
        val events: List<EventRow>,
        val deviceFamily: DeviceFamily,
        val timezone: String = "UTC",
        val history: HistoryInputReader.Day = HistoryInputReader.Day(),
        val steps: List<StepSample> = emptyList(),
        val skinTemp: List<SkinTempSample> = emptyList(),
        val spo2: List<Spo2Sample> = emptyList(),
        val bandSleepState: List<Pair<Long,Int>> = emptyList(),
        val v18Aux: List<com.noop.data.V18AuxRow> = emptyList(),
        val auxiliaryGaps: Set<String> = emptySet(),
        val externalDeviceId: String = deviceId,
        val skinTempAnchorRaw: Double? = null,
        val legacyWorkouts: List<LegacyWorkoutReader.Workout> = emptyList(),
        val scalarInputs: ScalarInputReader.Result? = null,
    ) {
        val isOura get()=com.noop.data.DeviceBrandCatalog.isOura(externalDeviceId)
        val scoringResp get()=if(isOura) emptyList() else resp
        val vendorResp get()=if(isOura) resp else emptyList()
    }

    override fun loadDay(userId: UUID, day: String, deviceId: UUID): DayInputs? = loadDay(userId,day,deviceId,false)
    override fun loadHistoricalDay(userId: UUID, day: String, deviceId: UUID): DayInputs? = loadDay(userId,day,deviceId,true)
    private fun loadDay(userId: UUID, day: String, deviceId: UUID, historical: Boolean): DayInputs? =
        db.withConnection { conn ->
            conn.transactionIsolation = Connection.TRANSACTION_REPEATABLE_READ
            conn.autoCommit = false
            try {
            val deviceIdText = deviceId.toString()
            if (!deviceExistsForUser(conn, userId, deviceId)) return@withConnection null
            val history = HistoryInputReader.load(conn, userId, deviceId, day)
            val legacyProfile = loadProfile(conn, userId, deviceId)
            // Once a versioned profile journal exists, absence as-of D is UNKNOWN/default, not
            // permission to borrow the mutable current profile (which may describe the future).
            val profileRow = if (historical || history.profileJournalExists) legacyProfile.copy(
                profile=history.effectiveProfile(),zoneId=UserDayBounds.parseZone(history.timezone)) else legacyProfile
            val bounds = UserDayBounds.forDay(day, profileRow.zoneId)
            val scalars=ScalarInputReader.load(conn,userId,deviceId,bounds.nightLo,bounds.nightHi,historical)
            val auxiliary = if(history.configuration.optBoolean("spo2CandidateDisplayEnabled",false) &&
                !com.noop.data.DeviceBrandCatalog.isOura(profileRow.externalDeviceId))
                auxiliaryObjects.load(conn,userId,deviceId,bounds.nightLo,bounds.nightHi)
                else AuxiliaryObjectReader.Result(emptyList(),emptySet())

            DayInputs(
                userId = userId,
                day = day,
                deviceId = deviceIdText,
                tzOffsetSeconds = bounds.tzOffsetSeconds,
                dayLo = bounds.dayLo,
                dayHi = bounds.dayHi,
                profile = profileRow.profile,
                nightLo = bounds.nightLo,
                nightHi = bounds.nightHi,
                hr = loadHr(conn, userId, deviceIdText, bounds.nightLo, bounds.nightHi),
                rr = loadRr(conn, userId, deviceIdText, bounds.nightLo, bounds.nightHi),
                resp = loadResp(conn, userId, deviceIdText, bounds.nightLo, bounds.nightHi),
                gravity = loadGravity(conn, userId, deviceIdText, bounds.nightLo, bounds.nightHi),
                events = loadEvents(conn, userId, deviceIdText, bounds.nightLo, bounds.nightHi),
                deviceFamily = profileRow.deviceFamily,
                timezone = profileRow.zoneId.id,
                history = history,
                steps = scalars.steps,
                skinTemp = loadSkinTemp(conn,userId,deviceId,bounds.nightLo,bounds.nightHi),
                spo2 = loadSpo2(conn,userId,deviceId,bounds.nightLo,bounds.nightHi),
                bandSleepState = scalars.bandState,
                v18Aux = auxiliary.rows,
                auxiliaryGaps = auxiliary.gaps,
                externalDeviceId = profileRow.externalDeviceId,
                skinTempAnchorRaw = if(historical && profileRow.deviceFamily==DeviceFamily.WHOOP4)
                    loadSkinAnchor(conn,userId,deviceId,java.time.LocalDate.parse(day).minusDays(20).atStartOfDay(profileRow.zoneId).toEpochSecond()-30*3600,bounds.dayHi)
                    else null,
                legacyWorkouts = if(historical) LegacyWorkoutReader.load(conn,userId,deviceId,bounds.nightLo,bounds.dayHi) else emptyList(),
                scalarInputs = scalars,
            )
            } finally {
                conn.rollback()
                conn.autoCommit = true
                conn.transactionIsolation = Connection.TRANSACTION_READ_COMMITTED
            }
        }

    fun listDeviceIds(userId: UUID): List<UUID> =
        db.withConnection { conn ->
            conn.prepareStatement(
                """
                select id
                from public.devices
                where user_id = ?
                order by last_seen_at desc nulls last
                """.trimIndent(),
            ).use { ps ->
                ps.setObject(1, userId)
                ps.executeQuery().use { rs ->
                    buildList {
                        while (rs.next()) {
                            add(UUID.fromString(rs.getString("id")))
                        }
                    }
                }
            }
        }

    private fun <T> stream(c:Connection,query:String,owner:UUID,device:UUID,lo:Long,hi:Long,
                           decode:(java.sql.ResultSet)->T):List<T> = c.prepareStatement(query).use { s ->
        s.setObject(1,owner); s.setObject(2,device); s.setLong(3,lo); s.setLong(4,hi)
        s.executeQuery().use { r -> buildList { while(r.next()) add(decode(r)) } }
    }
    private fun loadSkinAnchor(c:Connection,u:UUID,d:UUID,lo:Long,hi:Long):Double? = c.prepareStatement("""
        select percentile_cont(0.5) within group(order by raw)::double precision
        from noop_skin_temp_samples where user_id=? and device_id=? and ts between ? and ? and raw between 550 and 2040
        having count(*)>=100
    """.trimIndent()).use { s ->
        s.setObject(1,u);s.setObject(2,d);s.setLong(3,lo);s.setLong(4,hi)
        s.executeQuery().use { r -> if(r.next()) r.getDouble(1) else null }
    }
    private fun loadSkinTemp(c:Connection,u:UUID,d:UUID,lo:Long,hi:Long) = stream(c,
        """select ts,raw,"aux1Raw","aux2Raw" from noop_skin_temp_samples where user_id=? and device_id=? and ts between ? and ? order by ts""",u,d,lo,hi) {
        SkinTempSample(d.toString(),it.getLong(1),it.getInt(2),aux1Raw=it.getInt(3).let { v -> if(it.wasNull()) null else v },
            aux2Raw=it.getInt(4).let { v -> if(it.wasNull()) null else v })
    }
    private fun loadSpo2(c:Connection,u:UUID,d:UUID,lo:Long,hi:Long) = stream(c,
        "select ts,red,ir from noop_spo2_samples where user_id=? and device_id=? and ts between ? and ? order by ts",u,d,lo,hi) {
        Spo2Sample(d.toString(),it.getLong(1),it.getInt(2),it.getInt(3))
    }

    private data class ProfileRow(
        val profile: UserProfile,
        val zoneId: java.time.ZoneId,
        val deviceFamily: DeviceFamily,
        val externalDeviceId: String,
    )

    private fun deviceExistsForUser(conn: Connection, userId: UUID, deviceId: UUID): Boolean =
        conn.prepareStatement(
            """
            select 1
            from public.devices
            where user_id = ? and id = ?
            """.trimIndent(),
        ).use { ps ->
            ps.setObject(1, userId)
            ps.setObject(2, deviceId)
            ps.executeQuery().use { rs -> rs.next() }
        }

    private fun loadProfile(conn: Connection, userId: UUID, deviceId: UUID): ProfileRow {
        conn.prepareStatement(
            """
            select
              coalesce(p.reported_age_years, 30)::double precision as age,
              coalesce(p.sex_model, 'nonbinary') as sex,
              coalesce(p.weight_kg, 70)::double precision as weight_kg,
              coalesce(p.height_cm, 170)::double precision as height_cm,
              coalesce(p.timezone, 'UTC') as timezone_name,
              coalesce(d.device_family, 'whoop5') as device_family,
              coalesce(d.external_device_id,d.id::text) as external_device_id
            from public.profiles p
            join public.devices d on d.user_id = p.id and d.id = ?
            where p.id = ?
            """.trimIndent(),
        ).use { ps ->
            ps.setObject(1, deviceId)
            ps.setObject(2, userId)
            ps.executeQuery().use { rs ->
                if (!rs.next()) {
                    return ProfileRow(UserProfile(), UserDayBounds.parseZone("UTC"), DeviceFamily.WHOOP5,deviceId.toString())
                }
                val zoneId = UserDayBounds.parseZone(rs.getString("timezone_name"))
                val family = when (rs.getString("device_family")?.lowercase()) {
                    "whoop4", "4.0", "whoop 4.0" -> DeviceFamily.WHOOP4
                    else -> DeviceFamily.WHOOP5
                }
                return ProfileRow(
                    profile = UserProfile(
                        age = rs.getDouble("age"),
                        sex = rs.getString("sex"),
                        weightKg = rs.getDouble("weight_kg"),
                        heightCm = rs.getDouble("height_cm"),
                    ),
                    zoneId = zoneId,
                    deviceFamily = family,
                    externalDeviceId = rs.getString("external_device_id"),
                )
            }
        }
    }

    private fun loadHr(
        conn: Connection,
        userId: UUID,
        deviceId: String,
        fromTs: Long,
        toTs: Long,
    ): List<HrSample> = conn.prepareStatement(
        """
        select ts, bpm
        from public.noop_hr_samples
        where user_id = ? and device_id::text = ? and ts between ? and ?
        order by ts asc
        """.trimIndent(),
    ).use { ps ->
        ps.setObject(1, userId)
        ps.setString(2, deviceId)
        ps.setLong(3, fromTs)
        ps.setLong(4, toTs)
        ps.executeQuery().use { rs ->
            buildList {
                while (rs.next()) {
                    add(HrSample(deviceId = deviceId, ts = rs.getLong("ts"), bpm = rs.getInt("bpm")))
                }
            }
        }
    }

    // Unknown-family evidence is window-local: a future modern beat must not change an already
    // settled historical train. Explicit family changes still use the device invalidation trigger.
    fun loadRr(
        conn: Connection,
        userId: UUID,
        deviceId: String,
        fromTs: Long,
        toTs: Long,
    ): List<RrInterval> = conn.prepareStatement(
        """
        with rr_window as materialized (
          select device_id, ts, "rrMs", seq, ord, "srcChannel", "tsSuspect"
          from public.noop_rr_intervals
          where user_id = ? and device_id::text = ? and ts between ? and ?
            and ("tsSuspect" is null or "tsSuspect" <> 1)
            and ("srcChannel" is null or "srcChannel" <> 2)
        ), rr_policy as materialized (
          select coalesce(bool_or("srcChannel" in (5,6,7)), false) as has_modern,
                 min("srcChannel") filter (where "srcChannel" in (5,7)) as canonical
          from rr_window
        ), decision as materialized (
          select p.canonical,
                 exists(select 1 from public.devices d
                   where d.id=(select w.device_id from rr_window w limit 1)
                     and (lower(coalesce(d.device_family,'')) in
                            ('whoop5','whoop5_mg','whoopmg','whoop 5.0','5.0','mg')
                       or (d.device_family is null and p.has_modern))) as canonical_only
          from rr_policy p
        )
        select r.ts, r."rrMs", r.seq, r.ord, r."srcChannel", r."tsSuspect"
        from rr_window r cross join decision p
        where not p.canonical_only or r."srcChannel"=p.canonical
        order by r.ts asc, r.ord asc nulls first, r."rrMs" asc, r.seq asc
        """.trimIndent(),
    ).use { ps ->
        ps.setObject(1, userId)
        ps.setString(2, deviceId)
        ps.setLong(3, fromTs)
        ps.setLong(4, toTs)
        ps.executeQuery().use { rs ->
            buildList {
                while (rs.next()) {
                    add(
                        RrInterval(
                            deviceId = deviceId,
                            ts = rs.getLong("ts"),
                            rrMs = rs.getInt("rrMs"),
                            seq = rs.getInt("seq"),
                            ord = rs.getObject("ord") as? Int,
                            srcChannel = rs.getObject("srcChannel") as? Int,
                            tsSuspect = rs.getObject("tsSuspect") as? Int,
                        ),
                    )
                }
            }
        }
    }

    private fun loadResp(
        conn: Connection,
        userId: UUID,
        deviceId: String,
        fromTs: Long,
        toTs: Long,
    ): List<RespSample> = conn.prepareStatement(
        """
        select ts, raw
        from public.noop_resp_samples
        where user_id = ? and device_id::text = ? and ts between ? and ?
        order by ts asc
        """.trimIndent(),
    ).use { ps ->
        ps.setObject(1, userId)
        ps.setString(2, deviceId)
        ps.setLong(3, fromTs)
        ps.setLong(4, toTs)
        ps.executeQuery().use { rs ->
            buildList {
                while (rs.next()) {
                    add(RespSample(deviceId = deviceId, ts = rs.getLong("ts"), raw = rs.getInt("raw")))
                }
            }
        }
    }

    private fun loadGravity(
        conn: Connection,
        userId: UUID,
        deviceId: String,
        fromTs: Long,
        toTs: Long,
    ): List<GravitySample> = conn.prepareStatement(
        """
        select ts, x, y, z
        from public.noop_gravity_samples
        where user_id = ? and device_id::text = ? and ts between ? and ?
        order by ts asc
        """.trimIndent(),
    ).use { ps ->
        ps.setObject(1, userId)
        ps.setString(2, deviceId)
        ps.setLong(3, fromTs)
        ps.setLong(4, toTs)
        ps.executeQuery().use { rs ->
            buildList {
                while (rs.next()) {
                    add(
                        GravitySample(
                            deviceId = deviceId,
                            ts = rs.getLong("ts"),
                            x = rs.getDouble("x"),
                            y = rs.getDouble("y"),
                            z = rs.getDouble("z"),
                        ),
                    )
                }
            }
        }
    }

    private fun loadEvents(
        conn: Connection,
        userId: UUID,
        deviceId: String,
        fromTs: Long,
        toTs: Long,
    ): List<EventRow> = conn.prepareStatement(
        """
        select ts, kind, "payloadJSON"
        from public.noop_events
        where user_id = ? and device_id::text = ? and ts between ? and ?
        order by ts asc
        """.trimIndent(),
    ).use { ps ->
        ps.setObject(1, userId)
        ps.setString(2, deviceId)
        ps.setLong(3, fromTs)
        ps.setLong(4, toTs)
        ps.executeQuery().use { rs ->
            buildList {
                while (rs.next()) {
                    add(
                        EventRow(
                            deviceId = deviceId,
                            ts = rs.getLong("ts"),
                            kind = rs.getString("kind"),
                            payloadJSON = rs.getString("payloadJSON"),
                        ),
                    )
                }
            }
        }
    }
}
