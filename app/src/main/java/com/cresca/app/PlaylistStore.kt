package com.cresca.app

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class Playlist(
    val id: String,
    val name: String,
    val tracks: List<YtTrack>,
    val createdAt: Long,
    /** Custom cover image path (filesDir). Blank = auto mosaic. */
    val coverPath: String = "",
    /** Spotify playlist id for live sync ("" = manual list). Rename-safe link. */
    val spotifyId: String = ""
)

/**
 * User playlists, persisted as JSON in filesDir.
 * Suggestions are computed live from playlist artists at open time.
 *
 * Crash hardening:
 * - all file I/O synchronized (concurrent add/remove from sheets + menus)
 * - atomic writes (.tmp + rename) so kills never leave half-JSON
 * - corrupt JSON -> backup + empty (never throw to UI)
 * - blank ids / blank tracks rejected (never persist invalid rows)
 * - pure JSON helpers are unit-tested without Android (see PlaylistStressTest)
 */
object PlaylistStore {
    private const val TAG = "PlaylistStore"
    private const val FILE = "playlists.json"
    private const val MAX_TRACKS = 2000
    private const val MAX_LISTS = 200
    private val lock = Any()

    internal fun trackToJson(t: YtTrack): JSONObject {
        val o = JSONObject()
        try {
            o.put("id", t.id)
            o.put("title", t.title)
            o.put("artist", t.artist)
            o.put("thumb", t.thumbUrl)
            o.put("watch", t.watchUrl)
        } catch (e: Exception) {
        }
        return o
    }

    internal fun trackFromJson(o: JSONObject): YtTrack? {
        return try {
            val t = YtTrack(
                id = o.optString("id"),
                title = o.optString("title"),
                artist = o.optString("artist"),
                thumbUrl = o.optString("thumb"),
                watchUrl = o.optString("watch")
            )
            if (t.id.isBlank()) null else t
        } catch (e: Exception) {
            null
        }
    }

