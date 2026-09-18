package com.cresca.app

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
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

    // Channels that are labels, not artists: searching them poisons results.
    private val labelWords = listOf(
        "t series", "tseries", "tips", "zee music", "saregama",
        "sony music", "universal", "yrf", "eros", "ipop",
        "times music", "maddock", "tips official", "melody", "records"
    )

    private fun cleanArtist(raw: String): String {
        var s = raw.split("|", "|", "•").firstOrNull()?.trim() ?: raw
        s = s.split(
            Regex("""\s+(and|&|\+|,|x|with|feat\.?|ft\.?)\s+""", RegexOption.IGNORE_CASE)
        ).firstOrNull()?.trim() ?: s
        s = s.replace(
            Regex("""(?i)\b(vevo|official|music|records|films|company|studios?|superhits|entertainment|media|productions?|originals|topic|channel)\b"""),
            " "
        )
        s = s.replace(Regex("""[^A-Za-z ]"""), " ")
        s = s.split(Regex("""\s+""")).filter { it.isNotBlank() }.take(3).joinToString(" ").trim()
        if (s.isEmpty()) {
            return ""
        }
        val low = s.lowercase()
        for (w in labelWords) {
            if (low.contains(w)) {
                return ""
            }
        }
        // "SonyMusicIndia" style channel blobs carry no artist signal.
        if (!s.contains(" ") && s.length > 10) {
            return ""
        }
        return s
    }

    private fun cleanTitle(raw: String): String {
        var s = raw
            .replace(Regex("""\s*[\(\[].*?(official|video|audio|lyric|visualizer).*?[\)\]]""", RegexOption.IGNORE_CASE), "")
            .replace(Regex("""\s+[|｜].*$"""), "")
            .trim()
        // "Shayad - Love Aaj Kal" -> "Shayad" (song name leads).
        val dash = s.indexOf(" - ")
        if (dash >= 3) {
            s = s.substring(0, dash).trim()
        }
        s = s.replace(Regex("""\s*[\(\[].*?[\)\]]"""), "").trim()
        return s
    }

    private fun get(url: String): String? {
        return try {
            val req = Request.Builder().url(url)
                .header("User-Agent", "Cresca/0.1").get().build()
            http.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) {
                    return null
                }
                resp.body?.string()
            }
        } catch (e: Exception) {
            null
        }
    }

    // Fuzzy lrclib search: full records come back, synced lyrics included.
    // Returns null when nothing matches well enough.
    private fun searchLrclib(query: String): LyricsState? {
        try {
            val body = get(
                "https://lrclib.net/api/search?q=" + URLEncoder.encode(query, "UTF-8")
            ) ?: return null
            val arr = JSONArray(body)
            if (arr.length() == 0) {
                return null
            }
            var bestScore = -1
            var bestSynced = ""
            var bestPlain = ""
            val ql = query.lowercase()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val tn = o.optString("trackName", "")
                val an = o.optString("artistName", "")
                if (tn.isBlank()) {
                    continue
                }
                var score = 0
                val synced = o.optString("syncedLyrics", "")
                val plain = o.optString("plainLyrics", "")
                if (synced.isNotBlank()) {
                    score += 3
                } else if (plain.isNotBlank()) {
                    score += 1
                } else {
                    continue
                }
                val tl = tn.lowercase()
                val al = an.lowercase()
                // Title word overlap required: kills unrelated hits.
                val qwords = ql.split(Regex("""\s+""")).filter { it.length > 3 }
                var overlap = false
                for (w in qwords) {
                    if (tl.contains(w)) {
                        overlap = true
                        break
                    }
                }
                if (!overlap) {
                    continue
                }
                if (tl.startsWith(qwords.firstOrNull() ?: "@@@")) {
                    score += 1
                }
                if (al.isNotBlank() && ql.contains(al.split(" ").firstOrNull() ?: "@@@")) {
                    score += 1
                }
                if (score > bestScore) {
                    bestScore = score
                    bestSynced = synced
                    bestPlain = plain
                }
            }
            if (bestScore < 0) {
                return null
            }
            if (bestSynced.isNotBlank()) {
                val lines = parseLrc(bestSynced)
                if (lines.isNotEmpty()) {
                    return LyricsState.Synced(lines)
                }
            }
            if (bestPlain.isNotBlank()) {
                return LyricsState.Plain(bestPlain)
            }
            return null
        } catch (e: Exception) {
            Log.w(TAG, "lrclib search failed", e)
            return null
        }
    }

    /** Free sources, no keys. Tries fuzzy variants before giving up. */
    suspend fun fetch(artist: String, title: String): LyricsState =
        withContext(Dispatchers.IO) {
            val a = cleanArtist(artist)
            val t = cleanTitle(title)
            if (t.length < 2) {
                return@withContext LyricsState.NotFound
            }
            val queries = ArrayList<String>()
            if (a.isNotBlank()) {
                queries.add("$t $a")
            }
            queries.add(t)
            for (q in queries) {
                try {
                    searchLrclib(q)?.let { return@withContext it }
                } catch (e: Exception) {
                }
            }
            // Source 2: lyrics.ovh, plain lyrics, no key needed.
            try {
                val who = if (a.isNotBlank()) a else t
                val url2 = "https://api.lyrics.ovh/v1/" +
                    URLEncoder.encode(who, "UTF-8") +
                    "/" + URLEncoder.encode(t, "UTF-8")
                val body = get(url2)
                if (body != null) {
                    val txt = JSONObject(body).optString("lyrics", "").trim()
                    if (txt.isNotBlank()) {
                        return@withContext LyricsState.Plain(txt)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "lyrics.ovh failed", e)
            }
            LyricsState.NotFound
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
