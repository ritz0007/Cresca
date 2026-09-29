package com.cresca.app.spotify

import android.content.Context
import android.util.Log
import com.cresca.app.PlaylistStore
import com.cresca.app.RecentStore
import com.cresca.app.YoutubeRepository
import com.cresca.app.YtTrack
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

data class ImportResult(
    val playlists: Int = 0,
    val tracks: Int = 0,
    val liked: Int = 0,
    val topArtists: List<String> = emptyList(),
    /** Spotify tracks seen (0 = Spotify unreachable / empty library). */
    val fetched: Int = 0,
    /** Lists skipped because a "Spotify • <name>" already exists. */
    val skipped: Int = 0,
    /** True when every fetched ref was processed (safe to mark done). */
    val complete: Boolean = false,
    /** Playlists endpoint answered (false = never reached Spotify). */
    val playlistsOk: Boolean = true,
    /** Playlists seen on Spotify (0 with ok=true = truly no playlists). */
    val listsSeen: Int = 0
)

/**
 * Spotify → Cresca importer: each Spotify track is resolved to a YouTube
 * track via the existing music search (first hit), then stored as a local
 * playlist ("Spotify • <name>"). Taste (top artists/tracks) feeds home
 * rails exactly like the YT taste seeds — recommendations only.
 */
object SpotifyImport {
    private const val TAG = "SpotifyImport"

    /** Prefs keys for per-list completion (resume without re-work). */
    private const val PREFS = "cresca_prefs"
    private const val K_DONE = "spotify_import_done"
    private const val K_TASTE = "spotify_taste_done"

    fun isImportDone(ctx: Context): Boolean {
        return try {
            ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(K_DONE, false)
        } catch (e: Exception) {
            false
        }
    }

    internal fun setImportDone(ctx: Context, done: Boolean) {
        try {
            ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(K_DONE, done).apply()
        } catch (e: Exception) {
        }
    }

    /** Clears all import progress (call on Spotify logout → next connect re-imports). */
    fun clearProgress(ctx: Context) {
        try {
            val p = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val e = p.edit().remove(K_DONE).remove(K_TASTE)
            try {
                for (k in p.all.keys) {
                    if (k.startsWith("spotify_done_pl_") || k == "spotify_done_liked") e.remove(k)
                }
            } catch (e2: Exception) {
            }
            e.apply()
        } catch (e: Exception) {
        }
    }
    /** Pure: YouTube search query for a Spotify track (unit-tested). */
    internal fun queryFor(t: SpotifyTrack): String {
        return try {
            val artist = t.artists.firstOrNull()?.trim() ?: ""
            ("${t.name} $artist").trim().replace(Regex("""\s+"""), " ")
        } catch (e: Exception) {
            t.name
        }
    }

