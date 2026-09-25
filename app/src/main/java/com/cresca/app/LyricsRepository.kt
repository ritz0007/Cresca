package com.cresca.app

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap

/** Unified lyric line: both YouTube captions and LRCLIB normalize here. */
data class LyricLine(val startTimeMs: Long, val text: String)

/** Compat alias for the historical `ms` name (call sites/tests untouched). */
val LyricLine.ms: Long get() = startTimeMs

enum class LyricSource { YOUTUBE_CAPTIONS, LRCLIB, NONE }

/** Unified result across providers (captions primary, LRCLIB fallback). */
data class LyricsResult(
    val isSynced: Boolean,
    val lines: List<LyricLine>,
    val source: LyricSource
)

sealed interface LyricsState {
    data object Loading : LyricsState
    data class Synced(
        val lines: List<LyricLine>,
        val source: LyricSource = LyricSource.LRCLIB
    ) : LyricsState
    data class Plain(val text: String) : LyricsState
    data object NotFound : LyricsState
}

/** Unified view of any [LyricsState] (captions + LRCLIB normalize here). */
fun LyricsState.toResult(): LyricsResult = when (this) {
    is LyricsState.Synced -> LyricsResult(true, lines, source)
    is LyricsState.Plain -> LyricsResult(
        false, listOf(LyricLine(0L, text)), LyricSource.LRCLIB
    )
    else -> LyricsResult(false, emptyList(), LyricSource.NONE)
}

object LyricsRepository {
    private const val TAG = "LyricsRepo"
    private val http = OkHttpClient()
    private val lrcLine = Regex("""\[(\d+):(\d+)[.:](\d+)\](.*)""")

    /** Per-video lyrics memo: track re-entry never re-hits the network. */
    private val cache = ConcurrentHashMap<String, LyricsState>()

    private fun cachePut(videoId: String, state: LyricsState) {
        try {
            if (videoId.length != 11) return
            if (cache.size > 128) cache.clear()
            cache[videoId] = state
        } catch (e: Exception) {
        }
    }

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

    /** Last timestamp in synced LRC (0 when unparseable). Pure, tested. */
    internal fun lastLineMs(synced: String): Long {
        return try {
            var last = 0L
            for (m in lrcLine.findAll(synced)) {
                try {
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
                    last = maxOf(last, (min * 60 + sec) * 1000 + ms)
                } catch (e: Exception) {
                }
            }
            last
        } catch (e: Exception) {
            0L
        }
    }

