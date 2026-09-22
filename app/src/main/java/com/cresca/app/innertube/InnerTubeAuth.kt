package com.cresca.app.innertube

import java.security.MessageDigest

/**
 * Auth headers for youtubei/v1 (InnerTune pattern).
 * SAPISIDHASH is required when cookies carry a login session; without it
 * authenticated player calls 403 even with a valid Cookie header.
 */
object InnerTubeAuth {
    fun sapisidHash(cookies: String, nowSec: Long = System.currentTimeMillis() / 1000): String? {
        return try {
            val sapisid = cookies.split(";")
                .map { it.trim() }
                .firstOrNull { it.startsWith("SAPISID=") }
                ?.substringAfter("=")
                ?.trim()
                ?: return null
            if (sapisid.isBlank()) return null
            val input = "$nowSec $sapisid https://music.youtube.com"
            val md = MessageDigest.getInstance("SHA-1")
            val hash = md.digest(input.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            "${nowSec}_$hash"
        } catch (e: Exception) {
            null
        }
    }

    fun originHeaders(
        builder: okhttp3.Request.Builder,
        client: TubeClient,
        cookies: String,
        visitorData: String,
        poToken: String
    ) {
        try {
            builder.header("Content-Type", "application/json")
            builder.header("X-Goog-Api-Format-Version", "1")
            builder.header("X-YouTube-Client-Name", client.clientName)
            builder.header("X-YouTube-Client-Version", client.clientVersion)
            builder.header("User-Agent", client.userAgent)
            builder.header("Origin", "https://music.youtube.com")
            builder.header("X-Origin", "https://music.youtube.com")
            client.referer?.let { builder.header("Referer", it) }
            if (visitorData.isNotBlank()) {
                builder.header("X-Goog-Visitor-Id", visitorData)
            }
            if (cookies.isNotBlank()) {
                builder.header("Cookie", cookies)
                val nowSec = System.currentTimeMillis() / 1000
                sapisidHash(cookies, nowSec)?.let {
                    builder.header("Authorization", "SAPISIDHASH $it")
                }
            }
            // PO-token (BotGuard) when available; player also accepts it
            // inside context.playbackContext / serviceIntegrityDimensions.
            if (poToken.isNotBlank()) {
                builder.header("X-Goog-EOM-Visitor-Id", poToken)
            }
        } catch (e: Exception) {
        }
    }
}
