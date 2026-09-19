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

    /** Pre-store one resolved stream URL (URL cache should be warm first). */
    suspend fun warmUrl(ctx: Context, url: String) = withContext(Dispatchers.IO) {
        try {
            if (url.isBlank()) return@withContext
            val app = ctx.applicationContext
            val cache = ExoCache.get(app)
            val http = DefaultHttpDataSource.Factory()
                .setConnectTimeoutMs(15000)
                .setReadTimeoutMs(15000)
                .setAllowCrossProtocolRedirects(true)
                .setUserAgent("Cresca/1.0 (Android)")
            val factory = CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(DefaultDataSource.Factory(app, http))
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
            val dataSpec = DataSpec(Uri.parse(url), 0, CAP_BYTES)
            // Default cache key = the URL itself (matches CacheDataSource's
            // default key factory for key-less specs; a miss only means we
            // re-verify, never a wrong read).
            val cachedBefore = try {
                cache.getCachedBytes(url, 0, CAP_BYTES)
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
                cache.getCachedBytes(url, 0, CAP_BYTES)
            } catch (e: Exception) {
                cachedBefore
            }
            Log.i(TAG, "precached ${(cachedAfter - cachedBefore) / 1024} KB")
        } catch (e: Exception) {
            Log.w(TAG, "precache failed", e)
        }
    }

    /** Resolve + pre-store the next [count] tracks (skips offline ones). */
    suspend fun warmUpcoming(ctx: Context, tracks: List<YtTrack>, count: Int = 5) =
        withContext(Dispatchers.IO) {
            try {
                val app = ctx.applicationContext
                for (t in tracks.take(count.coerceIn(1, 8))) {
                    try {
                        if (t.watchUrl.isBlank()) continue
                        if (DownloadStore.isDownloaded(app, t.id)) continue
                        val url = YoutubeRepository.audioUrl(t.watchUrl) ?: continue
                        warmUrl(app, url)
                        warmArt(app, t.thumbUrl)
                    } catch (e: Exception) {
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "warmUpcoming failed", e)
            }
        }

    /**
     * Taste-predicted warming: queue Up Next first (instant skip), then a
     * few vibe-matched predictions from liked + recent seeds. Runs on IO,
     * never throws, safe to call on every track change.
     */
    suspend fun warmPredicted(
        ctx: Context,
        upcoming: List<YtTrack>,
        liked: List<YtTrack> = emptyList(),
        recent: List<YtTrack> = emptyList()
    ) = withContext(Dispatchers.IO) {
        try {
            val app = ctx.applicationContext
            // 1) Up Next: the next 5 play instantly (covers rapid skipping).
            warmUpcoming(app, upcoming, 5)
            // 2) Taste predictions: 3 vibe picks from library seeds.
            try {
                val seeds = (liked.take(6) + recent.take(6)).distinctBy { it.id }
                    .filter { it.watchUrl.isNotBlank() }.take(3)
                for (s in seeds) {
                    try {
                        if (DownloadStore.isDownloaded(app, s.id)) continue
                        val url = YoutubeRepository.audioUrl(s.watchUrl) ?: continue
                        // Only top-up bytes (CacheWriter skips cached ranges).
                        warmUrl(app, url)
                        warmArt(app, s.thumbUrl)
                    } catch (e: Exception) {
                    }
                }
            } catch (e: Exception) {
            }
        } catch (e: Exception) {
            Log.w(TAG, "warmPredicted failed", e)
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
