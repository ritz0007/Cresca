package com.cresca.app.spotify

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.json.JSONObject

data class SpotifyTrack(
    val id: String,
    val name: String,
    val artists: List<String>,
    val album: String = ""
)

data class SpotifyPlaylist(
    val id: String,
    val name: String,
    val total: Int = 0
)

/**
 * Minimal Spotify Web API reader (OkHttp + org.json, no SDK).
 * Every call is best-effort: empty list on any failure, never throws.
 */
object SpotifyApi {
    private const val TAG = "SpotifyApi"

    private val http = okhttp3.OkHttpClient.Builder()
        .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(12, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(12, java.util.concurrent.TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    /**
     * GET with backoff: 429 always retried (Retry-After honored), 403
     * retried too (Spotify rate-limits surface as bare 403s). Auth-scope
     * 403s won't heal — they cost ~3s then return null (caller skips).
     */
    private suspend fun getJson(ctx: Context, url: String, tries: Int = 3): JSONObject? =
        withContext(Dispatchers.IO) {
            var waitMs = 1000L
            repeat(tries) { attempt ->
                try {
                    val token = SpotifyAuth.accessToken(ctx)
                    if (token.isBlank()) return@withContext null
                    val req = Request.Builder().url(url)
                        .header("Authorization", "Bearer $token")
                        .get().build()
                    http.newCall(req).execute().use { resp ->
                        if (resp.isSuccessful) {
                            val text = resp.body?.string() ?: return@withContext null
                            return@withContext JSONObject(text)
                        }
                        val code = resp.code
                        val peek = try {
                            resp.body?.string()?.take(200) ?: ""
                        } catch (e: Exception) {
                            ""
                        }
                        if ((code == 429 || code == 403) && attempt < tries - 1) {
                            val raMs = try {
                                (resp.header("Retry-After")?.toLongOrNull() ?: 0L) * 1000L
                            } catch (e: Exception) {
                                0L
                            }
                            Log.d(TAG, "GET $code $url body=$peek (retry ${attempt + 1})")
                            try {
                                delay(if (raMs > 0) raMs.coerceAtMost(15000L) else waitMs)
                            } catch (e: Exception) {
                            }
                            waitMs = (waitMs * 2).coerceAtMost(8000L)
                        } else {
                            Log.d(TAG, "GET $code $url body=$peek")
                            return@withContext null
                        }
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "GET failed: ${e.message}")
                    return@withContext null
                }
            }
            null
        }

    /** Next page URL, or null. Guards Spotify's literal null plus the
     * org.json quirk that can surface it as the string "null" (which
     * otherwise fires one bogus scheme-less request per list). */
    private fun nextUrl(json: JSONObject): String? {
        return try {
            val n = json.optString("next", "")
            if (n.isBlank() || n == "null" || !n.startsWith("http")) null else n
        } catch (e: Exception) {
            null
        }
    }
    /** Pure: one playlist object → ref (unit-tested). */
    internal fun parsePlaylist(o: JSONObject): SpotifyPlaylist? {
        return try {
            val id = o.optString("id", "")
            val name = o.optString("name", "").trim()
            if (id.isBlank() || name.isBlank()) return null
            SpotifyPlaylist(
                id = id,
                name = name,
                total = try {
                    o.optJSONObject("tracks")?.optInt("total", 0) ?: 0
                } catch (e: Exception) {
                    0
                }
            )
        } catch (e: Exception) {
            null
        }
    }

    /** Pure: one Spotify track object → ref (unit-tested). */
    internal fun parseTrack(o: JSONObject): SpotifyTrack? {
        return try {
            // Playlist items wrap track under "track"; saved/top return it bare.
            val t = if (o.has("track") && !o.isNull("track")) o.optJSONObject("track") ?: return null else o
            if (t.optString("is_local", "false").toString() == "true") return null
            // Episodes (podcasts) share these endpoints — never songs.
            if (t.optString("type", "track") == "episode") return null
            val id = t.optString("id", "")
            val name = t.optString("name", "").trim()
            if (name.isBlank()) return null
            val artists = ArrayList<String>()
            try {
                val arr = t.optJSONArray("artists")
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        val n = arr.optJSONObject(i)?.optString("name", "")?.trim() ?: ""
                        if (n.isNotBlank()) artists.add(n)
                    }
                }
            } catch (e: Exception) {
            }
            if (artists.isEmpty()) return null
            SpotifyTrack(
                id = id,
                name = name,
                artists = artists,
                album = try {
                    t.optJSONObject("album")?.optString("name", "") ?: ""
                } catch (e: Exception) {
                    ""
                }
            )
        } catch (e: Exception) {
            null
        }
    }

