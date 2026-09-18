package com.cresca.app

import android.util.Log
import androidx.compose.runtime.*
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

class PlayerQueue(
    private val player: Player,
    private val scope: CoroutineScope,
    private val onResolveStart: () -> Unit = {},
    private val onResolved: (YtTrack) -> Unit = {},
    private val onError: (String) -> Unit = {}
) {
    companion object {
        private const val TAG = "PlayerQueue"
    }

    val items: SnapshotStateList<YtTrack> = mutableStateListOf()

    var currentIndex: Int by mutableIntStateOf(-1)
        private set

    var shuffleOn: Boolean by mutableStateOf(false)
        private set

    var repeatModeState: Int by mutableIntStateOf(Player.REPEAT_MODE_OFF)
        private set

    val current: YtTrack?
        get() = items.getOrNull(currentIndex)

    private val order: MutableList<Int> = mutableListOf()

    init {
        player.repeatMode = Player.REPEAT_MODE_OFF
    }

    fun setQueue(tracks: List<YtTrack>, startIndex: Int = 0) {
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

    /** Load tracks without autoplaying (for home/search results). */
    fun replaceAll(tracks: List<YtTrack>) {
        val keepId = current?.id
        items.clear()
        items.addAll(tracks)
        rebuildIdentity()
        currentIndex = keepId?.let { id -> items.indexOfFirst { it.id == id } }
            ?.takeIf { it >= 0 } ?: -1
        if (shuffleOn) rebuildShuffled()
    }

    fun playAt(index: Int) {
        if (index !in items.indices) return
        currentIndex = index
        resolveAndPlay(items[index])
    }

    fun playTrack(t: YtTrack) {
        val idx = items.indexOfFirst { it.id == t.id }
        if (idx >= 0) {
            playAt(idx)
        } else {
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
                    onResolved(items[currentIndex])
                    return
                }
            }
        }
        if (pos < order.lastIndex) {
            currentIndex = order[pos + 1]
            resolveAndPlay(items[currentIndex])
        } else if (repeatModeState == Player.REPEAT_MODE_ALL) {
            currentIndex = order[0]
            resolveAndPlay(items[currentIndex])
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
            currentIndex = order[pos - 1]
            resolveAndPlay(items[currentIndex])
        } else if (repeatModeState == Player.REPEAT_MODE_ALL) {
            currentIndex = order[order.lastIndex]
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

    // Buffer the upcoming track behind the current one: ExoPlayer then
    // flips gaplessly on auto-advance, and manual next() is instant.
    fun primeNext() {
        if (items.isEmpty() || currentIndex == -1) return
        if (repeatModeState == Player.REPEAT_MODE_ONE) return
        if (player.mediaItemCount != 1) return
        val idx = peekNextIndex() ?: return
        val t = items.getOrNull(idx) ?: return
        if (t.watchUrl.isBlank()) return
        scope.launch {
            try {
                val url = YoutubeRepository.audioUrl(t.watchUrl)
                if (url == null) return@launch
                if (player.mediaItemCount != 1) return@launch
                if (peekNextIndex() != idx) return@launch
                player.addMediaItem(mediaItemFor(t, url))
            } catch (e: Exception) {
            }
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
            items.getOrNull(idx)?.let { onResolved(it) }
        } catch (e: Exception) {
            Log.e(TAG, "confirmAdvanced failed", e)
        }
    }

    fun toggleShuffle() {
        shuffleOn = !shuffleOn
        if (items.isEmpty()) {
            order.clear()
            return
        }
        if (currentIndex == -1) {
            if (shuffleOn) {
                order.clear()
                order.addAll(items.indices.shuffled())
            } else {
                rebuildIdentity()
            }
            return
        }
        if (shuffleOn) {
            rebuildShuffled()
        } else {
            rebuildIdentity()
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
        scope.launch {
            try {
                onResolveStart()
                val urls = YoutubeRepository.audioUrls(t.watchUrl)
                urlOptions = urls
                urlIndex = 0
                val url = urls.firstOrNull()
                if (url != null) {
                    playUrl(t, url)
                    onResolved(t)
                    prefetchNext()
                } else {
                    onError("Could not resolve audio stream")
                }
            } catch (e: Exception) {
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
            onResolved(t)
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
