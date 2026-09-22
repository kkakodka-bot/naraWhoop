package com.noop.push

import org.json.JSONArray
import org.json.JSONObject

/** A receiver may only narrow the fixed protocol registry, never name new data. */
data class PushCapabilities(
    val appendTables: Set<PushAppendTable>,
    val mutableTables: Set<PushMutableTable>,
    val binaryTables: Set<PushBinaryTable> = emptySet(),
    val protocolVersion: String = PushProtocol.VERSION,
    val receiverStateId: String = UNSCOPED_RECEIVER_STATE_ID,
    val objectLane: PushObjectLane? = null,
) {
    val isEmpty: Boolean get() = appendTables.isEmpty() && mutableTables.isEmpty() && binaryTables.isEmpty()
    val wireNames: List<String> get() =
        PushAppendTable.entries.filter { it in appendTables }.map { it.wireName } +
            PushMutableTable.entries.filter { it in mutableTables }.map { it.wireName } +
            PushBinaryTable.entries.filter { it in binaryTables }.map { it.wireName }

    companion object {
        /** Test/local default. Network capability documents must always provide a real receiver state id. */
        const val UNSCOPED_RECEIVER_STATE_ID = "00000000-0000-4000-8000-000000000000"
        val ALL = PushCapabilities(
            PushAppendTable.entries.toSet(),
            PushMutableTable.entries.toSet(),
            PushBinaryTable.entries.toSet(),
        )

        fun parse(bytes: ByteArray): PushCapabilities {
            if (bytes.size > PushProtocol.MAX_ACK_BYTES) {
                throw PushProtocolException("capabilities exceed size limit")
            }
            val obj = try {
                JSONObject(bytes.toString(Charsets.UTF_8))
            } catch (_: Throwable) {
                throw PushProtocolException("capabilities are not valid JSON")
            }
            val required = setOf("type", "protocolVersion", "receiverStateId", "streams")
            val actualMembers = obj.keys().asSequence().toSet()
            if (!actualMembers.containsAll(required)) {
                throw PushProtocolException("capabilities are missing required protocol 1.0 members")
            }
            if (actualMembers.any { it in PushProtocol.FORBIDDEN_REMOTE_CONTROL_MEMBERS }) {
                throw PushProtocolException("capabilities contain forbidden remote-control metadata")
            }
            val version = obj.opt("protocolVersion") as? String ?: ""
            if (obj.opt("type") != "capabilities" ||
                version !in setOf(PushProtocol.VERSION, "1.1", PushProtocol.OBJECT_VERSION, "1.3", "1.4")
            ) {
                throw PushProtocolException("unsupported capability document")
            }
            val receiverStateId = (obj.opt("receiverStateId") as? String)?.takeIf(::isCanonicalUuid)
                ?: throw PushProtocolException("capabilities.receiverStateId must be a canonical UUID")
            val array = obj.opt("streams") as? JSONArray
                ?: throw PushProtocolException("capabilities.streams must be an array")
            val appendByName = PushAppendTable.entries.associateBy { it.wireName }
            val mutableByName = PushMutableTable.entries.associateBy { it.wireName }
            val binaryByName = PushBinaryTable.entries.associateBy { it.wireName }
            val seen = mutableSetOf<String>()
            val append = linkedSetOf<PushAppendTable>()
            val mutable = linkedSetOf<PushMutableTable>()
            val binary = linkedSetOf<PushBinaryTable>()
            for (index in 0 until array.length()) {
                val name = array.opt(index) as? String
                    ?: throw PushProtocolException("capability stream names must be strings")
                if (!seen.add(name)) throw PushProtocolException("duplicate capability stream")
                appendByName[name]?.let { if (!it.isScalarExtension || version != PushProtocol.VERSION) append += it }
                    ?: mutableByName[name]?.let { mutable += it }
                    ?: binaryByName[name]?.let { binary += it }
            }
            val objectLane = if (version in setOf(PushProtocol.OBJECT_VERSION, "1.3", "1.4") && obj.opt("objectLane") is JSONObject) {
                parseObjectLane(obj.getJSONObject("objectLane"), binaryByName)
            } else {
                null
            }
            return PushCapabilities(append, mutable, binary, version, receiverStateId, objectLane)
        }

        private fun parseObjectLane(
            obj: JSONObject,
            binaryByName: Map<String, PushBinaryTable>,
        ): PushObjectLane? {
            val endpoint = obj.opt("endpoint") as? String ?: return null
            if (endpoint.length > 256 || !endpoint.startsWith("/") || endpoint.startsWith("//") ||
                endpoint.contains(Regex("\\s"))
            ) {
                return null
            }
            val maxObjectBytes = jsonInt64(obj.opt("maxObjectBytes")) ?: return null
            if (maxObjectBytes <= 0L || maxObjectBytes > PushProtocol.MAX_OBJECT_WIRE_BYTES) return null
            val urlTtlSec = when (val ttl = jsonInt64(obj.opt("urlTtlSec"))) {
                null -> null
                else -> if (ttl > 0L) ttl else return null
            }
            val streamItems = obj.opt("streams") as? JSONArray ?: return null
            val laneStreams = linkedSetOf<PushBinaryTable>()
            for (index in 0 until streamItems.length()) {
                val name = streamItems.opt(index) as? String ?: return null
                val table = binaryByName[name] ?: continue
                if (!laneStreams.add(table)) return null
            }
            if (laneStreams.isEmpty()) return null
            return PushObjectLane(endpoint, maxObjectBytes, urlTtlSec, laneStreams)
        }

        private fun jsonInt64(value: Any?): Long? {
            if (value == null || value == JSONObject.NULL || value is Boolean) return null
            val number = value as? Number ?: return null
            val double = number.toDouble()
            if (double != double.toLong().toDouble()) return null
            return number.toLong()
        }

        private fun isCanonicalUuid(value: String): Boolean = runCatching {
            java.util.UUID.fromString(value).toString() == value
        }.getOrDefault(false)
    }
}

internal class PushConnectionTester(
    private val transportFactory: (PushEndpointPolicy.ValidEndpoint, String) -> PushTransport =
        { endpoint, token -> PushHttpTransport(endpoint, token) },
) {
    suspend fun test(
        endpoint: PushEndpointPolicy.ValidEndpoint,
        token: String,
    ): PushCapabilitiesResult = try {
        transportFactory(endpoint, token).capabilities()
    } catch (cancelled: kotlinx.coroutines.CancellationException) {
        throw cancelled
    } catch (_: Throwable) {
        val failure = PushFailure(PushFailureCode.NETWORK_IO)
        PushCapabilitiesResult.Rejected(failure.safeCode, failure.retryable, failure)
    }
}

internal fun canStartPushConnectionTest(
    networkAvailable: Boolean,
    endpointValid: Boolean,
    tokenAvailable: Boolean,
): Boolean = networkAvailable && endpointValid && tokenAvailable

sealed interface PushCapabilitiesResult {
    data class Available(val capabilities: PushCapabilities) : PushCapabilitiesResult
    data class Rejected(
        val reason: String,
        val retryable: Boolean,
        val failure: PushFailure? = null,
    ) : PushCapabilitiesResult
}
