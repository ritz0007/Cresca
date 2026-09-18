package com.cresca.app

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.MediaFormat
import org.schabi.newpipe.extractor.ServiceList.YouTube
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
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
