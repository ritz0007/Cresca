package com.cresca.app

import com.cresca.app.innertube.InnerTubeApi
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/**
 * YouTube-captions leg: VTT / SRT / timedtext-XML parsing, format
 * auto-detect, caption-track ranking, and the unified result model.
 * All pure JVM (no Android APIs in the parsers).
 */
class LyricsCaptionsTest {

    private val vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:03.500
        Hello <v Singer>world</v>

        00:00:04.000 --> 00:00:06.000
        Second line
    """.trimIndent()

    private val srt = """
        1
        00:00:01,000 --> 00:00:03,500
        Hello world

        2
        00:00:04,000 --> 00:00:06,000
        Second line
    """.trimIndent()

    private val xml = """
        <transcript>
        <text start="1.0" dur="2.5">Hello &amp; goodbye</text>
        <text start="4.25" dur="1.75"><i>Second</i> line</text>
        <text start="9.0" dur="1.0">[Music]</text>
        </transcript>
    """.trimIndent()

    @Test
    fun vtt_parsesStartMs() {
        val out = LyricsRepository.parseVtt(vtt)
        assertEquals(2, out.size)
        assertEquals(1000L, out[0].startTimeMs)
        assertEquals("Hello world", out[0].text)
        assertEquals(4000L, out[1].startTimeMs)
    }

    @Test
    fun srt_parsesCommaMs() {
        val out = LyricsRepository.parseSrt(srt)
        assertEquals(2, out.size)
        assertEquals(1000L, out[0].startTimeMs)
        assertEquals("Hello world", out[0].text)
        assertEquals(4000L, out[1].startTimeMs)
    }

    @Test
    fun timedtextXml_parsesSecondsEntitiesAndDropsMusic() {
        val out = LyricsRepository.parseTimedTextXml(xml)
        assertEquals(2, out.size)
        assertEquals(1000L, out[0].startTimeMs)
        assertEquals("Hello & goodbye", out[0].text)
        assertEquals(4250L, out[1].startTimeMs)
        assertEquals("Second line", out[1].text)
    }

    @Test
    fun parseCaptions_autodetectsAllFormats() {
        assertEquals(2, LyricsRepository.parseCaptions(vtt).size)
        assertEquals(2, LyricsRepository.parseCaptions(srt).size)
        assertEquals(2, LyricsRepository.parseCaptions(xml).size)
        assertTrue(LyricsRepository.parseCaptions("garbage").isEmpty())
        assertTrue(LyricsRepository.parseCaptions("").isEmpty())
    }

    @Test
    fun parseCaptions_sortsAndDedupes() {
        val dup = """
            WEBVTT

            00:00:04.000 --> 00:00:06.000
            Second

            00:00:01.000 --> 00:00:03.000
            First

            00:00:02.000 --> 00:00:03.500
            First
        """.trimIndent()
        val out = LyricsRepository.parseCaptions(dup)
        assertEquals(listOf("First", "Second"), out.map { it.text })
        assertEquals(1000L, out[0].startTimeMs)
    }

    @Test
    fun vttTsToMs_edges() {
        assertEquals(0L, LyricsRepository.vttTsToMs("00:00.000"))
        assertEquals(62350L, LyricsRepository.vttTsToMs("01:02.350"))
        assertEquals(3723456L, LyricsRepository.vttTsToMs("01:02:03.456"))
        assertEquals(1000L, LyricsRepository.vttTsToMs("00:00:01,000"))
        assertEquals(-1L, LyricsRepository.vttTsToMs("bogus"))
    }

    @Test
    fun captionTracks_rankManualOverAuto() {
        val root = JSONObject(
            """{"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
            {"baseUrl":"https://x/auto?fmt=srv3","languageCode":"en","kind":"asr",
             "name":{"runs":[{"text":"English (auto-generated)"}]}},
            {"baseUrl":"https://x/hi","languageCode":"hi",
             "name":{"simpleText":"Hindi"}}
            ]}}}"""
        )
        val tracks = InnerTubeApi.parseCaptionTracks(root)
        assertEquals(2, tracks.size)
        assertTrue(tracks[0].isAuto)
        assertFalse(tracks[1].isAuto)
        val ranked = InnerTubeApi.rankCaptions(tracks)
        assertEquals("hi", ranked[0].lang)
        assertEquals("en", ranked[1].lang)
    }

    @Test
    fun lyricLine_msCompatAlias() {
        val l = LyricLine(123L, "x")
        assertEquals(123L, l.startTimeMs)
        assertEquals(123L, l.ms)
    }

    @Test
    fun toResult_unifiesStates() {
        val synced = LyricsState.Synced(
            listOf(LyricLine(1L, "a")), LyricSource.YOUTUBE_CAPTIONS
        ).toResult()
        assertTrue(synced.isSynced)
        assertEquals(LyricSource.YOUTUBE_CAPTIONS, synced.source)
        assertEquals(1, synced.lines.size)

        val plain = LyricsState.Plain("words").toResult()
        assertFalse(plain.isSynced)
        assertEquals("words", plain.lines.single().text)

        val missing = LyricsState.NotFound.toResult()
        assertFalse(missing.isSynced)
        assertTrue(missing.lines.isEmpty())
        assertEquals(LyricSource.NONE, missing.source)
    }
}
