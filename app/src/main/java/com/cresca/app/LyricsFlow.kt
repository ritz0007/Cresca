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
 * - dots only when gap > 3s (>= 3000ms)
 * - 3000..3999ms = 1 dot, 4000..6999ms = 2 dots, >= 7000ms = 3 dots
 * - wait is split evenly among the dots (sequential fill)
 * - dots occupy [line.ms + 1000, next.ms): the previous line stays
 *   highlighted for 1s then darkens, dots take over, next line activates
 *   exactly at its timestamp (after the dots).
 * - past dots dim + blur like past lyrics (never stay shiny white).
 */
@Composable
fun LyricsView(
    state: LyricsState,
    positionMs: Long,
    isPlaying: Boolean,
    modifier: Modifier = Modifier,
    onLineClick: ((Long) -> Unit)? = null
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
                    onLineClick = onLineClick
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
    onLineClick: ((Long) -> Unit)? = null
) {
    val listState = rememberLazyListState()
    val safePos = try {
        positionMs.coerceAtLeast(0L)
    } catch (e: Exception) {
        0L
    }
    val activeIdx = try {
        lines.indexOfLast { it.ms <= safePos }
    } catch (e: Exception) {
        -1
    }

    // Display model: lyric rows + silence-dot rows for long gaps.
    val rows = remember(lines) {
        try {
            buildLyricRows(lines)
        } catch (e: Exception) {
            lines.mapIndexed { i, l -> LyricRow.Line(i, l.text, l.ms) }
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
                        .graphicsLayer(scaleX = scale, scaleY = scale)
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
                    val dotsTotal = row.dotCount.coerceAtLeast(1)
                    val span = (row.toMs - row.fromMs).coerceAtLeast(1)
                    val rawFrac = try {
                        ((safePos - row.fromMs).toFloat() / span.toFloat()).coerceIn(0f, 1f)
                    } catch (e: Exception) {
                        0f
                    }
                    // Eased fill: position polls discretely, so animate the
                    // fraction itself — dots glide instead of jumping.
                    val frac by animateFloatAsState(
                        targetValue = rawFrac,
                        animationSpec = tween(220),
                        label = "dotsFrac"
                    )
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
                            12.dp, Alignment.CenterHorizontally
                        ),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        for (d in 0 until dotsTotal) {
                            val on = d < filled && isActiveDots
                            // Fixed 24dp cell: the halo lives INSIDE it, so lit
                            // dots never re-lay-out the row (that was the crack).
                            Box(
                                modifier = Modifier.size(24.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                if (on) {
                                    // Red halo behind the dot (cheap glow: two
                                    // flat circles, no shadowElevation pass).
                                    Box(
                                        modifier = Modifier
                                            .size(20.dp)
                                            .background(
                                                color = Color(0xFFFA243C).copy(alpha = 0.35f * glow),
                                                shape = androidx.compose.foundation.shape.CircleShape
                                            )
                                    )
                                }
                                Box(
                                    modifier = Modifier
                                        .size(if (on) 11.dp else 8.dp)
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
}

// ---------------------------------------------------------------------------
// Pure helpers (internal for unit/stress tests — no Compose/Android needed).
// ---------------------------------------------------------------------------

internal const val DOTS_MIN_GAP_MS = 3000L
internal const val DOTS_ONE_MAX_MS = 4000L
internal const val DOTS_TWO_MAX_MS = 7000L
internal const val LYRIC_HOLD_MS = 1000L

/**
 * Dots for a wait gap: 0 when <= 3s, 1 for 3s, 2 for 4-6s, 3 for 7s+.
 * Boundaries: [3000,4000)=1, [4000,7000)=2, [7000,inf)=3.
 */
internal fun dotCountForGap(gapMs: Long): Int {
    return try {
        if (gapMs < DOTS_MIN_GAP_MS) 0
        else if (gapMs < DOTS_ONE_MAX_MS) 1
        else if (gapMs < DOTS_TWO_MAX_MS) 2
        else 3
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

// Long instrumental gaps become a countdown row between the lines.
// Dots live in [line.ms + 1s, next.ms - 1s): the sung line darkens 1s
// after its timestamp, the wait fills dot-by-dot, then all dots hold
// bright for 1 more second before the next line fires.
internal fun buildLyricRows(lines: List<LyricLine>): List<LyricRow> {
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
    val out = ArrayList<LyricRow>(sorted.size + 2)
    for (i in sorted.indices) {
        val (_, ms, text) = sorted[i]
        out.add(LyricRow.Line(i, text, ms))
        val nextMs = sorted.getOrNull(i + 1)?.second
        if (nextMs != null) {
            val gap = nextMs - ms
            val n = dotCountForGap(gap)
            if (n > 0) {
                val from = ms + LYRIC_HOLD_MS
                val to = nextMs - LYRIC_HOLD_MS
                if (to > from) {
                    out.add(LyricRow.Dots(from, to, n))
                }
            }
        }
    }
    return out
}

/**
 * Active row: dots win while the position sits inside their window PLUS
 * the 1s bright-hold after the last dot ([from, to + 1s)).
 */
internal fun activeRowIndex(rows: List<LyricRow>, activeLineIdx: Int, positionMs: Long): Int {
    if (rows.isEmpty()) return 0
    try {
        rows.forEachIndexed { i, r ->
            if (r is LyricRow.Dots && positionMs in r.fromMs until (r.toMs + LYRIC_HOLD_MS)) return i
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
 * Covers the fill window plus the 1s bright-hold before the next line. */
internal fun isDotsActiveAfter(rows: List<LyricRow>, lineIdx: Int, positionMs: Long): Boolean {
    return try {
        val li = rows.indexOfFirst { it is LyricRow.Line && it.index == lineIdx }
        if (li < 0) return false
        val dots = rows.getOrNull(li + 1)
        dots is LyricRow.Dots && positionMs >= dots.fromMs && positionMs < (dots.toMs + LYRIC_HOLD_MS)
    } catch (e: Exception) {
        false
    }
}