    internal suspend fun resolveOne(ref: SpotifyTrack): YtTrack? {
        return try {
            val q = queryFor(ref)
            if (q.isBlank()) return null
            YoutubeRepository.searchMusic(q, 3).firstOrNull()
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Imports everything: playlists + Liked Songs + taste. Runs in the
     * background after connect — caps are generous, resolves are paced
     * (~4/sec) to stay gentle on the network. Each local playlist is
     * created FIRST and filled track-by-track, so Library grows live
     * while the import runs. Already-imported lists (by
     * "Spotify • <name>") are skipped so reconnects never duplicate.
     */
    suspend fun importAll(
        ctx: Context,
        maxPlaylists: Int = 50,
        perPlaylist: Int = 500,
        maxTotal: Int = 2500,
        onProgress: (done: Int, total: Int, stage: String) -> Unit = { _, _, _ -> }
    ): ImportResult = withContext(Dispatchers.IO) {
        try {
            val app = ctx.applicationContext
            val (playlistsOk, lists) = try {
                SpotifyApi.myPlaylists(app, maxPlaylists)
            } catch (e: Exception) {
                Pair(false, emptyList())
            }
            // Early signal (status + log): how many playlists Spotify claims.
            try {
                Log.i(TAG, "spotify lists: ${lists.size} ok=$playlistsOk")
            } catch (e: Exception) {
            }
            try {
                onProgress(0, 1, "${lists.size} playlists found")
            } catch (e: Exception) {
            }
            val existingMap = try {
                PlaylistStore.list(app).associateBy { it.name }
            } catch (e: Exception) {
                emptyMap()
            }
            val mirrorBySpotify = try {
                PlaylistStore.list(app).filter { it.spotifyId.isNotBlank() }
                    .associateBy { it.spotifyId }
            } catch (e: Exception) {
                emptyMap()
            }
            val progPrefs = try {
                app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            } catch (e: Exception) {
                null
            }
            fun isListDone(key: String): Boolean {
                return try {
                    progPrefs?.getBoolean("spotify_done_$key", false) == true
                } catch (e: Exception) {
                    false
                }
            }
            fun markListDone(key: String) {
                try {
                    progPrefs?.edit()?.putBoolean("spotify_done_$key", true)?.apply()
                } catch (e: Exception) {
                }
            }
            var totalResolved = 0
            var donePlaylists = 0
            var skipped = 0
            var fetched = 0
            var hitCap = false
            // Progress estimate, self-correcting: starts from Spotify's
            // totals, then adjusts to actual fetched sizes (Spotify totals
            // can disagree). Shown total never drops below done.
            var totalEst = (lists.sumOf { it.total } + 50).coerceAtLeast(1)
            var done = 0
            fun progress(stage: String) {
                try {
                    val shown = if (totalEst > done) totalEst else done
                    onProgress(done, shown, stage)
                } catch (e: Exception) {
                }
            }
            for (pl in lists) {
                if (totalResolved >= maxTotal) {
                    hitCap = true
                    break
                }
                val localName = "Spotify • ${pl.name}"
                val flagKey = "pl_${pl.id}"
                // Rename-safe link first (spotifyId survives renames), then legacy name.
                val local = mirrorBySpotify[pl.id] ?: existingMap[localName]
                if (local != null && isListDone(flagKey)) {
                    skipped++
                    continue
                }
                try {
                    val refs = SpotifyApi.playlistTracks(app, pl.id, perPlaylist)
                    if (refs.isEmpty()) continue
                    fetched += refs.size
                    totalEst += refs.size - pl.total
                    // Create first (or reuse): Library fills live as tracks resolve.
                    var created = local ?: try {
                        PlaylistStore.create(app, localName, pl.id)
                    } catch (e: Exception) {
                        null
                    } ?: continue
                    // Older mirrors lack the link: attach it once.
                    if (created.spotifyId.isBlank()) {
                        try {
                            PlaylistStore.setSpotifyId(app, created.id, pl.id)
                        } catch (e: Exception) {
                        }
                    }
                    val known = try {
                        (local?.tracks ?: emptyList()).map { it.id }.toHashSet()
                    } catch (e: Exception) {
                        HashSet()
                    }
                    val seen = HashSet<String>()
                    var added = 0
                    var finished = true
                    for (r in refs) {
                        if (totalResolved >= maxTotal) {
                            hitCap = true
                            finished = false
                            break
                        }
                        val t = resolveOne(r)
                        if (t != null && seen.add(t.id) && !known.contains(t.id)) {
                            try {
                                if (PlaylistStore.add(app, created.id, t)) {
                                    added++
                                    totalResolved++
                                    known.add(t.id)
                                }
                            } catch (e: Exception) {
                            }
                        }
                        done++
                        progress(localName)
                        try {
                            delay(250)
                        } catch (e: Exception) {
                        }
                    }
                    if (added > 0) donePlaylists++
                    if (finished) markListDone(flagKey)
                } catch (e: Exception) {
                    Log.w(TAG, "playlist import failed (${pl.name})", e)
                }
            }
            // Liked Songs → its own local playlist (merged when present).
            var likedCount = 0
            try {
                val likedName = "Spotify • Liked Songs"
                val likedLocal = mirrorBySpotify["spotify:liked"] ?: existingMap[likedName]
                if (likedLocal == null || !isListDone("liked")) {
                    val likedRefs = SpotifyApi.savedTracks(app, 1500)
                    if (likedRefs.isNotEmpty()) {
                        fetched += likedRefs.size
                        var created = likedLocal ?: try {
                            PlaylistStore.create(app, likedName, "spotify:liked")
                        } catch (e: Exception) {
                            null
                        }
                        if (created != null && created.spotifyId.isBlank()) {
                            try {
                                PlaylistStore.setSpotifyId(app, created.id, "spotify:liked")
                            } catch (e: Exception) {
                            }
                            created = created.copy(spotifyId = "spotify:liked")
                        }
                        if (created != null) {
                            val known = try {
                                (likedLocal?.tracks ?: emptyList()).map { it.id }.toHashSet()
                            } catch (e: Exception) {
                                HashSet()
                            }
                            val seen = HashSet<String>()
                            var finished = true
                            for (r in likedRefs) {
                                if (totalResolved >= maxTotal) {
                                    hitCap = true
                                    finished = false
                                    break
                                }
                                val t = resolveOne(r)
                                if (t != null && seen.add(t.id) && !known.contains(t.id)) {
                                    try {
                                        if (PlaylistStore.add(app, created.id, t)) {
                                            likedCount++
                                            totalResolved++
                                            known.add(t.id)
                                        }
                                    } catch (e: Exception) {
                                    }
                                }
                                done++
                                progress(likedName)
                                try {
                                    delay(250)
                                } catch (e: Exception) {
                                }
                            }
                            if (finished) markListDone("liked")
                        }
                    }
                } else {
                    skipped++
                }
            } catch (e: Exception) {
                Log.w(TAG, "liked import failed", e)
            }
            // Preferences/taste: top artists (rails) + top tracks (seeds file).
            // Runs when something new arrived or taste was never saved.
            val tasteDone = try {
                progPrefs?.getBoolean(K_TASTE, false) == true
            } catch (e: Exception) {
                false
            }
            val artists = try {
                SpotifyApi.topArtists(app, 20)
            } catch (e: Exception) {
                emptyList()
            }
            try {
                if (artists.isNotEmpty()) {
                    app.getSharedPreferences("cresca_prefs", Context.MODE_PRIVATE)
                        .edit().putString("spotify_top_artists", artists.joinToString(","))
                        .apply()
                }
            } catch (e: Exception) {
            }
            if (totalResolved > 0 || !tasteDone) {
                try {
                    val topRefs = SpotifyApi.topTracks(app, 20)
                    val seeds = ArrayList<YtTrack>()
                    for (r in topRefs) {
                        val t = resolveOne(r) ?: continue
                        if (seeds.none { it.id == t.id }) seeds.add(t)
                    }
                    if (seeds.isNotEmpty()) RecentStore.save(app, seeds, "spotify_seeds.json")
                    try {
                        progPrefs?.edit()?.putBoolean(K_TASTE, true)?.apply()
                    } catch (e: Exception) {
                    }
                } catch (e: Exception) {
                }
            }
            val complete = fetched > 0 && !hitCap
            try {
                Log.i(TAG, "import done: $donePlaylists lists, $totalResolved tracks, $likedCount liked, $skipped skipped, complete=$complete listsSeen=${lists.size} playlistsOk=$playlistsOk")
            } catch (e: Exception) {
            }
            ImportResult(donePlaylists, totalResolved, likedCount, artists, fetched, skipped, complete, playlistsOk, lists.size)
        } catch (e: Exception) {
            Log.w(TAG, "import failed", e)
            ImportResult()
        }
    }
}
