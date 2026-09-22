package com.frwhoop.scoring.db

import com.frwhoop.scoring.scoring.UserDayBounds
import com.noop.analytics.UserProfile
import com.noop.data.EventRow
import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RespSample
import com.noop.data.RrInterval
import com.noop.data.StepSample
import com.noop.protocol.DeviceFamily
import java.sql.Connection
import java.util.UUID

/** Maps Postgres `noop_*` projection rows into the Kotlin twin's on-device entity shapes. */
class SignalSampleReader(private val db: PostgresClient) : ScoreInputProvider {
    private val rawCatalogue = com.frwhoop.scoring.signals.RawSignalCatalogue(db.dataSource,
        com.frwhoop.scoring.signals.VerifiedRawObjectReader(object : com.frwhoop.scoring.b2.B2ObjectStore.GetClient {
            override fun getObject(key: String, maximumBytes: Int): ByteArray = error("inventory_never_fetches_bytes")
        }))

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
        val deviceFirmware: String? = null,
        val rrSourcePolicyVersion: String = CanonicalRrPolicy.VERSION,
        val rrTimingPrecisionSeconds: Double = CanonicalRrPolicy.TIMESTAMP_PRECISION_SECONDS,
        val rrContinuityEvidence: String = "packet_identity_not_projected",
        val steps: List<StepSample> = emptyList(),
        val sleepContext: List<com.noop.analytics.SleepContextSpan> = emptyList(),
        val sleepOverrides: List<com.frwhoop.scoring.scoring.SleepBoundaryOverride> = emptyList(),
        val bandSleepState: List<Pair<Long,Int>> = emptyList(),
        val hrvObservations: List<com.noop.analytics.PhysiologyQuality.IntervalObservation>? = null,
        val hrvHistory: List<com.noop.analytics.HrvWindow.Result> = emptyList(),
        val calendarOwnership: CalendarOwnershipReader.Ownership? = null,
        val skinTemp: List<com.noop.data.SkinTempSample> = emptyList(),
        val baselines: com.noop.analytics.ProfileBaselines = com.noop.analytics.ProfileBaselines(),
        val acquisitionEvidence: SensorAcquisitionReader.Evidence = SensorAcquisitionReader.Evidence(emptyList()),
        val rawManifests: List<com.frwhoop.scoring.signals.VerifiedRawObjectReader.Manifest> = emptyList(),
        val temperatureSources: Map<Long,String> = emptyMap(),
    )

    override fun loadDay(userId: UUID, day: String, deviceId: UUID): DayInputs? =
        loadDayWithZone(userId, day, deviceId, null)

    override fun loadDay(userId: UUID, day: String, deviceId: UUID, timezoneId: String): DayInputs? =
        loadDayWithZone(userId, day, deviceId, timezoneId)

    private fun loadDayWithZone(userId: UUID, day: String, deviceId: UUID, timezoneId: String?): DayInputs? =
        db.withConnection { conn ->
            val deviceIdText = deviceId.toString()
            if (!deviceExistsForUser(conn, userId, deviceId)) return@withConnection null
            val profileRow = loadProfile(conn, userId, deviceId) ?: return@withConnection null
            val bounds = UserDayBounds.forDay(day, timezoneId?.let(UserDayBounds::parseZone) ?: profileRow.zoneId)
            val ownership = CalendarOwnershipReader.load(conn, userId, day)
            val dayLo = ownership.dayLo ?: bounds.dayLo
            val dayHi = ownership.dayHiInclusive ?: bounds.dayHi
            val nightLo = ownership.contextLo ?: bounds.nightLo
            val nightHi = ownership.contextHiInclusive ?: bounds.nightHi
            val available = ownership.unavailableReason == null
            fun inContext(timestamp: Long) = ownership.contextIntervals.any { timestamp >= it.first && timestamp < it.second }
            val rr = if (available) loadRr(conn, userId, deviceIdText, nightLo, nightHi, profileRow.deviceFamily,
                ownership.contextIntervals) else emptyList()
            val rrPackets = if (available) loadRrPackets(conn, userId, deviceIdText, nightLo, nightHi + 1)
                .filter { inContext(it.ts) } else emptyList()
            var observations = RrPacketObservationBridge.observations(rrPackets, rr, profileRow.deviceFamily,
                userId.toString(), deviceIdText, profileRow.deviceFirmware)
            var evidence = if(available) SensorAcquisitionReader.load(conn,userId,deviceId,nightLo,nightHi+1)
                else SensorAcquisitionReader.Evidence(emptyList())
            val packetSources = sourceIdentities(conn,userId,deviceId,"noop_rr_packet_provenance","packetId",nightLo,nightHi+1)
            val qualified = mutableListOf<com.noop.analytics.PhysiologyQuality.IntervalObservation>()
            for(receipt in evidence.receipts.filter { it.kind=="beat_timing" }) {
                try {
                    val proof = com.frwhoop.scoring.signals.SensorAcquisitionProof.verify(receipt,userId,deviceId)
                    qualified += com.frwhoop.scoring.signals.SensorAcquisitionProof.beats(proof,rrPackets,userId,deviceId,packetSources)
                } catch(e: Exception) {
                    evidence = evidence.copy(reason=com.frwhoop.scoring.signals.BoundedRawFeatureLane.safeReason(e))
                }
            }
            if(qualified.isNotEmpty()) {
                val ids=qualified.map { it.originalId }.toSet()
                observations=observations.orEmpty().filter { it.originalId !in ids } + qualified
            }

            DayInputs(
                userId = userId,
                day = day,
                deviceId = deviceIdText,
                tzOffsetSeconds = bounds.tzOffsetSeconds,
                dayLo = dayLo,
                dayHi = dayHi,
                profile = profileRow.profile,
                nightLo = nightLo,
                nightHi = nightHi,
                hr = if (available) loadHr(conn, userId, deviceIdText, nightLo, nightHi).filter { inContext(it.ts) } else emptyList(),
                rr = rr,
                resp = if (available) loadResp(conn, userId, deviceIdText, nightLo, nightHi).filter { inContext(it.ts) } else emptyList(),
                gravity = if (available) loadGravity(conn, userId, deviceIdText, nightLo, nightHi).filter { inContext(it.ts) } else emptyList(),
                events = if (available) loadEvents(conn, userId, deviceIdText, nightLo, nightHi) else emptyList(),
                deviceFamily = profileRow.deviceFamily,
                deviceFirmware = profileRow.deviceFirmware,
                rrContinuityEvidence = when {
                    qualified.any { it.verifiedSpan != null } -> "capture_evidence_bound_original_words"
                    observations != null -> "verified_packet_local_original_words_no_beat_clock"
                    else -> "packet_identity_not_projected"
                },
                hrvObservations = observations,
                steps = if (available) loadSteps(conn, userId, deviceIdText, nightLo, nightHi).filter { inContext(it.ts) } else emptyList(),
                sleepContext = if (available) SleepContextReader.annotations(conn,userId,deviceId,nightLo,nightHi).flatMap { span ->
                    ownership.contextIntervals.mapNotNull { interval ->
                        val start = maxOf(span.start, interval.first); val end = minOf(span.end, interval.second)
                        if (start < end) span.copy(start = start, end = end) else null
                    }
                } else emptyList(),
                sleepOverrides = if (available) SleepContextReader.overrides(conn,userId,deviceId,nightLo,nightHi) else emptyList(),
                bandSleepState = if (available) SleepContextReader.bandState(conn,userId,deviceId,nightLo,nightHi)
                    .filter { inContext(it.first) } else emptyList(),
                hrvHistory = if (available) loadHrvHistory(conn,userId,deviceId,dayLo,nightLo) else emptyList(),
                calendarOwnership = ownership,
                skinTemp = if (available) loadSkinTemp(conn, userId, deviceIdText, nightLo, nightHi)
                    .filter { inContext(it.ts) } else emptyList(),
                baselines = if (available) CanonicalBaselineReader.load(conn, userId, deviceId, day)
                    else com.noop.analytics.ProfileBaselines(),
                acquisitionEvidence=evidence,
                rawManifests=rawCatalogue.discover(userId,deviceId,nightLo,nightHi+1,SensorAcquisitionReader.objectIds(evidence)),
                temperatureSources=sourceIdentities(conn,userId,deviceId,"noop_skin_temp_samples","ts",nightLo,nightHi+1).mapKeys { it.key.toLong() },
            )
        }

    private fun sourceIdentities(conn: Connection,user: UUID,device: UUID,table: String,key: String,start: Long,end: Long): Map<String,String> {
        require(table in setOf("noop_rr_packet_provenance","noop_skin_temp_samples") && key in setOf("packetId","ts"))
        return conn.prepareStatement("select \"$key\",source_id from public.$table where user_id=? and device_id=? and ts>=? and ts<?").use { q ->
            q.setObject(1,user); q.setObject(2,device); q.setLong(3,start); q.setLong(4,end)
            q.executeQuery().use { rows -> buildMap { while(rows.next()) rows.getString(2)?.let { put(rows.getString(1),it) } } }
        }
    }

    private fun loadRrPackets(conn: Connection, user: UUID, device: String, from: Long, to: Long): List<com.noop.protocol.RrPacketProvenance> =
        conn.prepareStatement("""
            select * from public.noop_rr_packet_provenance
            where user_id=? and device_id=?::uuid and ts>=? and ts<? order by ts,"recordIndex","packetId"
        """.trimIndent()).use { stmt ->
            stmt.setObject(1, user); stmt.setString(2, device); stmt.setLong(3, from); stmt.setLong(4, to)
            stmt.executeQuery().use { rs -> buildList {
                while (rs.next()) {
                    val packet = com.noop.protocol.RrPacketProvenance(rs.getString("packetId"), rs.getLong("ts"),
                        rs.getLong("sensorTs"), rs.getLong("recordIndex"), rs.getString("rawHex"), rs.getInt("srcChannel"),
                        rs.getInt("schemaVersion"), rs.getString("decoderVersion"), rs.getString("clockVersion"),
                        rs.getDouble("timestampPrecisionSeconds"), rs.getLong("clockOffsetSeconds"), rs.getInt("declaredCount"))
                    RrPacketObservationBridge.verified(packet)?.let(::add)
                }
            } }
        }

    private fun loadHrvHistory(conn: Connection,user: UUID,device: UUID,before: Long,contextStart:Long): List<com.noop.analytics.HrvWindow.Result> =
        conn.prepareStatement("""
            with latest_days as (
              select distinct on(r.period_day) r.* from public.server_physiology_results r
              join public.physiology_work_items q on q.user_id=r.user_id and q.device_id=r.device_id and q.day=r.period_day
              where r.user_id=? and r.device_id=? and r.algorithm_version=? and r.measurement_revision=q.measurement_revision
                and r.period_day between to_timestamp(?)::date-1 and to_timestamp(?)::date+1
              order by r.period_day,r.input_revision desc
            ), windows as (
              select distinct on(m->>'window_id') m from latest_days r
              cross join lateral jsonb_array_elements(r.payload->'measurements') m
              where m->>'feature'='hrv'
              order by m->>'window_id',r.computed_at desc,r.input_revision desc
            ) select m::text from windows
              where m->>'measurement_valid'='true' and m->>'baseline_eligible'='true'
                and (m->>'end')::bigint<=? and (m->>'start')::bigint>=? limit 10000
        """.trimIndent()).use { p ->
            p.setObject(1,user);p.setObject(2,device)
            p.setString(3,com.frwhoop.scoring.scoring.CanonicalScorePayload.ALGORITHM_VERSION)
            // Each prior-night window has its own past-only 28-day history, not the day's midnight.
            p.setLong(4,contextStart-28*86400L);p.setLong(5,before)
            p.setLong(6,before);p.setLong(7,contextStart-28*86400L)
            p.executeQuery().use { r -> buildList { while(r.next()) {
                // Incompatible older schemas do not enter a new baseline. Their immutable snapshot
                // remains readable for rollback; malformed measurements never become zero.
                val window=runCatching { com.frwhoop.scoring.scoring.HrvPayloadCodec.decode(org.json.JSONObject(r.getString(1))) }.getOrNull()
                if(window?.userId==user.toString() && window.deviceId==device.toString()) add(window)
            } } }
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

    private data class ProfileRow(
        val profile: UserProfile,
        val zoneId: java.time.ZoneId,
        val deviceFamily: DeviceFamily,
        val deviceFirmware: String? = null,
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

    private fun loadProfile(conn: Connection, userId: UUID, deviceId: UUID): ProfileRow? {
        conn.prepareStatement(
            """
            select
              coalesce(p.reported_age_years, 30)::double precision as age,
              coalesce(p.sex_model, 'nonbinary') as sex,
              coalesce(p.weight_kg, 70)::double precision as weight_kg,
              coalesce(p.height_cm, 170)::double precision as height_cm,
              coalesce(p.timezone, 'UTC') as timezone_name,
              coalesce(d.device_family, 'whoop5') as device_family,
              d.firmware as device_firmware
            from public.devices d
            left join public.profiles p on p.id = d.user_id
            where d.id = ? and d.user_id = ?
            """.trimIndent(),
        ).use { ps ->
            ps.setObject(1, deviceId)
            ps.setObject(2, userId)
            ps.executeQuery().use { rs ->
                if (!rs.next()) return null
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
                    deviceFirmware = rs.getString("device_firmware"),
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

    fun loadRr(
        conn: Connection,
        userId: UUID,
        deviceId: String,
        fromTs: Long,
        toTs: Long,
        family: DeviceFamily = DeviceFamily.WHOOP5,
        contextIntervals: List<Pair<Long, Long>>? = null,
    ): List<RrInterval> = conn.prepareStatement(
        """
        select ts, "rrMs", seq, ord, "srcChannel", "tsSuspect"
        from public.noop_rr_intervals
        where user_id = ? and device_id::text = ? and ts between ? and ?
        order by ts asc, ord asc nulls first, "rrMs" asc, seq asc
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
    }.let { rows -> CanonicalRrPolicy.candidates(rows.filter { row -> contextIntervals == null ||
        contextIntervals.any { row.ts >= it.first && row.ts < it.second } }, family) }

    private fun loadSteps(conn: Connection, userId: UUID, deviceId: String,
                          fromTs: Long, toTs: Long): List<StepSample> = conn.prepareStatement(
        """
        select ts, counter, "activityClass" from public.noop_step_samples
        where user_id = ? and device_id::text = ? and ts between ? and ? order by ts
        """.trimIndent(),
    ).use { ps ->
        ps.setObject(1, userId)
        ps.setString(2, deviceId)
        ps.setLong(3, fromTs)
        ps.setLong(4, toTs)
        ps.executeQuery().use { rs ->
            buildList {
                while (rs.next()) add(StepSample(deviceId = deviceId, ts = rs.getLong("ts"),
                    counter = rs.getInt("counter"), activityClass = rs.getObject("activityClass") as? Int))
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
        select ts, x, y, z,
          case when motion_evidence_version='projected-dynamic-acceleration-g-1' then "dynAccel" else null end as "dynAccel"
        from public.noop_gravity_samples
        where user_id = ? and device_id::text = ? and ts between ? and ?
          and orientation_evidence_version='projected-gravity-g-1'
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
                            dynAccel = (rs.getObject("dynAccel") as? Number)?.toDouble(),
                        ),
                    )
                }
            }
        }
    }

    private fun loadSkinTemp(
        conn: Connection,
        userId: UUID,
        deviceId: String,
        fromTs: Long,
        toTs: Long,
    ): List<com.noop.data.SkinTempSample> = conn.prepareStatement(
        """
        select ts, raw, "aux1Raw", "aux2Raw"
        from public.noop_skin_temp_samples
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
                        com.noop.data.SkinTempSample(
                            deviceId = deviceId,
                            ts = rs.getLong("ts"),
                            raw = rs.getInt("raw"),
                            aux1Raw = (rs.getObject("aux1Raw") as? Number)?.toInt(),
                            aux2Raw = (rs.getObject("aux2Raw") as? Number)?.toInt(),
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
        with scope as (select ?::uuid as owner,?::uuid as device,?::bigint as lo,?::bigint as hi),
        prior as (
          select max(e.ts) as ts from public.noop_events e,scope s
          where e.user_id=s.owner and e.device_id=s.device and e.ts<s.lo
            and (left(e.kind,9)='WRIST_OFF' or left(e.kind,8)='WRIST_ON')
        )
        select e.ts,e.kind,e."payloadJSON" from public.noop_events e,scope s
        where e.user_id=s.owner and e.device_id=s.device and (e.ts between s.lo and s.hi or
          (e.ts=(select ts from prior) and (left(e.kind,9)='WRIST_OFF' or left(e.kind,8)='WRIST_ON')))
        -- A conflicting same-second ON/OFF cannot assert wear; process OFF last conservatively.
        order by e.ts asc,e.kind desc
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
