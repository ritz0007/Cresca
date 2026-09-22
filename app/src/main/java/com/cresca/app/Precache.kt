package com.cresca.app

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import coil.Coil
import coil.request.CachePolicy
import coil.request.ImageRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext

/**
 * Background store for the next playable songs: stream bytes go to the
 * ExoPlayer disk cache (3 GB LRU) and artwork to Coil's disk cache, so
 * skipping forward plays instantly even on a flaky network. Idempotent:
 * cached ranges are served from disk, never re-downloaded.
 *
 * Taste prediction: beyond the queue's Up Next, we also warm vibe-matched
 * candidates (liked + recent seeds) the user is likely to tap, so those
 * play instantly too.
 */
object Precache {
    private const val TAG = "Precache"

    // Whole songs: typical audio streams are 3-8 MB.
    private const val CAP_BYTES = 10L * 1024L * 1024L

    /**
     * 4 GB on-device budget (mirrors ExoCache). The SimpleCache LRU evictor
     * enforces it automatically on every write — hottest bytes (current,
     * upcoming, recent, charts, searches) stay resident; cold bytes are
     * dropped first. This helper only reports pressure for diagnostics.
     */
    const val BUDGET_BYTES = 4L * 1024L * 1024L

    /** 0..1 budget pressure (1 = evictor actively trimming). Never throws. */
    suspend fun budgetPressure(ctx: Context): Float = withContext(Dispatchers.IO) {
        try {
            val used = ExoCache.get(ctx.applicationContext).cacheSpace
            (used.toFloat() / BUDGET_BYTES.toFloat()).coerceIn(0f, 1f)
        } catch (e: Exception) {
            0f
        }
    }

    /**
     * Pre-store one resolved stream URL (URL cache should be warm first).
     * [trackId] keys the bytes by videoId ("yt:"+id, same as the player's
     * customCacheKey): signed URLs change per resolve, so a full-URL key
     * orphaned every precache on the next resolve. Legacy full-URL entries
     * simply age out via LRU; a miss never misreads.
     */
    suspend fun warmUrl(ctx: Context, url: String, trackId: String = "") =
        withContext(Dispatchers.IO) {
        try {
            if (url.isBlank()) return@withContext
            val app = ctx.applicationContext
            val cache = ExoCache.get(app)
            val http = DefaultHttpDataSource.Factory()
                .setConnectTimeoutMs(10000)
                .setReadTimeoutMs(12000)
                .setAllowCrossProtocolRedirects(true)
                .setUserAgent("Cresca/1.0 (Android)")
            val factory = CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(DefaultDataSource.Factory(app, http))
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
            val key = if (trackId.isNotBlank()) "yt:$trackId" else null
            val dataSpec = if (key != null) DataSpec(Uri.parse(url), 0, CAP_BYTES, key)
            else DataSpec(Uri.parse(url), 0, CAP_BYTES)
            val probeKey = key ?: url
            val cachedBefore = try {
                cache.getCachedBytes(probeKey, 0, CAP_BYTES)
            } catch (e: Exception) {
                0L
            }
            if (cachedBefore >= CAP_BYTES) return@withContext
            try {
                CacheWriter(factory.createDataSource(), dataSpec, null, null).cache()
            } catch (e: Exception) {
                // Partial writes still help; the player resumes the rest.
                Log.d(TAG, "partial precache", e)
            }
            val cachedAfter = try {
                cache.getCachedBytes(probeKey, 0, CAP_BYTES)
            } catch (e: Exception) {
                cachedBefore
            }
            Log.i(TAG, "precached ${(cachedAfter - cachedBefore) / 1024} KB")
        } catch (e: Exception) {
            Log.w(TAG, "precache failed", e)
        }
    }

    /** Resolve + pre-store the next [count] tracks (skips offline ones).
     * Parallel x4: was sequential (4x fetchPage serialized) — now one wave.
     * Fire-and-forget safe: never throws, skips cached/downloaded. */
    suspend fun warmUpcoming(ctx: Context, tracks: List<YtTrack>, count: Int = 5) =
        withContext(Dispatchers.IO) {
            try {
                val app = ctx.applicationContext
                val slice = tracks.take(count.coerceIn(1, 8)).filter { it.watchUrl.isNotBlank() }
                if (slice.isEmpty()) return@withContext
                try {
                    coroutineScope {
                        slice.map { t ->
                            async {
                                try {
                                    if (DownloadStore.isDownloaded(app, t.id)) return@async
                                    val url = YoutubeRepository.audioUrl(t.watchUrl) ?: return@async
                                    warmUrl(app, url, t.id)
                                    warmArt(app, t.thumbUrl)
                                } catch (e: Exception) {
                                }
                            }
                        }.awaitAll()
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "warmUpcoming failed", e)
                }
            } catch (e: Exception) {
                Log.w(TAG, "warmUpcoming failed", e)
            }
        }

