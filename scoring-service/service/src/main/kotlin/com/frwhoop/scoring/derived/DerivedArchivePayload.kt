package com.frwhoop.scoring.derived

import com.frwhoop.scoring.scoring.CanonicalScorePayload
import com.frwhoop.scoring.scoring.ServerScoreBundle
import org.json.JSONObject
import java.time.Instant

/** Archive and SQL publication share the canonical result mapping. */
object DerivedArchivePayload {
    fun build(bundle: ServerScoreBundle, computedAt: Instant = bundle.computedAt): JSONObject =
        CanonicalScorePayload.build(bundle, computedAt)
}