    /** Pure: parse playlists JSON (no Android). Never throws. */
    internal fun parseJson(raw: String): ArrayList<Playlist> {
        val out = ArrayList<Playlist>()
        try {
            if (raw.isBlank()) return out
            val arr = try {
                JSONArray(raw)
            } catch (e: Exception) {
                return out
            }
            val seen = HashSet<String>()
            for (i in 0 until arr.length()) {
                try {
                    val o = arr.optJSONObject(i) ?: continue
                    val id = o.optString("id").trim()
                    if (id.isBlank() || !seen.add(id)) continue
                    val name = o.optString("name").trim()
                    if (name.isBlank()) continue
                    val tarr = o.optJSONArray("tracks")
                    val tracks = ArrayList<YtTrack>()
                    val seenT = HashSet<String>()
                    if (tarr != null) {
                        for (j in 0 until tarr.length()) {
                            try {
                                if (tracks.size >= MAX_TRACKS) break
                                val tob = tarr.optJSONObject(j) ?: continue
                                val t = trackFromJson(tob) ?: continue
                                if (!seenT.add(t.id)) continue
                                tracks.add(t)
                            } catch (e: Exception) {
                            }
                        }
                    }
                    out.add(
                        Playlist(
                            id = id,
                            name = name.take(120),
                            tracks = tracks,
                            createdAt = try {
                                o.optLong("createdAt", 0L)
                            } catch (e: Exception) {
                                0L
                            },
                            coverPath = try {
                                o.optString("cover", "")
                            } catch (e: Exception) {
                                ""
                            },
                            spotifyId = try {
                                o.optString("spotifyId", "")
                            } catch (e: Exception) {
                                ""
                            }
                        )
                    )
                    if (out.size >= MAX_LISTS) break
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
        }
        return out
    }

    /** Pure: serialize (no Android). Never throws. */
    internal fun toJson(lists: List<Playlist>): String {
        return try {
            val arr = JSONArray()
            for (p in lists.take(MAX_LISTS)) {
                try {
                    if (p.id.isBlank() || p.name.isBlank()) continue
                    val o = JSONObject()
                    o.put("id", p.id)
                    o.put("name", p.name.take(120))
                    o.put("createdAt", p.createdAt)
                    if (p.coverPath.isNotBlank()) o.put("cover", p.coverPath)
                    if (p.spotifyId.isNotBlank()) o.put("spotifyId", p.spotifyId)
                    val tarr = JSONArray()
                    val seen = HashSet<String>()
                    for (t in p.tracks) {
                        try {
                            if (t.id.isBlank() || !seen.add(t.id)) continue
                            if (tarr.length() >= MAX_TRACKS) break
                            tarr.put(trackToJson(t))
                        } catch (e: Exception) {
                        }
                    }
                    o.put("tracks", tarr)
                    arr.put(o)
                } catch (e: Exception) {
                }
            }
            arr.toString()
        } catch (e: Exception) {
            "[]"
        }
    }

    /** Pure: add track (dedup, caps). Returns new list or null when no-op. */
    internal fun addedTrack(lists: List<Playlist>, id: String, track: YtTrack): List<Playlist>? {
        try {
            if (id.isBlank() || track.id.isBlank()) return null
            val idx = lists.indexOfFirst { it.id == id }
            if (idx < 0) return null
            val p = lists[idx]
            if (p.tracks.any { it.id == track.id }) return null
            if (p.tracks.size >= MAX_TRACKS) return null
            val nt = ArrayList<YtTrack>(p.tracks.size + 1)
            nt.addAll(p.tracks)
            nt.add(track)
            val out = ArrayList<Playlist>(lists.size)
            out.addAll(lists)
            out[idx] = p.copy(tracks = nt)
            return out
        } catch (e: Exception) {
            return null
        }
    }

    fun list(ctx: Context): ArrayList<Playlist> {
        synchronized(lock) {
            try {
                val f = File(ctx.filesDir, FILE)
                if (!f.exists() || f.length() == 0L) {
                    return ArrayList()
                }
                val raw = try {
                    f.readText()
                } catch (e: Exception) {
                    Log.w(TAG, "read failed", e)
                    return ArrayList()
                }
                val parsed = parseJson(raw)
                // Corrupt file that parses to empty while raw was non-empty:
                // back it up once so user data isn't silently lost.
                try {
                    if (parsed.isEmpty() && raw.trim().length > 2 && raw.trim() != "[]") {
                        File(ctx.filesDir, "$FILE.corrupt.${System.currentTimeMillis()}")
                            .writeText(raw.take(200 * 1024))
                    }
                } catch (e: Exception) {
                }
                return parsed
            } catch (e: Exception) {
                Log.w(TAG, "list failed", e)
                return ArrayList()
            }
        }
    }

    private fun saveAll(ctx: Context, lists: List<Playlist>) {
        synchronized(lock) {
            try {
                val json = toJson(lists)
                val dir = ctx.filesDir
                val tmp = File(dir, "$FILE.tmp")
                val dst = File(dir, FILE)
                try {
                    tmp.writeText(json)
                } catch (e: Exception) {
                    Log.w(TAG, "tmp write failed", e)
                    return
                }
                try {
                    if (dst.exists()) {
                        // Keep one backup for crash recovery.
                        try {
                            File(dir, "$FILE.bak").delete()
                        } catch (e: Exception) {
                        }
                        try {
                            dst.copyTo(File(dir, "$FILE.bak"), overwrite = true)
                        } catch (e: Exception) {
                        }
                    }
                    if (!tmp.renameTo(dst)) {
                        try {
                            dst.delete()
                        } catch (e: Exception) {
                        }
                        tmp.renameTo(dst)
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "rename failed", e)
                    try {
                        dst.writeText(json)
                    } catch (ignored: Exception) {
                    }
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

    fun create(ctx: Context, name: String, spotifyId: String = ""): Playlist {
        val clean = try {
            name.trim().take(120).ifEmpty { "My Playlist" }
        } catch (e: Exception) {
            "My Playlist"
        }
        val now = System.currentTimeMillis()
        val p = Playlist(
            id = "pl_" + now + "_" + try {
                UUID.randomUUID().toString().take(8)
            } catch (e: Exception) {
                (now % 100000).toString()
            },
            name = clean,
            tracks = emptyList(),
            createdAt = now,
            spotifyId = try {
                spotifyId.trim()
            } catch (e: Exception) {
                ""
            }
        )
        try {
            val all = list(ctx)
            all.add(0, p)
            saveAll(ctx, all.take(MAX_LISTS))
        } catch (e: Exception) {
            Log.w(TAG, "create failed", e)
        }
        return p
    }

    /** Applies fn to one playlist, persists when non-null is returned. */
    private fun update(ctx: Context, id: String, fn: (Playlist) -> Playlist?): Boolean {
        try {
            if (id.isBlank()) return false
            val all = list(ctx)
            val idx = all.indexOfFirst { it.id == id }
            if (idx < 0) return false
            val next = try {
                fn(all[idx])
            } catch (e: Exception) {
                null
            } ?: return false
            all[idx] = next
            saveAll(ctx, all)
            return true
        } catch (e: Exception) {
            Log.w(TAG, "update failed", e)
            return false
        }
    }

    /** Renames a playlist. False when blank/unchanged/missing. */
    fun rename(ctx: Context, id: String, name: String): Boolean {
        val clean = try {
            name.trim().take(120)
        } catch (e: Exception) {
            ""
        }
        if (clean.isBlank()) return false
        return update(ctx, id) { p ->
            if (p.name == clean) null else p.copy(name = clean)
        }
    }

    /** Sets (or clears with "") a custom cover image path. */
    fun setCover(ctx: Context, id: String, path: String): Boolean {
        val clean = try {
            path.trim()
        } catch (e: Exception) {
            ""
        }
        return update(ctx, id) { p ->
            if (p.coverPath == clean) null else p.copy(coverPath = clean)
        }
    }

    /** Links a local mirror to its Spotify playlist id (rename-safe sync). */
    fun setSpotifyId(ctx: Context, id: String, spotifyId: String): Boolean {
        return update(ctx, id) { p ->
            p.copy(spotifyId = try {
                spotifyId.trim()
            } catch (e: Exception) {
                ""
            })
        }
    }

    /**
     * Stores gallery bytes as this playlist's cover (filesDir/covers,
     * downscaled side-effect free: caller passes raw bytes, we cap size).
     * Returns the stored path, or null on failure.
     */
    fun saveCoverFile(ctx: Context, playlistId: String, bytes: ByteArray): String? {
        try {
            if (playlistId.isBlank() || bytes.isEmpty()) return null
            val safe = bytes.take(3 * 1024 * 1024).toByteArray()
            val dir = File(ctx.filesDir, "covers")
            try {
                if (!dir.exists()) dir.mkdirs()
            } catch (e: Exception) {
            }
            val dst = File(dir, playlistId.replace(Regex("[^A-Za-z0-9_-]"), "_").take(48) + ".jpg")
            try {
                dst.writeBytes(safe)
            } catch (e: Exception) {
                return null
            }
            return dst.absolutePath
        } catch (e: Exception) {
            Log.w(TAG, "cover save failed", e)
            return null
        }
    }

    fun delete(ctx: Context, id: String) {
        try {
            if (id.isBlank()) return
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
        } catch (e: Exception) {
            Log.w(TAG, "delete failed", e)
        }
    }

    // Returns false when the song was already in the playlist.
    fun add(ctx: Context, id: String, track: YtTrack): Boolean {
        try {
            if (id.isBlank() || track.id.isBlank()) return false
            val all = list(ctx)
            val next = addedTrack(all, id, track) ?: return false
            saveAll(ctx, next)
            return true
        } catch (e: Exception) {
            Log.w(TAG, "add failed", e)
            return false
        }
    }

    fun remove(ctx: Context, id: String, trackId: String) {
        try {
            if (id.isBlank() || trackId.isBlank()) return
            val all = list(ctx)
            for (i in 0 until all.size) {
                val p = all[i]
                if (p.id == id) {
                    val nt = ArrayList<YtTrack>()
                    for (j in 0 until p.tracks.size) {
                        try {
                            if (p.tracks[j].id != trackId) {
                                nt.add(p.tracks[j])
                            }
                        } catch (e: Exception) {
                        }
                    }
                    if (nt.size != p.tracks.size) {
                        all[i] = p.copy(tracks = nt)
                        saveAll(ctx, all)
                    }
                    return
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "remove failed", e)
        }
    }
}
