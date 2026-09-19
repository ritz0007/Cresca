package com.cresca.app

import android.util.Log
import androidx.compose.runtime.*
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class PlayerQueue(
    private val player: Player,
    private val scope: CoroutineScope,
    private val onResolveStart: () -> Unit = {},
    private val onResolved: suspend (YtTrack) -> Unit = {},
    private val onError: (String) -> Unit = {},
    var onExhausted: ((YtTrack) -> Unit)? = null
) {
    companion object {
        private const val TAG = "PlayerQueue"
        const val SHUFFLE_OFF = 0
        const val SHUFFLE_ON = 1
        const val SHUFFLE_SMART = 2
    }

    val items: SnapshotStateList<YtTrack> = mutableStateListOf()

    var currentIndex: Int by mutableIntStateOf(-1)
        private set

    var shuffleMode: Int by mutableIntStateOf(SHUFFLE_OFF)
        private set

    /** Compat mirror: true when any shuffle mode is active. */
    var shuffleOn: Boolean by mutableStateOf(false)
        private set

    var repeatModeState: Int by mutableIntStateOf(Player.REPEAT_MODE_OFF)
        private set

    val current: YtTrack?
        get() = items.getOrNull(currentIndex)

    private val order: MutableList<Int> = mutableListOf()

    // Auto-fill bookkeeping: ids the engine appended (replaceable tail).
    private val autoIds: LinkedHashSet<String> = LinkedHashSet()

    // Exhaust hook fires once per track (avoids fetch loops).
    private var exhaustedFor: String? = null

    // Stuck fix: every resolve gets a generation token. Rapid taps cancel
    // the stale job so the last tap always wins (no wrong-track flips,
    // no shared urlOptions cross-talk, no permanent `resolving` lock).
    private var generation: Long = 0L
    private var resolveJob: Job? = null

    /** Cancel any in-flight resolve so a new tap starts clean. */
    fun cancelPending() {
        generation++
        try {
            resolveJob?.cancel()
        } catch (e: Exception) {
        }
        resolveJob = null
    }

    init {
        player.repeatMode = Player.REPEAT_MODE_OFF
    }

    fun setQueue(tracks: List<YtTrack>, startIndex: Int = 0) {
        cancelPending()
        autoIds.clear()
        exhaustedFor = null
        items.clear()
        items.addAll(tracks)
        if (items.isEmpty()) {
            currentIndex = -1
            order.clear()
            player.stop()
            return
        }
        currentIndex = startIndex.coerceIn(items.indices)
        if (shuffleOn) rebuildShuffled() else rebuildIdentity()
        current?.let { resolveAndPlay(it) }
    }

    /**
     * Restore a saved session without autoplaying (Spotify-style cold
     * start: queue + position are back, user presses play to resume).
     * Returns the restored index or -1.
     */
    fun setQueueSilent(
        tracks: List<YtTrack>,
        startIndex: Int,
        shuffle: Boolean,
        repeat: Int
    ): Int {
        cancelPending()
        items.clear()
        items.addAll(tracks)
        if (items.isEmpty()) {
            currentIndex = -1
            order.clear()
            return -1
        }
        // Apply shuffle/repeat BEFORE building order.
        shuffleMode = if (shuffle) SHUFFLE_ON else SHUFFLE_OFF
        shuffleOn = shuffle
        repeatModeState = repeat
        try {
            player.repeatMode = Player.REPEAT_MODE_OFF
        } catch (e: Exception) {
        }
        currentIndex = startIndex.coerceIn(items.indices)
        if (shuffleOn) {
            // Preserve restored index as the shuffle head.
            order.clear()
            order.add(currentIndex)
            order.addAll(items.indices.filter { it != currentIndex }.shuffled())
        } else {
            rebuildIdentity()
        }
        return currentIndex
    }

    fun snapshot(): List<YtTrack> = items.toList()

    /** Current play order (index list). UI splits prev/current/next from it. */
    fun playOrder(): List<Int> = try {
        order.toList()
    } catch (e: Exception) {
        emptyList()
    }

    /** Load tracks without autoplaying (for home/search results). */
    fun replaceAll(tracks: List<YtTrack>) {
        val keepId = current?.id
        val keepShuffle = shuffleOn
        items.clear()
        items.addAll(tracks)
        currentIndex = keepId?.let { id -> items.indexOfFirst { it.id == id } }
            ?.takeIf { it >= 0 } ?: -1
        // Shuffle fix: rebuildShuffled() early-returns when currentIndex == -1,
        // leaving an identity order behind while shuffleOn == true.
        if (keepShuffle && currentIndex != -1) {
            rebuildShuffled()
        } else {
            if (keepShuffle && currentIndex == -1) {
                // No current track: keep shuffle ON but order empty until a
                // track is chosen, so next() never uses a stale identity order.
                order.clear()
            } else {
                rebuildIdentity()
            }
        }
    }

    fun playAt(index: Int) {
        if (index !in items.indices) return
        cancelPending()
        currentIndex = index
        exhaustedFor = null
        resolveAndPlay(items[index])
    }

    fun playTrack(t: YtTrack) {
        val idx = items.indexOfFirst { it.id == t.id }
        if (idx >= 0) {
            playAt(idx)
        } else {
            cancelPending()
            items.add(t)
            order.add(items.lastIndex)
            playAt(items.lastIndex)
        }
    }

    fun addToQueue(t: YtTrack) {
        items.add(t)
        order.add(items.lastIndex)
    }

    fun playNext(t: YtTrack) {
        if (items.isEmpty() || currentIndex == -1) {
            items.add(t)
            if (!order.contains(items.lastIndex)) order.add(items.lastIndex)
            return
        }
        val insertPos = (currentIndex + 1).coerceIn(0..items.size)
        items.add(insertPos, t)
        for (i in order.indices) {
            if (order[i] >= insertPos) order[i]++
        }
        val curPos = order.indexOf(currentIndex)
        if (curPos == -1) {
            order.add(insertPos)
        } else {
            order.add(curPos + 1, insertPos)
        }
    }

    fun removeAt(index: Int) {
        if (index !in items.indices) return
        val removingCurrent = index == currentIndex
        if (removingCurrent) cancelPending()
        items.removeAt(index)
        if (items.isEmpty()) {
            currentIndex = -1
            order.clear()
            player.stop()
            player.clearMediaItems()
            return
        }
        order.remove(index)
        for (i in order.indices) {
            if (order[i] > index) order[i]--
        }
        if (removingCurrent) {
            currentIndex = if (index < items.size) index else items.size - 1
            if (!order.contains(currentIndex)) {
                order.add(0, currentIndex)
            }
            resolveAndPlay(items[currentIndex])
        } else if (index < currentIndex) {
            currentIndex--
        }
    }

    fun next() {
        if (items.isEmpty() || currentIndex == -1) return
        if (repeatModeState == Player.REPEAT_MODE_ONE) {
            cancelPending()
            current?.let { resolveAndPlay(it) }
            return
        }
        val pos = order.indexOf(currentIndex)
        if (pos == -1) {
            if (shuffleOn) rebuildShuffled() else rebuildIdentity()
            return
        }
        // Instant path: the next item is already buffered behind current.
        if (player.mediaItemCount > 1) {
            val expected = if (pos < order.lastIndex) {
                order[pos + 1]
            } else if (repeatModeState == Player.REPEAT_MODE_ALL) {
                order[0]
            } else {
                null
            }
            if (expected != null) {
                val got = try {
                    player.getMediaItemAt(1).mediaId
                } catch (e: Exception) {
                    null
                }
                val want = items.getOrNull(expected)?.id
                if (got != null && want != null && got == want) {
                    currentIndex = expected
                    exhaustedFor = null
                    try {
                        player.seekToNext()
                        player.play()
                        if (player.mediaItemCount > 1) {
                            player.removeMediaItem(0)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "seekToNext failed", e)
                        resolveAndPlay(items[currentIndex])
                        return
                    }
                    scope.launch { onResolved(items[currentIndex]) }
                    return
                }
            }
        }
        if (pos < order.lastIndex) {
            cancelPending()
            currentIndex = order[pos + 1]
            exhaustedFor = null
            resolveAndPlay(items[currentIndex])
        } else if (repeatModeState == Player.REPEAT_MODE_ALL) {
            cancelPending()
            currentIndex = order[0]
            exhaustedFor = null
            resolveAndPlay(items[currentIndex])
        } else {
            // Queue exhausted with repeat off: autoplay related tracks
            // of the current song (endless radio). Fires once per track.
            val cur = current
            if (cur != null && exhaustedFor != cur.id) {
                exhaustedFor = cur.id
                try {
                    onExhausted?.invoke(cur)
                } catch (e: Exception) {
                    Log.w(TAG, "onExhausted failed", e)
                }
            }
        }
    }

    fun previous() {
        if (items.isEmpty() || currentIndex == -1) return
        val pos = order.indexOf(currentIndex)
        if (pos == -1) {
            if (shuffleOn) rebuildShuffled() else rebuildIdentity()
            return
        }
        if (pos > 0) {
            cancelPending()
            currentIndex = order[pos - 1]
            exhaustedFor = null
            resolveAndPlay(items[currentIndex])
        } else if (repeatModeState == Player.REPEAT_MODE_ALL) {
            cancelPending()
            currentIndex = order[order.lastIndex]
            exhaustedFor = null
            resolveAndPlay(items[currentIndex])
        }
    }

    private fun mediaItemFor(t: YtTrack, url: String): MediaItem {
        val metaBuilder = MediaMetadata.Builder()
            .setTitle(t.title)
            .setArtist(t.artist)
        try {
            if (t.thumbUrl.isNotBlank()) {
                metaBuilder.setArtworkUri(android.net.Uri.parse(t.thumbUrl))
            }
        } catch (e: Exception) {
        }
        return MediaItem.Builder()
            .setUri(url)
            .setMediaId(t.id)
            .setMediaMetadata(metaBuilder.build())
            .build()
    }

    // Buffer upcoming tracks behind current: ExoPlayer flips gaplessly on
    // auto-advance, and manual next() is instant (even 2 rapid skips).
    // Keeps up to 2 primed ahead: [current, next, next+1].
    suspend fun primeNext() {
        if (items.isEmpty() || currentIndex == -1) return
        if (repeatModeState == Player.REPEAT_MODE_ONE) return
        try {
            // Prime while fewer than 3 buffered (covers double-skip).
            while (player.mediaItemCount < 3) {
                val idx = peekIndexAhead(player.mediaItemCount - 1) ?: return
                val t = items.getOrNull(idx) ?: return
                if (t.watchUrl.isBlank()) return
                val url = try {
                    YoutubeRepository.audioUrl(t.watchUrl)
                } catch (e: Exception) {
                    null
                } ?: return
                // Race guard: queue moved while resolving.
                if (peekIndexAhead(player.mediaItemCount - 1) != idx) return
                try {
                    player.addMediaItem(mediaItemFor(t, url))
                } catch (e: Exception) {
                    return
                }
            }
        } catch (e: Exception) {
        }
    }

    /** Index N steps ahead in play order (0 = immediate next). */
    private fun peekIndexAhead(ahead: Int): Int? {
        try {
            if (items.isEmpty() || currentIndex == -1) return null
            if (repeatModeState == Player.REPEAT_MODE_ONE) {
                return if (ahead == 0) currentIndex else null
            }
            val pos = order.indexOf(currentIndex)
            if (pos == -1) return null
            val target = pos + 1 + ahead
            if (target <= order.lastIndex) return order[target]
            if (repeatModeState == Player.REPEAT_MODE_ALL && order.isNotEmpty()) {
                return order[target % order.size]
            }
            return null
        } catch (e: Exception) {
            return null
        }
    }

    // Called when the player auto-advanced onto the primed item.
    fun confirmAdvanced() {
        try {
            if (player.mediaItemCount < 2) return
            val idx = peekNextIndex() ?: return
            val got = try {
                player.getMediaItemAt(1).mediaId
            } catch (e: Exception) {
                null
            }
            val want = items.getOrNull(idx)?.id
            if (got == null || want == null || got != want) return
            currentIndex = idx
            try {
                player.removeMediaItem(0)
            } catch (e: Exception) {
            }
            items.getOrNull(idx)?.let { scope.launch { onResolved(it) } }
        } catch (e: Exception) {
            Log.e(TAG, "confirmAdvanced failed", e)
        }
    }

    fun cycleRepeat() {
        // Repeat is handled manually via next()/STATE_ENDED so the queue
        // advances correctly; the player itself always stays un-looped.
        repeatModeState = when (repeatModeState) {
            Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL
            Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE
            else -> Player.REPEAT_MODE_OFF
        }
    }

    /**
     * Shuffle cycles OFF -> shuffle -> SMART shuffle -> OFF.
     * SMART orders upcoming tracks by listener preference (applied by UI).
     */
    fun cycleShuffle(): Int {
        shuffleMode = when (shuffleMode) {
            SHUFFLE_OFF -> SHUFFLE_ON
            SHUFFLE_ON -> SHUFFLE_SMART
            else -> SHUFFLE_OFF
        }
        shuffleOn = shuffleMode != SHUFFLE_OFF
        if (items.isEmpty() || currentIndex == -1) {
            order.clear()
            return shuffleMode
        }
        when (shuffleMode) {
            SHUFFLE_OFF -> rebuildIdentity()
            else -> rebuildShuffled()
        }
        return shuffleMode
    }

    fun toggleShuffle() {
        cycleShuffle()
    }

    /** Manual reorder: move one step in play order (drag & drop). */
    fun moveInOrder(fromPos: Int, toPos: Int) {
        try {
            if (fromPos !in order.indices || toPos !in order.indices) return
            if (fromPos == toPos) return
            val v = order.removeAt(fromPos)
            order.add(toPos.coerceIn(order.indices), v)
        } catch (e: Exception) {
            Log.w(TAG, "moveInOrder failed", e)
        }
    }

    /** Apply a caller-computed play order (smart shuffle). Current first. */
    fun applyOrder(indices: List<Int>) {
        try {
            if (indices.toSet() != items.indices.toSet()) return
            order.clear()
            order.addAll(indices)
        } catch (e: Exception) {
            Log.w(TAG, "applyOrder failed", e)
        }
    }

    /** True when next() would move somewhere (used for ENDED dead-end fix). */
    fun hasNext(): Boolean {
        if (items.isEmpty() || currentIndex == -1) return false
        if (repeatModeState != Player.REPEAT_MODE_OFF) return true
        val pos = order.indexOf(currentIndex)
        if (pos == -1) return items.size > 1
        if (pos < order.lastIndex) return true
        // End of queue but autoplay can extend it with related tracks.
        return onExhausted != null
    }

    /** Tracks queued after the current one (autoplay keeps this at ~20). */
    fun upcomingCount(): Int {
        if (items.isEmpty() || currentIndex == -1) return 0
        val pos = order.indexOf(currentIndex)
        if (pos == -1) return items.size
        return order.lastIndex - pos
    }

    /** Next [n] tracks in play order (for background pre-caching). */
    fun upcomingIds(n: Int): List<YtTrack> {
        try {
            if (items.isEmpty() || currentIndex == -1 || n <= 0) return emptyList()
            val pos = order.indexOf(currentIndex)
            if (pos == -1) return emptyList()
            return order.subList(pos + 1, order.size).take(n)
                .mapNotNull { items.getOrNull(it) }
        } catch (e: Exception) {
            return emptyList()
        }
    }

    /**
     * Append engine-picked tracks (related autoplay). New ids are tagged so
     * the next refresh can replace the tail without touching user tracks.
     * Inserted right after the current position in play order.
     */
    fun appendAuto(tracks: List<YtTrack>) {
        try {
            if (tracks.isEmpty()) return
            val fresh = tracks.filter { t -> items.none { it.id == t.id } }
            if (fresh.isEmpty()) return
            val base = items.size
            items.addAll(fresh)
            for (t in fresh) autoIds.add(t.id)
            val curPos = order.indexOf(currentIndex)
            var at = if (curPos == -1) order.size else curPos + 1
            for (k in fresh.indices) {
                order.add(at.coerceIn(0..order.size), base + k)
                at++
            }
        } catch (e: Exception) {
            Log.w(TAG, "appendAuto failed", e)
        }
    }

    /** Drop engine-picked tail (keeps the playing track + user tracks). */
    fun clearAutoTail() {
        try {
            if (autoIds.isEmpty()) return
            val curId = current?.id
            val drop = items.indices.filter { i ->
                i != currentIndex && autoIds.contains(items[i].id)
            }.sortedDescending()
            if (drop.isEmpty()) {
                autoIds.clear()
                return
            }
            for (i in drop) items.removeAt(i)
            autoIds.clear()
            // Rebuild play order around the surviving tracks.
            order.clear()
            if (items.isEmpty()) {
                currentIndex = -1
                return
            }
            currentIndex = curId?.let { id -> items.indexOfFirst { it.id == id } }
                ?.takeIf { it >= 0 } ?: 0
            if (shuffleMode == SHUFFLE_OFF) {
                rebuildIdentity()
            } else {
                order.add(currentIndex)
                order.addAll(items.indices.filter { it != currentIndex }.shuffled())
            }
        } catch (e: Exception) {
            Log.w(TAG, "clearAutoTail failed", e)
        }
    }

    private fun rebuildIdentity() {
        order.clear()
        order.addAll(items.indices)
    }

    private fun rebuildShuffled() {
        order.clear()
        if (items.isEmpty() || currentIndex == -1) return
        val cur = currentIndex
        order.add(cur)
        order.addAll(items.indices.filter { it != cur }.shuffled())
    }

    private var urlOptions: List<String> = emptyList()
    private var urlIndex: Int = 0

    private fun resolveAndPlay(t: YtTrack) {
        generation++
        val gen = generation
        try {
            resolveJob?.cancel()
        } catch (e: Exception) {
        }
        resolveJob = scope.launch {
            try {
                onResolveStart()
                val urls = YoutubeRepository.audioUrls(t.watchUrl)
                // Stale resolve: a newer tap already started, drop this one.
                if (gen != generation) return@launch
                urlOptions = urls
                urlIndex = 0
                val url = urls.firstOrNull()
                if (url != null) {
                    if (gen != generation) return@launch
                    playUrl(t, url)
                    scope.launch { onResolved(t) }
                    prefetchNext()
                } else {
                    if (gen != generation) return@launch
                    onError("Could not resolve audio stream")
                }
            } catch (e: Exception) {
                if (gen != generation) return@launch
                Log.e(TAG, "resolveAndPlay failed", e)
                onError("Could not resolve audio stream")
            }
        }
    }

    private fun playUrl(t: YtTrack, url: String) {
        val metaBuilder = MediaMetadata.Builder()
            .setTitle(t.title)
            .setArtist(t.artist)
        try {
            if (t.thumbUrl.isNotBlank()) {
                metaBuilder.setArtworkUri(android.net.Uri.parse(t.thumbUrl))
            }
        } catch (e: Exception) {
        }
        val item = MediaItem.Builder()
            .setUri(url)
            .setMediaId(t.id)
            .setMediaMetadata(metaBuilder.build())
            .build()
        player.setMediaItem(item)
        player.prepare()
        player.play()
    }

    // 403/410 fallback: the extractor hands several hosts; try the next one.
    // Returns false when nothing is left to try.
    fun retryWithNextUrl(): Boolean {
        val t = current ?: return false
        if (t.watchUrl.isBlank()) {
            return false
        }
        val next = urlIndex + 1
        if (next >= urlOptions.size) {
            return false
        }
urlIndex = next
            onResolveStart()
            try {
                playUrl(t, urlOptions[next])
                scope.launch { onResolved(t) }
        } catch (e: Exception) {
            Log.e(TAG, "retry play failed", e)
            return retryWithNextUrl()
        }
        return true
    }

    // Warm the stream-URL cache for the upcoming track while this one plays.
    private fun peekNextIndex(): Int? {
        if (items.isEmpty() || currentIndex == -1) return null
        if (repeatModeState == Player.REPEAT_MODE_ONE) return currentIndex
        val pos = order.indexOf(currentIndex)
        if (pos == -1) return null
        if (pos < order.lastIndex) return order[pos + 1]
        if (repeatModeState == Player.REPEAT_MODE_ALL) return order[0]
        return null
    }

    private fun prefetchNext() {
        try {
            val idx = peekNextIndex() ?: return
            val t = items.getOrNull(idx) ?: return
            if (t.watchUrl.isBlank()) return
            scope.launch {
                try {
                    YoutubeRepository.audioUrl(t.watchUrl)
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
        }
    }
}
