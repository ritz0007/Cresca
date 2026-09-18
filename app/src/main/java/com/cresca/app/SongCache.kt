package com.cresca.app

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Tiny disk cache: home + recent searches load instantly,
 * network refreshes silently in the background.
 * Plain JSON in cacheDir, survives app restarts.
 */
object SongCache {
    private const val TAG = "SongCache"

    fun save(ctx: Context, key: String, tracks: List<YtTrack>) {
        try {
            val arr = JSONArray()
            val n = tracks.size
            for (i in 0 until n) {
                val t = tracks[i]
                val o = JSONObject()
                o.put("id", t.id)
                o.put("title", t.title)
                o.put("artist", t.artist)
                o.put("thumb", t.thumbUrl)
                o.put("watch", t.watchUrl)
                arr.put(o)
            }
            val root = JSONObject()
            root.put("savedAt", System.currentTimeMillis())
            root.put("items", arr)
            File(ctx.cacheDir, "yt_" + key + ".json").writeText(root.toString())
        } catch (e: Exception) {
            Log.w(TAG, "save failed for " + key, e)
        }
    }

    fun load(ctx: Context, key: String, ttlMs: Long): List<YtTrack>? {
        try {
            val f = File(ctx.cacheDir, "yt_" + key + ".json")
            if (!f.exists()) {
                return null
            }
            val root = JSONObject(f.readText())
            val age = System.currentTimeMillis() - root.optLong("savedAt", 0L)
            if (age > ttlMs) {
                return null
            }
            val arr = root.optJSONArray("items")
            if (arr == null || arr.length() == 0) {
                return null
            }
            val out = ArrayList<YtTrack>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val t = YtTrack(
                    id = o.optString("id"),
                    title = o.optString("title"),
                    artist = o.optString("artist"),
                    thumbUrl = o.optString("thumb"),
                    watchUrl = o.optString("watch")
                )
                if (t.id.isNotEmpty()) {
                    out.add(t)
                }
            }
            if (out.isEmpty()) {
                return null
            }
            return out
        } catch (e: Exception) {
            Log.w(TAG, "load failed for " + key, e)
            return null
        }
    }
}