    /** All own + followed playlists (paginated, capped).
     * Returns (ok, lists): ok=false means Spotify never answered
     * (vs a truly empty library) so callers can say so. */
    suspend fun myPlaylists(ctx: Context, max: Int = 50): Pair<Boolean, List<SpotifyPlaylist>> {
        val out = ArrayList<SpotifyPlaylist>()
        var ok = false
        try {
            var url: String? = "https://api.spotify.com/v1/me/playlists?limit=50&offset=0"
            while (url != null && out.size < max) {
                val json = getJson(ctx, url) ?: break
                ok = true
                try {
                    val items = json.optJSONArray("items") ?: break
                    for (i in 0 until items.length()) {
                        val p = try {
                            parsePlaylist(items.optJSONObject(i) ?: continue)
                        } catch (e: Exception) {
                            null
                        } ?: continue
                        out.add(p)
                        if (out.size >= max) break
                    }
                } catch (e: Exception) {
                    break
                }
                url = nextUrl(json)
            }
        } catch (e: Exception) {
        }
        return Pair(ok, out)
    }

    /** Tracks of one playlist (paginated, capped). Full track objects
     * (no fields= filter: a wrong filter fails every playlist at once). */
    suspend fun playlistTracks(
        ctx: Context,
        playlistId: String,
        max: Int = 500
    ): List<SpotifyTrack> {
        val out = ArrayList<SpotifyTrack>()
        try {
            var url: String? =
                "https://api.spotify.com/v1/playlists/$playlistId/tracks" +
                    "?limit=100&offset=0"
            while (url != null && out.size < max) {
                val json = getJson(ctx, url) ?: break
                try {
                    val items = json.optJSONArray("items") ?: break
                    for (i in 0 until items.length()) {
                        val t = try {
                            parseTrack(items.optJSONObject(i) ?: continue)
                        } catch (e: Exception) {
                            null
                        } ?: continue
                        out.add(t)
                        if (out.size >= max) break
                    }
                } catch (e: Exception) {
                    break
                }
                url = nextUrl(json)
            }
        } catch (e: Exception) {
        }
        return out
    }

    /** Liked Songs (saved tracks, capped). */
    suspend fun savedTracks(ctx: Context, max: Int = 100): List<SpotifyTrack> {
        val out = ArrayList<SpotifyTrack>()
        try {
            var url: String? =
                "https://api.spotify.com/v1/me/tracks?limit=50&offset=0"
            while (url != null && out.size < max) {
                val json = getJson(ctx, url) ?: break
                try {
                    val items = json.optJSONArray("items") ?: break
                    for (i in 0 until items.length()) {
                        val t = try {
                            parseTrack(items.optJSONObject(i) ?: continue)
                        } catch (e: Exception) {
                            null
                        } ?: continue
                        out.add(t)
                        if (out.size >= max) break
                    }
                } catch (e: Exception) {
                    break
                }
                url = nextUrl(json)
            }
        } catch (e: Exception) {
        }
        return out
    }

    /** Top artist names (taste seeds for home rails). */
    suspend fun topArtists(ctx: Context, max: Int = 20): List<String> {
        return try {
            val json = getJson(
                ctx,
                "https://api.spotify.com/v1/me/top/artists?limit=$max&time_range=medium_term"
            ) ?: return emptyList()
            val out = ArrayList<String>()
            val items = json.optJSONArray("items") ?: return emptyList()
            for (i in 0 until items.length()) {
                val n = items.optJSONObject(i)?.optString("name", "")?.trim() ?: ""
                if (n.isNotBlank() && out.none { it.equals(n, true) }) out.add(n)
                if (out.size >= max) break
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    /** Top tracks (taste seeds). */
    suspend fun topTracks(ctx: Context, max: Int = 20): List<SpotifyTrack> {
        return try {
            val json = getJson(
                ctx,
                "https://api.spotify.com/v1/me/top/tracks?limit=$max&time_range=medium_term"
            ) ?: return emptyList()
            val out = ArrayList<SpotifyTrack>()
            val items = json.optJSONArray("items") ?: return emptyList()
            for (i in 0 until items.length()) {
                val t = try {
                    parseTrack(items.optJSONObject(i) ?: continue)
                } catch (e: Exception) {
                    null
                } ?: continue
                out.add(t)
                if (out.size >= max) break
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }
}
