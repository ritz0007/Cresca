package com.cresca.app

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Persists the last session like Spotify / Apple Music / YT Music:
 * full queue + current index + position + shuffle/repeat.
 * Plain JSON in filesDir, always on Dispatchers.IO.
 */
object PlaybackStateStore {
    private const val TAG = "PlaybackState"
    private const val NAME = "playback_state.json"

    data class SavedSession(
        val tracks: List<YtTrack>,
        val index: Int,
        val trackId: String,
        val positionMs: Long,
        val shuffleOn: Boolean,
        val repeatMode: Int
    )

    private fun file(ctx: Context): File = File(ctx.filesDir, NAME)

    suspend fun save(
        ctx: Context,
        tracks: List<YtTrack>,
        index: Int,
        current: YtTrack?,
        positionMs: Long,
        shuffleOn: Boolean,
        repeatMode: Int
    ) = withContext(Dispatchers.IO) {
        try {
            if (tracks.isEmpty() || current == null) return@withContext
            val root = JSONObject()
            root.put("savedAt", System.currentTimeMillis())
            root.put("index", index.coerceIn(0, (tracks.size - 1).coerceAtLeast(0)))
            root.put("trackId", current.id)
            root.put("positionMs", positionMs.coerceAtLeast(0L))
            root.put("shuffleOn", shuffleOn)
            root.put("repeatMode", repeatMode)
            val arr = JSONArray()
            // Cap queue at 200 to keep the file small and load fast.
            for (t in tracks.take(200)) {
                val o = JSONObject()
                o.put("id", t.id)
                o.put("title", t.title)
                o.put("artist", t.artist)
                o.put("thumb", t.thumbUrl)
                o.put("watch", t.watchUrl)
                arr.put(o)
            }
            root.put("items", arr)
            file(ctx.applicationContext).writeText(root.toString())
        } catch (e: Exception) {
            Log.w(TAG, "save failed", e)
        }
    }

    /** Position-only fast save for the 5s ticker (no queue rewrite). */
    suspend fun savePosition(ctx: Context, positionMs: Long) = withContext(Dispatchers.IO) {
        try {
            val f = file(ctx.applicationContext)
            if (!f.exists()) return@withContext
            val root = JSONObject(f.readText())
            root.put("positionMs", positionMs.coerceAtLeast(0L))
            root.put("savedAt", System.currentTimeMillis())
            f.writeText(root.toString())
        } catch (e: Exception) {
            Log.w(TAG, "savePosition failed", e)
        }
    }

    suspend fun load(ctx: Context): SavedSession? = withContext(Dispatchers.IO) {
        try {
            val f = file(ctx.applicationContext)
            if (!f.exists()) return@withContext null
            val root = JSONObject(f.readText())
            val arr = root.optJSONArray("items") ?: return@withContext null
            if (arr.length() == 0) return@withContext null
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
                if (t.id.isNotEmpty()) out.add(t)
            }
            if (out.isEmpty()) return@withContext null
            val trackId = root.optString("trackId", "")
            var index = root.optInt("index", 0)
            if (trackId.isNotEmpty()) {
                val byId = out.indexOfFirst { it.id == trackId }
                if (byId >= 0) index = byId
            }
            index = index.coerceIn(out.indices)
            SavedSession(
                tracks = out,
                index = index,
                trackId = trackId,
                positionMs = root.optLong("positionMs", 0L).coerceAtLeast(0L),
                shuffleOn = root.optBoolean("shuffleOn", false),
                repeatMode = root.optInt("repeatMode", androidx.media3.common.Player.REPEAT_MODE_OFF)
            )
        } catch (e: Exception) {
            Log.w(TAG, "load failed", e)
            null
        }
    }

    suspend fun clear(ctx: Context) = withContext(Dispatchers.IO) {
        try {
            file(ctx.applicationContext).delete()
        } catch (e: Exception) {
        }
    }
}
