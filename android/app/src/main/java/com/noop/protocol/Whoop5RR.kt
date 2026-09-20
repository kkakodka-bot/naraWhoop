package com.noop.protocol

/** WHOOP 5 type-40/v18 words are 1/1024-second ticks. Swift Whoop5RR; WHOOP 4 stays unchanged. */
object Whoop5RR {
    fun milliseconds(ticks: Int): Int {
        require(ticks in 0..65535)
        return (ticks * 1000 + 512) / 1024
    }

    fun usesCanonicalSource(model: String?, brand: String?, hasTaggedIntervals: Boolean): Boolean {
        if (!brand.isNullOrEmpty() && !brand.equals("WHOOP", ignoreCase = true)) return false
        return when (DeviceFamily.confirmedRegistryFamily(model, brand)) {
            DeviceFamily.WHOOP4 -> false
            DeviceFamily.WHOOP5 -> true
            null -> hasTaggedIntervals
        }
    }

}
