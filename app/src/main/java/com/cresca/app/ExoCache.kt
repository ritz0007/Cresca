package com.cresca.app

import android.content.Context
import android.util.Log
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File

/**
 * On-disk ExoPlayer cache:
 * streamed audio bytes are reused on replay / prefetch / offline-ish
 * replay, so playback is smooth and non-stop even on flaky networks.
 * 4 GB LRU in cacheDir/exoplayer: upcoming + previous + taste-predicted
 * + charts + search-top songs live here. Least-recently-used eviction
 * keeps the 4 GB budget automatically (hot songs stay, cold bytes go).
 */
object ExoCache {
    private const val TAG = "ExoCache"
    @Volatile private var instance: SimpleCache? = null

    @Synchronized
    fun get(ctx: Context): SimpleCache {
        instance?.let { return it }
        val dir = try {
            File(ctx.cacheDir, "exoplayer").apply { mkdirs() }
        } catch (e: Exception) {
            Log.w(TAG, "cache dir failed", e)
            File(ctx.cacheDir, "exoplayer")
        }
        val db = try {
            StandaloneDatabaseProvider(ctx.applicationContext)
        } catch (e: Exception) {
            Log.w(TAG, "db provider failed", e)
            StandaloneDatabaseProvider(ctx.applicationContext)
        }
        val cache = SimpleCache(
            dir, LeastRecentlyUsedCacheEvictor(4L * 1024L * 1024L * 1024L), db
        )
        instance = cache
        return cache
    }

    fun release() {
        try {
            instance?.release()
        } catch (e: Exception) {
        }
        instance = null
    }
}