    /**
     * Timestamp-consistency penalty: lines must live inside the record's own
     * duration. Kills mistimed records (e.g. full-length timestamps attached
     * to a 3:00 sped-up upload) that text scoring alone cannot catch.
     */
    internal fun consistencyPenalty(lastMs: Long, durSec: Double): Int {
        return try {
            if (lastMs <= 0L || durSec.isNaN() || durSec <= 0) return 0
            val durMs = (durSec * 1000).toLong()
            when {
                lastMs > durMs + 15000 -> -8
                lastMs < (durMs * 0.6).toLong() -> -4
                else -> 0
            }
        } catch (e: Exception) {
            0
        }
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
                // Bands are tight on purpose: a 30s-longer music video with
                // audio-timed lines desyncs visibly ("lyrics run faster").
                if (durationMs > 0 && !durSec.isNaN() && durSec > 0) {
                    val diff = kotlin.math.abs(durSec * 1000 - durationMs)
                    when {
                        diff <= 10000 -> score += 4
                        diff <= 25000 -> score += 1
                        diff > 60000 -> score -= 6
                        else -> score -= 4
                    }
                }
                // Timestamp consistency: the record's own lines must fit its
                // own duration (catches full-length lines on sped-up uploads
                // that text scoring cannot see).
                if (synced.isNotBlank() && !durSec.isNaN() && durSec > 0) {
                    try {
                        score += consistencyPenalty(lastLineMs(synced), durSec)
                    } catch (e: Exception) {
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
                kotlin.math.abs(durSec * 1000 - durationMs) > 30000
            ) {
                Log.i(TAG, "lyrics exact rejected on duration")
                return null
            }
            // Same mistimed-record guard as fuzzy search.
            if (synced.isNotBlank() && !durSec.isNaN() && durSec > 0) {
                try {
                    if (consistencyPenalty(lastLineMs(synced), durSec) < 0) {
                        Log.i(TAG, "lyrics exact rejected on consistency")
                        return null
                    }
                } catch (e: Exception) {
                }
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

    /**
     * Primary pipeline: YouTube captions for this exact video first
     * (video-timed, always in sync), LRCLIB exact/fuzzy + lyrics.ovh
     * strictly as fallback. Results memoize per videoId.
     */
    suspend fun fetch(
        videoId: String,
        artist: String,
        title: String,
        durationMs: Long = 0L
    ): LyricsState =
        withContext(Dispatchers.IO) {
            val vid = videoId.trim()
            if (vid.length == 11) {
                try {
                    cache[vid]?.let { return@withContext it }
                } catch (e: Exception) {
                }
                // Race: captions and LRCLIB run concurrently; captions win
                // on ties (video-timed), but a caption miss never delays
                // the fallback — latency is the min, not the sum.
                val capDef = async {
                    try {
                        withTimeoutOrNull(9000L) { fetchCaptions(vid) }
                    } catch (e: Exception) {
                        LyricsState.NotFound
                    }
                }
                val lrcDef = async { fetchLrclib(artist, title, durationMs) }
                try {
                    val capped = capDef.await()
                    if (capped is LyricsState.Synced && capped.lines.size >= 3) {
                        try {
                            lrcDef.cancel()
                        } catch (e: Exception) {
                        }
                        cachePut(vid, capped)
                        return@withContext capped
                    }
                } catch (e: Exception) {
                }
                val res = try {
                    lrcDef.await()
                } catch (e: Exception) {
                    LyricsState.NotFound
                }
                if (res !is LyricsState.NotFound) {
                    cachePut(vid, res)
                }
                return@withContext res
            }
            fetchLrclib(artist, title, durationMs)
        }

    /** Back-compat overload (no video: LRCLIB path only). */
    suspend fun fetch(artist: String, title: String, durationMs: Long = 0L): LyricsState =
        fetch("", artist, title, durationMs)

    /**
     * YouTube captions leg: InnerTube timedtext first, NewPipeExtractor
     * subtitles second. Both normalize into [LyricLine]. NotFound when
     * captions are absent, disabled, or unparseable.
     */
    internal suspend fun fetchCaptions(videoId: String): LyricsState =
        withContext(Dispatchers.IO) {
            // 1. InnerTube timedtext captionTracks.
            try {
                val cookies = try {
                    YoutubeRepository.sessionCookies()
                } catch (e: Exception) {
                    ""
                }
                val tracks = try {
                    com.cresca.app.innertube.InnerTubeApi.captionTracks(
                        videoId, cookies, ""
                    )
                } catch (e: Exception) {
                    emptyList()
                }
                for (t in tracks.take(3)) {
                    try {
                        val raw = com.cresca.app.innertube.InnerTubeApi
                            .fetchCaptionText(t.baseUrl) ?: continue
                        val lines = parseCaptions(raw)
                        if (lines.size >= 3) {
                            Log.i(TAG, "lyrics youtube-captions: ${t.lang} auto=${t.isAuto} ${lines.size} lines")
                            return@withContext LyricsState.Synced(
                                lines, LyricSource.YOUTUBE_CAPTIONS
                            )
                        }
                    } catch (e: Exception) {
                    }
                }
            } catch (e: Exception) {
            }
            // 2. NewPipeExtractor subtitles.
            try {
                val lines = withTimeoutOrNull(8000L) {
                    YoutubeRepository.captionLines(videoId)
                }
                if (lines != null && lines.size >= 3) {
                    return@withContext LyricsState.Synced(
                        lines, LyricSource.YOUTUBE_CAPTIONS
                    )
                }
            } catch (e: Exception) {
            }
            LyricsState.NotFound
        }

    /** Free sources, no keys. Exact first, fuzzy variants, then plain. */
    suspend fun fetchLrclib(artist: String, title: String, durationMs: Long = 0L): LyricsState =
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

    // ------------------------------------------------------------------
    // Caption parsers (pure, JVM-testable: regex/string ops only, no
    // Android APIs). WebVTT, SRT, and YouTube timedtext XML all land in
    // the same [LyricLine] model LRCLIB uses.
    // ------------------------------------------------------------------

    private val cueTs = Regex(
        """(\d{2,}:\d{2}:\d{2}[.,]\d{1,3}|\d{2}:\d{2}[.,]\d{1,3})\s*-->\s*(\d{2,}:\d{2}:\d{2}[.,]\d{1,3}|\d{2}:\d{2}[.,]\d{1,3})"""
    )
    private val xmlText = Regex("""<text\b([^>]*)>(.*?)</text>""", RegexOption.DOT_MATCHES_ALL)
    private val xmlStart = Regex("""start="([\d.]+)"""")
    private val bracketOnly = Regex("""^[\s♪♫\[\(（].*[\]）\)\s♪♫]*$""")

    internal fun vttTsToMs(ts: String): Long {
        return try {
            val norm = ts.trim().replace(',', '.')
            val parts = norm.split(":")
            val secParts = parts.last().split(".")
            val sec = secParts[0].toLong()
            var frac = (secParts.getOrNull(1) ?: "0")
            frac = (frac + "000").take(3)
            val ms = frac.toLong()
            val min = if (parts.size == 3) parts[1].toLong() else parts[0].toLong()
            val hour = if (parts.size == 3) parts[0].toLong() else 0L
            ((hour * 3600 + min * 60 + sec) * 1000) + ms
        } catch (e: Exception) {
            -1L
        }
    }

    internal fun unescapeEntities(s: String): String {
        return try {
            var r = s.replace("&amp;", "&").replace("&lt;", "<")
                .replace("&gt;", ">").replace("&quot;", "\"")
                .replace("&#39;", "'").replace("&apos;", "'")
                .replace("&nbsp;", " ")
            r = r.replace(Regex("&#(\\d+);")) {
                try {
                    String(Character.toChars(it.groupValues[1].toInt()))
                } catch (e: Exception) {
                    it.value
                }
            }
            r.replace(Regex("&#x([0-9a-fA-F]+);")) {
                try {
                    String(Character.toChars(it.groupValues[1].toInt(16)))
                } catch (e: Exception) {
                    it.value
                }
            }
        } catch (e: Exception) {
            s
        }
    }

    /** Shared caption hygiene: strip tags, collapse space, drop blanks and [Music]-style bracket cues. */
    internal fun cleanCaptionText(raw: String): String {
        return try {
            var s = raw.replace(Regex("""<[^>]*>"""), " ")
            s = unescapeEntities(s)
            s = s.replace(Regex("""\s+"""), " ").trim()
            if (s.isBlank()) return ""
            if (s.length <= 40 && bracketOnly.matches(s)) return ""
            s
        } catch (e: Exception) {
            ""
        }
    }

    internal fun parseVtt(vtt: String): List<LyricLine> {
        val out = ArrayList<LyricLine>()
        try {
            var pendingMs: Long? = null
            val buf = StringBuilder()
            fun flush() {
                try {
                    val ms = pendingMs
                    if (ms != null && ms >= 0) {
                        val text = cleanCaptionText(buf.toString())
                        if (text.isNotBlank()) out.add(LyricLine(ms, text))
                    }
                } catch (e: Exception) {
                }
                pendingMs = null
                buf.clear()
            }
            for (raw in vtt.lineSequence()) {
                val line = raw.trim()
                if (line.isEmpty()) {
                    flush()
                    continue
                }
                if (line.startsWith("WEBVTT") || line.startsWith("NOTE") ||
                    line.startsWith("STYLE") || line.startsWith("REGION")
                ) continue
                val m = cueTs.find(line)
                if (m != null) {
                    flush()
                    pendingMs = vttTsToMs(m.groupValues[1])
                    continue
                }
                if (pendingMs != null) {
                    if (buf.isNotEmpty()) buf.append(" ")
                    buf.append(line)
                }
            }
            flush()
        } catch (e: Exception) {
        }
        return out
    }

    internal fun parseSrt(srt: String): List<LyricLine> {
        val out = ArrayList<LyricLine>()
        try {
            var pendingMs: Long? = null
            val buf = StringBuilder()
            fun flush() {
                try {
                    val ms = pendingMs
                    if (ms != null && ms >= 0) {
                        val text = cleanCaptionText(buf.toString())
                        if (text.isNotBlank()) out.add(LyricLine(ms, text))
                    }
                } catch (e: Exception) {
                }
                pendingMs = null
                buf.clear()
            }
            for (raw in srt.lineSequence()) {
                val line = raw.trim()
                if (line.isEmpty()) {
                    flush()
                    continue
                }
                if (line.matches(Regex("""\d+"""))) continue
                val m = cueTs.find(line)
                if (m != null) {
                    flush()
                    pendingMs = vttTsToMs(m.groupValues[1])
                    continue
                }
                if (pendingMs != null) {
                    if (buf.isNotEmpty()) buf.append(" ")
                    buf.append(line)
                }
            }
            flush()
        } catch (e: Exception) {
        }
        return out
    }

    internal fun parseTimedTextXml(xml: String): List<LyricLine> {
        val out = ArrayList<LyricLine>()
        try {
            for (m in xmlText.findAll(xml)) {
                try {
                    val start = xmlStart.find(m.groupValues[1])?.groupValues?.get(1)
                        ?.toDoubleOrNull() ?: continue
                    val text = cleanCaptionText(m.groupValues[2])
                    if (text.isBlank()) continue
                    out.add(LyricLine((start * 1000).toLong(), text))
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
        }
        return out
    }

    /**
     * Auto-detect caption format (VTT / SRT / timedtext XML) and parse.
     * Post pass: time-sorted, consecutive duplicates collapsed.
     */
    internal fun parseCaptions(raw: String): List<LyricLine> {
        return try {
            val t = raw.trim()
            if (t.isEmpty()) return emptyList()
            val parsed = when {
                t.startsWith("WEBVTT") -> parseVtt(t)
                t.contains("<text") || t.contains("<transcript") ||
                    t.contains("<timedtext") -> parseTimedTextXml(t)
                cueTs.containsMatchIn(t) ->
                    if (Regex("""\d{2}:\d{2}:\d{2},\d{3}\s*-->""").containsMatchIn(t)) {
                        parseSrt(t)
                    } else {
                        parseVtt(t)
                    }
                else -> emptyList()
            }
            if (parsed.isEmpty()) return emptyList()
            val sorted = parsed.filter { it.text.isNotBlank() }
                .sortedBy { it.startTimeMs.coerceAtLeast(0L) }
            val out = ArrayList<LyricLine>(sorted.size)
            for (l in sorted) {
                if (l.startTimeMs < 0) continue
                if (out.isNotEmpty() && out.last().text == l.text) continue
                out.add(l)
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    internal fun parseLrc(lrc: String): List<LyricLine> {
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
