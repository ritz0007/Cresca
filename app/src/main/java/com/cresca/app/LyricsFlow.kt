package com.cresca.app

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
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
import androidx.compose.runtime.remember
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

/**
 * Apple-Music-style karaoke visualizer.
 *
 * Relies on the caller to poll [positionMs]; this composable does no
 * timers/players itself so there is no per-frame work beyond the
 * caller's own position updates.
 */
@Composable
fun LyricsView(state: LyricsState, positionMs: Long, isPlaying: Boolean, modifier: Modifier = Modifier) {
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
                    modifier = modifier
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
    modifier: Modifier = Modifier
) {
    val listState = rememberLazyListState()
    val activeIdx = lines.indexOfLast { it.ms <= positionMs }

    // Display model: lyric rows + silence-dot rows for long gaps, so the
    // listener sees the wait filling in (Apple Music style).
    val rows = remember(lines) { buildLyricRows(lines) }
    val activeRow = remember(rows, activeIdx, positionMs) {
        rows.indexOfFirst { row ->
            when (row) {
                is LyricRow.Line -> row.index == activeIdx
                is LyricRow.Dots -> positionMs in row.fromMs until row.toMs
            }
        }.takeIf { it >= 0 } ?: rows.indexOfFirst {
            it is LyricRow.Line && it.index == activeIdx
        }.takeIf { it >= 0 } ?: 0
    }

    LaunchedEffect(activeRow) {
        listState.animateScrollToItem((activeRow - 1).coerceAtLeast(0))
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        state = listState,
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 64.dp)
    ) {
        itemsIndexed(rows, key = { index, row -> "$index-${row.key()}" }) { _, row ->
            when (row) {
                is LyricRow.Line -> {
                    val isActive = row.index == activeIdx
                    val isPast = row.index < activeIdx
                    val targetScale = if (isActive && isPlaying) 1.04f else 1f
                    val scale by animateFloatAsState(targetValue = targetScale, label = "lyricScale")
                    Text(
                        text = row.text,
                        fontSize = if (isActive) 23.sp else 21.sp,
                        lineHeight = 30.sp,
                        fontWeight = if (isActive) FontWeight.Bold else FontWeight.Normal,
                        // Neon shiny active line; past/future dim + frosted.
                        style = if (isActive) TextStyle(
                            shadow = Shadow(
                                color = Color(0xFFFA243C).copy(alpha = 0.85f),
                                offset = Offset.Zero,
                                blurRadius = 18f
                            )
                        ) else TextStyle.Default,
                        color = if (isActive) {
                            Color.White
                        } else if (isPast) {
                            Color.White.copy(alpha = 0.32f)
                        } else {
                            Color.White.copy(alpha = 0.55f)
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 12.dp)
                            .graphicsLayer(scaleX = scale, scaleY = scale)
                            .then(
                                if (isActive) Modifier
                                else Modifier
                                    .alpha(if (isPast) 0.8f else 1f)
                                    .blur(5.dp)
                            )
                    )
                }
                is LyricRow.Dots -> {
                    val frac = ((positionMs - row.fromMs).toFloat() /
                        (row.toMs - row.fromMs).coerceAtLeast(1).toFloat())
                        .coerceIn(0f, 1f)
                    val filled = (frac * DOT_COUNT).toInt().coerceIn(0, DOT_COUNT)
                    val glow by animateFloatAsState(
                        targetValue = if (isPlaying) 1f else 0.4f, label = "dotsGlow"
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 14.dp),
                        horizontalArrangement = Arrangement.spacedBy(
                            10.dp, Alignment.CenterHorizontally
                        ),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        for (d in 0 until DOT_COUNT) {
                            val on = d < filled
                            Box(
                                modifier = Modifier
                                    .size(if (on) 11.dp else 9.dp)
                                    .graphicsLayer {
                                        shadowElevation = if (on) 12f * glow else 0f
                                        spotShadowColor = Color(0xFFFA243C)
                                    }
                                    .background(
                                        color = if (on) {
                                            Color.White.copy(alpha = 0.55f + 0.45f * glow)
                                        } else {
                                            Color.White.copy(alpha = 0.22f)
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

private const val DOT_COUNT = 3
private const val SILENCE_GAP_MS = 6000L

private sealed interface LyricRow {
    fun key(): String

    data class Line(val index: Int, val text: String, val ms: Long) : LyricRow {
        override fun key(): String = "l$index-$ms"
    }

    data class Dots(val fromMs: Long, val toMs: Long) : LyricRow {
        override fun key(): String = "d$fromMs-$toMs"
    }
}

// Long instrumental gaps become a countdown row between the lines.
private fun buildLyricRows(lines: List<LyricLine>): List<LyricRow> {
    if (lines.isEmpty()) {
        return emptyList()
    }
    val out = ArrayList<LyricRow>(lines.size + 2)
    for (i in lines.indices) {
        val line = lines[i]
        out.add(LyricRow.Line(i, line.text, line.ms))
        val nextMs = lines.getOrNull(i + 1)?.ms
        if (nextMs != null && nextMs - line.ms >= SILENCE_GAP_MS) {
            // Dots live in the back half of the gap: sing soon, not yet.
            val span = nextMs - line.ms
            out.add(LyricRow.Dots(line.ms + span / 2, nextMs))
        }
    }
    return out
}
