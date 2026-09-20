package com.noop.push

import org.json.JSONObject

object PushObjectIntentParser {
    fun parse(bytes: ByteArray, expectedObjectId: String): PushObjectIntent {
        if (bytes.size > PushProtocol.MAX_ACK_BYTES) {
            throw PushProtocolException("object intent exceeds size limit")
        }
        val obj = try {
            JSONObject(bytes.toString(Charsets.UTF_8))
        } catch (_: Throwable) {
            throw PushProtocolException("object intent is not valid JSON")
        }
        val required = setOf("type", "protocolVersion", "objectId", "objectKey", "duplicate")
        val actual = obj.keys().asSequence().toSet()
        if (!actual.containsAll(required)) {
            throw PushProtocolException("object intent is missing required protocol 1.2 members")
        }
        if (actual.any { it in PushProtocol.FORBIDDEN_REMOTE_CONTROL_MEMBERS }) {
            throw PushProtocolException("object intent contains forbidden remote-control metadata")
        }
        if (obj.opt("type") != "objectIntent" || obj.opt("protocolVersion") !in setOf(PushProtocol.OBJECT_VERSION, "1.3", "1.4")) {
            throw PushProtocolException("unsupported object intent document")
        }
        val objectId = (obj.opt("objectId") as? String)?.takeIf(::isCanonicalObjectUuid)
            ?: throw PushProtocolException("object intent.objectId must be a canonical UUID")
        if (objectId != expectedObjectId) {
            throw PushProtocolException("object intent.objectId does not match the request")
        }
        val objectKey = (obj.opt("objectKey") as? String)?.takeIf(::isValidObjectKey)
            ?: throw PushProtocolException("object intent.objectKey must be a non-empty key")
        val duplicate = objectLaneBool(obj, "duplicate")
        val expiresAt = when (val raw = obj.opt("expiresAt")) {
            null, JSONObject.NULL -> null
            is String -> raw.takeIf { it.length <= 64 }
                ?: throw PushProtocolException("object intent.expiresAt must be a string")
            else -> throw PushProtocolException("object intent.expiresAt must be a string")
        }
        var uploadUrl: String? = null
        val requiredHeaders = linkedMapOf<String, String>()
        when (val rawUrl = obj.opt("uploadUrl")) {
            null, JSONObject.NULL -> Unit
            is String -> {
                if (rawUrl.length > 8192) throw PushProtocolException("object intent.uploadUrl must be a string")
                if (PushEndpointPolicy.validate(rawUrl) !is PushEndpointPolicy.Result.Valid) {
                    throw PushProtocolException("object intent.uploadUrl is not an allowed URL")
                }
                uploadUrl = rawUrl
            }
            else -> throw PushProtocolException("object intent.uploadUrl must be a string")
        }
        when (val rawHeaders = obj.opt("requiredHeaders")) {
            null, JSONObject.NULL -> Unit
            is JSONObject -> {
                val keys = rawHeaders.keys().asSequence().toList()
                if (keys.size > 32) throw PushProtocolException("object intent.requiredHeaders must be an object")
                for (name in keys) {
                    if (name.length > 64 || !HEADER_NAME.matches(name)) {
                        throw PushProtocolException("object intent.requiredHeaders are invalid")
                    }
                    val headerValue = rawHeaders.opt(name) as? String
                        ?: throw PushProtocolException("object intent.requiredHeaders are invalid")
                    if (headerValue.length > 512) {
                        throw PushProtocolException("object intent.requiredHeaders are invalid")
                    }
                    requiredHeaders[name.lowercase()] = headerValue
                }
            }
            else -> throw PushProtocolException("object intent.requiredHeaders must be an object")
        }
        if (!duplicate && uploadUrl == null) {
            throw PushProtocolException("object intent without uploadUrl must be marked duplicate")
        }
        return PushObjectIntent(objectId, objectKey, uploadUrl, requiredHeaders, expiresAt, duplicate)
    }
}

object PushObjectAckParser {
    fun parse(bytes: ByteArray, expectedObjectId: String): PushObjectAck {
        if (bytes.size > PushProtocol.MAX_ACK_BYTES) {
            throw PushProtocolException("object ack exceeds size limit")
        }
        val obj = try {
            JSONObject(bytes.toString(Charsets.UTF_8))
        } catch (_: Throwable) {
            throw PushProtocolException("object ack is not valid JSON")
        }
        val required = setOf("type", "protocolVersion", "objectId", "status", "objectKey", "duplicate")
        val actual = obj.keys().asSequence().toSet()
        if (!actual.containsAll(required)) {
            throw PushProtocolException("object ack is missing required protocol 1.2 members")
        }
        if (actual.any { it in PushProtocol.FORBIDDEN_REMOTE_CONTROL_MEMBERS }) {
            throw PushProtocolException("object ack contains forbidden remote-control metadata")
        }
        if (obj.opt("type") != "objectAck" || obj.opt("protocolVersion") !in setOf(PushProtocol.OBJECT_VERSION, "1.3", "1.4")) {
            throw PushProtocolException("unsupported object ack document")
        }
        val objectId = (obj.opt("objectId") as? String)?.takeIf(::isCanonicalObjectUuid)
            ?: throw PushProtocolException("object ack.objectId must be a canonical UUID")
        if (objectId != expectedObjectId) {
            throw PushProtocolException("object ack.objectId does not match the request")
        }
        val status = (obj.opt("status") as? String)?.takeIf { it.isNotEmpty() && it.length <= 64 }
            ?: throw PushProtocolException("object ack.status must be a non-empty string")
        val objectKey = (obj.opt("objectKey") as? String)?.takeIf(::isValidObjectKey)
            ?: throw PushProtocolException("object ack.objectKey must be a non-empty key")
        val duplicate = objectLaneBool(obj, "duplicate")
        return PushObjectAck(objectId, status, objectKey, duplicate)
    }
}

private fun isCanonicalObjectUuid(value: String): Boolean = runCatching {
    java.util.UUID.fromString(value).toString() == value
}.getOrDefault(false)

private fun isValidObjectKey(value: String): Boolean =
    value.isNotEmpty() && value.length <= 1024 && !value.contains(Regex("\\s"))

private val HEADER_NAME = Regex("^[!#\$%&'*+\\-.^_`|~0-9A-Za-z]+$")

private fun objectLaneBool(obj: JSONObject, name: String): Boolean {
    if (!obj.has(name) || obj.isNull(name)) {
        throw PushProtocolException("object lane response.$name must be a boolean")
    }
    return when (val value = obj.opt(name)) {
        is Boolean -> value
        else -> throw PushProtocolException("object lane response.$name must be a boolean")
    }
}
