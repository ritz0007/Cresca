package com.cresca.app

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
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
    // Generous timeouts: search does several round trips; slow networks
    // must not surface as crashes or instant failures.
    private val http = okhttp3.OkHttpClient.Builder()
        .connectTimeout(25, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(25, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(25, java.util.concurrent.TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    @Volatile private var ready = false
    @Volatile private var appContext: Context? = null

    // Resolved stream URLs, good for hours. Hits make replays instant.
    private const val URL_TTL_MS = 5 * 60 * 60 * 1000L
    private val urlCache = java.util.concurrent.ConcurrentHashMap<String, Pair<String, Long>>()
    private val videoOptsCache =
        java.util.concurrent.ConcurrentHashMap<String, Pair<List<VideoOption>, Long>>()

    fun initAppContext(ctx: Context) {
        appContext = ctx.applicationContext
    }

    internal fun sessionCookies(): String {
        val c = appContext ?: return ""
        return try {
            YtSessionManager.loadCookies(c)
        } catch (e: Exception) {
            ""
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
            ensureInit()
            val qh = YouTube.searchQHFactory.fromQuery(query)
            val items = SearchInfo.getInfo(YouTube, qh).relatedItems
            items.filterIsInstance<StreamInfoItem>()
                .filter { item ->
                    val d = try { item.duration } catch (e: Exception) { 0L }
                    d <= 0L || d <= 600L
                }
                .take(max).mapNotNull { item ->
                    try {
                        val id = Regex("[?&]v=([A-Za-z0-9_-]{11})")
                            .find(item.url)?.groupValues?.get(1) ?: return@mapNotNull null
                        val thumb = item.thumbnails.maxByOrNull { it.height }?.url ?: ""
                        YtTrack(
                            id = id,
                            title = item.name,
                            artist = item.uploaderName ?: "YouTube",
                            thumbUrl = thumb,
                            watchUrl = item.url
                        )
                    } catch (e: Exception) {
                        Log.w(TAG, "skip item", e)
                        null
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
            val d = try {
                item.duration
            } catch (e: Exception) {
                0L
            }
            // Songs only: keep unknown-length and <= 10 min.
            if (d > 600L) return null
            val id = Regex("[?&]v=([A-Za-z0-9_-]{11})")
                .find(item.url)?.groupValues?.get(1) ?: return null
            val thumb = try {
                item.thumbnails.maxByOrNull { it.height }?.url ?: ""
            } catch (e: Exception) {
                ""
            }
            val artist = try {
                item.uploaderName ?: "YouTube"
            } catch (e: Exception) {
                "YouTube"
            }
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
            ensureInit()
            val qh = YouTube.searchQHFactory.fromQuery(
                query, listOf("music_songs"), ""
            )
            val info = SearchInfo.getInfo(YouTube, qh)
            info.relatedItems.filterIsInstance<StreamInfoItem>()
                .mapNotNull { toTrack(it) }
                .distinctBy { it.id }
                .take(max)
        }

    /** YouTube Charts trending music (charts.youtube.com Right Now). */
    suspend fun trendingMusic(max: Int = 15): List<YtTrack> =
        withContext(Dispatchers.IO) {
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

    /** "Because you listened" mix: streams related to a watched track. */
    suspend fun relatedTracks(watchUrl: String, max: Int = 12): List<YtTrack> =
        withContext(Dispatchers.IO) {
            ensureInit()
            try {
                // Related extraction is reliable on www URLs; music URLs
                // carry the same video id.
                val id = Regex("[?&]v=([A-Za-z0-9_-]{11})")
                    .find(watchUrl)?.groupValues?.get(1) ?: return@withContext emptyList()
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
     * Autoplay pool for a track: related streams first, topped up with an
     * artist music-search when related extraction comes back thin. Always
     * returns something playable when the network cooperates.
     */
    suspend fun autoplayFor(t: YtTrack, max: Int = 20): List<YtTrack> =
        withContext(Dispatchers.IO) {
            ensureInit()
            val rel = try {
                relatedTracks(t.watchUrl, max)
            } catch (e: Exception) {
                emptyList()
            }
            if (rel.size >= max / 2) return@withContext rel
            try {
                val low = t.artist.lowercase()
                val labelish = low.isBlank() || low == "youtube" ||
                    low.contains("music") || low.contains("official") ||
                    low.contains("films") || low.contains("records")
                val q = if (labelish) "${t.title} songs" else "${t.artist} songs"
                val extra = try {
                    searchMusic(q, max)
                } catch (e: Exception) {
                    emptyList()
                }
                (rel + extra).distinctBy { it.id }
                    .filter { it.id != t.id }
                    .take(max)
                    .also { Log.i(TAG, "autoplay ${rel.size} related + ${extra.size} search") }
            } catch (e: Exception) {
                rel
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
                    try {
                        urlCache[watchUrl] = Pair(best, System.currentTimeMillis())
                    } catch (e: Exception) {
                    }
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

    /** Direct audio stream URL for Media3 ExoPlayer (handles signature decipher). */
    suspend fun audioUrl(watchUrl: String): String? =
        withContext(Dispatchers.IO) {
            ensureInit()
            // Memory cache first: stream URLs stay valid for hours.
            try {
                val hit = urlCache[watchUrl]
                if (hit != null && System.currentTimeMillis() - hit.second < URL_TTL_MS) {
                    return@withContext hit.first
                } else if (hit != null) {
                    urlCache.remove(watchUrl)
                }
            } catch (e: Exception) {
            }
            audioUrls(watchUrl).firstOrNull()
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
