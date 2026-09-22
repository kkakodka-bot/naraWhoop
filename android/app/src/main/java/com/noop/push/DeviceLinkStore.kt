package com.noop.push

import android.content.Context
import android.content.SharedPreferences
import com.noop.data.SecurePrefs
import org.json.JSONObject

/** A previous server ACK permits offline use only for this exact installation and device. */
class DeviceLinkStore internal constructor(private val prefs: SharedPreferences) {
    data class Identity(val endpoint: String, val owner: String, val source: String, val device: String) {
        val key: String = EnrollmentDataScope.digest("$endpoint\u0000$owner\u0000$source\u0000$device")
    }

    fun confirmed(identity: Identity): String? = runCatching {
        val receipt = JSONObject(prefs.getString(identity.key, null) ?: return null)
        validate(receipt, identity)
    }.getOrNull()

    fun record(identity: Identity, response: String): String {
        val receipt = JSONObject(response).getJSONObject("identity")
        val canonical = validate(receipt, identity)
        check(prefs.edit().putString(identity.key, receipt.toString()).commit()) { "Device acknowledgement could not be saved" }
        return canonical
    }

    private fun validate(receipt: JSONObject, expected: Identity): String {
        require(receipt.getString("userId") == expected.owner && receipt.getString("sourceId") == expected.source &&
            receipt.getString("externalDeviceId") == expected.device) { "Device acknowledgement scope changed" }
        return receipt.getString("deviceId").also { require(PushEnrollmentCredential.isCanonicalUuid(it)) }
    }

    companion object {
        fun from(context: Context) = DeviceLinkStore(SecurePrefs.of(context, "noop_enrolled_device_links"))
        fun identity(context: Context): Identity? {
            val credential = EnrollmentDataScope.credential(context)
            val owner = credential?.userId ?: CloudAuthClient.identitySnapshot(context).scope?.userID ?: return null
            val endpoint = if (credential != null) SelfHostedPushSettings.from(context).configuredEndpoint()?.url
                else CloudAuthClient.identitySnapshot(context).scope?.projectURL?.trimEnd('/')?.plus("/functions/v1/push")
            if (endpoint == null) return null
            return Identity(endpoint, owner, credential?.sourceId ?: SelfHostedPushSettings.from(context).sourceId(), ServerScoreClient.localDeviceId(context))
        }
        fun currentConfirmed(context: Context): Boolean = runCatching {
            val identity = identity(context) ?: return false
            from(context).confirmed(identity) != null
        }.getOrDefault(false)
    }
}
