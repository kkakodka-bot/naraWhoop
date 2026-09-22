package com.noop.push

import java.net.URI

/** Shared project-scope normalization for authentication and server-result admission. */
internal object ProjectURLCanonicalizer {
    fun canonicalOrNull(value: String): String? {
        val uri = URI(value)
        val scheme = uri.scheme?.lowercase()
        val host = uri.host?.lowercase() ?: return null
        require(uri.userInfo == null && uri.query == null && uri.fragment == null &&
            !value.contains('\u0000') && !uri.path.orEmpty().contains(".."))
        require(scheme == "https" || (scheme == "http" && host in setOf("localhost", "127.0.0.1", "[::1]")))
        val port = if ((scheme == "https" && uri.port == 443) || (scheme == "http" && uri.port == 80)) -1 else uri.port
        return URI(scheme, null, host, port, uri.path.orEmpty().trimEnd('/'), null, null).toString()
    }
}
