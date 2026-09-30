package com.cresca.app

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class LikedArtist(
    val name: String,
    val thumbUrl: String = "",
    val subs: String = ""
)

/**
 * Favorite artists, persisted as JSON in filesDir. Name-keyed (case
 * insensitive); art refreshes on re-like. Never throws.
 */
object LikedArtists {
    private const val TAG = "LikedArtists"
    private const val FILE = "artists_liked.json"

    fun load(ctx: Context): ArrayList<LikedArtist> {
        val out = ArrayList<LikedArtist>()
        try {
            val f = File(ctx.filesDir, FILE)
            if (!f.exists()) return out
            val arr = try {
                JSONArray(f.readText())
            } catch (e: Exception) {
                return out
            }
            val seen = HashSet<String>()
            for (i in 0 until arr.length()) {
                try {
                    val o = arr.optJSONObject(i) ?: continue
                    val name = o.optString("name", "").trim()
                    if (name.isBlank() || !seen.add(name.lowercase())) continue
                    out.add(
                        LikedArtist(
                            name = name,
                            thumbUrl = o.optString("thumb", ""),
                            subs = o.optString("subs", "")
                        )
                    )
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "load failed", e)
        }
        return out
    }

    fun save(ctx: Context, artists: List<LikedArtist>) {
        try {
            val arr = JSONArray()
            for (a in artists.take(500)) {
                try {
                    if (a.name.isBlank()) continue
                    arr.put(
                        JSONObject().put("name", a.name.take(120))
                            .put("thumb", a.thumbUrl)
                            .put("subs", a.subs)
                    )
                } catch (e: Exception) {
                }
            }
            val tmp = File(ctx.filesDir, "$FILE.tmp")
            val dst = File(ctx.filesDir, FILE)
            tmp.writeText(arr.toString())
            if (!tmp.renameTo(dst)) {
                try {
                    dst.delete()
                } catch (e: Exception) {
                }
                tmp.renameTo(dst)
            }
            try {
                tmp.delete()
            } catch (e: Exception) {
            }
        } catch (e: Exception) {
            Log.w(TAG, "save failed", e)
        }
    }
}
