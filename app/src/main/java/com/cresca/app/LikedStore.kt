package com.cresca.app

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Liked songs, persisted as JSON in filesDir.
 * Stores full track objects so Library works offline.
 */
object LikedStore {
    private const val TAG = "LikedStore"

    fun load(ctx: Context): ArrayList<YtTrack> {
        val out = ArrayList<YtTrack>()
        try {
            val f = File(ctx.filesDir, "liked.json")
            if (!f.exists()) {
                return out
            }
            val arr = JSONArray(f.readText())
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
        } catch (e: Exception) {
            Log.w(TAG, "load failed", e)
        }
        return out
    }

    fun save(ctx: Context, tracks: List<YtTrack>) {
        try {
            val arr = JSONArray()
            for (i in 0 until tracks.size) {
                val t = tracks[i]
                val o = JSONObject()
                o.put("id", t.id)
                o.put("title", t.title)
                o.put("artist", t.artist)
                o.put("thumb", t.thumbUrl)
                o.put("watch", t.watchUrl)
                arr.put(o)
            }
            File(ctx.filesDir, "liked.json").writeText(arr.toString())
        } catch (e: Exception) {
            Log.w(TAG, "save failed", e)
        }
    }
}
