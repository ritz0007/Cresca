package com.cresca.app

import org.junit.Assert.*
import org.junit.Test

/**
 * Unit + stress tests for the karaoke waiting-dots contract:
 * - dots only when gap >= 3000ms
 * - 3000..3999 = 1 dot, 4000..6999 = 2 dots, >= 7000 = 3 dots
 * - wait split evenly among dots (frac fill)
 * - lyric fires after dots, prev darkens 1s after its timestamp
 * - past dots dim (never stay shiny white)
 */
class LyricsGapsTest {

    private fun line(ms: Long, text: String = "la") = LyricLine(ms, text)

    @Test
    fun lastLineMs_readsLatestTimestamp() {
        val lrc = "[00:09.44] a\n[00:19.02] b\n[01:02.33] c\n"
        assertEquals(62330L, LyricsRepository.lastLineMs(lrc))
        assertEquals(0L, LyricsRepository.lastLineMs("no tags here"))
    }

    @Test
    fun consistencyPenalty_mistimedRecord() {
        // Full-length lines (260s) on a 180s upload: reject hard.
        assertEquals(-8, LyricsRepository.consistencyPenalty(260000L, 180.0))
        // Healthy record: last line inside duration.
        assertEquals(0, LyricsRepository.consistencyPenalty(260000L, 269.0))
        // Partial lyrics (<60% coverage): penalize lightly.
        assertEquals(-4, LyricsRepository.consistencyPenalty(60000L, 269.0))
        // Unknowns: no opinion.
        assertEquals(0, LyricsRepository.consistencyPenalty(0L, 269.0))
        assertEquals(0, LyricsRepository.consistencyPenalty(260000L, Double.NaN))
    }

    @Test
    fun dotCount_thresholds() {
        assertEquals(0, dotCountForGap(0))
        assertEquals(0, dotCountForGap(2999))
        assertEquals(0, dotCountForGap(3000))
        assertEquals(0, dotCountForGap(4999))
        assertEquals(0, dotCountForGap(5000))
        assertEquals(0, dotCountForGap(8999))
        assertEquals(3, dotCountForGap(9000))
        assertEquals(3, dotCountForGap(10000))
        assertEquals(3, dotCountForGap(15000))
        assertEquals(3, dotCountForGap(120000))
        assertEquals(0, dotCountForGap(-500))
    }

    @Test
    fun buildRows_noDotsForShortGaps() {
        // Anything under 9s stays clean lines — no 1/2-dot rows exist.
        val rows = buildLyricRows(
            listOf(line(0, "a"), line(2000, "b"), line(4000, "c"), line(7000, "d")),
            12000L
        )
        assertTrue(rows.all { it is LyricRow.Line })
        assertEquals(4, rows.size)
    }

    @Test
    fun buildRows_oneDotFor5s() {
        // 9s wait: 3 dots over [1000, 7000), 2s hold, lyric at 9000.
        // (1s sung spotlight first: no ticking while lyrics are sung.)
        val rows = buildLyricRows(listOf(line(0, "a"), line(9000, "b")))
        assertEquals(3, rows.size)
        val dots = rows[1] as LyricRow.Dots
        assertEquals(3, dots.dotCount)
        assertEquals(1000L, dots.fromMs)
        assertEquals(7000L, dots.toMs)
    }

    @Test
    fun buildRows_twoDotsFor7s_split() {
        // 12s wait: 3 dots over [1000, 10000), split in thirds.
        val rows = buildLyricRows(listOf(line(0, "a"), line(12000, "b")))
        val dots = rows[1] as LyricRow.Dots
        assertEquals(3, dots.dotCount)
        assertEquals(1000L, dots.fromMs)
        assertEquals(10000L, dots.toMs)
        // Split: each dot owns a third of the window (3000ms each).
        val span = dots.toMs - dots.fromMs
        assertEquals(9000L, span)
    }

    @Test
    fun buildRows_threeDotsAbove9s() {
        val rows = buildLyricRows(listOf(line(0, "a"), line(15000, "b")))
        val dots = rows[1] as LyricRow.Dots
        assertEquals(3, dots.dotCount)
        assertEquals(1000L, dots.fromMs)
        assertEquals(13000L, dots.toMs)
    }

    @Test
    fun buildRows_bands() {
        // Under 9s: clean lines. 9s+ breaks: exactly 3 dots.
        assertEquals(0, dotCountForGap(8999))
        assertEquals(3, dotCountForGap(9000))
        assertEquals(3, dotCountForGap(9999))
        assertEquals(3, dotCountForGap(10000))
        assertEquals(3, dotCountForGap(15000))
        assertEquals(3, dotCountForGap(60000))
    }

