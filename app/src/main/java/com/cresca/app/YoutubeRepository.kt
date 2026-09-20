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
                .take(max + 10).mapNotNull { item ->
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
                // Duplicate ids crash keyed lazy lists: drop them here.
                .distinctBy { it.id }
                .take(max)
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
     * Vibe-based autoplay (YT Music style): YouTube's related graph is the
     * vibe signal (co-listened tracks, same mood/tempo — NOT same singer).
     * Same-artist search is only a last-resort filler, down-ranked, so the
     * queue matches the song's vibe instead of looping one singer.
     */
    suspend fun autoplayFor(t: YtTrack, max: Int = 20): List<YtTrack> =
        withContext(Dispatchers.IO) {
            ensureInit()
            val rel = try {
                relatedTracks(t.watchUrl, max)
            } catch (e: Exception) {
                emptyList()
            }
            // Related IS the vibe (YT Music mixes the same way). Enough? Done.
            if (rel.size >= max / 2) {
                return@withContext rel.filter { it.id != t.id }.take(max)
            }
            // Thin related: vibe-search by song keywords (mood/title words),
            // NOT artist name — artist-only is what caused same-singer loops.
            // Same-NAME hits from search are dropped outright (a "Diamond"
            // search must not queue every song called Diamond — that's
            // title-matching, not vibe). Related-graph hits are untouched.
            val vibeQs = try {
                vibeQueries(t)
            } catch (e: Exception) {
                emptyList()
            }
            val pool = ArrayList<YtTrack>(rel)
            val relIds = try {
                rel.map { it.id }.toSet()
            } catch (e: Exception) {
                emptySet()
            }
            for (q in vibeQs.take(3)) {
                try {
                    val hits = searchMusic(q, 12)
                    for (h in hits) {
                        if (pool.none { it.id == h.id } && h.id != t.id &&
                            !isSameName(h, t)
                        ) pool.add(h)
                        if (pool.size >= max + 10) break
                    }
                } catch (e: Exception) {
                }
                if (pool.size >= max + 10) break
            }
            // Last resort: a LITTLE same-artist filler (max 25%), clearly last.
            try {
                if (pool.size < max) {
                    val low = t.artist.lowercase()
                    val labelish = low.isBlank() || low == "youtube" ||
                        low.contains("music") || low.contains("official") ||
                        low.contains("films") || low.contains("records")
                    if (!labelish) {
                        val extra = searchMusic("${t.artist} songs", 8)
                        var added = 0
                        for (h in extra) {
                            if (pool.none { it.id == h.id } && h.id != t.id &&
                                !isSameName(h, t) && added < max / 4
                            ) {
                                pool.add(h)
                                added++
                            }
                        }
                    }
                }
            } catch (e: Exception) {
            }
            // Vibe-rank: related graph first, mood overlap next, same-name
            // and same-artist clumps sunk, then shuffle within tiers.
            val ranked = try {
                rankByVibe(t, pool, relIds)
            } catch (e: Exception) {
                pool
            }
            ranked.distinctBy { it.id }.filter { it.id != t.id }.take(max)
                .also { Log.i(TAG, "autoplay vibe ${rel.size} related + ${pool.size - rel.size} vibe") }
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
