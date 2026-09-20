package com.frwhoop.scoring.b2

/** B2 credentials — same bucket/endpoint as the raw object lane on the VPS. */
data class B2Config(
    val keyId: String,
    val applicationKey: String,
    val bucket: String,
    val endpoint: String,
    val region: String,
    val derivedRetentionDays: Int = 90,
) {
    val enabled: Boolean = keyId.isNotBlank() && applicationKey.isNotBlank()

    companion object {
        fun fromEnv(): B2Config? {
            val keyId = System.getenv("B2_KEY_ID")?.trim()?.takeIf { it.isNotEmpty() }
                ?: System.getenv("KEY_ID")?.trim()?.takeIf { it.isNotEmpty() }
            val appKey = System.getenv("B2_APPLICATION_KEY")?.trim()?.takeIf { it.isNotEmpty() }
                ?: System.getenv("APPLICATION_KEY")?.trim()?.takeIf { it.isNotEmpty() }
            if (keyId == null || appKey == null) return null
            val endpoint = (System.getenv("B2_S3_ENDPOINT") ?: "s3.us-west-004.backblazeb2.com")
                .trim()
                .removePrefix("https://")
                .removePrefix("http://")
                .removeSuffix("/")
            return B2Config(
                keyId = keyId,
                applicationKey = appKey,
                bucket = System.getenv("B2_BUCKET")?.trim()?.takeIf { it.isNotEmpty() }
                    ?: System.getenv("B2_BUCKET_NAME")?.trim()?.takeIf { it.isNotEmpty() }
                    ?: System.getenv("BUCKET_NAME")?.trim()?.takeIf { it.isNotEmpty() }
                    ?: "FRWHOOP",
                endpoint = endpoint,
                region = System.getenv("B2_REGION")?.trim()?.takeIf { it.isNotEmpty() }
                    ?: System.getenv("B2_S3_REGION")?.trim()?.takeIf { it.isNotEmpty() }
                    ?: "us-west-004",
                derivedRetentionDays = System.getenv("DERIVED_RETENTION_DAYS")?.toIntOrNull() ?: 90,
            )
        }
    }
}
