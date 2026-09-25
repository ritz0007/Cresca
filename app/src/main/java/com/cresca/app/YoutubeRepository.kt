package com.cresca.app

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.MediaFormat
import org.schabi.newpipe.extractor.Page
import org.schabi.newpipe.extractor.ServiceList.YouTube
import org.schabi.newpipe.extractor.channel.ChannelInfoItem
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.feed.FeedInfo
import org.schabi.newpipe.extractor.kiosk.KioskInfo
import org.schabi.newpipe.extractor.localization.Localization
import org.schabi.newpipe.extractor.search.SearchInfo
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import org.schabi.newpipe.extractor.stream.VideoStream

data class YtTrack(
    val id: String,
    val title: String,
    val artist: String,
    val thumbUrl: String,
    val watchUrl: String,
    val localPath: String = ""
)

/**
 * Songs + music videos ONLY. Drops podcast/TV episodes, trailers, Shorts
 * and other non-music clutter by title/artist shape. Shared by the NewPipe
 * mappers here and the InnerTube parsers (same module, internal).
 */
internal fun isMusicJunk(title: String, artist: String): Boolean {
    return try {
        val t = title.lowercase()
        val a = artist.lowercase().trim()
        // Episode-shaped titles: "Mohini Episode 12", "Ep. 5", "S01E03".
        if (Regex("""\b(ep|episode|eps)\b[\s._:#-]{0,4}\d+""").containsMatchIn(t)) return true
        if (Regex("""\bs\d{1,2}\s?e\d{1,3}\b""").containsMatchIn(t)) return true
        // Non-music first segments: podcast/trailer/teaser/episode uploads.
        if (a in setOf("episode", "episodes", "podcast", "podcasts", "trailer", "trailers", "teaser", "shorts")) return true
        if (t.contains("full episode") || t.contains("episode recap")) return true
        false
    } catch (e: Exception) {
        false
    }
}

/** True for YouTube Shorts URLs (never songs-in-queue material). */
internal fun isShortsUrl(url: String): Boolean {
    return try {
        url.contains("/shorts/")
    } catch (e: Exception) {
        false
    }
}

/** OkHttp-backed downloader so NewPipeExtractor can fetch YouTube pages. */
private class OkHttpDownloader(private val client: OkHttpClient) : Downloader() {
    override fun execute(request: Request): Response {
        val builder = okhttp3.Request.Builder().url(request.url())
        for ((k, vs) in request.headers()) {
            for (v in vs) builder.addHeader(k, v)
        }
        // Carry the login session when present.
        try {
            val ck = YoutubeRepository.sessionCookies()
            if (ck.isNotBlank()) builder.addHeader("Cookie", ck)
        } catch (e: Exception) {
        }
        val data = request.dataToSend()
        if (data != null) {
            builder.post(data.toRequestBody("application/json".toMediaTypeOrNull()))
        } else if (request.httpMethod() == "POST") {
            builder.post(ByteArray(0).toRequestBody(null))
        } else {
            builder.get()
        }
        client.newCall(builder.build()).execute().use { resp ->
            return Response(
                resp.code,
                resp.message,
                resp.headers.toMultimap(),
                resp.body?.string() ?: "",
                request.url()
            )
        }
    }
}