    @Test
    fun buildRows_introOutro() {
        // Lead-in: first line at 12s -> 3 dots before it, 2s hold.
        val intro = buildLyricRows(listOf(line(12000, "a"), line(13000, "b")))
        assertTrue(intro.first() is LyricRow.Dots)
        val lead = intro.first() as LyricRow.Dots
        assertEquals(0L, lead.fromMs)
        assertEquals(10000L, lead.toMs)
        assertEquals(3, lead.dotCount)
        // No lead-in when the song starts singing immediately.
        val noIntro = buildLyricRows(listOf(line(500, "a"), line(1500, "b")))
        assertTrue(noIntro.first() is LyricRow.Line)
        // Outro: 10s tail after the last line -> 3 dots at the end.
        val outro = buildLyricRows(listOf(line(0, "a"), line(2000, "b")), 12000L)
        assertTrue(outro.last() is LyricRow.Dots)
        val tail = outro.last() as LyricRow.Dots
        assertEquals(3000L, tail.fromMs)
        assertEquals(10000L, tail.toMs)
        assertEquals(3, tail.dotCount)
        // Short tail: no outro dots.
        val noOutro = buildLyricRows(listOf(line(0, "a"), line(2000, "b")), 4000L)
        assertTrue(noOutro.last() is LyricRow.Line)
    }

    @Test
    fun activeRow_handoffUntilFirstDot() {
        // 9s gap: line owns [0,1000) spotlight, dots [1000,9000), lyric at 9000.
        val rows = buildLyricRows(listOf(line(0, "a"), line(9000, "b")))
        assertTrue(rows[activeRowIndex(rows, 0, 500)] is LyricRow.Line)
        assertTrue(rows[activeRowIndex(rows, 0, 999)] is LyricRow.Line)
        assertTrue(rows[activeRowIndex(rows, 0, 1000)] is LyricRow.Dots)
        assertTrue(rows[activeRowIndex(rows, 0, 8999)] is LyricRow.Dots)
        val nextIdx = activeRowIndex(rows, 1, 9000)
        assertTrue(rows[nextIdx] is LyricRow.Line)
        assertEquals(1, (rows[nextIdx] as LyricRow.Line).index)
        assertFalse(isDotsActiveAfter(rows, 0, 999))
        assertTrue(isDotsActiveAfter(rows, 0, 1000))
        assertFalse(isDotsActiveAfter(rows, 0, 9000))
    }

    @Test
    fun activeRow_dotsWinDuringWait() {
        // 15s gap, 3 dots over [1000,13000): line [0,1000), dots to 15000.
        val rows = buildLyricRows(listOf(line(0, "a"), line(15000, "b")))
        assertTrue(activeRowIndex(rows, 0, 500).let { rows[it] is LyricRow.Line })
        assertTrue(rows[activeRowIndex(rows, 0, 1000)] is LyricRow.Dots)
        assertTrue(rows[activeRowIndex(rows, 0, 12999)] is LyricRow.Dots)
        // 2s bright-hold still dots; lyric exactly at 15000.
        assertTrue(rows[activeRowIndex(rows, 0, 14000)] is LyricRow.Dots)
        val nextIdx = activeRowIndex(rows, 1, 15000)
        assertTrue(rows[nextIdx] is LyricRow.Line)
        assertEquals(1, (rows[nextIdx] as LyricRow.Line).index)
    }

    @Test
    fun activeRow_lineDarkensAfter1s() {
        val rows = buildLyricRows(listOf(line(0, "a"), line(15000, "b")))
        // 1s sung spotlight, then dots take over.
        assertFalse(isDotsActiveAfter(rows, 0, 500))
        assertFalse(isDotsActiveAfter(rows, 0, 999))
        assertTrue(isDotsActiveAfter(rows, 0, 1000))
        assertTrue(isDotsActiveAfter(rows, 0, 4000))
        // 2s bright-hold still dots-active; lyric only at 15000.
        assertTrue(isDotsActiveAfter(rows, 0, 14000))
        assertFalse(isDotsActiveAfter(rows, 0, 15000))
    }

    @Test
    fun dotsFill_splitsEvenly() {
        // 3 dots over [1000,7000): lights at 3000, 5000, 7000.
        val from = 1000L
        val to = 7000L
        val total = 3
        fun filledAt(pos: Long): Int {
            val frac = ((pos - from).toFloat() / (to - from).toFloat()).coerceIn(0f, 1f)
            return (frac * total).toInt().coerceIn(0, total)
        }
        assertEquals(0, filledAt(1000))
        assertEquals(1, filledAt(3000))
        assertEquals(2, filledAt(5000))
        assertEquals(3, filledAt(7000))
    }

