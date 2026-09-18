package com.cresca.app

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.graphicsLayer
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

    LaunchedEffect(activeIdx) {
        listState.animateScrollToItem((activeIdx - 2).coerceAtLeast(0))
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        state = listState,
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 64.dp)
    ) {
        itemsIndexed(lines, key = { index, line -> "$index-${line.ms}-${line.text}" }) { index, line ->
            val isActive = index == activeIdx
            val targetScale = if (isActive && isPlaying) 1.04f else 1f
            val scale by animateFloatAsState(targetValue = targetScale, label = "lyricScale")

            Text(
                text = line.text,
                fontSize = 21.sp,
                lineHeight = 30.sp,
                fontWeight = if (isActive) FontWeight.Bold else FontWeight.Normal,
                color = if (isActive) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.onSurface
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 12.dp)
                    .graphicsLayer(scaleX = scale, scaleY = scale)
                    .alpha(if (isActive) 1f else 0.35f)
            )
        }
    }
}
