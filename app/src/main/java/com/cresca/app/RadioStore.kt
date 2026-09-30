package com.cresca.app

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class SavedRadio(
    val id: String,
    val seed: YtTrack,
    val title: String,
    val subtitle: String,
    val thumbUrl: String,
    val tracks: List<YtTrack>,
    val liked: Boolean = false,
    val createdAt: Long = 0L,
    val updatedAt: Long = 0L
)

/**
 * Saved + recent radios, persisted as JSON in filesDir. One card per
 * seed track (upsert bumps recency); LRU-capped at 30. Never throws.
 */
object RadioStore {
    private const val TAG = "RadioStore"
    private const val FILE = "radios.json"
    private const val MAX_RADIOS = 30
    private const val MAX_TRACKS = 200

    fun list(ctx: Context): ArrayList<SavedRadio> {
        val out = ArrayList<SavedRadio>()
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
                    val seedId = o.optString("seedId", "")
                    if (seedId.isBlank() || !seen.add(seedId)) continue
                    val tracks = ArrayList<YtTrack>()
                    try {
                        val tarr = o.optJSONArray("tracks")
                        if (tarr != null) {
                            for (j in 0 until tarr.length()) {
                                try {
                                    PlaylistStore.trackFromJson(
                                        tarr.optJSONObject(j) ?: continue
                                    )?.let { tracks.add(it) }
                                    if (tracks.size >= MAX_TRACKS) break
                                } catch (e: Exception) {
                                }
                            }
                        }
                    } catch (e: Exception) {
                    }
                    out.add(
                        SavedRadio(
                            id = o.optString("id", "radio_$seedId"),
                            seed = YtTrack(
                                id = seedId,
                                title = o.optString("seedTitle", ""),
                                artist = o.optString("seedArtist", ""),
                                thumbUrl = o.optString("seedThumb", ""),
                                watchUrl = o.optString("seedWatch", "")
                            ),
                            title = o.optString("title", "").takeIf { it.isNotBlank() }
                                ?: "Radio",
                            subtitle = o.optString("subtitle", ""),
                            thumbUrl = o.optString("thumb", ""),
                            tracks = tracks,
                            liked = o.optBoolean("liked", false),
                            createdAt = o.optLong("createdAt", 0L),
                            updatedAt = o.optLong("updatedAt", 0L)
                        )
                    )
                    if (out.size >= MAX_RADIOS) break
                } catch (e: Exception) {
                }
            }
            // Recency first, liked float above the rest.
            out.sortWith(
                compareByDescending<SavedRadio> { it.liked }
                    .thenByDescending { it.updatedAt }
            )
        } catch (e: Exception) {
            Log.w(TAG, "list failed", e)
        }
        return out
    }

    private fun saveAll(ctx: Context, radios: List<SavedRadio>) {
        try {
            val arr = JSONArray()
            for (r in radios.take(MAX_RADIOS)) {
                try {
                    val o = JSONObject()
                    o.put("id", r.id)
                    o.put("seedId", r.seed.id)
                    o.put("seedTitle", r.seed.title)
                    o.put("seedArtist", r.seed.artist)
                    o.put("seedThumb", r.seed.thumbUrl)
                    o.put("seedWatch", r.seed.watchUrl)
                    o.put("title", r.title.take(120))
                    o.put("subtitle", r.subtitle.take(120))
                    o.put("thumb", r.thumbUrl)
                    o.put("liked", r.liked)
                    o.put("createdAt", r.createdAt)
                    o.put("updatedAt", r.updatedAt)
                    val tarr = JSONArray()
                    for (t in r.tracks.take(MAX_TRACKS)) {
                        try {
                            if (t.id.isBlank()) continue
                            tarr.put(PlaylistStore.trackToJson(t))
                        } catch (e: Exception) {
                        }
                    }
                    o.put("tracks", tarr)
                    arr.put(o)
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

    /** Insert or refresh a radio card (liked flag survives refreshes). */
    fun upsert(ctx: Context, radio: SavedRadio) {
        try {
            if (radio.seed.id.isBlank()) return
            val all = list(ctx)
            val idx = all.indexOfFirst { it.seed.id == radio.seed.id }
            val keepLiked = if (idx >= 0) all[idx].liked else radio.liked
            val merged = radio.copy(
                id = if (idx >= 0) all[idx].id else radio.id,
                liked = keepLiked,
                createdAt = if (idx >= 0) all[idx].createdAt else radio.createdAt,
                updatedAt = System.currentTimeMillis()
            )
            val out = ArrayList<SavedRadio>(all.size + 1)
            out.add(merged)
            for (r in all) {
                if (r.seed.id != radio.seed.id) out.add(r)
            }
            saveAll(ctx, out)
        } catch (e: Exception) {
            Log.w(TAG, "upsert failed", e)
        }
    }

    /** Toggles the heart. Returns the new liked state. */
    fun toggleLike(ctx: Context, seedId: String): Boolean {
        return try {
            if (seedId.isBlank()) return false
            val all = list(ctx)
            val idx = all.indexOfFirst { it.seed.id == seedId }
            if (idx < 0) return false
            val next = !all[idx].liked
            all[idx] = all[idx].copy(liked = next, updatedAt = System.currentTimeMillis())
            saveAll(ctx, all)
            next
        } catch (e: Exception) {
            false
        }
    }

    fun delete(ctx: Context, seedId: String) {
        try {
            if (seedId.isBlank()) return
            val all = list(ctx)
            if (all.none { it.seed.id == seedId }) return
            saveAll(ctx, all.filter { it.seed.id != seedId })
        } catch (e: Exception) {
        }
    }
}
