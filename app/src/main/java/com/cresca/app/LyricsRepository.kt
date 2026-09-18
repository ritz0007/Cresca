package com.cresca.app

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.net.URLEncoder

data class LyricLine(val ms: Long, val text: String)

sealed interface LyricsState {
    data object Loading : LyricsState
    data class Synced(val lines: List<LyricLine>) : LyricsState
    data class Plain(val text: String) : LyricsState
    data object NotFound : LyricsState
}

object LyricsRepository {
    private const val TAG = "LyricsRepo"
    private val http = OkHttpClient()
    private val lrcLine = Regex("""\[(\d+):(\d+)[.:](\d+)\](.*)""")

    /** Free lrclib API, no key needed. Falls back gracefully. */
    suspend fun fetch(artist: String, title: String): LyricsState =
        withContext(Dispatchers.IO) {
            try {
                // Strip " (Official Video)" junk for better matches
                val cleanTitle = title
                    .replace(Regex("""\s*[\(\[].*?(official|video|audio|lyric|visualizer).*?[\)\]]""", RegexOption.IGNORE_CASE), "")
                    .replace(Regex("""\s+[|｜].*$"""), "")
                    .trim()
                val url = "https://lrclib.net/api/get?artist_name=" +
                    URLEncoder.encode(artist, "UTF-8") +
                    "&track_name=" + URLEncoder.encode(cleanTitle, "UTF-8")
                val req = Request.Builder().url(url)
                    .header("User-Agent", "Cresca/0.1").get().build()
                http.newCall(req).execute().use { resp ->
                    if (resp.isSuccessful) {
                        val json = JSONObject(resp.body?.string() ?: "")
                        val synced = json.optString("syncedLyrics", "")
                        val plain = json.optString("plainLyrics", "")
                        if (synced.isNotBlank()) {
                            val lines = parseLrc(synced)
                            if (lines.isNotEmpty()) return@withContext LyricsState.Synced(lines)
                        }
                        if (plain.isNotBlank()) return@withContext LyricsState.Plain(plain)
                    }
                }
                // Source 2: lyrics.ovh, plain lyrics, no key needed.
                try {
                    val url2 = "https://api.lyrics.ovh/v1/" +
                        URLEncoder.encode(artist, "UTF-8") +
                        "/" + URLEncoder.encode(cleanTitle, "UTF-8")
                    val req2 = Request.Builder().url(url2)
                        .header("User-Agent", "Cresca/0.1").get().build()
                    http.newCall(req2).execute().use { resp2 ->
                        if (resp2.isSuccessful) {
                            val txt = JSONObject(resp2.body?.string() ?: "")
                                .optString("lyrics", "").trim()
                            if (txt.isNotBlank()) {
                                return@withContext LyricsState.Plain(txt)
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "lyrics.ovh failed", e)
                }
                LyricsState.NotFound
            } catch (e: Exception) {
                Log.w(TAG, "lyrics fetch failed", e)
                LyricsState.NotFound
            }
        }

    private fun parseLrc(lrc: String): List<LyricLine> =
        lrc.lineSequence().mapNotNull { raw ->
            val m = lrcLine.find(raw.trim()) ?: return@mapNotNull null
            val text = m.groupValues[4].trim()
            if (text.isEmpty()) return@mapNotNull null
            val min = m.groupValues[1].toLong()
            val sec = m.groupValues[2].toLong()
            var frac = m.groupValues[3]
            val ms = when (frac.length) {
                2 -> frac.toLong() * 10
                3 -> frac.toLong()
                else -> {
                    frac = (frac + "000").take(3)
                    frac.toLong()
                }
            }
            LyricLine((min * 60 + sec) * 1000 + ms, text)
        }.toList()
}
