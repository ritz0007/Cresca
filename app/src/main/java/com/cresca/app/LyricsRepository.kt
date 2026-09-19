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
    // durationMs (track length, 0 when unknown) disambiguates covers and
    // wrong songs sharing a title. Returns null when nothing matches well.
    private fun searchLrclib(query: String, durationMs: Long): LyricsState? {
        try {
            val body = get(
                "https://lrclib.net/api/search?q=" + URLEncoder.encode(query, "UTF-8")
            ) ?: return null
            val arr = JSONArray(body)
            if (arr.length() == 0) {
                return null
            }
            var bestScore = -1000
            var bestSynced = ""
            var bestPlain = ""
            var bestLabel = ""
            val ql = query.lowercase()
            val qwords = ql.split(Regex("""\s+""")).filter { it.length > 3 }
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val tn = o.optString("trackName", "")
                val an = o.optString("artistName", "")
                if (tn.isBlank()) {
                    continue
                }
                val synced = o.optString("syncedLyrics", "")
                val plain = o.optString("plainLyrics", "")
                val durSec = o.optDouble("duration", Double.NaN)
                if (synced.isBlank() && plain.isBlank()) {
                    continue
                }
                val tl = tn.lowercase()
                val al = an.lowercase()
                // Strong title gate: need exact normalized equality, a
                // start-match, or 2+ significant shared words.
                val normQ = ql.replace(Regex("""[^a-z0-9 ]"""), " ")
                    .split(Regex("""\s+""")).filter { it.length > 2 }
                val normT = tl.replace(Regex("""[^a-z0-9 ]"""), " ")
                    .split(Regex("""\s+""")).filter { it.length > 2 }
                val shared = normQ.count { it in normT }
                val exactTitle = normQ.isNotEmpty() && normQ == normT
                val startMatch = normQ.isNotEmpty() && normT.isNotEmpty() &&
                    (normT.take(normQ.size) == normQ || normQ.take(normT.size) == normT)
                if (!exactTitle && !startMatch && shared < 2) {
                    continue
                }
                var score = 0
                if (synced.isNotBlank()) {
                    score += 4
                } else {
                    score += 1
                }
                if (exactTitle) {
                    score += 4
                } else if (startMatch) {
                    score += 2
                } else {
                    score += shared
                }
                if (al.isNotBlank()) {
                    val aw = al.split(Regex("""\s+""")).filter { it.length > 2 }
                    if (aw.isNotEmpty() && aw.all { ql.contains(it) }) {
                        score += 4
                    } else if (aw.any { ql.contains(it) }) {
                        score += 1
                    } else {
                        // Confident wrong artist: penalize hard.
                        score -= 4
                    }
                }
                // Duration proximity: official audio vs lyric video/covers.
                if (durationMs > 0 && !durSec.isNaN() && durSec > 0) {
                    val diff = kotlin.math.abs(durSec * 1000 - durationMs)
                    when {
                        diff <= 10000 -> score += 4
                        diff <= 25000 -> score += 1
                        diff > 60000 -> score -= 6
                        else -> score -= 2
                    }
                }
                if (score > bestScore) {
                    bestScore = score
                    bestSynced = synced
                    bestPlain = plain
                    bestLabel = "$tn - $an"
                }
            }
            if (bestScore < 4) {
                return null
            }
            if (bestSynced.isNotBlank()) {
                val lines = parseLrc(bestSynced)
                if (lines.isNotEmpty()) {
                    Log.i(TAG, "lyrics lrclib-search: $bestLabel (score $bestScore)")
                    return LyricsState.Synced(lines)
                }
            }
            if (bestPlain.isNotBlank()) {
                Log.i(TAG, "lyrics lrclib-search-plain: $bestLabel (score $bestScore)")
                return LyricsState.Plain(bestPlain)
            }
            return null
        } catch (e: Exception) {
            Log.w(TAG, "lrclib search failed", e)
            return null
        }
    }

    // Exact lrclib endpoint: precise artist+title hit when cleaning worked.
    private fun getLrclibExact(artist: String, title: String, durationMs: Long): LyricsState? {
        try {
            if (artist.isBlank() || title.isBlank()) {
                return null
            }
            val url = "https://lrclib.net/api/get?artist_name=" +
                URLEncoder.encode(artist, "UTF-8") + "&track_name=" +
                URLEncoder.encode(title, "UTF-8")
            val body = get(url) ?: return null
            val o = JSONObject(body)
            val synced = o.optString("syncedLyrics", "")
            val plain = o.optString("plainLyrics", "")
            if (synced.isBlank() && plain.isBlank()) {
                return null
            }
            val durSec = o.optDouble("duration", Double.NaN)
            if (durationMs > 0 && !durSec.isNaN() && durSec > 0 &&
                kotlin.math.abs(durSec * 1000 - durationMs) > 45000
            ) {
                Log.i(TAG, "lyrics exact rejected on duration")
                return null
            }
            if (synced.isNotBlank()) {
                val lines = parseLrc(synced)
                if (lines.isNotEmpty()) {
                    Log.i(TAG, "lyrics lrclib-exact: $title - $artist")
                    return LyricsState.Synced(lines)
                }
            }
            if (plain.isNotBlank()) {
                Log.i(TAG, "lyrics lrclib-exact-plain: $title - $artist")
                return LyricsState.Plain(plain)
            }
            return null
        } catch (e: Exception) {
            return null
        }
    }

    /** Free sources, no keys. Exact first, fuzzy variants, then plain. */
    suspend fun fetch(artist: String, title: String, durationMs: Long = 0L): LyricsState =
        withContext(Dispatchers.IO) {
            val a = cleanArtist(artist)
            val t = cleanTitle(title)
            if (t.length < 2) {
                return@withContext LyricsState.NotFound
            }
            try {
                getLrclibExact(a, t, durationMs)?.let { return@withContext it }
            } catch (e: Exception) {
            }
            val queries = ArrayList<String>()
            if (a.isNotBlank()) {
                queries.add("$t $a")
            }
            queries.add(t)
            for (q in queries) {
                try {
                    searchLrclib(q, durationMs)?.let { return@withContext it }
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
                        Log.i(TAG, "lyrics ovh-plain: $t")
                        return@withContext LyricsState.Plain(txt)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "lyrics.ovh failed", e)
            }
            LyricsState.NotFound
        }

    private fun parseLrc(lrc: String): List<LyricLine> {
        // Global offset tag shifts every line ([offset:+500] / [offset:-200]).
        var shift = 0L
        val offMatch = Regex("""\[offset:\s*([+-]?\d+)\]""").find(lrc)
        if (offMatch != null) {
            try {
                shift = offMatch.groupValues[1].toLong()
            } catch (e: Exception) {
            }
        }
        return lrc.lineSequence().mapNotNull { raw ->
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
            val at = (min * 60 + sec) * 1000 + ms + shift
            if (at < 0) return@mapNotNull null
            LyricLine(at, text)
        }.toList()
    }
}
