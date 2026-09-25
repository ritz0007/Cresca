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
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
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
 * - dots ONLY for real breaks of 9s or more — anything shorter shows
 *   lines back-to-back, and every break shows exactly 3 dots
 * - while a lyric is sung, no dots tick: the line owns a 1s spotlight,
 *   then hands off hard — dots fill only after the line darkens
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
    // Tick isolation: line past/active derives from these two snapshots,
    // which change every few seconds — never on the 150ms position tick.
    // Rows that only read them skip recomposition between line changes.
    val activeIsDots = remember(rows, activeRow) {
        try {
            rows.getOrNull(activeRow) is LyricRow.Dots
        } catch (e: Exception) {
            false
        }
    }
    // Stabilized seek callback: the caller's lambda instance is recreated
    // on every tick, which would defeat row skipping without this.
    val latestClick by rememberUpdatedState(onLineClick)
    val stableClick: ((Long) -> Unit)? = remember(onLineClick != null) {
        if (onLineClick == null) {
            null
        } else {
            { ms: Long ->
                try {
                    latestClick?.invoke(ms)
                    Unit
                } catch (e: Exception) {
                    Unit
                }
            }
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
        itemsIndexed(
            rows,
            key = { index, row -> "$index-${row.key()}" },
            contentType = { _, row ->
                when (row) {
                    is LyricRow.Line -> "line"
                    is LyricRow.Dots -> "dots"
                }
            }
        ) { _, row ->
            when (row) {
                is LyricRow.Line -> {
                    val isActiveRow = rows.getOrNull(activeRow) == row
                    // Distance from the sung line drives visibility: prev/next
                    // (distance 1) stay clearly readable, far lines fade.
                    val dist = if (activeIdx < 0) Int.MAX_VALUE else kotlin.math.abs(row.index - activeIdx)
                    val isAdjacent = dist == 1
                    // When dots own the active row, no line is "active".
                    val isActive = isActiveRow && (rows.getOrNull(activeRow) is LyricRow.Line)
                    // No position read here: takeover state is precomputed,
                    // so settled lines skip every 150ms tick.
                    val isPast = when {
                        manualMode -> false
                        isActive -> false
                        else -> row.index < activeIdx ||
                            (row.index == activeIdx && activeIsDots)
                    }
                    // Separate composable with stable params: unchanged rows
                    // skip recomposition entirely (the 60fps fix).
                    LyricLineRow(
                        text = row.text,
                        seekMs = row.ms,
                        isActive = isActive,
                        isPast = isPast,
                        isAdjacent = isAdjacent,
                        isPlaying = isPlaying,
                        manualMode = manualMode,
                        onSeek = stableClick
                    )
                }
                is LyricRow.Dots -> {
                    val isActiveDots = rows.getOrNull(activeRow) == row
                    // Position-free past/future: the authoritative active row
                    // decides, so settled dots skip every 150ms tick.
                    val rowPos = try {
                        rows.indexOf(row)
                    } catch (e: Exception) {
                        -1
                    }
                    val isPastDots = rowPos >= 0 && rowPos < activeRow
                    val isFutureDots = rowPos >= 0 && rowPos > activeRow
                    // Direct drive, no easing on the fraction: the position
                    // already polls at 150ms, and re-triggered tweens never
                    // finished — that's what made dots look stuck. Only the
                    // live row reads the ticking position.
                    val span = (row.toMs - row.fromMs).coerceAtLeast(1)
                    val frac = if (isActiveDots) {
                        try {
                            ((safePos - row.fromMs).toFloat() / span.toFloat())
                                .coerceIn(0f, 1f)
                        } catch (e: Exception) {
                            0f
                        }
                    } else if (isPastDots) {
                        1f
                    } else {
                        0f
                    }
                    LyricDotsRow(
                        frac = frac,
                        isActiveDots = isActiveDots,
                        isPastDots = isPastDots,
                        isFutureDots = isFutureDots,
                        isPlaying = isPlaying,
                        manualMode = manualMode
                    )
                }
            }
        }
    }
}

