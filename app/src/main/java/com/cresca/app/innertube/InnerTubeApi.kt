package com.cresca.app.innertube

import android.util.Log
import com.cresca.app.YtTrack
import com.cresca.app.isMusicJunk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

/**
 * Minimal on-device youtubei/v1 client (search + player + browse + next).
 * OkHttp + org.json only — no Ktor/serialization (toolchain pins).
 * Every call is best-effort: empty list on any failure so callers fall
 * back to NewPipeExtractor. Never throws.
 */
object InnerTubeApi {
    private const val TAG = "InnerTube"
    private val JSON = "application/json; charset=utf-8".toMediaType()

    private val http = okhttp3.OkHttpClient.Builder()
        .dispatcher(okhttp3.Dispatcher().apply {
            maxRequests = 64
            maxRequestsPerHost = 16
        })
        .connectionPool(okhttp3.ConnectionPool(8, 5, java.util.concurrent.TimeUnit.MINUTES))
        .protocols(listOf(okhttp3.Protocol.HTTP_2, okhttp3.Protocol.HTTP_1_1))
        .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(12, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(12, java.util.concurrent.TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    // Player fast lane: short timeouts so a dead client fails over in
    // seconds (was 10/12s per client × 3 sequential = 24s+ worst case).
    private val playerHttp = okhttp3.OkHttpClient.Builder()
        .dispatcher(okhttp3.Dispatcher().apply {
            maxRequests = 64
            maxRequestsPerHost = 16
        })
        .connectionPool(okhttp3.ConnectionPool(8, 5, java.util.concurrent.TimeUnit.MINUTES))
        .protocols(listOf(okhttp3.Protocol.HTTP_2, okhttp3.Protocol.HTTP_1_1))
        .connectTimeout(4, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(6, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(6, java.util.concurrent.TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    private fun contextJson(client: TubeClient, visitorData: String): JSONObject {
        val c = JSONObject()
            .put("clientName", client.clientName)
            .put("clientVersion", client.clientVersion)
            .put("hl", "en")
            .put("gl", "US")
        if (visitorData.isNotBlank()) c.put("visitorData", visitorData)
        if (client.clientName.startsWith("ANDROID")) {
            c.put("androidSdkVersion", 34)
        }
        return JSONObject().put("client", c)
            .put("user", JSONObject().put("lockedSafetyMode", false))
    }

    private fun post(
        endpoint: String,
        client: TubeClient,
        body: JSONObject,
        cookies: String,
        visitorData: String,
        poToken: String,
        host: String = "https://music.youtube.com",
        httpClient: okhttp3.OkHttpClient = http
    ): JSONObject? {
        return try {
            val url = "$host/youtubei/v1/$endpoint?key=${client.apiKey}&prettyPrint=false"
            val rb = body.toString().toRequestBody(JSON)
            val req = okhttp3.Request.Builder().url(url).post(rb)
            InnerTubeAuth.originHeaders(req, client, cookies, visitorData, poToken)
            httpClient.newCall(req.build()).execute().use { resp ->
                if (!resp.isSuccessful) {
                    Log.d(TAG, "$endpoint ${client.clientName} http ${resp.code}")
                    return null
                }
                val text = resp.body?.string() ?: return null
                JSONObject(text)
            }
        } catch (e: Exception) {
            Log.d(TAG, "$endpoint ${client.clientName} failed: ${e.message}")
            null
        }
    }

    // ---------- search ----------

    suspend fun searchMusic(
        query: String,
        max: Int,
        cookies: String,
        visitorData: String,
        poToken: String = ""
    ): List<YtTrack> = withContext(Dispatchers.IO) {
        val t0 = android.os.SystemClock.elapsedRealtime()
        try {
            val client = TubeClient.WEB_REMIX
            val body = JSONObject()
                .put("context", contextJson(client, visitorData))
                .put("query", query)
            val json = post("search", client, body, cookies, visitorData, poToken)
                ?: return@withContext emptyList()
            val out = parseSearch(json, max)
            try {
                Log.d(TAG, "search '$query' ${out.size} hits ${android.os.SystemClock.elapsedRealtime() - t0}ms via WEB_REMIX")
            } catch (e: Exception) {
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    internal fun parseSearch(root: JSONObject, max: Int): List<YtTrack> {
        val found = ArrayList<JSONObject>()
        collectRenderers(root, "musicResponsiveListItemRenderer", found)
        val out = ArrayList<YtTrack>()
        val seen = HashSet<String>()
        for (r in found) {
            try {
                val t = parseMusicItem(r) ?: continue
                if (seen.add(t.id)) out.add(t)
                if (out.size >= max) break
            } catch (e: Exception) {
            }
        }
        if (out.size < max) {
            // Fallback: plain videoRenderer (e.g. WEBස client shape).
            val vids = ArrayList<JSONObject>()
            collectRenderers(root, "videoRenderer", vids)
            for (r in vids) {
                try {
                    val t = parseVideoItem(r) ?: continue
                    if (seen.add(t.id)) out.add(t)
                    if (out.size >= max) break
                } catch (e: Exception) {
                }
            }
        }
        return out
    }

    private fun collectRenderers(node: Any?, key: String, acc: MutableList<JSONObject>) {
        try {
            when (node) {
                is JSONObject -> {
                    if (node.has(key)) {
                        try {
                            acc.add(node.getJSONObject(key))
                        } catch (e: Exception) {
                        }
                    }
                    val keys = node.keys()
                    while (keys.hasNext()) {
                        val k = keys.next()
                        try {
                            collectRenderers(node.get(k), key, acc)
                        } catch (e: Exception) {
                        }
                    }
                }
                is JSONArray -> {
                    for (i in 0 until node.length()) {
                        try {
                            collectRenderers(node.get(i), key, acc)
                        } catch (e: Exception) {
                        }
                    }
                }
            }
        } catch (e: Exception) {
        }
    }

    private fun parseMusicItem(r: JSONObject): YtTrack? {
        // Shorts ride reel endpoints, never watch endpoints with songs.
        try {
            val nav = r.optJSONObject("navigationEndpoint")
            if (nav != null && (nav.has("reelEndpoint") || nav.has("reelWatchEndpoint"))) return null
        } catch (e: Exception) {
        }
        // videoId from several possible slots.
        var videoId: String? = null
        try {
            videoId = r.optJSONObject("playlistItemData")?.optString("videoId")
        } catch (e: Exception) {
        }
        if (videoId.isNullOrBlank()) {
            try {
                videoId = r.optJSONObject("overlay")
                    ?.optJSONObject("musicItemThumbnailOverlayRenderer")
                    ?.optJSONObject("content")
                    ?.optJSONObject("musicPlayButtonRenderer")
                    ?.optJSONObject("playNavigationEndpoint")
                    ?.optJSONObject("watchEndpoint")
                    ?.optString("videoId")
            } catch (e: Exception) {
            }
        }
        if (videoId.isNullOrBlank()) {
            try {
                videoId = r.optJSONObject("navigationEndpoint")
                    ?.optJSONObject("watchEndpoint")?.optString("videoId")
            } catch (e: Exception) {
            }
        }
        if (videoId.isNullOrBlank() || videoId.length != 11) return null

        var title = ""
        var artist = "YouTube"
        var durationSec = -1L
        try {
            val flex = r.optJSONArray("flexColumns")
            val c0 = flex?.optJSONObject(0)
                ?.optJSONObject("musicResponsiveListItemFlexColumnRenderer")
            title = runsText(c0?.optJSONObject("text")) ?: ""
            val c1 = flex?.optJSONObject(1)
                ?.optJSONObject("musicResponsiveListItemFlexColumnRenderer")
            val sub = runsText(c1?.optJSONObject("text")) ?: ""
            // Subtitle is "Artist • Album • Duration": first = artist,
            // trailing M:SS = duration (hour-long comps die here).
            val segs = sub.split("•").map { it.trim() }.filter { it.isNotEmpty() }
            artist = segs.firstOrNull()?.takeIf { it.isNotEmpty() } ?: "YouTube"
            val last = segs.lastOrNull() ?: ""
            val m = Regex("""^(?:(\d+):)?([0-5]?\d):([0-5]\d)$""").find(last)
            if (m != null) {
                durationSec = (m.groupValues[1].toLongOrNull() ?: 0L) * 3600 +
                    (m.groupValues[2].toLongOrNull() ?: 0L) * 60 +
                    (m.groupValues[3].toLongOrNull() ?: 0L)
            }
        } catch (e: Exception) {
        }
        if (title.isBlank()) return null
        // Lives have no usable duration segment; badges say LIVE.
        if (durationSec < 0L && isLiveBadge(r)) return null
        // Known duration must be a song: 30s-10min.
        if (durationSec in 0L..29L || durationSec > 600L) return null
        // Episodes/Shorts-shaped clutter never enters any list.
        if (isMusicJunk(title, artist)) return null

        var thumb = ""
        try {
            val thumbs = r.optJSONObject("thumbnail")
                ?.optJSONObject("musicThumbnailRenderer")
                ?.optJSONObject("thumbnail")
                ?.optJSONArray("thumbnails")
            if (thumbs != null && thumbs.length() > 0) {
                thumb = thumbs.optJSONObject(thumbs.length() - 1)?.optString("url") ?: ""
            }
        } catch (e: Exception) {
        }
        return YtTrack(
            id = videoId,
            title = title,
            artist = artist,
            thumbUrl = sharpThumb(thumb),
            watchUrl = "https://www.youtube.com/watch?v=$videoId"
        )
    }

    /**
     * YTM thumbs arrive as =w120-h120 (blurry on cards): upscale the size
     * params to w544 — same CDN pixels YTM itself serves on desktop.
     */
    internal fun sharpThumb(url: String): String {
        return try {
            if (url.isBlank()) return url
            val m = Regex("=w\\d+-h\\d+").find(url) ?: return url
            url.replace(m.value, "=w544-h544")
        } catch (e: Exception) {
            url
        }
    }

    /** True when badges mark a live/upcoming stream (unusable duration). */    internal fun isLiveBadge(r: JSONObject): Boolean {
        return try {
            val badges = r.optJSONArray("badges") ?: return false
            for (i in 0 until badges.length()) {
                val label = badges.optJSONObject(i)
                    ?.optJSONObject("metadataBadgeRenderer")
                    ?.optString("label", "")
                    ?.lowercase() ?: ""
                if (label.contains("live") || label.contains("upcoming") || label.contains("premiere")) return true
            }
            false
        } catch (e: Exception) {
            false
        }
    }

    private fun parseVideoItem(r: JSONObject): YtTrack? {
        val videoId = try { r.optString("videoId") } catch (e: Exception) { "" }
        if (videoId.isBlank() || videoId.length != 11) return null
        if (isLiveBadge(r)) return null
        try {
            val nav = r.optJSONObject("navigationEndpoint")
            if (nav != null && (nav.has("reelEndpoint") || nav.has("reelWatchEndpoint"))) return null
        } catch (e: Exception) {
        }
        // lengthText "12:34": songs only, 30s-10min.
        try {
            val len = runsText(r.optJSONObject("lengthText")) ?: ""
            val m = Regex("""^(?:(\d+):)?([0-5]?\d):([0-5]\d)$""").find(len.trim())
            if (m != null) {
                val s = (m.groupValues[1].toLongOrNull() ?: 0L) * 3600 +
                    (m.groupValues[2].toLongOrNull() ?: 0L) * 60 +
                    (m.groupValues[3].toLongOrNull() ?: 0L)
                if (s !in 30L..600L) return null
            }
        } catch (e: Exception) {
        }
        val title = try { runsText(r.optJSONObject("title")) ?: "" } catch (e: Exception) { "" }
        if (title.isBlank()) return null
        val artist = try {
            runsText(r.optJSONObject("ownerText")) ?: r.optJSONObject("shortBylineText")?.let { runsText(it) } ?: "YouTube"
        } catch (e: Exception) {
            "YouTube"
        }
        if (isMusicJunk(title, artist)) return null
        var thumb = ""
        try {
            val arr = r.optJSONObject("thumbnail")?.optJSONArray("thumbnails")
            if (arr != null && arr.length() > 0) thumb = arr.optJSONObject(arr.length() - 1)?.optString("url") ?: ""
        } catch (e: Exception) {
        }
        return YtTrack(id = videoId, title = title, artist = artist, thumbUrl = sharpThumb(thumb), watchUrl = "https://www.youtube.com/watch?v=$videoId")
    }

    private fun runsText(textObj: JSONObject?): String? {
        return try {
            val runs = textObj?.optJSONArray("runs") ?: return textObj?.optString("simpleText")
            val sb = StringBuilder()
            for (i in 0 until runs.length()) {
                sb.append(runs.optJSONObject(i)?.optString("text") ?: "")
            }
            sb.toString().takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            null
        }
    }

    // ---------- player ----------

    /**
     * Resolve ranked audio URLs via player endpoint.
     * Race: ANDROID_MUSIC vs ANDROID_VR concurrently (first non-empty
     * wins, 8s cap), then WEB_REMIX. Was 3 sequential clients × 10/12s
     * timeouts = 24s+ worst case; typical is now max(one RTT), not the sum.
     * Best-bitrate ranking preserved — only the waiting is parallel.
     * Returns best-first urls, empty on failure (caller falls back).
     */
    suspend fun audioUrls(
        videoId: String,
        cookies: String,
        visitorData: String,
        poToken: String = ""
    ): List<String> = withContext(Dispatchers.IO) {
        val t0 = android.os.SystemClock.elapsedRealtime()
        try {
            val raced: List<String> = coroutineScope {
                val vrDef = async {
                    try {
                        withTimeoutOrNull(8000L) {
                            playerUrls(videoId, TubeClient.ANDROID_VR, cookies, visitorData, poToken)
                        } ?: emptyList()
                    } catch (e: Exception) {
                        emptyList()
                    }
                }
                val music = try {
                    withTimeoutOrNull(8000L) {
                        playerUrls(videoId, TubeClient.ANDROID_MUSIC, cookies, visitorData, poToken)
                    } ?: emptyList()
                } catch (e: Exception) {
                    emptyList()
                }
                if (music.isNotEmpty()) {
                    try {
                        vrDef.cancel()
                    } catch (e: Exception) {
                    }
                    music
                } else {
                    try {
                        vrDef.await()
                    } catch (e: Exception) {
                        emptyList()
                    }
                }
            }
            if (raced.isNotEmpty()) {
                try {
                    Log.d(TAG, "player $videoId ${raced.size} urls ${android.os.SystemClock.elapsedRealtime() - t0}ms via race")
                } catch (e: Exception) {
                }
                return@withContext raced
            }
            val remix = try {
                withTimeoutOrNull(8000L) {
                    playerUrls(videoId, TubeClient.WEB_REMIX, cookies, visitorData, poToken)
                } ?: emptyList()
            } catch (e: Exception) {
                emptyList()
            }
            if (remix.isNotEmpty()) {
                try {
                    Log.d(TAG, "player $videoId ${remix.size} urls ${android.os.SystemClock.elapsedRealtime() - t0}ms via WEB_REMIX")
                } catch (e: Exception) {
                }
            }
            remix
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun playerUrls(
        videoId: String,
        client: TubeClient,
        cookies: String,
        visitorData: String,
        poToken: String
    ): List<String> {
        val body = JSONObject()
            .put("context", contextJson(client, visitorData))
            .put("videoId", videoId)
            .put("racyCheckOk", true)
            .put("contentCheckOk", true)
        if (poToken.isNotBlank()) {
            try {
                body.put("serviceIntegrityDimensions", JSONObject().put("poToken", poToken))
            } catch (e: Exception) {
            }
        }
        val host = "https://music.youtube.com"
        val json = post("player", client, body, cookies, visitorData, poToken, host, playerHttp)
            ?: return emptyList()
        try {
            val status = json.optJSONObject("playabilityStatus")?.optString("status") ?: ""
            if (status.isNotBlank() && status != "OK") {
                Log.d(TAG, "player $videoId status $status via ${client.clientName}")
                return emptyList()
            }
        } catch (e: Exception) {
        }
        val urls = ArrayList<Pair<Int, String>>()
        try {
            val sd = json.optJSONObject("streamingData") ?: return emptyList()
            collectAudio(sd.optJSONArray("adaptiveFormats"), urls)
            collectAudio(sd.optJSONArray("formats"), urls)
        } catch (e: Exception) {
            return emptyList()
        }
        return urls.sortedByDescending { it.first }.map { it.second }.distinct()
    }

    private fun collectAudio(arr: JSONArray?, acc: MutableList<Pair<Int, String>>) {
        if (arr == null) return
        for (i in 0 until arr.length()) {
            try {
                val f = arr.optJSONObject(i) ?: continue
                val mime = f.optString("mimeType", "")
                if (!mime.startsWith("audio/")) continue
                val url = f.optString("url", "")
                // signatureCipher URLs need decipher (NewPipe path handles
                // those) — InnerTube fast path only takes direct URLs.
                if (url.isBlank()) continue
                val br = try { f.optInt("bitrate", 0) } catch (e: Exception) { 0 }
                acc.add(Pair(br, url))
            } catch (e: Exception) {
            }
        }
    }

    // ---------- suggestions (as-you-type) ----------

    suspend fun suggestions(
        input: String,
        cookies: String,
        visitorData: String
    ): List<String> = withContext(Dispatchers.IO) {
        try {
            if (input.trim().length < 2) return@withContext emptyList()
            val client = TubeClient.WEB_REMIX
            val body = JSONObject()
                .put("context", contextJson(client, visitorData))
                .put("input", input)
            val json = post("music/get_search_suggestions", client, body, cookies, visitorData, "")
                ?: return@withContext emptyList()
            val out = ArrayList<String>()
            val arr = try {
                json.optJSONObject("contents")
                    ?.optJSONArray("searchSuggestionsSectionContents")
            } catch (e: Exception) {
                null
            } ?: return@withContext emptyList()
            for (i in 0 until arr.length()) {
                try {
                    val s = arr.optJSONObject(i)
                        ?.optJSONObject("searchSuggestionRenderer")
                        ?.optJSONObject("suggestion")
                        ?.optJSONArray("runs")
                    if (s != null && s.length() > 0) {
                        val text = StringBuilder()
                        for (j in 0 until s.length()) text.append(s.optJSONObject(j)?.optString("text") ?: "")
                        if (text.isNotBlank() && out.none { it.equals(text.toString(), true) }) out.add(text.toString())
                    }
                    if (out.size >= 8) break
                } catch (e: Exception) {
                }
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    // ---------- browse (home shelves + charts) ----------

    /**
     * Browse a YT Music shelf page. browseId "FEmusic_home" = home,
     * "FEmusic_charts" = charts. Returns shelf title → tracks.
     */
    suspend fun browseShelves(
        browseId: String,
        cookies: String,
        visitorData: String,
        poToken: String = "",
        maxShelves: Int = 8,
        perShelf: Int = 12
    ): Map<String, List<YtTrack>> = withContext(Dispatchers.IO) {
        val t0 = android.os.SystemClock.elapsedRealtime()
        try {
            val client = TubeClient.WEB_REMIX
            val body = JSONObject()
                .put("context", contextJson(client, visitorData))
                .put("browseId", browseId)
            val json = post("browse", client, body, cookies, visitorData, poToken)
                ?: return@withContext emptyMap()
            val out = parseShelves(json, maxShelves, perShelf)
            try {
                if (out.isEmpty()) {
                    Log.d(TAG, "browse $browseId 0 shelves; shape=${diagnoseKeys(json)}")
                } else {
                    Log.d(TAG, "browse $browseId ${out.size} shelves ${android.os.SystemClock.elapsedRealtime() - t0}ms")
                }
            } catch (e: Exception) {
            }
            out
        } catch (e: Exception) {
            emptyMap()
        }
    }

    /** One-line structural fingerprint for empty parses (field diagnosis). */
    internal fun diagnoseKeys(root: JSONObject): String {
        return try {
            val seen = LinkedHashSet<String>()
            // Shelf-level: which *ShelfRenderer variants exist anywhere.
            val shelfHits = ArrayList<JSONObject>()
            collectRenderers(root, "musicCarouselShelfRenderer", shelfHits)
            collectRenderers(root, "musicShelfRenderer", shelfHits)
            seen.add("shelfHits=${shelfHits.size}")
            // If a sectionListRenderer exists, fingerprint its item wrappers.
            val sections = ArrayList<JSONObject>()
            collectRenderers(root, "sectionListRenderer", sections)
            seen.add("sections=${sections.size}")
            for (s in sections.take(1)) {
                try {
                    val items = s.optJSONArray("contents")
                    seen.add("sectionItems=${items?.length() ?: -1}")
                    if (items != null) {
                        val kinds = LinkedHashSet<String>()
                        for (i in 0 until minOf(items.length(), 8)) {
                            try {
                                val o = items.optJSONObject(i) ?: continue
                                val ks = o.keys()
                                while (ks.hasNext()) kinds.add(ks.next())
                            } catch (e: Exception) {
                            }
                        }
                        seen.add("kinds=" + kinds.joinToString("|").take(300))
                    }
                } catch (e: Exception) {
                }
            }
            fun walk(node: Any?, depth: Int) {
                // Depth 7: shelves live at contents→tabs[0]→tabRenderer→
                // content→sectionListRenderer (depth 5-6).
                if (depth > 7 || seen.size >= 60) return
                try {
                    when (node) {
                        is JSONObject -> {
                            val keys = node.keys()
                            while (keys.hasNext()) {
                                val k = keys.next()
                                if (k.endsWith("Renderer") || k == "contents" || k == "tabs") {
                                    seen.add("${"-".repeat(depth)}$k")
                                }
                                try {
                                    walk(node.get(k), depth + 1)
                                } catch (e: Exception) {
                                }
                            }
                        }
                        is JSONArray -> {
                            for (i in 0 until minOf(node.length(), 3)) {
                                try {
                                    walk(node.get(i), depth + 1)
                                } catch (e: Exception) {
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                }
            }
            walk(root, 0)
            seen.joinToString(",").take(600)
        } catch (e: Exception) {
            "unreadable"
        }
    }

    internal fun parseShelves(root: JSONObject, maxShelves: Int, perShelf: Int): Map<String, List<YtTrack>> {
        val out = LinkedHashMap<String, List<YtTrack>>()
        val shelves = ArrayList<JSONObject>()
        collectRenderers(root, "musicCarouselShelfRenderer", shelves)
        collectRenderers(root, "musicShelfRenderer", shelves)
        var skippedTitle = 0
        var skippedItems = 0
        for (s in shelves) {
            try {
                val title = shelfTitle(s)
                if (title == null) {
                    skippedTitle++
                    continue
                }
                if (out.containsKey(title)) continue
                val items = ArrayList<YtTrack>()
                val seen = HashSet<String>()
                val contents = s.optJSONObject("contents")?.optJSONArray("contents")
                    ?: s.optJSONArray("contents")
                if (contents != null) {
                    for (i in 0 until contents.length()) {
                        try {
                            val w = contents.optJSONObject(i) ?: continue
                            val t = when {
                                w.has("musicResponsiveListItemRenderer") ->
                                    parseMusicItem(w.getJSONObject("musicResponsiveListItemRenderer"))
                                w.has("musicTwoRowItemRenderer") ->
                                    parseTwoRowItem(w.getJSONObject("musicTwoRowItemRenderer"))
                                // Bare shapes: renderer object used directly.
                                w.has("flexColumns") -> parseMusicItem(w)
                                w.has("title") && w.has("navigationEndpoint") -> parseTwoRowItem(w)
                                else -> null
                            } ?: continue
                            if (seen.add(t.id)) items.add(t)
                            if (items.size >= perShelf) break
                        } catch (e: Exception) {
                        }
                    }
                }
                if (items.isNotEmpty()) {
                    out[title] = items
                    if (out.size >= maxShelves) break
                } else {
                    skippedItems++
                }
            } catch (e: Exception) {
            }
        }
        if (out.isEmpty() && shelves.isNotEmpty()) {
            try {
                // Field diagnosis: wrapper keys of the first shelf's items.
                var itemKeys = ""
                try {
                    val s0 = shelves.firstOrNull()
                    val c0 = s0?.optJSONObject("contents")?.optJSONArray("contents")
                        ?: s0?.optJSONArray("contents")
                    val w0 = c0?.optJSONObject(0)
                    if (w0 != null) {
                        val ks = w0.keys()
                        val list = ArrayList<String>()
                        while (ks.hasNext()) list.add(ks.next())
                        itemKeys = " w0=" + list.joinToString("|").take(200)
                        // One level deeper for the common wrapper-of-wrapper.
                        val inner = list.firstOrNull()?.let { w0.optJSONObject(it) }
                        if (inner != null) {
                            val ks2 = inner.keys()
                            val list2 = ArrayList<String>()
                            while (ks2.hasNext()) list2.add(ks2.next())
                            itemKeys += " inner=" + list2.joinToString("|").take(200)
                        }
                    }
                } catch (e: Exception) {
                }
                Log.d(TAG, "parseShelves 0/${shelves.size} noTitle=$skippedTitle noItems=$skippedItems$itemKeys")
            } catch (e: Exception) {
            }
        }
        return out
    }

    private fun shelfTitle(s: JSONObject): String? {
        return try {
            val h = s.optJSONObject("header")
                ?.optJSONObject("musicCarouselShelfBasicHeaderRenderer")
                ?: s.optJSONObject("header")
                    ?.optJSONObject("musicShelfHeaderRenderer")
            runsText(h?.optJSONObject("title"))?.takeIf { it.isNotBlank() }
                // Bare header shapes.
                ?: runsText(s.optJSONObject("header")?.optJSONObject("title"))?.takeIf { it.isNotBlank() }
                ?: s.optJSONObject("header")?.optString("title")?.takeIf { it.isNotBlank() }
                ?: runsText(s.optJSONObject("title"))?.takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            null
        }
    }

    internal fun parseTwoRowItem(r: JSONObject): YtTrack? {
        return try {
            if (isLiveBadge(r)) return null
            val nav = r.optJSONObject("navigationEndpoint")
            if (nav != null && (nav.has("reelEndpoint") || nav.has("reelWatchEndpoint"))) return null
            val videoId = nav
                ?.optJSONObject("watchEndpoint")?.optString("videoId")
                ?.takeIf { it.length == 11 } ?: return null
            val title = runsText(r.optJSONObject("title"))?.takeIf { it.isNotBlank() } ?: return null
            val artist = runsText(r.optJSONObject("subtitle"))?.split("•")?.firstOrNull()?.trim()
                ?.takeIf { it.isNotEmpty() } ?: "YouTube"
            if (isMusicJunk(title, artist)) return null
            var thumb = ""
            try {
                val arr = r.optJSONObject("thumbnailRenderer")
                    ?.optJSONObject("musicThumbnailRenderer")
                    ?.optJSONObject("thumbnail")?.optJSONArray("thumbnails")
                if (arr != null && arr.length() > 0) thumb = arr.optJSONObject(arr.length() - 1)?.optString("url") ?: ""
            } catch (e: Exception) {
            }
            YtTrack(id = videoId, title = title, artist = artist, thumbUrl = sharpThumb(thumb), watchUrl = "https://www.youtube.com/watch?v=$videoId")
        } catch (e: Exception) {
            null
        }
    }

    // ---------- next (radio / related autoplay mixes) ----------

    /**
     * BitChord-style radio: RDAMVM<videoId> playlist via the next endpoint —
     * YouTube's own ordered radio mix (what's next when a song ends on YTM),
     * not the generic watch-next column. Songs + music videos only: Shorts
     * (reel endpoints), lives and episode/trailer junk are dropped here.
     */
    suspend fun related(
        videoId: String,
        max: Int,
        cookies: String,
        visitorData: String,
        poToken: String = ""
    ): List<YtTrack> = withContext(Dispatchers.IO) {
        val t0 = android.os.SystemClock.elapsedRealtime()
        try {
            val client = TubeClient.WEB_REMIX
            // Radio first: RDAMVM playlist is the relevance-ordered mix.
            val radio = try {
                val body = JSONObject()
                    .put("context", contextJson(client, visitorData))
                    .put("videoId", videoId)
                    .put("playlistId", "RDAMVM$videoId")
                val json = post("next", client, body, cookies, visitorData, poToken)
                if (json != null) parseRadioPanels(json, videoId, max) else emptyList()
            } catch (e: Exception) {
                emptyList()
            }
            if (radio.size >= max / 2) {
                try {
                    Log.d(TAG, "radio $videoId ${radio.size} tracks ${android.os.SystemClock.elapsedRealtime() - t0}ms")
                } catch (e: Exception) {
                }
                return@withContext radio.take(max)
            }
            // Thin radio: plain next column as filler (same junk gates).
            val out = ArrayList(radio)
            try {
                val body = JSONObject()
                    .put("context", contextJson(client, visitorData))
                    .put("videoId", videoId)
                val json = post("next", client, body, cookies, visitorData, poToken)
                if (json != null) {
                    for (t in parseRadioPanels(json, videoId, max + out.size)) {
                        if (out.none { it.id == t.id }) out.add(t)
                        if (out.size >= max) break
                    }
                }
            } catch (e: Exception) {
            }
            if (out.isEmpty()) {
                out.addAll(parseSearch(postToJson(client, videoId, cookies, visitorData, poToken), max))
            }
            try {
                Log.d(TAG, "next $videoId ${out.size} related ${android.os.SystemClock.elapsedRealtime() - t0}ms")
            } catch (e: Exception) {
            }
            out.distinctBy { it.id }.take(max)
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun postToJson(
        client: TubeClient,
        videoId: String,
        cookies: String,
        visitorData: String,
        poToken: String
    ): JSONObject {
        val body = JSONObject()
            .put("context", contextJson(client, visitorData))
            .put("videoId", videoId)
        return post("next", client, body, cookies, visitorData, poToken) ?: JSONObject()
    }

    /** Ordered radio/watch-next panels → tracks (junk-gated). */
    internal fun parseRadioPanels(root: JSONObject, seedId: String, max: Int): List<YtTrack> {
        // next → contents.twoColumnWatchNextResults.playlist.playlist.contents[]
        // each with playlistPanelVideoRenderer (videoId/title/shortByline).
        val out = ArrayList<YtTrack>()
        val seen = HashSet<String>()
        val panels = ArrayList<JSONObject>()
        collectRenderers(root, "playlistPanelVideoRenderer", panels)
        for (p in panels) {
            try {
                val vid = p.optString("videoId", "").takeIf { it.length == 11 } ?: continue
                if (vid == seedId) continue
                try {
                    val nav = p.optJSONObject("navigationEndpoint")
                    if (nav != null && (nav.has("reelEndpoint") || nav.has("reelWatchEndpoint"))) continue
                } catch (e: Exception) {
                }
                val title = runsText(p.optJSONObject("title")) ?: continue
                if (title.isBlank()) continue
                val artist = runsText(p.optJSONObject("shortBylineText"))?.takeIf { it.isNotBlank() } ?: "YouTube"
                if (isMusicJunk(title, artist)) continue
                // Panel lengthText "4:12" gates hour-long mixes/junk.
                try {
                    val len = runsText(p.optJSONObject("lengthText")) ?: ""
                    val m = Regex("""^(?:(\d+):)?([0-5]?\d):([0-5]\d)$""").find(len.trim())
                    if (m != null) {
                        val s = (m.groupValues[1].toLongOrNull() ?: 0L) * 3600 +
                            (m.groupValues[2].toLongOrNull() ?: 0L) * 60 +
                            (m.groupValues[3].toLongOrNull() ?: 0L)
                        if (s !in 30L..600L) continue
                    }
                } catch (e: Exception) {
                }
                var thumb = ""
                try {
                    val arr = p.optJSONObject("thumbnail")?.optJSONArray("thumbnails")
                    if (arr != null && arr.length() > 0) thumb = arr.optJSONObject(arr.length() - 1)?.optString("url") ?: ""
                } catch (e: Exception) {
                }
                if (seen.add(vid)) out.add(YtTrack(vid, title, artist, sharpThumb(thumb), "https://www.youtube.com/watch?v=$vid"))
                if (out.size >= max) break
            } catch (e: Exception) {
            }
        }
        return out
    }
}
