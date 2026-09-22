package com.cresca.app

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Real play history: every played track, newest first, persisted as JSON in
 * filesDir since install. Cap 300 (user's lifetime window). Full track
 * objects so Library/rails work offline. Callers must use Dispatchers.IO.
 */
object RecentStore {
    private const val TAG = "RecentStore"
    const val MAX = 300

    fun load(ctx: Context, file: String = "recent.json"): ArrayList<YtTrack> {
        val out = ArrayList<YtTrack>()
        try {
            val f = File(ctx.filesDir, file)
            if (!f.exists()) {
                return out
            }
            val arr = JSONArray(f.readText())
            for (i in 0 until arr.length()) {
                try {
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
                    if (out.size >= MAX) break
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "load failed", e)
        }
        return out
    }

    fun save(ctx: Context, tracks: List<YtTrack>, file: String = "recent.json") {
        try {
            val arr = JSONArray()
            val n = tracks.size.coerceAtMost(MAX)
            for (i in 0 until n) {
                val t = tracks[i]
                if (t.id.isEmpty()) continue
                val o = JSONObject()
                o.put("id", t.id)
                o.put("title", t.title)
                o.put("artist", t.artist)
                o.put("thumb", t.thumbUrl)
                o.put("watch", t.watchUrl)
                arr.put(o)
            }
            File(ctx.filesDir, file).writeText(arr.toString())
        } catch (e: Exception) {
            Log.w(TAG, "save failed", e)
        }
    }
}
