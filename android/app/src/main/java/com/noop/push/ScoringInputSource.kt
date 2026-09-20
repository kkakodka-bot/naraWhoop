package com.noop.push

import com.noop.account.AccountStorageContext

/** An uploader UUID is NOT a sensor UUID. Freeze the actual raw-upload device before suspension. */
class ScoringInputSource private constructor(val account: AccountSessionContext, val rawDeviceId: String,
    val uploadSourceId: String, val serverDeviceId: String) {
    companion object {
        fun capture(context: AccountStorageContext, rawDeviceId: String): ScoringInputSource {
            val account = requireNotNull(context.identity.context)
            require(rawDeviceId.isNotBlank() && rawDeviceId.length <= 512)
            check(context.isCurrent())
            return ScoringInputSource(account, rawDeviceId, SelfHostedPushSettings.from(context).sourceId(),
                canonicalDevice(account.scope.userID, rawDeviceId))
        }
        /** Same mapping as Edge noopDeviceId and Swift PushDurabilityReceipt.canonicalDevice. */
        fun canonicalDevice(owner: String, rawDevice: String): String {
            if (Regex("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$").matches(rawDevice))
                return rawDevice.lowercase()
            val hex = AccountScope.digest("$owner|noop|${rawDevice.ifEmpty { "strap" }}").take(32).toCharArray()
            hex[12] = '5'; hex[16] = 'a'
            val value = String(hex)
            return listOf(value.substring(0, 8), value.substring(8, 12), value.substring(12, 16), value.substring(16, 20), value.substring(20)).joinToString("-")
        }
    }
}
