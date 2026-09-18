package com.cresca.app

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class Playlist(
    val id: String,
    val name: String,
    val tracks: List<YtTrack>,
    val createdAt: Long
)

/**
 * User playlists, persisted as JSON in filesDir.
 * Suggestions are computed live from playlist artists at open time.
 */
object PlaylistStore {
    private const val TAG = "PlaylistStore"
    private const val FILE = "playlists.json"

    private fun trackToJson(t: YtTrack): JSONObject {
        val o = JSONObject()
        o.put("id", t.id)
        o.put("title", t.title)
        o.put("artist", t.artist)
        o.put("thumb", t.thumbUrl)
        o.put("watch", t.watchUrl)
        return o
    }

    private fun trackFromJson(o: JSONObject): YtTrack? {
        return try {
            val t = YtTrack(
                id = o.optString("id"),
                title = o.optString("title"),
                artist = o.optString("artist"),
                thumbUrl = o.optString("thumb"),
                watchUrl = o.optString("watch")
            )
            if (t.id.isEmpty()) null else t
        } catch (e: Exception) {
            null
        }
    }

    fun list(ctx: Context): ArrayList<Playlist> {
        val out = ArrayList<Playlist>()
        try {
            val f = File(ctx.filesDir, FILE)
            if (!f.exists()) {
                return out
            }
            val arr = JSONArray(f.readText())
            for (i in 0 until arr.length()) {
                try {
                    val o = arr.getJSONObject(i)
                    val tarr = o.optJSONArray("tracks")
                    val tracks = ArrayList<YtTrack>()
                    if (tarr != null) {
                        for (j in 0 until tarr.length()) {
                            val t = trackFromJson(tarr.getJSONObject(j))
                            if (t != null) {
                                tracks.add(t)
                            }
                        }
                    }
                    val name = o.optString("name")
                    if (name.isEmpty()) {
                        continue
                    }
                    out.add(
                        Playlist(
                            id = o.optString("id"),
                            name = name,
                            tracks = tracks,
                            createdAt = o.optLong("createdAt", 0L)
                        )
                    )
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "list failed", e)
        }
        return out
    }

    private fun saveAll(ctx: Context, lists: List<Playlist>) {
        try {
            val arr = JSONArray()
            for (i in 0 until lists.size) {
                val p = lists[i]
                val o = JSONObject()
                o.put("id", p.id)
                o.put("name", p.name)
                o.put("createdAt", p.createdAt)
                val tarr = JSONArray()
                for (j in 0 until p.tracks.size) {
                    tarr.put(trackToJson(p.tracks[j]))
                }
                o.put("tracks", tarr)
                arr.put(o)
            }
            File(ctx.filesDir, FILE).writeText(arr.toString())
        } catch (e: Exception) {
            Log.w(TAG, "save failed", e)
        }
    }

    fun create(ctx: Context, name: String): Playlist {
        val clean = name.trim().ifEmpty { "My Playlist" }
        val p = Playlist(
            id = "pl_" + System.currentTimeMillis(),
            name = clean,
            tracks = emptyList(),
            createdAt = System.currentTimeMillis()
        )
        val all = list(ctx)
        all.add(0, p)
        saveAll(ctx, all)
        return p
    }

    fun delete(ctx: Context, id: String) {
        val all = list(ctx)
        var removed = false
        val it = all.iterator()
        while (it.hasNext()) {
            if (it.next().id == id) {
                it.remove()
                removed = true
            }
        }
        if (removed) {
            saveAll(ctx, all)
        }
    }

    // Returns false when the song was already in the playlist.
    fun add(ctx: Context, id: String, track: YtTrack): Boolean {
        val all = list(ctx)
        for (i in 0 until all.size) {
            val p = all[i]
            if (p.id == id) {
                for (j in 0 until p.tracks.size) {
                    if (p.tracks[j].id == track.id) {
                        return false
                    }
                }
                val nt = ArrayList<YtTrack>(p.tracks.size + 1)
                nt.addAll(p.tracks)
                nt.add(track)
                all[i] = p.copy(tracks = nt)
                saveAll(ctx, all)
                return true
            }
        }
        return false
    }

    fun remove(ctx: Context, id: String, trackId: String) {
        val all = list(ctx)
        for (i in 0 until all.size) {
            val p = all[i]
            if (p.id == id) {
                val nt = ArrayList<YtTrack>()
                for (j in 0 until p.tracks.size) {
                    if (p.tracks[j].id != trackId) {
                        nt.add(p.tracks[j])
                    }
                }
                if (nt.size != p.tracks.size) {
                    all[i] = p.copy(tracks = nt)
                    saveAll(ctx, all)
                }
                return
            }
        }
    }
}
