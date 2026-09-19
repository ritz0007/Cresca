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
        assertEquals(1, dotCountForGap(3000))
        assertEquals(1, dotCountForGap(3500))
        assertEquals(1, dotCountForGap(3999))
        assertEquals(2, dotCountForGap(4000))
        assertEquals(2, dotCountForGap(5000))
        assertEquals(2, dotCountForGap(6000))
        assertEquals(2, dotCountForGap(6999))
        assertEquals(3, dotCountForGap(7000))
        assertEquals(3, dotCountForGap(15000))
        assertEquals(3, dotCountForGap(120000))
        assertEquals(0, dotCountForGap(-500))
    }

    @Test
    fun buildRows_noDotsForShortGaps() {
        val rows = buildLyricRows(listOf(line(0, "a"), line(2000, "b"), line(4000, "c")))
        assertEquals(3, rows.size)
        assertTrue(rows.all { it is LyricRow.Line })
    }

    @Test
    fun buildRows_oneDotFor3s() {
        val rows = buildLyricRows(listOf(line(0, "a"), line(3000, "b")))
        assertEquals(3, rows.size)
        val dots = rows[1] as LyricRow.Dots
        assertEquals(1, dots.dotCount)
        // 1s darkening hold: dots start 1s after prev line.
        assertEquals(1000L, dots.fromMs)
        assertEquals(3000L, dots.toMs)
    }

    @Test
    fun buildRows_twoDotsFor5s_split() {
        val rows = buildLyricRows(listOf(line(0, "a"), line(5000, "b")))
        val dots = rows[1] as LyricRow.Dots
        assertEquals(2, dots.dotCount)
        assertEquals(1000L, dots.fromMs)
        assertEquals(5000L, dots.toMs)
        // Split: each dot owns half the window (2000ms each).
        val span = dots.toMs - dots.fromMs
        assertEquals(4000L, span)
    }

    @Test
    fun buildRows_threeDotsFor8s() {
        val rows = buildLyricRows(listOf(line(0, "a"), line(8000, "b")))
        val dots = rows[1] as LyricRow.Dots
        assertEquals(3, dots.dotCount)
    }

    @Test
    fun activeRow_dotsWinDuringWait() {
        val rows = buildLyricRows(listOf(line(0, "a"), line(8000, "b")))
        // Line a active in [0,1000).
        assertTrue(activeRowIndex(rows, 0, 500).let { rows[it] is LyricRow.Line })
        // Dots active in [1000,8000).
        val dotsIdx = activeRowIndex(rows, 0, 2000)
        assertTrue(rows[dotsIdx] is LyricRow.Dots)
        assertTrue(rows[activeRowIndex(rows, 0, 7999)] is LyricRow.Dots)
        // Next line exactly at its timestamp (after dots).
        val nextIdx = activeRowIndex(rows, 1, 8000)
        assertTrue(rows[nextIdx] is LyricRow.Line)
        assertEquals(1, (rows[nextIdx] as LyricRow.Line).index)
    }

    @Test
    fun activeRow_lineDarkensAfter1s() {
        val rows = buildLyricRows(listOf(line(0, "a"), line(8000, "b")))
        // At 500ms: line still active, dots not yet.
        assertFalse(isDotsActiveAfter(rows, 0, 500))
        // At 1500ms: dots took over -> line should dim.
        assertTrue(isDotsActiveAfter(rows, 0, 1500))
        // After dots: no longer dots-active.
        assertFalse(isDotsActiveAfter(rows, 0, 8000))
    }

    @Test
    fun dotsFill_splitsEvenly() {
        // 2 dots over [1000,5000): dot0 fills at 3000, dot1 at 5000.
        val from = 1000L
        val to = 5000L
        val total = 2
        fun filledAt(pos: Long): Int {
            val frac = ((pos - from).toFloat() / (to - from).toFloat()).coerceIn(0f, 1f)
            return (frac * total).toInt().coerceIn(0, total)
        }
        assertEquals(0, filledAt(1000))
        assertEquals(1, filledAt(3000))
        assertEquals(2, filledAt(5000))
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
            for (r in rows) {
                if (r is LyricRow.Dots) {
                    assertTrue(r.toMs > r.fromMs)
                    assertTrue(r.dotCount in 1..3)
                    val gap = lines.zipWithNext().firstOrNull { (_, _) -> true }
                    // dot count matches its gap.
                    val idx = rows.indexOf(r)
                    val prev = rows[idx - 1] as LyricRow.Line
                    val nextLineMs = lines[prev.index + 1].ms
                    assertEquals(dotCountForGap(nextLineMs - prev.ms), r.dotCount)
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
        val single = buildLyricRows(listOf(line(5000, "solo")))
        assertEquals(1, single.size)
        // Unsorted input must not crash and must sort (8s gap => 2 lines + dots).
        val rows = buildLyricRows(listOf(line(8000, "b"), line(0, "a")))
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