    /**
     * Taste-predicted warming: queue Up Next first (instant skip), previous
     * tracks (instant back-skip), likely charts, then a few vibe-matched
     * predictions from liked + recent seeds. Runs on IO, never throws,
     * safe to call on every track change.
     */
    suspend fun warmPredicted(
        ctx: Context,
        upcoming: List<YtTrack>,
        liked: List<YtTrack> = emptyList(),
        recent: List<YtTrack> = emptyList(),
        previous: List<YtTrack> = emptyList(),
        charts: List<YtTrack> = emptyList()
    ) = withContext(Dispatchers.IO) {
        try {
            val app = ctx.applicationContext
            // Waves run concurrently (were sequential: 5+3+6+3 resolves
            // serialized). Up Next first wave with prev/charts; taste seeds
            // join the same wave — single-flight audioUrl dedups overlap.
            coroutineScope {
                val w1 = async {
                    try {
                        // 1) Up Next: the next 5 play instantly (rapid skips).
                        warmUpcoming(app, upcoming, 5)
                    } catch (e: Exception) {
                    }
                }
                val w2 = async {
                    try {
                        // 2) Previous: back-skips resolve instantly too.
                        warmUpcoming(app, previous.take(3), 3)
                    } catch (e: Exception) {
                    }
                }
                val w3 = async {
                    try {
                        // 3) Charts the user opens (or probably opens).
                        warmUpcoming(app, charts.take(6), 6)
                    } catch (e: Exception) {
                    }
                }
                val w4 = async {
                    try {
                        // 4) Taste predictions: 3 vibe picks from library seeds.
                        val seeds = (liked.take(6) + recent.take(6)).distinctBy { it.id }
                            .filter { it.watchUrl.isNotBlank() }.take(3)
                        for (s in seeds) {
                            try {
                                if (DownloadStore.isDownloaded(app, s.id)) continue
                                val url = YoutubeRepository.audioUrl(s.watchUrl) ?: continue
                                // Only top-up bytes (CacheWriter skips cached ranges).
                                warmUrl(app, url, s.id)
                                warmArt(app, s.thumbUrl)
                            } catch (e: Exception) {
                            }
                        }
                    } catch (e: Exception) {
                    }
                }
                try {
                    listOf(w1, w2, w3, w4).awaitAll()
                } catch (e: Exception) {
                }
            }
            try {
                val pressure = budgetPressure(app)
                if (pressure > 0.9f) Log.i(TAG, "cache pressure ${"%.0f".format(pressure * 100)}%")
            } catch (e: Exception) {
            }
        } catch (e: Exception) {
            Log.w(TAG, "warmPredicted failed", e)
        }
    }

    /**
     * Search fast-lane: the moment results land, store the top 4 instantly
     * so tapping any of them streams from disk. Fire-and-forget on IO.
     */
    suspend fun warmSearchTop(ctx: Context, results: List<YtTrack>) =
        withContext(Dispatchers.IO) {
            try {
                warmUpcoming(ctx.applicationContext, results.take(4), 4)
            } catch (e: Exception) {
                Log.w(TAG, "warmSearchTop failed", e)
            }
        }

    /** Warm Coil disk cache so artwork appears instantly. */
    suspend fun warmArt(ctx: Context, url: String) = withContext(Dispatchers.IO) {
        try {
            if (url.isBlank()) return@withContext
            val loader = try {
                Coil.imageLoader(ctx.applicationContext)
            } catch (e: Exception) {
                return@withContext
            }
            val cached = try {
                loader.diskCache?.openSnapshot(url)?.use { true } ?: false
            } catch (e: Exception) {
                false
            }
            if (cached) return@withContext
            loader.enqueue(
                ImageRequest.Builder(ctx.applicationContext)
                    .data(url)
                    .memoryCachePolicy(CachePolicy.DISABLED)
                    .diskCachePolicy(CachePolicy.ENABLED)
                    .build()
            )
        } catch (e: Exception) {
        }
    }

    /** ExoPlayer cache footprint, for settings/diagnostics. */
    suspend fun cacheBytes(ctx: Context): Long = withContext(Dispatchers.IO) {
        try {
            ExoCache.get(ctx.applicationContext).cacheSpace
        } catch (e: Exception) {
            0L
        }
    }
}