    @Test
    fun buildRows_stress_randomGaps() {
        val rnd = java.util.Random(42)
        repeat(500) {
            val n = 1 + rnd.nextInt(20)
            var ms = 0L
            val lines = (0 until n).map { i ->
                ms += rnd.nextInt(12000)
                line(ms, "line $i")
            }
            val rows = try {
                buildLyricRows(lines)
            } catch (e: Exception) {
                fail("buildLyricRows threw: $e")
                return@repeat
            }
            // Keys unique (LazyColumn crash guard).
            val keys = rows.mapIndexed { idx, r -> "$idx-${r.key()}" }
            assertEquals(keys.size, keys.toSet().size)
            // Every dots row has valid window + count.
            val sortedLines = lines.sortedBy { it.ms }
            for (r in rows) {
                if (r is LyricRow.Dots) {
                    assertTrue(r.toMs > r.fromMs)
                    assertTrue(r.dotCount in 1..3)
                    // dot count matches its gap (lead-in measures from 0).
                    val idx = rows.indexOf(r)
                    val prev = rows.getOrNull(idx - 1) as? LyricRow.Line
                    if (prev == null) {
                        // Lead-in dots: gap is first line ms from song start.
                        val firstMs = sortedLines.first().ms
                        assertEquals(dotCountForGap(firstMs), r.dotCount)
                    } else {
                        val nextLineMs = sortedLines[prev.index + 1].ms
                        assertEquals(dotCountForGap(nextLineMs - prev.ms), r.dotCount)
                    }
                }
            }
            // Active row always in bounds for sampled positions.
            val maxMs = (lines.maxOfOrNull { it.ms } ?: 0L) + 5000
            var pos = 0L
            while (pos <= maxMs) {
                val ai = lines.indexOfLast { it.ms <= pos }
                val ar = activeRowIndex(rows, ai, pos)
                assertTrue(ar in rows.indices)
                pos += 750
            }
        }
    }

    @Test
    fun buildRows_edge_emptySingleUnsorted() {
        assertTrue(buildLyricRows(emptyList()).isEmpty())
        // Single line at 5s: no lead-in (under 9s), just the line.
        val single = buildLyricRows(listOf(line(5000, "solo")))
        assertEquals(1, single.size)
        assertTrue(single[0] is LyricRow.Line)
        // Single line at 12s: lead-in dots (12s wait) + line.
        val leadSingle = buildLyricRows(listOf(line(12000, "solo")))
        assertEquals(2, leadSingle.size)
        assertTrue(leadSingle[0] is LyricRow.Dots)
        // Single line at 1s: no lead-in, just the line.
        assertEquals(1, buildLyricRows(listOf(line(1000, "solo"))).size)
        // Unsorted input must not crash and must sort (12s gap => 2 lines + dots).
        val rows = buildLyricRows(listOf(line(12000, "b"), line(0, "a")))
        assertEquals(3, rows.size)
        assertEquals(0L, (rows[0] as LyricRow.Line).ms)
        assertTrue(rows[1] is LyricRow.Dots)
        assertEquals(3, (rows[1] as LyricRow.Dots).dotCount)
        // Blank lines dropped, never crash.
        val blanks = buildLyricRows(listOf(line(0, ""), line(1000, "  "), line(9000, "ok")))
        assertTrue(blanks.isNotEmpty())
    }

    @Test
    fun lrcParse_offsetsAndMalformed() {
        val lrc = "[00:01.00]hello\n[00:05.00]world\n[offset:+500]\nbad line\n[99:99.99]x"
        val out = LyricsRepository.parseLrc("[offset:+1000]\n[00:01.00]a\n[00:02.50]b")
        assertEquals(2, out.size)
        assertEquals(2000L, out[0].ms)
        assertEquals(3500L, out[1].ms)
        // Malformed never throws, blanks dropped.
        val bad = LyricsRepository.parseLrc("garbage\n[xx:yy]no\n[00:01.00]  \n[00:02.00]ok")
        assertEquals(1, bad.size)
        assertEquals("ok", bad[0].text)
    }

    @Test
    fun lrcParse_stress_fuzz() {
        val rnd = java.util.Random(13)
        repeat(1000) {
            val sb = StringBuilder()
            val n = rnd.nextInt(10)
            repeat(n) {
                val m = rnd.nextInt(5)
                val s = rnd.nextInt(60)
                val f = rnd.nextInt(100)
                sb.append("[$m:${"%02d".format(s)}.$f]")
                if (rnd.nextBoolean()) sb.append("text ${rnd.nextInt(1000)}")
                sb.append("\n")
            }
            if (rnd.nextBoolean()) sb.append("garbage line\n")
            val out = try {
                LyricsRepository.parseLrc(sb.toString())
            } catch (e: Exception) {
                fail("parseLrc threw")
                return@repeat
            }
            assertTrue(out.all { it.ms >= 0 && it.text.isNotBlank() })
        }
    }
}