/**
 * One karaoke line. All params are stable snapshots, so Compose skips this
 * entirely unless the line's own visual state changes (the 60fps fix).
 *
 * Perf notes: exactly ONE animation (the active-line zoom spring). Alpha
 * and pan are direct values — per-line tweens re-emitted on every tick
 * were a major frame cost for a visually negligible ease. No blur anywhere:
 * each blurred line costs an offscreen render pass per frame, and alpha
 * depth reads identically at 60fps.
 */
@Composable
private fun LyricLineRow(
    text: String,
    seekMs: Long,
    isActive: Boolean,
    isPast: Boolean,
    isAdjacent: Boolean,
    isPlaying: Boolean,
    manualMode: Boolean,
    onSeek: ((Long) -> Unit)?
) {
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
    val alpha = when {
        manualMode -> 1f
        isActive -> 1f
        isAdjacent -> 0.95f
        isPast -> 0.60f
        else -> 0.80f
    }
    // Past lines rest lifted, upcoming settle from below.
    val shift = when {
        isActive -> 0f
        isPast -> -8f
        else -> 8f
    }
    var mod = Modifier
        .fillMaxWidth()
        .padding(vertical = 12.dp)
        .graphicsLayer(scaleX = scale, scaleY = scale, translationY = shift)
        .alpha(alpha)
    if (onSeek != null) {
        mod = mod.clickable {
            try {
                onSeek(seekMs)
            } catch (e: Exception) {
            }
        }
    }
    Text(
        text = text,
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

/** One 3-dot waiting row. Only the live row ticks; settled rows are static. */
@Composable
private fun LyricDotsRow(
    frac: Float,
    isActiveDots: Boolean,
    isPastDots: Boolean,
    isFutureDots: Boolean,
    isPlaying: Boolean,
    manualMode: Boolean
) {
    val dotsTotal = 3
    val filled = (frac * dotsTotal).toInt().coerceIn(0, dotsTotal)
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

// ---------------------------------------------------------------------------
// Pure helpers (internal for unit/stress tests — no Compose/Android needed).
// ---------------------------------------------------------------------------

internal const val DOTS_MIN_GAP_MS = 9000L
internal const val LYRIC_HOLD_MS = 2000L

/** Spotlight: how long the sung line owns the screen before dots tick. */
internal const val PREV_SPOTLIGHT_MS = 1000L

/**
 * Dots for a wait gap: none under 9s (normal lines and short pauses stay
 * clean), exactly 3 dots for any longer break.
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

// Long waits become 3 countdown dots between the lines — plus a lead-in
// before the first line and an outro after the last one (same rules).
// A dots segment [start, end) always ends a full 2s BEFORE the next line:
// the fill completes, dots hold bright 2s, then the lyric fires.
// The sung line owns a 1s spotlight first ([prev, prev + 1s)): dots sit
// quiet until the handoff, so they never tick while lyrics are sung.
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

    // Lead-in: song starts but the first line waits 9s+.
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
                val from = ms + PREV_SPOTLIGHT_MS
                val to = nextMs - LYRIC_HOLD_MS
                if (to > from) {
                    out.add(LyricRow.Dots(from, to, n))
                }
            }
        }
    }

    // Outro: song plays on 9s+ after the last line.
    try {
        if (durationMs > 0L) {
            val lastMs = sorted.last().second
            val tail = durationMs - lastMs
            val tailN = dotCountForGap(tail)
            if (tailN > 0) {
                val to = durationMs - LYRIC_HOLD_MS
                val from = lastMs + PREV_SPOTLIGHT_MS
                if (to > from) {
                    out.add(LyricRow.Dots(from, to, tailN))
                }
            }
        }
    } catch (e: Exception) {
    }
    return out
}

/**
 * Position where the dots take over: exactly the segment start. The sung
 * line darkens at the same instant the first fill begins — never ticking
 * while lyrics are sung.
 */
internal fun dotsTakeoverMs(dots: LyricRow.Dots): Long {
    return try {
        dots.fromMs
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