object YoutubeRepository {
    private const val TAG = "YoutubeRepo"
    // Tuned for instant fetches: short fail-fast timeouts (slow networks
    // retry quickly instead of hanging 25s), shared pool + higher per-host
    // concurrency so parallel rails don't queue behind each other.
    // HTTP/2 + keep-alive reuses TLS sessions across search/player calls.
    private val dispatcher = okhttp3.Dispatcher().apply {
        maxRequests = 64
        maxRequestsPerHost = 16
    }
    private val pool = okhttp3.ConnectionPool(12, 5, java.util.concurrent.TimeUnit.MINUTES)
    private val http = okhttp3.OkHttpClient.Builder()
        .dispatcher(dispatcher)
        .connectionPool(pool)
        .protocols(listOf(okhttp3.Protocol.HTTP_2, okhttp3.Protocol.HTTP_1_1))
        .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(12, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(12, java.util.concurrent.TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    /** Elapsed-ms helper for fetch timing logs (Phase 0 baseline). */
    private inline fun <T> timed(tag: String, block: () -> T): T {
        val t0 = android.os.SystemClock.elapsedRealtime()
        try {
            return block()
        } finally {
            try {
                Log.d(TAG, "$tag ${android.os.SystemClock.elapsedRealtime() - t0}ms")
            } catch (e: Exception) {
            }
        }
    }

    @Volatile private var ready = false
    @Volatile private var appContext: Context? = null

    /**
     * InnerTube fast path (default ON; Stable available in Profile).
     * true → try on-device youtubei/v1 first, fall back to NewPipeExtractor
     * on empty/failure. Every fast call logs `via InnerTube` with ms so
     * field timings prove the win; fallback logs the reason.
     */
    @Volatile var useInnerTube: Boolean = true

    // Resolved stream URLs, good for hours. Hits make replays instant.
    // Memory (5h) fronted by a disk snapshot (6h): process restarts and
    // song picks from search/charts resolve without any network when fresh.
    private const val URL_TTL_MS = 5 * 60 * 60 * 1000L
    private const val URL_DISK_TTL_MS = 6 * 60 * 60 * 1000L
    private const val URL_DISK_FILE = "yt_urls.json"
    private val urlCache = java.util.concurrent.ConcurrentHashMap<String, Pair<String, Long>>()
    private val videoOptsCache =
        java.util.concurrent.ConcurrentHashMap<String, Pair<List<VideoOption>, Long>>()
    private val urlDiskScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var lastUrlDiskSave = 0L

    private fun rememberUrl(watchUrl: String, url: String) {
        try {
            urlCache[watchUrl] = Pair(url, System.currentTimeMillis())
        } catch (e: Exception) {
        }
        // Throttled disk snapshot (≤1 write/30s) so hot paths stay cheap.
        try {
            val now = System.currentTimeMillis()
            if (now - lastUrlDiskSave < 30_000L) return
            lastUrlDiskSave = now
            val ctx = appContext ?: return
            val snap = try {
                HashMap(urlCache)
            } catch (e: Exception) {
                return
            }
            urlDiskScope.launch {
                try {
                    val root = org.json.JSONObject()
                    root.put("savedAt", now)
                    val items = org.json.JSONObject()
                    for ((k, v) in snap) {
                        try {
                            // Skip already-stale rows at write time.
                            if (now - v.second > URL_DISK_TTL_MS) continue
                            items.put(k, org.json.JSONObject().put("u", v.first).put("t", v.second))
                        } catch (e: Exception) {
                        }
                    }
                    root.put("items", items)
                    java.io.File(ctx.cacheDir, URL_DISK_FILE).writeText(root.toString())
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
        }
    }

    private fun loadUrlDisk() {
        val ctx = appContext ?: return
        try {
            val f = java.io.File(ctx.cacheDir, URL_DISK_FILE)
            if (!f.exists()) return
            val root = org.json.JSONObject(f.readText())
            val items = root.optJSONObject("items") ?: return
            val now = System.currentTimeMillis()
            var n = 0
            val keys = items.keys()
            while (keys.hasNext()) {
                try {
                    val k = keys.next()
                    val o = items.optJSONObject(k) ?: continue
                    val t = o.optLong("t", 0L)
                    if (now - t > URL_DISK_TTL_MS) continue
                    val u = o.optString("u", "")
                    if (u.isBlank()) continue
                    urlCache.putIfAbsent(k, Pair(u, t))
                    n++
                } catch (e: Exception) {
                }
            }
            Log.d(TAG, "urlCache disk restored $n rows")
        } catch (e: Exception) {
        }
    }

    /** Best-effort TLS/DNS warmup so the first tap reuses a live connection. */
    private fun prewarmConnection() {
        try {
            val req = okhttp3.Request.Builder()
                .url("https://music.youtube.com/")
                .header("User-Agent", "Cresca/1.0 (Android)")
                .get()
                .build()
            http.newCall(req).enqueue(object : okhttp3.Callback {
                override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {}
                override fun onResponse(call: okhttp3.Call, resp: okhttp3.Response) {
                    try {
                        resp.close()
                    } catch (e: Exception) {
                    }
                }
            })
        } catch (e: Exception) {
        }
    }

    fun initAppContext(ctx: Context) {
        appContext = ctx.applicationContext
        // Disk urlCache (cold starts aren't cold) + connection pre-warm
        // (first tap skips DNS/TLS handshake). Fire-and-forget, never throws.
        urlDiskScope.launch {
            try {
                loadUrlDisk()
            } catch (e: Exception) {
            }
            try {
                prewarmConnection()
            } catch (e: Exception) {
            }
        }
    }

    internal fun sessionCookies(): String {
        val c = appContext ?: return ""
        return try {
            YtSessionManager.loadCookies(c)
        } catch (e: Exception) {
            ""
        }
    }

    private fun sessionVisitor(): String {
        val c = appContext ?: return ""
        return try {
            YtSessionManager.loadVisitorData(c)
        } catch (e: Exception) {
            ""
        }
    }

    private fun sessionPoToken(): String {
        val c = appContext ?: return ""
        return try {
            YtSessionManager.loadPoToken(c)
        } catch (e: Exception) {
            ""
        }
    }

    private fun innerTubeAllowed(): Boolean {
        if (!useInnerTube) return false
        val c = appContext ?: return true
        return try {
            YtSessionManager.canFetchInnerTube(c)
        } catch (e: Exception) {
            true
        }
    }

    /** As-you-type suggestions (fast path only; empty in stable mode). */
    suspend fun suggestions(input: String): List<String> =
        withContext(Dispatchers.IO) {
            if (!innerTubeAllowed()) return@withContext emptyList()
            if (input.trim().length < 2) return@withContext emptyList()
            try {
                com.cresca.app.innertube.InnerTubeApi.suggestions(
                    input, sessionCookies(), sessionVisitor()
                )
            } catch (e: Exception) {
                emptyList()
            }
        }

    /**
     * Logged-in library pull (YT liked songs + history) for taste seeds.
     * Authed browse (cookies + SAPISIDHASH ride along); empty when logged
     * out or on any failure. Caller persists + feeds recommendation seeds —
     * never merges into local liked/recent.
     */
    suspend fun ytLibrary(max: Int = 50): Pair<List<YtTrack>, List<YtTrack>> =
        withContext(Dispatchers.IO) {
            val c = appContext ?: return@withContext Pair(emptyList(), emptyList())
            val cookies = try {
                YtSessionManager.loadCookies(c)
            } catch (e: Exception) {
                ""
            }
            if (!YtSessionManager.isLoggedIn(c)) return@withContext Pair(emptyList(), emptyList())
            val visitor = sessionVisitor()
            val po = sessionPoToken()
            val liked = try {
                com.cresca.app.innertube.InnerTubeApi.browseShelves(
                    "FEmusic_liked", cookies, visitor, po, maxShelves = 4, perShelf = 25
                ).values.flatten().distinctBy { it.id }.take(max)
            } catch (e: Exception) {
                Log.d(TAG, "yt liked pull failed: ${e.message}")
                emptyList()
            }
            val history = try {
                com.cresca.app.innertube.InnerTubeApi.browseShelves(
                    "FEmusic_history", cookies, visitor, po, maxShelves = 4, perShelf = 25
                ).values.flatten().distinctBy { it.id }.take(max)
            } catch (e: Exception) {
                Log.d(TAG, "yt history pull failed: ${e.message}")
                emptyList()
            }
            Log.i(TAG, "yt library: ${liked.size} liked, ${history.size} history")
            Pair(liked, history)
        }

    /**
     * One-call home shelves (FEmusic_home). Returns shelf title → tracks,
     * empty on failure (caller keeps existing rails logic as fallback).
     */
    suspend fun homeShelves(maxShelves: Int = 8, perShelf: Int = 12): Map<String, List<YtTrack>> =
        withContext(Dispatchers.IO) {
            if (!innerTubeAllowed()) return@withContext emptyMap()
            try {
                com.cresca.app.innertube.InnerTubeApi.browseShelves(
                    "FEmusic_home", sessionCookies(), sessionVisitor(), sessionPoToken(),
                    maxShelves = maxShelves, perShelf = perShelf
                )
            } catch (e: Exception) {
                Log.d(TAG, "homeShelves failed: ${e.message}")
                emptyMap()
            }
        }

    @Synchronized
    fun ensureInit() {
        if (!ready) {
            NewPipe.init(OkHttpDownloader(http), Localization("en", "US"))
            ready = true
        }
    }

    /**
     * Songs only: drops playlists-channels-compilations.
     * Keeps single videos <= 10 min (official songs, lyric videos);
     * drops 50-min jukeboxes, mixes, lives and hour-long uploads.
     * Fetches extra, then filters, so the list stays full.
     */
    suspend fun searchSongs(query: String, max: Int = 15): List<YtTrack> =
        withContext(Dispatchers.IO) {
            val t0 = android.os.SystemClock.elapsedRealtime()
            // Fast path: youtubei/v1 search (WEB_REMIX), fallback to scrape.
            if (innerTubeAllowed()) {
                try {
                    val fast = com.cresca.app.innertube.InnerTubeApi.searchMusic(
                        query, max + 10, sessionCookies(), sessionVisitor(), sessionPoToken()
                    )
                    if (fast.isNotEmpty()) {
                        return@withContext fast.distinctBy { it.id }.take(max)
                            .also {
                                try {
                                    Log.d(TAG, "searchSongs '$query' ${it.size} hits ${android.os.SystemClock.elapsedRealtime() - t0}ms via InnerTube")
                                } catch (e: Exception) {
                                }
                            }
                    }
                    Log.d(TAG, "searchSongs InnerTube empty, falling back to NewPipe")
                } catch (e: Exception) {
                    Log.d(TAG, "searchSongs InnerTube failed, fallback: ${e.message}")
                }
            }
            ensureInit()
            val qh = YouTube.searchQHFactory.fromQuery(query)
            val items = SearchInfo.getInfo(YouTube, qh).relatedItems
            items.filterIsInstance<StreamInfoItem>()
                // Songs only, strict: known duration 30s-10min. Unknown-length
                // uploads are compilations/lives/episodes far more often than
                // songs, and they were the "Mohini episodes" leak.
                .filter { item ->
                    val d = try { item.duration } catch (e: Exception) { 0L }
                    d in 30L..600L
                }
                .take(max + 10).mapNotNull { item ->
                    try {
                        if (isShortsUrl(item.url)) return@mapNotNull null
                        val id = Regex("[?&]v=([A-Za-z0-9_-]{11})")
                            .find(item.url)?.groupValues?.get(1) ?: return@mapNotNull null
                        val thumb = item.thumbnails.maxByOrNull { it.height }?.url ?: ""
                        val artist = item.uploaderName ?: "YouTube"
                        if (isMusicJunk(item.name, artist)) return@mapNotNull null
                        YtTrack(
                            id = id,
                            title = item.name,
                            artist = artist,
                            thumbUrl = thumb,
                            watchUrl = item.url
                        )
                    } catch (e: Exception) {
                        Log.w(TAG, "skip item", e)
                        null
                    }
                }
                // Duplicate ids crash keyed lazy lists: drop them here.
                .distinctBy { it.id }
                .take(max)
                .also {
                    try {
                        Log.d(TAG, "searchSongs '$query' ${it.size} hits ${android.os.SystemClock.elapsedRealtime() - t0}ms")
                    } catch (e: Exception) {
                    }
                }
        }

    /** Real YouTube search. Throws on network/parse failure (caller falls back to demo). */
    suspend fun search(query: String, max: Int = 15): List<YtTrack> =
        searchSongs(query, max)

    // ---- YT Music style discovery (SimpMusic-shaped, NewPipe-powered) ----

    /** One search hit -> track, or null. Shared by every discovery source. */
    private fun toTrack(item: StreamInfoItem): YtTrack? {
        return try {
            // Shorts + episodes/trailer junk never enter any list.
            try {
                if (isShortsUrl(item.url)) return null
            } catch (e: Exception) {
            }
            // Lives/upcoming/episode streams are never songs.
            try {
                if (item.streamType == org.schabi.newpipe.extractor.stream.StreamType.LIVE_STREAM) return null
            } catch (e: Exception) {
            }
            val d = try {
                item.duration
            } catch (e: Exception) {
                0L
            }
            // Songs only, strict: known duration 30s-10min. Unknown-length
            // uploads are compilations/lives/episodes far more often than
            // songs (the "Mohini episodes" leak).
            if (d !in 30L..600L) return null
            val id = Regex("[?&]v=([A-Za-z0-9_-]{11})")
                .find(item.url)?.groupValues?.get(1) ?: return null
            val thumb = try {
                val raw = item.thumbnails.maxByOrNull { it.height }?.url ?: ""
                // YTM serves =w120 thumbs: upscale at parse so cards are sharp.
                com.cresca.app.innertube.InnerTubeApi.sharpThumb(raw)
            } catch (e: Exception) {
                ""
            }
            val artist = try {
                item.uploaderName ?: "YouTube"
            } catch (e: Exception) {
                "YouTube"
            }
            if (isMusicJunk(item.name, artist)) return null
            YtTrack(
                id = id,
                title = item.name,
                artist = artist,
                thumbUrl = thumb,
                watchUrl = item.url
            )
        } catch (e: Exception) {
            Log.w(TAG, "skip item", e)
            null
        }
    }

    /**
     * YouTube Music song search (music.youtube.com, like YT Music / SimpMusic
     * shelves). Returns cleaner artist/title pairs than plain YouTube search.
     */
    suspend fun searchMusic(query: String, max: Int = 15): List<YtTrack> =
        withContext(Dispatchers.IO) {
            val t0 = android.os.SystemClock.elapsedRealtime()
            if (innerTubeAllowed()) {
                try {
                    val fast = com.cresca.app.innertube.InnerTubeApi.searchMusic(
                        query, max, sessionCookies(), sessionVisitor(), sessionPoToken()
                    )
                    if (fast.isNotEmpty()) {
                        return@withContext fast.distinctBy { it.id }.take(max)
                            .also {
                                try {
                                    Log.d(TAG, "searchMusic '$query' ${it.size} hits ${android.os.SystemClock.elapsedRealtime() - t0}ms via InnerTube")
                                } catch (e: Exception) {
                                }
                            }
                    }
                    Log.d(TAG, "searchMusic InnerTube empty, falling back to NewPipe")
                } catch (e: Exception) {
                    Log.d(TAG, "searchMusic InnerTube failed, fallback: ${e.message}")
                }
            }
            ensureInit()
            val qh = YouTube.searchQHFactory.fromQuery(
                query, listOf("music_songs"), ""
            )
            val info = SearchInfo.getInfo(YouTube, qh)
            info.relatedItems.filterIsInstance<StreamInfoItem>()
                .mapNotNull { toTrack(it) }
                .distinctBy { it.id }
                .take(max)
                .also {
                    try {
                        Log.d(TAG, "searchMusic '$query' ${it.size} hits ${android.os.SystemClock.elapsedRealtime() - t0}ms")
                    } catch (e: Exception) {
                    }
                }
        }

    /** YouTube Charts trending music. Fast path: browse FEmusic_charts shelves. */
    suspend fun trendingMusic(max: Int = 15): List<YtTrack> =
        withContext(Dispatchers.IO) {
            if (innerTubeAllowed()) {
                try {
                    val shelves = com.cresca.app.innertube.InnerTubeApi.browseShelves(
                        "FEmusic_charts", sessionCookies(), sessionVisitor(), sessionPoToken(),
                        maxShelves = 3, perShelf = max
                    )
                    val flat = shelves.values.flatten().distinctBy { it.id }.take(max)
                    if (flat.isNotEmpty()) {
                        Log.d(TAG, "trending ${flat.size} via InnerTube charts")
                        return@withContext flat
                    }
                    Log.d(TAG, "trending InnerTube empty, falling back to kiosk")
                } catch (e: Exception) {
                    Log.d(TAG, "trending InnerTube failed, fallback: ${e.message}")
                }
            }
            ensureInit()
            try {
                val extractor = YouTube.getKioskList().getExtractorById("trending_music", null)
                extractor.fetchPage()
                val info = KioskInfo.getInfo(extractor)
                info.relatedItems.filterIsInstance<StreamInfoItem>()
                    .mapNotNull { toTrack(it) }
                    .distinctBy { it.id }
                    .take(max)
            } catch (e: Exception) {
                Log.w(TAG, "trending failed", e)
                emptyList()
            }
        }

    /**
     * True new releases: latest uploads from the artists' own channels
     * (channel feeds are newest-first), round-robin interleaved.
     * Falls back to a "new songs" music search when the library is empty.
     */
    suspend fun newReleases(artists: List<String>, max: Int = 12): List<YtTrack> =
        withContext(Dispatchers.IO) {
            ensureInit()
            val seeds = artists.map { it.trim() }
                .filter { it.isNotEmpty() && !it.equals("YouTube", true) }
                .distinct()
                .take(3)
            if (seeds.isEmpty()) {
                return@withContext try {
                    searchMusic("new hindi songs 2026", max)
                } catch (e: Exception) {
                    emptyList()
                }
            }
            try {
                val perArtist: List<List<YtTrack>> = coroutineScope {
                    seeds.map { artist ->
                        async(Dispatchers.IO) {
                            try {
                                val aqh = YouTube.searchQHFactory.fromQuery(
                                    artist, listOf("music_artists"), ""
                                )
                                val ainfo = SearchInfo.getInfo(YouTube, aqh)
                                val chan = ainfo.relatedItems
                                    .filterIsInstance<ChannelInfoItem>()
                                    .firstOrNull() ?: return@async emptyList<YtTrack>()
                                val feed = FeedInfo.getInfo(YouTube, chan.url)
                                feed.relatedItems.filterIsInstance<StreamInfoItem>()
                                    .mapNotNull { toTrack(it) }
                                    .distinctBy { it.id }
                                    .take(5)
                            } catch (e: Exception) {
                                Log.w(TAG, "artist feed failed ($artist)", e)
                                emptyList()
                            }
                        }
                    }.awaitAll()
                }
                // Round-robin interleave keeps every artist represented.
                val out = ArrayList<YtTrack>(max)
                val seen = HashSet<String>()
                var round = 0
                var progress = true
                while (out.size < max && progress) {
                    progress = false
                    for (list in perArtist) {
                        val t = list.getOrNull(round) ?: continue
                        if (seen.add(t.id)) {
                            out.add(t)
                            progress = true
                            if (out.size >= max) break
                        }
                    }
                    round++
                }
                if (out.isNotEmpty()) out
                else searchMusic("new hindi songs 2026", max)
            } catch (e: Exception) {
                Log.w(TAG, "newReleases failed", e)
                try {
                    searchMusic("new hindi songs 2026", max)
                } catch (e2: Exception) {
                    emptyList()
                }
            }
        }

    /**
     * Curated playlist rail (e.g. the user's Released playlist): one
     * PlaylistInfo fetch, same song gates as everything else (duration,
     * junk, distinct). Empty on failure (caller keeps old rail).
     */
    suspend fun playlistTracks(playlistId: String, max: Int = 25): List<YtTrack> =
        withContext(Dispatchers.IO) {
            val t0 = android.os.SystemClock.elapsedRealtime()
            ensureInit()
            try {
                val info = org.schabi.newpipe.extractor.playlist.PlaylistInfo.getInfo(
                    YouTube, "https://www.youtube.com/playlist?list=$playlistId"
                )
                info.relatedItems.filterIsInstance<StreamInfoItem>()
                    .mapNotNull { toTrack(it) }
                    .distinctBy { it.id }
                    .take(max)
                    .also {
                        try {
                            Log.d(TAG, "playlist $playlistId ${it.size} tracks ${android.os.SystemClock.elapsedRealtime() - t0}ms")
                        } catch (e: Exception) {
                        }
                    }
            } catch (e: Exception) {
                Log.w(TAG, "playlist failed ($playlistId)", e)
                emptyList()
            }
        }

    /** "Because you listened" mix: fast path via next endpoint, fallback to extractor. */
    suspend fun relatedTracks(watchUrl: String, max: Int = 12): List<YtTrack> =
        withContext(Dispatchers.IO) {
            val id = Regex("[?&]v=([A-Za-z0-9_-]{11})")
                .find(watchUrl)?.groupValues?.get(1) ?: return@withContext emptyList()
            if (innerTubeAllowed()) {
                try {
                    val fast = com.cresca.app.innertube.InnerTubeApi.related(
                        id, max, sessionCookies(), sessionVisitor(), sessionPoToken()
                    )
                    if (fast.isNotEmpty()) return@withContext fast
                    Log.d(TAG, "related InnerTube empty for $id, falling back")
                } catch (e: Exception) {
                    Log.d(TAG, "related InnerTube failed, fallback: ${e.message}")
                }
            }
            ensureInit()
            try {
                // Related extraction is reliable on www URLs; music URLs
                // carry the same video id (reuses `id` above).
                val se = YouTube.getStreamExtractor("https://www.youtube.com/watch?v=$id")
                se.fetchPage()
                val out = (se.relatedStreams?.items ?: emptyList())
                    .filterIsInstance<StreamInfoItem>()
                    .mapNotNull { toTrack(it) }
                    .distinctBy { it.id }
                    .take(max)
                if (out.isEmpty()) Log.w(TAG, "related empty for $id")
                out
            } catch (e: Exception) {
                Log.w(TAG, "related failed", e)
                emptyList()
            }
        }

    /**
     * BitChord-style autoplay: the related graph (RDAMVM/co-listen) IS the
     * queue. Hard rules that killed the "Mohini episodes" bug:
     *  - same-NAME tracks dropped outright (title-matching is never vibe)
     *  - max 2 tracks per artist (no singer loops, seed artist included)
     *  - no title-word vibe searches (they re-imported the junk)
     * One artist-radio filler only when the graph is thin.
     */
    suspend fun autoplayFor(t: YtTrack, max: Int = 20): List<YtTrack> =
        withContext(Dispatchers.IO) {
            ensureInit()
            val rel = try {
                relatedTracks(t.watchUrl, max + 10)
            } catch (e: Exception) {
                emptyList()
            }
            // Hard pass: seed itself + same-name echoes are never queue.
            val clean = ArrayList<YtTrack>()
            val artistCount = HashMap<String, Int>()
            for (c in rel) {
                if (c.id == t.id || isSameName(c, t)) continue
                val key = c.artist.lowercase()
                val n = (artistCount[key] ?: 0) + 1
                if (n > 2) continue
                artistCount[key] = n
                clean.add(c)
                if (clean.size >= max) break
            }
                if (clean.size >= max / 2) {
                    return@withContext clean.take(max)
                        .also { Log.i(TAG, "autoplay ${it.size} related (clean)") }
                }
            // Thin graph: ONE artist-radio filler, same hard rules.
            try {
                val low = t.artist.lowercase()
                val labelish = low.isBlank() || low == "youtube" ||
                    low == "song" || low == "songs" ||
                    low == "episode" || low == "episodes" || low == "podcast" ||
                    low.contains("music") || low.contains("official") ||
                    low.contains("films") || low.contains("records")
                if (!labelish) {
                    val extra = searchMusic("${t.artist} songs", 10)
                    for (h in extra) {
                        if (clean.size >= max) break
                        if (h.id == t.id || isSameName(h, t)) continue
                        if (clean.any { it.id == h.id }) continue
                        val key = h.artist.lowercase()
                        val n = (artistCount[key] ?: 0) + 1
                        if (n > 2) continue
                        artistCount[key] = n
                        clean.add(h)
                    }
                }
            } catch (e: Exception) {
            }
            // Order: related-graph first, mood overlap next, clumps sunk.
            val relIds = try {
                rel.map { it.id }.toSet()
            } catch (e: Exception) {
                emptySet()
            }
            val ranked = try {
                rankByVibe(t, clean, relIds)
            } catch (e: Exception) {
                clean
            }
            ranked.distinctBy { it.id }.filter { it.id != t.id }.take(max)
                .also { Log.i(TAG, "autoplay ${rel.size} related -> ${it.size} clean") }
        }

    /** Vibe queries from a track: title keywords + mood words, no artist. */
    internal fun vibeQueries(t: YtTrack): List<String> {
        return try {
            var title = t.title.lowercase()
            // Strip video-type noise (official/video/lyric/visualizer/etc).
            title = title.replace(
                Regex("""[\(\[].*?(official|video|audio|lyric|visualizer|mv|m\/v|teaser|trailer).*?[\)\]]"""),
                " "
            )
            title = title.replace(Regex("""\s+[|｜].*$"""), " ")
            val dash = title.indexOf(" - ")
            if (dash >= 3) title = title.substring(0, dash)
            title = title.replace(Regex("""[^a-z0-9 ]"""), " ")
            val words = title.split(Regex("""\s+"""))
                .map { it.trim() }.filter { it.length > 3 }
                .filterNot { it in setOf("official", "video", "audio", "lyrics", "song", "songs", "full", "hd", "with") }
                .distinct().take(4)
            val mood = detectMood(t.title + " " + t.artist)
            val out = ArrayList<String>()
            // Mood first: broad vibe pool (title echo comes later and its
            // same-name hits are dropped downstream anyway).
            if (mood != null) out.add("$mood hindi songs")
            if (words.size >= 2) out.add((words.take(3) + (mood?.let { listOf(it) } ?: emptyList())).joinToString(" ") + " songs")
            if (words.isNotEmpty() && mood != null) out.add(words.take(2).joinToString(" ") + " $mood")
            else if (words.isNotEmpty()) out.add(words.take(2).joinToString(" ") + " songs")
            out.distinct().take(3)
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun detectMood(text: String): String? {
        return try {
            val low = text.lowercase()
            when {
                low.contains("love") || low.contains("romantic") || low.contains("dil") -> "romantic"
                low.contains("party") || low.contains("dance") || low.contains("club") -> "party"
                low.contains("lofi") || low.contains("chill") || low.contains("slow") -> "lofi"
                low.contains("workout") || low.contains("gym") || low.contains("motivat") -> "workout"
                low.contains("sad") || low.contains("dard") || low.contains("bewafa") -> "sad"
                low.contains("punjabi") || low.contains("bhangra") -> "punjabi"
                else -> null
            }
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Same-name test: normalized titles equal, or one title's distinctive
     * core sits inside the other ("Diamond" vs "Diamond (Official Video)").
     * Same-name hits are title-matches, never vibe — dropped from search
     * filler and sunk in ranking.
     */
    internal fun isSameName(a: YtTrack, b: YtTrack): Boolean {
        return try {
            fun norm(t: String): List<String> {
                var s = t.lowercase()
                    .replace(Regex("""[\(\[].*?[\)\]]"""), " ")
                // "Song - Movie" suffixes go before punctuation is stripped
                // (stripping first would erase the " - " separator itself).
                val dash = s.indexOf(" - ")
                if (dash >= 3) s = s.substring(0, dash)
                s = s.replace(Regex("""[^a-z0-9 ]"""), " ")
                return s.split(Regex("""\s+"""))
                    .map { it.trim() }
                    .filter { it.length > 2 }
                    .filterNot {
                        it in setOf(
                            "official", "video", "audio", "lyrics", "lyric",
                            "song", "songs", "full", "visualizer", "the"
                        )
                    }
            }
            val aw = norm(a.title)
            val bw = norm(b.title)
            if (aw.isEmpty() || bw.isEmpty()) return false
            if (aw == bw) return true
            // Containment needs a 2+ word core: a lone shared word like
            // "Diamond" in "Diamond Eyes" is a different song, not an echo.
            val core = if (aw.size <= bw.size) aw else bw
            val other = if (aw.size <= bw.size) bw else aw
            return core.size >= 2 && core.all { it in other }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Score pool by vibe: related-graph tracks first (true co-listen vibe),
     * same mood next, artist variety over clumps, same-NAME sunk hard.
     * Title-word overlap is deliberately NOT scored — it queues every song
     * called "Diamond" instead of songs that feel like Diamond.
     */
    internal fun rankByVibe(
        seed: YtTrack,
        pool: List<YtTrack>,
        relatedIds: Set<String> = emptySet()
    ): List<YtTrack> {
        return try {
            val seedMood = try {
                detectMood(seed.title + " " + seed.artist)
            } catch (e: Exception) {
                null
            }
            val seedArtist = seed.artist.lowercase()
            val rnd = java.util.Random(System.currentTimeMillis())
            pool.map { c ->
                var s = 0
                if (c.id in relatedIds) s += 5
                if (isSameName(c, seed)) s -= 8
                try {
                    val cm = detectMood(c.title + " " + c.artist)
                    if (seedMood != null && cm == seedMood) s += 4
                } catch (e: Exception) {
                }
                // Variety wins: same-artist clumps sunk, fresh voices up.
                if (c.artist.lowercase() == seedArtist) s -= 3
                else if (c.artist.lowercase().contains(seedArtist.take(5)) && seedArtist.length > 5) s -= 2
                else s += 1
                Pair(s, c)
            }.sortedWith(compareByDescending<Pair<Int, YtTrack>> { it.first }
                .thenBy { rnd.nextInt() })
                .map { it.second }
        } catch (e: Exception) {
            pool.shuffled()
        }
    }

    /** Common type for endless See All pagers (search + kiosk). */
    interface EndlessPager {
        val exhausted: Boolean
        suspend fun loadMore(): List<YtTrack>
    }

    /**
     * Endless search pager for See All full pages: keeps the query handler +
     * continuation, appends page after page (SimpMusic continuation pattern).
     */
    class SearchPager(
        val query: String,
        val music: Boolean = true,
        val pageSize: Int = 20
    ) : EndlessPager {
        private var handler: org.schabi.newpipe.extractor.linkhandler.SearchQueryHandler? = null
        private var next: Page? = null
        private var started = false
        val seen: MutableSet<String> = HashSet()
        @Volatile override var exhausted: Boolean = false
            private set

        override suspend fun loadMore(): List<YtTrack> = withContext(Dispatchers.IO) {
            ensureInit()
            if (exhausted) return@withContext emptyList()
            try {
                val qh = handler ?: YouTube.searchQHFactory.fromQuery(
                    query,
                    if (music) listOf("music_songs") else emptyList(),
                    ""
                ).also { handler = it }
                val items: List<StreamInfoItem>
                val np: Page?
                if (!started) {
                    val info = SearchInfo.getInfo(YouTube, qh)
                    items = info.relatedItems.filterIsInstance<StreamInfoItem>()
                    np = try {
                        if (info.hasNextPage()) info.nextPage else null
                    } catch (e: Exception) {
                        null
                    }
                    started = true
                } else {
                    val p = next ?: run {
                        exhausted = true
                        return@withContext emptyList()
                    }
                    val page = SearchInfo.getMoreItems(YouTube, qh, p)
                    items = page.items.filterIsInstance<StreamInfoItem>()
                    np = try {
                        if (page.hasNextPage()) page.nextPage else null
                    } catch (e: Exception) {
                        null
                    }
                }
                next = np
                if (np == null) exhausted = true
                items.mapNotNull { toTrack(it) }
                    .filter { seen.add(it.id) }
                    .take(pageSize)
                    .also { if (it.isEmpty() && np == null) exhausted = true }
            } catch (e: Exception) {
                Log.w(TAG, "search page failed", e)
                emptyList()
            }
        }
    }

    /**
     * Endless charts pager for the Charts See All page.
     */
    class KioskPager(
        val kioskId: String = "trending_music",
        val pageSize: Int = 20
    ) : EndlessPager {
        private var extractor: org.schabi.newpipe.extractor.kiosk.KioskExtractor<*>? = null
        private var next: Page? = null
        private var started = false
        val seen: MutableSet<String> = HashSet()
        @Volatile override var exhausted: Boolean = false
            private set

        override suspend fun loadMore(): List<YtTrack> = withContext(Dispatchers.IO) {
            ensureInit()
            if (exhausted) return@withContext emptyList()
            try {
                val items: List<StreamInfoItem>
                val np: Page?
                if (!started) {
                    val ex = YouTube.getKioskList().getExtractorById(kioskId, null)
                    ex.fetchPage()
                    extractor = ex
                    val info = KioskInfo.getInfo(ex)
                    items = info.relatedItems.filterIsInstance<StreamInfoItem>()
                    np = try {
                        if (info.hasNextPage()) info.nextPage else null
                    } catch (e: Exception) {
                        null
                    }
                    started = true
                } else {
                    val ex = extractor ?: run {
                        exhausted = true
                        return@withContext emptyList()
                    }
                    val p = next ?: run {
                        exhausted = true
                        return@withContext emptyList()
                    }
                    val page = ex.getPage(p)
                    items = page.items.filterIsInstance<StreamInfoItem>()
                    np = try {
                        if (page.hasNextPage()) page.nextPage else null
                    } catch (e: Exception) {
                        null
                    }
                }
                next = np
                if (np == null) exhausted = true
                items.mapNotNull { toTrack(it) }
                    .filter { seen.add(it.id) }
                    .take(pageSize)
                    .also { if (it.isEmpty() && np == null) exhausted = true }
            } catch (e: Exception) {
                Log.w(TAG, "kiosk page failed", e)
                emptyList()
            }
        }
    }

    /** Ranked audio stream URLs, best first. Used for 403 fallback retries. */
    suspend fun audioUrls(watchUrl: String): List<String> =
        withContext(Dispatchers.IO) {
            val t0 = android.os.SystemClock.elapsedRealtime()
            // Fast path: player endpoint chain (MUSIC → VR → REMIX), then scrape.
            if (innerTubeAllowed()) {
                try {
                    val vid = Regex("[?&]v=([A-Za-z0-9_-]{11})")
                        .find(watchUrl)?.groupValues?.get(1)
                    if (!vid.isNullOrBlank()) {
                        val fast = com.cresca.app.innertube.InnerTubeApi.audioUrls(
                            vid, sessionCookies(), sessionVisitor(), sessionPoToken()
                        )
                        if (fast.isNotEmpty()) {
                            rememberUrl(watchUrl, fast.first())
                            try {
                                Log.d(TAG, "audioUrls ${fast.size} urls ${android.os.SystemClock.elapsedRealtime() - t0}ms via InnerTube")
                            } catch (e: Exception) {
                            }
                            return@withContext fast
                        }
                        Log.d(TAG, "audioUrls InnerTube empty, falling back to NewPipe")
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "audioUrls InnerTube failed, fallback: ${e.message}")
                }
            }
            ensureInit()
            try {
                val se = YouTube.getStreamExtractor(watchUrl)
                se.fetchPage()
                val ranked = se.audioStreams
                    .sortedByDescending { it.averageBitrate }
                    .mapNotNull {
                        try {
                            it.content
                        } catch (e: Exception) {
                            null
                        }
                    }
                    .filter { it.isNotBlank() }
                    .distinct()
                val best = ranked.firstOrNull()
                if (best != null) {
                    rememberUrl(watchUrl, best)
                }
                try {
                    Log.d(TAG, "audioUrls ${ranked.size} urls ${android.os.SystemClock.elapsedRealtime() - t0}ms")
                } catch (e: Exception) {
                }
                ranked
            } catch (e: Exception) {
                Log.e(TAG, "audioUrls failed", e)
                emptyList()
            }
        }

    /** Drops a stale cached URL (e.g. after a 403) so the next resolve refetches. */
    fun dropCachedUrl(watchUrl: String) {
        try {
            urlCache.remove(watchUrl)
        } catch (e: Exception) {
        }
    }

    /** Direct audio stream URL for Media3 ExoPlayer (handles signature decipher).
     * Single-flight: concurrent callers for the same track share one network
     * resolve (prime + prefetch + warm + UI used to pay 3-4x). */
    private val audioFlight =
        java.util.concurrent.ConcurrentHashMap<String, CompletableDeferred<String?>>()

    suspend fun audioUrl(watchUrl: String): String? {
        // Memory cache first: stream URLs stay valid for hours.
        try {
            val hit = urlCache[watchUrl]
            if (hit != null && System.currentTimeMillis() - hit.second < URL_TTL_MS) {
                return hit.first
            } else if (hit != null) {
                urlCache.remove(watchUrl)
            }
        } catch (e: Exception) {
        }
        // Join an in-flight resolve instead of starting a duplicate.
        val mine = CompletableDeferred<String?>()
        val existing = audioFlight.putIfAbsent(watchUrl, mine)
        if (existing != null) {
            return try {
                existing.await()
            } catch (e: Exception) {
                null
            }
        }
        try {
            val url = withContext(Dispatchers.IO) {
                ensureInit()
                audioUrls(watchUrl).firstOrNull()
            }
            try {
                mine.complete(url)
            } catch (e: Exception) {
            }
            return url
        } catch (e: Exception) {
            try {
                mine.complete(null)
            } catch (e2: Exception) {
            }
            return null
        } finally {
            try {
                audioFlight.remove(watchUrl, mine)
            } catch (e: Exception) {
            }
        }
    }

    /** Direct muxed (video+audio) progressive stream URL for Media3 ExoPlayer, capped at 720p. */
    suspend fun videoUrl(watchUrl: String): String? =
        withContext(Dispatchers.IO) {
            ensureInit()
            try {
                val se = YouTube.getStreamExtractor(watchUrl)
                se.fetchPage()
                val muxed = se.getVideoStreams().filter { !it.isVideoOnly() }
                val capped = muxed.filter { heightOf(it) <= 720 }
                val mp4 = (if (capped.isNotEmpty()) capped else muxed)
                    .filter { it.getFormat() == MediaFormat.MPEG_4 }
                val pool = when {
                    mp4.isNotEmpty() -> mp4
                    capped.isNotEmpty() -> capped
                    else -> muxed
                }
                val best: VideoStream? =
                    pool.maxWithOrNull(compareBy({ it.getBitrate() }, { heightOf(it) }))
                best?.getContent()
            } catch (e: Exception) {
                Log.e(TAG, "videoUrl failed", e)
                null
            }
        }

    /** One playable muxed quality level for the quality picker. */
    data class VideoOption(val url: String, val height: Int, val label: String)

    /** Credits-style details for the About card (Shazam-like). */
    data class VideoDetails(
        val views: Long,
        val likes: Long,
        val uploadDate: String,
        val description: String,
        val durationSec: Long,
        val dashUrl: String
    )

    private val detailsCache =
        java.util.concurrent.ConcurrentHashMap<String, VideoDetails>()

    suspend fun videoDetails(watchUrl: String): VideoDetails? =
        withContext(Dispatchers.IO) {
            ensureInit()
            try {
                detailsCache[watchUrl]?.let { return@withContext it }
            } catch (e: Exception) {
            }
            try {
                val se = YouTube.getStreamExtractor(watchUrl)
                se.fetchPage()
                var desc = ""
                try {
                    desc = se.description?.content ?: ""
                } catch (e: Exception) {
                }
                var dash = ""
                try {
                    dash = se.dashMpdUrl ?: ""
                } catch (e: Exception) {
                }
                var views = -1L
                try {
                    views = se.viewCount
                } catch (e: Exception) {
                }
                var likes = -1L
                try {
                    likes = se.likeCount
                } catch (e: Exception) {
                }
                var date = ""
                try {
                    date = se.textualUploadDate ?: ""
                } catch (e: Exception) {
                }
                var dur = -1L
                try {
                    dur = se.length
                } catch (e: Exception) {
                }
                val d = VideoDetails(views, likes, date, desc, dur, dash)
                try {
                    detailsCache[watchUrl] = d
                } catch (e: Exception) {
                }
                d
            } catch (e: Exception) {
                Log.e(TAG, "videoDetails failed", e)
                null
            }
        }

    /** All muxed (video+audio) quality levels, best first. Empty on failure. */
    suspend fun videoOptions(watchUrl: String): List<VideoOption> =
        withContext(Dispatchers.IO) {
            ensureInit()
            try {
                val hit = videoOptsCache[watchUrl]
                if (hit != null && System.currentTimeMillis() - hit.second < URL_TTL_MS) {
                    return@withContext hit.first
                } else if (hit != null) {
                    videoOptsCache.remove(watchUrl)
                }
            } catch (e: Exception) {
            }
            try {
                val se = YouTube.getStreamExtractor(watchUrl)
                se.fetchPage()
                val muxed = se.getVideoStreams().filter { !it.isVideoOnly() }
                val sorted = muxed.sortedWith(
                    compareByDescending<VideoStream> { heightOf(it) }
                        .thenByDescending { it.getBitrate() }
                )
                val out = ArrayList<VideoOption>(sorted.size)
                val seen = HashSet<Int>()
                for (i in 0 until sorted.size) {
                    val s = sorted[i]
                    val h = heightOf(s)
                    if (h <= 0 || h == Int.MAX_VALUE) {
                        continue
                    }
                    if (!seen.add(h)) {
                        continue
                    }
                    val url = try { s.getContent() } catch (e: Exception) { null }
                    if (url.isNullOrBlank()) {
                        continue
                    }
                    out.add(VideoOption(url, h, h.toString() + "p"))
                }
                try {
                    videoOptsCache[watchUrl] =
                        Pair(out, System.currentTimeMillis())
                } catch (e: Exception) {
                }
                out
            } catch (e: Exception) {
                Log.e(TAG, "videoOptions failed", e)
                emptyList()
            }
        }

    /**
     * Timed captions via NewPipeExtractor subtitles (second leg of the
     * YouTube-captions primary source; InnerTube timedtext is tried first
     * by LyricsRepository). Manual tracks first, en/hi preferred; the
     * first track parsing to 3+ lines wins. Null when absent/disabled.
     */
    suspend fun captionLines(videoId: String): List<LyricLine>? =
        withContext(Dispatchers.IO) {
            if (videoId.length != 11) return@withContext null
            ensureInit()
            try {
                val se = YouTube.getStreamExtractor(
                    "https://www.youtube.com/watch?v=$videoId"
                )
                se.fetchPage()
                val subs = try {
                    se.subtitlesDefault
                } catch (e: Exception) {
                    emptyList()
                }.ifEmpty {
                    try {
                        se.getSubtitles(MediaFormat.VTT)
                    } catch (e: Exception) {
                        emptyList()
                    }
                }
                if (subs.isEmpty()) return@withContext null
                val ranked = try {
                    subs.sortedWith(
                        compareByDescending<org.schabi.newpipe.extractor.stream.SubtitlesStream> {
                            try {
                                !it.isAutoGenerated
                            } catch (e: Exception) {
                                false
                            }
                        }.thenByDescending {
                            try {
                                val tag = it.languageTag ?: ""
                                when {
                                    tag.equals("en", true) -> 2
                                    tag.startsWith("en", true) -> 1
                                    tag.equals("hi", true) -> 1
                                    else -> 0
                                }
                            } catch (e: Exception) {
                                0
                            }
                        }
                    )
                } catch (e: Exception) {
                    subs
                }
                for (s in ranked.take(3)) {
                    try {
                        val url = try {
                            s.content
                        } catch (e: Exception) {
                            ""
                        }
                        if (url.isNullOrBlank()) continue
                        val raw = getText(url) ?: continue
                        val lines = LyricsRepository.parseCaptions(raw)
                        if (lines.size >= 3) {
                            Log.i(TAG, "captions newpipe: ${s.languageTag} auto=${try {
                                s.isAutoGenerated
                            } catch (e: Exception) {
                                false
                            }} ${lines.size} lines")
                            return@withContext lines
                        }
                    } catch (e: Exception) {
                    }
                }
                null
            } catch (e: Exception) {
                Log.d(TAG, "captions newpipe failed: ${e.message}")
                null
            }
        }

    private fun getText(url: String): String? {
        return try {
            val req = okhttp3.Request.Builder().url(url)
                .header("User-Agent", "Cresca/1.0 (Android)").get().build()
            http.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return null
                resp.body?.string()?.takeIf { it.isNotBlank() }
            }
        } catch (e: Exception) {
            null
        }
    }

    /** Stream height in px: explicit height when known, else parsed from "720p"/"720p60". */
    private fun heightOf(s: VideoStream): Int {        val h = try { s.getHeight() } catch (e: Exception) { 0 }
        if (h > 0) return h
        return try {
            Regex("""(\d+)""").find(s.getResolution() ?: "")
                ?.groupValues?.get(1)?.toIntOrNull() ?: Int.MAX_VALUE
        } catch (e: Exception) {
            Int.MAX_VALUE
        }
    }
}
