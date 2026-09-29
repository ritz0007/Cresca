package com.cresca.app.spotify

import android.content.Context
import android.util.Log
import com.cresca.app.PlaylistStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

data class SyncResult(
    val added: Int = 0,
    val removed: Int = 0,
    val lists: Int = 0
)

/**
 * Live Spotify → app sync. Mirrors are linked by Playlist.spotifyId
 * (rename-safe; legacy mirrors match by "Spotify • <name>" once and get
 * linked). Cheap path first: equal track counts skip the list entirely;
 * otherwise every ref is re-resolved and the mirror is diffed (adds +
 * removes). Vanished Spotify playlists delete their mirror. Throttled by
 * the caller (6h); never throws.
 */
object SpotifySync {
    private const val TAG = "SpotifySync"
    private const val PREFS = "cresca_prefs"
    private const val K_LAST = "spotify_last_sync"
    const val THROTTLE_MS = 6 * 60 * 60 * 1000L

    fun lastSync(ctx: Context): Long {
        return try {
            ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getLong(K_LAST, 0L)
        } catch (e: Exception) {
            0L
        }
    }

    private fun stampSync(ctx: Context) {
        try {
            ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putLong(K_LAST, System.currentTimeMillis()).apply()
        } catch (e: Exception) {
        }
    }

    suspend fun syncAll(
        ctx: Context,
        onStage: (String) -> Unit = {}
    ): SyncResult = withContext(Dispatchers.IO) {
        try {
            val app = ctx.applicationContext
            if (SpotifyAuth.accessToken(app).isBlank()) return@withContext SyncResult()
            val (ok, lists) = try {
                SpotifyApi.myPlaylists(app, 50)
            } catch (e: Exception) {
                Pair(false, emptyList())
            }
            // Never delete on fetch failure: only sync against a live answer.
            if (!ok) return@withContext SyncResult()
            var added = 0
            var removed = 0
            var touched = 0
            val currentIds = lists.map { it.id }.toHashSet()
            val mirrors = try {
                PlaylistStore.list(app).filter { it.spotifyId.isNotBlank() }
            } catch (e: Exception) {
                emptyList()
            }
            // 1) Vanished Spotify playlists drop their mirror (Liked never).
            for (m in mirrors) {
                try {
                    if (m.spotifyId != "spotify:liked" && !currentIds.contains(m.spotifyId)) {
                        PlaylistStore.delete(app, m.id)
                        touched++
                    }
                } catch (e: Exception) {
                }
            }
            // 2) Per-list diff.
            for (pl in lists) {
                try {
                    val mirror = try {
                        mirrors.find { it.spotifyId == pl.id }
                            ?: PlaylistStore.list(app).find { it.name == "Spotify • ${pl.name}" }
                    } catch (e: Exception) {
                        null
                    }
                    val refs = try {
                        SpotifyApi.playlistTracks(app, pl.id, 500)
                    } catch (e: Exception) {
                        emptyList()
                    }
                    if (refs.isEmpty()) continue
                    if (mirror == null) {
                        // Brand-new Spotify playlist: mirror it from scratch.
                        val created = try {
                            PlaylistStore.create(app, "Spotify • ${pl.name}", pl.id)
                        } catch (e: Exception) {
                            null
                        } ?: continue
                        val seen = HashSet<String>()
                        for (r in refs) {
                            val t = SpotifyImport.resolveOne(r) ?: continue
                            if (!seen.add(t.id)) continue
                            try {
                                if (PlaylistStore.add(app, created.id, t)) added++
                            } catch (e: Exception) {
                            }
                            try {
                                delay(250)
                            } catch (e: Exception) {
                            }
                        }
                        touched++
                        try {
                            onStage("Spotify • ${pl.name}")
                        } catch (e: Exception) {
                        }
                        continue
                    }
                    // Fast path: same size ≈ same content (swap-with-same-size
                    // is the known miss; full diff on any size change).
                    if (refs.size == mirror.tracks.size) continue
                    if (mirror.spotifyId.isBlank()) {
                        try {
                            PlaylistStore.setSpotifyId(app, mirror.id, pl.id)
                        } catch (e: Exception) {
                        }
                    }
                    val live = HashSet<String>()
                    for (r in refs) {
                        val t = try {
                            SpotifyImport.resolveOne(r)
                        } catch (e: Exception) {
                            null
                        } ?: continue
                        live.add(t.id)
                        if (mirror.tracks.none { it.id == t.id }) {
                            try {
                                if (PlaylistStore.add(app, mirror.id, t)) added++
                            } catch (e: Exception) {
                            }
                        }
                        try {
                            delay(250)
                        } catch (e: Exception) {
                        }
                    }
                    for (t in mirror.tracks) {
                        if (!live.contains(t.id)) {
                            try {
                                PlaylistStore.remove(app, mirror.id, t.id)
                                removed++
                            } catch (e: Exception) {
                            }
                        }
                    }
                    touched++
                    try {
                        onStage("Spotify • ${pl.name}")
                    } catch (e: Exception) {
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "sync list failed (${pl.name})", e)
                }
            }
            // 3) Liked diff (same shape, its own mirror key).
            try {
                val liked = try {
                    mirrors.find { it.spotifyId == "spotify:liked" }
                        ?: PlaylistStore.list(app).find { it.name == "Spotify • Liked Songs" }
                } catch (e: Exception) {
                    null
                }
                val refs = try {
                    SpotifyApi.savedTracks(app, 1500)
                } catch (e: Exception) {
                    emptyList()
                }
                if (refs.isNotEmpty()) {
                    if (liked == null) {
                        val created = try {
                            PlaylistStore.create(app, "Spotify • Liked Songs", "spotify:liked")
                        } catch (e: Exception) {
                            null
                        }
                        if (created != null) {
                            val seen = HashSet<String>()
                            for (r in refs) {
                                val t = SpotifyImport.resolveOne(r) ?: continue
                                if (!seen.add(t.id)) continue
                                try {
                                    if (PlaylistStore.add(app, created.id, t)) added++
                                } catch (e: Exception) {
                                }
                                try {
                                    delay(250)
                                } catch (e: Exception) {
                                }
                            }
                            touched++
                        }
                    } else if (refs.size != liked.tracks.size) {
                        if (liked.spotifyId.isBlank()) {
                            try {
                                PlaylistStore.setSpotifyId(app, liked.id, "spotify:liked")
                            } catch (e: Exception) {
                            }
                        }
                        val live = HashSet<String>()
                        for (r in refs) {
                            val t = try {
                                SpotifyImport.resolveOne(r)
                            } catch (e: Exception) {
                                null
                            } ?: continue
                            live.add(t.id)
                            if (liked.tracks.none { it.id == t.id }) {
                                try {
                                    if (PlaylistStore.add(app, liked.id, t)) added++
                                } catch (e: Exception) {
                                }
                            }
                            try {
                                delay(250)
                            } catch (e: Exception) {
                            }
                        }
                        for (t in liked.tracks) {
                            if (!live.contains(t.id)) {
                                try {
                                    PlaylistStore.remove(app, liked.id, t.id)
                                    removed++
                                } catch (e: Exception) {
                                }
                            }
                        }
                        touched++
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "sync liked failed", e)
            }
            try {
                stampSync(app)
            } catch (e: Exception) {
            }
            try {
                Log.i(TAG, "sync done: +$added -$removed ~$touched lists")
            } catch (e: Exception) {
            }
            SyncResult(added, removed, touched)
        } catch (e: Exception) {
            Log.w(TAG, "sync failed", e)
            SyncResult()
        }
    }
}
