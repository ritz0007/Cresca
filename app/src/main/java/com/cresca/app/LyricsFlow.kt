package com.cresca.app

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

/**
 * Apple-Music-style karaoke visualizer.
 *
 * Relies on the caller to poll [positionMs]; this composable does no
 * timers/players itself so there is no per-frame work beyond the
 * caller's own position updates.
 *
 * Waiting-dots contract (user spec):
 * - dots ONLY for real breaks: waits under 5s show lines back-to-back
 * - every break gets exactly 3 dots (no 1/2-dot rows)
 * - the dots segment always ends a full 2s BEFORE the next line: the
 *   fill completes, dots hold bright 2s, then the lyric fires
 * - dots also wrap the song: lead-in before the first line and outro
 *   after the last line (needs [durationMs], 0 = skip outro dots)
 * - past dots dim like past lyrics (never stay shiny white).
 */
@Composable
fun LyricsView(
    state: LyricsState,
    positionMs: Long,
    isPlaying: Boolean,
    modifier: Modifier = Modifier,
    onLineClick: ((Long) -> Unit)? = null,
    durationMs: Long = 0L
) {
    when (state) {
        is LyricsState.Loading -> {
            Box(
                modifier = modifier.fillMaxSize(),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
            }
        }
        is LyricsState.NotFound -> {
            Box(
                modifier = modifier
                    .fillMaxSize()
                    .padding(horizontal = 24.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "No lyrics found for this track yet.",
                    fontSize = 15.sp,
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                )
            }
        }
        is LyricsState.Plain -> {
            Box(
                modifier = modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp, vertical = 64.dp)
            ) {
                Text(
                    text = state.text,
                    fontSize = 18.sp,
                    lineHeight = 28.sp,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
        }
        is LyricsState.Synced -> {
            if (state.lines.isEmpty()) {
                Box(
                    modifier = modifier
                        .fillMaxSize()
                        .padding(horizontal = 24.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "No lyrics found for this track yet.",
                        fontSize = 15.sp,
                        textAlign = TextAlign.Center,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                    )
                }
            } else {
                SyncedLyrics(
                    lines = state.lines,
                    positionMs = positionMs,
                    isPlaying = isPlaying,
                    modifier = modifier,
                    onLineClick = onLineClick,
                    durationMs = durationMs
                )
            }
        }
    }
}

@Composable
private fun SyncedLyrics(
    lines: List<LyricLine>,
    positionMs: Long,
    isPlaying: Boolean,
    modifier: Modifier = Modifier,
    onLineClick: ((Long) -> Unit)? = null,
    durationMs: Long = 0L
) {
    val listState = rememberLazyListState()
    // Canonical order: extractor files are occasionally unsorted, and the
    // active-line index must address the SAME order the rows are built in
    // (unsorted input used to highlight the wrong line + dots in gaps).
    val sorted = remember(lines) {
        try {
            lines.filter { it.text.isNotBlank() }.sortedBy { it.ms.coerceAtLeast(0L) }
        } catch (e: Exception) {
            lines
        }
    }
    val safePos = try {
        positionMs.coerceAtLeast(0L)
    } catch (e: Exception) {
        0L
    }
    val activeIdx = try {
        sorted.indexOfLast { it.ms <= safePos }
    } catch (e: Exception) {
        -1
    }

    // Display model: lyric rows + silence-dot rows for long gaps.
    val rows = remember(sorted, durationMs) {
        try {
            buildLyricRows(sorted, durationMs)
        } catch (e: Exception) {
            sorted.mapIndexed { i, l -> LyricRow.Line(i, l.text, l.ms) }
        }
    }
    val activeRow = remember(rows, activeIdx, safePos) {
        try {
            activeRowIndex(rows, activeIdx, safePos)
        } catch (e: Exception) {
            0
        }
    }

    // Manual-scroll handling: while the user drags (or within 3s after),
    // suspend auto-scroll and show every line fully readable (no blur).
    var lastUserScrollMs by remember { mutableLongStateOf(0L) }
    var userHold by remember { mutableStateOf(false) }
    LaunchedEffect(listState.isScrollInProgress) {
        try {
            if (listState.isScrollInProgress) {
                userHold = true
                lastUserScrollMs = System.currentTimeMillis()
            }
        } catch (e: Exception) {
        }
    }
    LaunchedEffect(listState.firstVisibleItemIndex, listState.firstVisibleItemScrollOffset) {
        // Any programmatic scroll also settles here; only treat drags as manual.
        try {
            if (listState.isScrollInProgress) {
                lastUserScrollMs = System.currentTimeMillis()
                userHold = true
            }
        } catch (e: Exception) {
        }
    }
    // Release the hold 3s after the last manual scroll.
    LaunchedEffect(userHold, lastUserScrollMs, activeRow) {
        if (userHold) {
            try {
                delay(3000)
                // Only release if no newer scroll happened.
                if (System.currentTimeMillis() - lastUserScrollMs >= 2900) {
                    userHold = false
                }
            } catch (e: Exception) {
                userHold = false
            }
        }
    }
    val manualMode = userHold || listState.isScrollInProgress

    // Blur is the expensive effect here: while the list is moving we render
    // alpha-only (same layout, no offscreen passes); the frosted look
    // returns the moment scrolling settles. Beauty in stills, 60fps in motion.
    val scrolling = listState.isScrollInProgress

    LaunchedEffect(activeRow) {
        if (manualMode) return@LaunchedEffect
        try {
            val target = (activeRow - 1).coerceAtLeast(0)
            // Don't animate absurd jumps (track change): snap instead.
            val cur = try {
                listState.firstVisibleItemIndex
            } catch (e: Exception) {
                target
            }
            if (kotlin.math.abs(cur - target) > 12) {
                listState.scrollToItem(target)
            } else {
                listState.animateScrollToItem(target)
            }
        } catch (e: Exception) {
            try {
                listState.scrollToItem((activeRow - 1).coerceAtLeast(0))
            } catch (ignored: Exception) {
            }
        }
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        state = listState,
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 64.dp)
    ) {
        itemsIndexed(rows, key = { index, row -> "$index-${row.key()}" }) { _, row ->
            when (row) {
                is LyricRow.Line -> {
                    val isActiveRow = rows.getOrNull(activeRow) == row
                    // Distance from the sung line drives visibility: prev/next
                    // (distance 1) stay clearly readable, far lines fade.
                    val dist = if (activeIdx < 0) Int.MAX_VALUE else kotlin.math.abs(row.index - activeIdx)
                    val isAdjacent = dist == 1
                    // When dots own the active row, no line is "active".
                    val isActive = isActiveRow && (rows.getOrNull(activeRow) is LyricRow.Line)
                    val isPast = when {
                        manualMode -> false
                        isActive -> false
                        else -> try {
                            row.index < activeIdx ||
                                (row.index == activeIdx && isDotsActiveAfter(rows, row.index, safePos))
                        } catch (e: Exception) {
                            row.index < activeIdx
                        }
                    }
                    // Gentle zoom: soft spring, runs only when the active line
                    // changes (every few seconds), never per-frame.
                    val targetScale = when {
                        isActive && isPlaying -> 1.07f
                        isActive -> 1.04f
                        isAdjacent -> 1.0f
                        else -> 0.98f
                    }
                    val scale by animateFloatAsState(
                        targetValue = targetScale,
                        animationSpec = spring(dampingRatio = 0.85f, stiffness = 400f),
                        label = "lyricScale"
                    )
                    val targetAlpha = when {
                        manualMode -> 1f
                        isActive -> 1f
                        isAdjacent -> 0.95f
                        isPast -> 0.60f
                        else -> 0.80f
                    }
                    val alphaAnim by animateFloatAsState(
                        targetValue = targetAlpha,
                        animationSpec = tween(300),
                        label = "lyricAlpha"
                    )
                    // Constant gentle pan: past lines rest lifted, upcoming
                    // settle from below — always applied, eased, never jumpy.
                    val targetShift = when {
                        isActive -> 0f
                        isPast -> -8f
                        else -> 8f
                    }
                    val shift by animateFloatAsState(
                        targetValue = targetShift,
                        animationSpec = tween(320),
                        label = "lyricPan"
                    )
                    // Frosted depth for far lines, crisp prev/next. Blur is
                    // skipped while scrolling (perf) — alpha carries it.
                    val blurDp = when {
                        manualMode || scrolling || isActive || isAdjacent -> 0.dp
                        dist == 2 -> 2.dp
                        else -> 4.dp
                    }
                    var mod = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 12.dp)
                        .graphicsLayer(scaleX = scale, scaleY = scale, translationY = shift)
                        .alpha(alphaAnim)
                    if (blurDp.value > 0.01f) mod = mod.blur(blurDp)
                    if (onLineClick != null) {
                        val seekTo = row.ms
                        mod = mod.clickable {
                            try {
                                onLineClick(seekTo)
                            } catch (e: Exception) {
                            }
                        }
                    }
                    Text(
                        text = row.text,
                        fontSize = if (isActive) 24.sp else if (isAdjacent) 21.sp else 20.sp,
                        lineHeight = 30.sp,
                        fontWeight = if (isActive) FontWeight.Bold else if (isAdjacent) FontWeight.SemiBold else FontWeight.Normal,
                        // Neon glow on the sung line only (one shadowed layer
                        // at a time — cheap; per-line shadows were the jank).
                        style = if (isActive) TextStyle(
                            shadow = Shadow(
                                color = Color(0xFFFA243C).copy(alpha = 0.85f),
                                offset = Offset.Zero,
                                blurRadius = 18f
                            )
                        ) else TextStyle.Default,
                        color = when {
                            isActive -> Color.White
                            isPast -> Color.White.copy(alpha = 0.62f)
                            isAdjacent -> Color.White.copy(alpha = 0.90f)
                            else -> Color.White.copy(alpha = 0.72f)
                        },
                        modifier = mod
                    )
                }
                is LyricRow.Dots -> {
                    val dotsTotal = 3
                    val span = (row.toMs - row.fromMs).coerceAtLeast(1)
                    // Direct drive, no easing animation on the fraction: the
                    // position already polls at 150ms, and re-triggered tweens
                    // never finished — that's what made dots look stuck.
                    val frac = try {
                        ((safePos - row.fromMs).toFloat() / span.toFloat()).coerceIn(0f, 1f)
                    } catch (e: Exception) {
                        0f
                    }
                    val filled = (frac * dotsTotal).toInt().coerceIn(0, dotsTotal)
                    val isActiveDots = rows.getOrNull(activeRow) == row
                    val isPastDots = try {
                        safePos >= (row.toMs + LYRIC_HOLD_MS)
                    } catch (e: Exception) {
                        false
                    }
                    val isFutureDots = try {
                        safePos < row.fromMs
                    } catch (e: Exception) {
                        false
                    }
                    // Past/future dots dim like past/future lyrics — never
                    // shiny white after passing.
                    val rowAlphaTarget = when {
                        manualMode -> 1f
                        isActiveDots -> 1f
                        isPastDots -> 0.55f
                        isFutureDots -> 0.70f
                        else -> 0.8f
                    }
                    val rowAlpha by animateFloatAsState(
                        targetValue = rowAlphaTarget, animationSpec = tween(300), label = "dotsAlpha"
                    )
                    val glowTarget = when {
                        !isPlaying -> 0.45f
                        isActiveDots -> 1f
                        else -> 0.3f
                    }
                    val glow by animateFloatAsState(
                        targetValue = glowTarget, animationSpec = tween(300), label = "dotsGlow"
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 14.dp)
                            .alpha(rowAlpha),
                        horizontalArrangement = Arrangement.spacedBy(
                            8.dp, Alignment.CenterHorizontally
                        ),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        for (d in 0 until dotsTotal) {
                            val on = d < filled && isActiveDots
                            // Fixed size + scale pop (scale never re-lays-out,
                            // so no cracking); glow carried by brightness.
                            Box(
                                modifier = Modifier
                                    .size(10.dp)
                                    .graphicsLayer(
                                        scaleX = if (on) 1.3f else 1f,
                                        scaleY = if (on) 1.3f else 1f
                                    )
                                    .background(
                                        color = when {
                                            on -> Color.White.copy(alpha = 0.60f + 0.40f * glow)
                                            isPastDots -> Color.White.copy(alpha = 0.30f)
                                            isFutureDots -> Color.White.copy(alpha = 0.30f)
                                            else -> Color.White.copy(alpha = 0.22f)
                                        },
                                        shape = androidx.compose.foundation.shape.CircleShape
                                    )
                            )
                        }
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Pure helpers (internal for unit/stress tests — no Compose/Android needed).
// ---------------------------------------------------------------------------

internal const val DOTS_MIN_GAP_MS = 5000L
internal const val LYRIC_HOLD_MS = 2000L

/**
 * Dots for a wait gap: none under 5s (normal line gaps stay clean),
 * exactly 3 dots for any longer break.
 */
internal fun dotCountForGap(gapMs: Long): Int {
    return try {
        if (gapMs < DOTS_MIN_GAP_MS) 0 else 3
    } catch (e: Exception) {
        0
    }
}

internal sealed interface LyricRow {
    fun key(): String

    data class Line(val index: Int, val text: String, val ms: Long) : LyricRow {
        override fun key(): String = "l$index-$ms"
    }

    data class Dots(val fromMs: Long, val toMs: Long, val dotCount: Int = 3) : LyricRow {
        override fun key(): String = "d$fromMs-$toMs-$dotCount"
    }
}

// Long waits become countdown dots between the lines — plus a lead-in
// before the first line and an outro after the last one (same rules).
// A dots segment [start, end) always ends a full 1s BEFORE the next line:
// the fill completes over [start, end - 1s], dots hold bright 1s, then the
// lyric fires. e.g. 3s wait = dot lights over 2s + 1s hold + transition.
// The sung line stays lit until the FIRST dot lights (handoff), so short
// waits still show the lyric first and dots never steal its moment.
internal fun buildLyricRows(lines: List<LyricLine>, durationMs: Long = 0L): List<LyricRow> {
    if (lines.isEmpty()) {
        return emptyList()
    }
    // Defensive: sort by timestamp, drop blanks (extractor data is messy).
    val sorted = try {
        lines.mapIndexed { i, l ->
            Triple(i, l.ms.coerceAtLeast(0L), l.text)
        }.filter { it.third.isNotBlank() }
            .sortedBy { it.second }
    } catch (e: Exception) {
        return lines.mapIndexed { i, l -> LyricRow.Line(i, l.text, l.ms) }
    }
    val out = ArrayList<LyricRow>(sorted.size + 4)

    // Lead-in: song starts but the first line waits more than 3s.
    try {
        val firstMs = sorted.first().second
        val leadN = dotCountForGap(firstMs)
        if (leadN > 0) {
            val to = firstMs - LYRIC_HOLD_MS
            if (to > 0L) {
                out.add(LyricRow.Dots(0L, to, leadN))
            }
        }
    } catch (e: Exception) {
    }

    for (i in sorted.indices) {
        val (_, ms, text) = sorted[i]
        out.add(LyricRow.Line(i, text, ms))
        val nextMs = sorted.getOrNull(i + 1)?.second
        if (nextMs != null) {
            val gap = nextMs - ms
            val n = dotCountForGap(gap)
            if (n > 0) {
                val from = ms
                val to = nextMs - LYRIC_HOLD_MS
                if (to > from) {
                    out.add(LyricRow.Dots(from, to, n))
                }
            }
        }
    }

    // Outro: song plays on more than 3s after the last line.
    try {
        if (durationMs > 0L) {
            val lastMs = sorted.last().second
            val tail = durationMs - lastMs
            val tailN = dotCountForGap(tail)
            if (tailN > 0) {
                val to = durationMs - LYRIC_HOLD_MS
                if (to > lastMs) {
                    out.add(LyricRow.Dots(lastMs, to, tailN))
                }
            }
        }
    } catch (e: Exception) {
    }
    return out
}

/**
 * Position where the dots take over from the line before them: the sung
 * line stays lit until the FIRST dot lights (fill split evenly).
 */
internal fun dotsTakeoverMs(dots: LyricRow.Dots): Long {
    return try {
        val span = (dots.toMs - dots.fromMs).coerceAtLeast(1L)
        dots.fromMs + span / dots.dotCount.coerceAtLeast(1)
    } catch (e: Exception) {
        dots.fromMs
    }
}

/**
 * Active row: dots win from the moment their first dot lights through the
 * 1s bright-hold ([takeover, to + 1s)). Before that the sung line owns it.
 */
internal fun activeRowIndex(rows: List<LyricRow>, activeLineIdx: Int, positionMs: Long): Int {
    if (rows.isEmpty()) return 0
    try {
        rows.forEachIndexed { i, r ->
            if (r is LyricRow.Dots &&
                positionMs >= dotsTakeoverMs(r) && positionMs < (r.toMs + LYRIC_HOLD_MS)
            ) return i
        }
        rows.forEachIndexed { i, r ->
            if (r is LyricRow.Line && r.index == activeLineIdx) return i
        }
        // Before the first line: pin to top.
        if (activeLineIdx < 0) return 0
        // Past the end: pin to last line.
        for (i in rows.indices.reversed()) {
            if (rows[i] is LyricRow.Line) return i
        }
        return 0
    } catch (e: Exception) {
        return 0
    }
}

/** True when a dots row has taken over after [lineIdx] (line should dim).
 * Covers first-dot light through the 1s bright-hold before the next line. */
internal fun isDotsActiveAfter(rows: List<LyricRow>, lineIdx: Int, positionMs: Long): Boolean {
    return try {
        val li = rows.indexOfFirst { it is LyricRow.Line && it.index == lineIdx }
        if (li < 0) return false
        // Dots directly after the line (skipping nothing: rows are built
        // line,dots,line — but lead-in dots precede line 0, so check first).
        val dots = rows.getOrNull(li + 1)
        if (dots is LyricRow.Dots) {
            return positionMs >= dotsTakeoverMs(dots) &&
                positionMs < (dots.toMs + LYRIC_HOLD_MS)
        }
        false
    } catch (e: Exception) {
        false
    }
}
