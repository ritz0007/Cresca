package com.cresca.app.innertube

/**
 * On-device InnerTube client specs (InnerTune/Metrolist pattern, OkHttp port).
 * No new deps: plain OkHttp + org.json, reuses tuned pool settings.
 *
 * Clients:
 *  - WEB_REMIX  (music.youtube.com search/browse — shelves, stable)
 *  - ANDROID_MUSIC (player — direct audio URLs, minimal cipher)
 *  - ANDROID_VR (Oculus — direct signed URLs, no cipher; ~200ms fast path)
 *  - WEB (fallback for browse/next when music clients fail)
 */
data class TubeClient(
    val clientName: String,
    val clientVersion: String,
    val apiKey: String,
    val userAgent: String,
    val referer: String? = null
) {
    companion object {
        private const val UA_WEB =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        private const val UA_ANDROID =
            "com.google.android.apps.youtube.music/6.42.55 (Linux; U; Android 14) gzip"

        // Versions pinned from InnerTune (proven stable); bump only when
        // YouTube returns 403/400 on player/search across clients.
        val WEB_REMIX = TubeClient(
            clientName = "WEB_REMIX",
            clientVersion = "1.20260218.01.00",
            apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30",
            userAgent = UA_WEB,
            referer = "https://music.youtube.com/"
        )
        val ANDROID_MUSIC = TubeClient(
            clientName = "ANDROID_MUSIC",
            clientVersion = "6.42.55",
            apiKey = "AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI",
            userAgent = UA_ANDROID
        )
        val ANDROID_VR = TubeClient(
            clientName = "ANDROID_VR",
            clientVersion = "1.57.21",
            apiKey = "AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI",
            userAgent = UA_ANDROID
        )
        val WEB = TubeClient(
            clientName = "WEB",
            clientVersion = "2.20260218.01.00",
            apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX3",
            userAgent = UA_WEB
        )
    }
}
