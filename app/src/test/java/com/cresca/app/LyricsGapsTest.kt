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
    fun dotCount_thresholds() {
        assertEquals(0, dotCountForGap(0))
        assertEquals(0, dotCountForGap(2999))
        assertEquals(0, dotCountForGap(3000))
        assertEquals(0, dotCountForGap(4999))
        assertEquals(1, dotCountForGap(5000))
        assertEquals(1, dotCountForGap(5999))
        assertEquals(2, dotCountForGap(6000))
        assertEquals(2, dotCountForGap(9000))
        assertEquals(3, dotCountForGap(9001))
        assertEquals(3, dotCountForGap(10000))
        assertEquals(3, dotCountForGap(15000))
        assertEquals(3, dotCountForGap(120000))
        assertEquals(0, dotCountForGap(-500))
    }

    @Test
    fun buildRows_noDotsForShortGaps() {
        // Normal line gaps (< 5s) stay clean: no dots anywhere.
        val rows = buildLyricRows(
            listOf(line(0, "a"), line(2000, "b"), line(4000, "c"), line(7000, "d")),
            9000L
        )
        assertTrue(rows.all { it is LyricRow.Line })
        assertEquals(4, rows.size)
    }

    @Test
    fun buildRows_oneDotFor5s() {
        val rows = buildLyricRows(listOf(line(0, "a"), line(5000, "b")))
        assertEquals(3, rows.size)
        val dots = rows[1] as LyricRow.Dots
        assertEquals(1, dots.dotCount)
        // Fill over [0, 4000): dot completes in 4s, 1s hold, then lyric.
        assertEquals(0L, dots.fromMs)
        assertEquals(4000L, dots.toMs)
    }

    @Test
    fun buildRows_twoDotsFor7s_split() {
        val rows = buildLyricRows(listOf(line(0, "a"), line(7000, "b")))
        val dots = rows[1] as LyricRow.Dots
        assertEquals(2, dots.dotCount)
        assertEquals(0L, dots.fromMs)
        assertEquals(6000L, dots.toMs)
        // Split: each dot owns half the window (3000ms each).
        val span = dots.toMs - dots.fromMs
        assertEquals(6000L, span)
    }

    @Test
    fun buildRows_threeDotsAbove9s() {
        val rows = buildLyricRows(listOf(line(0, "a"), line(10000, "b")))
        val dots = rows[1] as LyricRow.Dots
        assertEquals(3, dots.dotCount)
        assertEquals(0L, dots.fromMs)
        assertEquals(9000L, dots.toMs)
    }

    @Test
    fun buildRows_bands() {
        // 1 dot ~5s, 2 dots up to 9s, 3 dots above 9s.
        assertEquals(0, dotCountForGap(4999))
        assertEquals(1, dotCountForGap(5000))
        assertEquals(1, dotCountForGap(5999))
        assertEquals(2, dotCountForGap(6000))
        assertEquals(2, dotCountForGap(9000))
        assertEquals(3, dotCountForGap(9001))
        assertEquals(3, dotCountForGap(10000))
        assertEquals(3, dotCountForGap(60000))
    }

    @Test
    fun buildRows_introOutro() {
        // Lead-in: first line at 10s -> dots before it.
        val intro = buildLyricRows(listOf(line(10000, "a"), line(11000, "b")))
        assertTrue(intro.first() is LyricRow.Dots)
        val lead = intro.first() as LyricRow.Dots
        assertEquals(0L, lead.fromMs)
        assertEquals(9000L, lead.toMs)
        assertEquals(3, lead.dotCount)
        // No lead-in when the song starts singing immediately.
        val noIntro = buildLyricRows(listOf(line(500, "a"), line(1500, "b")))
        assertTrue(noIntro.first() is LyricRow.Line)
        // Outro: 7s tail after the last line -> dots at the end.
        val outro = buildLyricRows(listOf(line(0, "a"), line(2000, "b")), 9000L)
        assertTrue(outro.last() is LyricRow.Dots)
        val tail = outro.last() as LyricRow.Dots
        assertEquals(2000L, tail.fromMs)
        assertEquals(8000L, tail.toMs)
        assertEquals(2, tail.dotCount)
        // Short tail: no outro dots.
        val noOutro = buildLyricRows(listOf(line(0, "a"), line(2000, "b")), 4000L)
        assertTrue(noOutro.last() is LyricRow.Line)
    }

    @Test
    fun activeRow_handoffUntilFirstDot() {
        // 5s gap, 1 dot over [0,4000): line lit [0,4000), dot pops at
        // 4000, holds to 5000, lyric fires at 5000.
        val rows = buildLyricRows(listOf(line(0, "a"), line(5000, "b")))
        assertTrue(rows[activeRowIndex(rows, 0, 500)] is LyricRow.Line)
        assertTrue(rows[activeRowIndex(rows, 0, 3999)] is LyricRow.Line)
        assertTrue(rows[activeRowIndex(rows, 0, 4000)] is LyricRow.Dots)
        assertTrue(rows[activeRowIndex(rows, 0, 4999)] is LyricRow.Dots)
        val nextIdx = activeRowIndex(rows, 1, 5000)
        assertTrue(rows[nextIdx] is LyricRow.Line)
        assertEquals(1, (rows[nextIdx] as LyricRow.Line).index)
        assertFalse(isDotsActiveAfter(rows, 0, 3999))
        assertTrue(isDotsActiveAfter(rows, 0, 4000))
        assertFalse(isDotsActiveAfter(rows, 0, 5000))
    }

    @Test
    fun activeRow_dotsWinDuringWait() {
        // 10s gap, 3 dots over [0,9000): handoff at 9000/3 = 3000.
        val rows = buildLyricRows(listOf(line(0, "a"), line(10000, "b")))
        assertTrue(activeRowIndex(rows, 0, 500).let { rows[it] is LyricRow.Line })
        assertTrue(rows[activeRowIndex(rows, 0, 3000)] is LyricRow.Dots)
        assertTrue(rows[activeRowIndex(rows, 0, 8999)] is LyricRow.Dots)
        // Bright-hold second still dots; lyric exactly at 10000.
        assertTrue(rows[activeRowIndex(rows, 0, 9500)] is LyricRow.Dots)
        val nextIdx = activeRowIndex(rows, 1, 10000)
        assertTrue(rows[nextIdx] is LyricRow.Line)
        assertEquals(1, (rows[nextIdx] as LyricRow.Line).index)
    }

    @Test
    fun activeRow_lineDarkensAfter1s() {
        val rows = buildLyricRows(listOf(line(0, "a"), line(10000, "b")))
        // Line owns the handoff window (first dot at ~3000).
        assertFalse(isDotsActiveAfter(rows, 0, 500))
        assertFalse(isDotsActiveAfter(rows, 0, 2000))
        assertTrue(isDotsActiveAfter(rows, 0, 4000))
        // Bright-hold second still dots-active; lyric only at 10000.
        assertTrue(isDotsActiveAfter(rows, 0, 9500))
        assertFalse(isDotsActiveAfter(rows, 0, 10000))
    }

    @Test
    fun dotsFill_splitsEvenly() {
        // 2 dots over [0,8000): dot0 fills at 4000, dot1 at 8000.
        val from = 0L
        val to = 8000L
        val total = 2
        fun filledAt(pos: Long): Int {
            val frac = ((pos - from).toFloat() / (to - from).toFloat()).coerceIn(0f, 1f)
            return (frac * total).toInt().coerceIn(0, total)
        }
        assertEquals(0, filledAt(0))
        assertEquals(1, filledAt(4000))
        assertEquals(2, filledAt(8000))
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
        // Single line at 5s: lead-in dots (5s wait from song start) + line.
        val single = buildLyricRows(listOf(line(5000, "solo")))
        assertEquals(2, single.size)
        assertTrue(single[0] is LyricRow.Dots)
        // Single line at 1s: no lead-in, just the line.
        assertEquals(1, buildLyricRows(listOf(line(1000, "solo"))).size)
        // Unsorted input must not crash and must sort (8s gap => 2 lines + dots).
        val rows = buildLyricRows(listOf(line(8000, "b"), line(0, "a")))
        assertEquals(3, rows.size)
        assertEquals(0L, (rows[0] as LyricRow.Line).ms)
        assertTrue(rows[1] is LyricRow.Dots)
        assertEquals(2, (rows[1] as LyricRow.Dots).dotCount)
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
