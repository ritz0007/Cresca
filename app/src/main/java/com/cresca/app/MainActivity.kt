package com.cresca.app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.core.view.WindowCompat
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import coil.compose.AsyncImage
import com.cresca.app.ui.theme.AppleMusicTheme
import com.cresca.app.ui.theme.ArtGradients
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeEffect
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.materials.ExperimentalHazeMaterialsApi
import dev.chrisbanes.haze.materials.HazeMaterials
import dev.chrisbanes.haze.rememberHazeState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import java.io.File

private const val TAG = "Cresca"
private const val HOME_QUERY = "latest hindi songs"
private const val HOME_CACHE_TTL = 12 * 60 * 60 * 1000L
private const val SEARCH_CACHE_TTL = 30 * 60 * 1000L

private data class Tab(val label: String, val icon: ImageVector)

private val tabs = listOf(
    Tab("Listen Now", Icons.Filled.Home),
    Tab("Browse", Icons.Filled.Explore),
    Tab("Radio", Icons.Filled.Radio),
    Tab("Library", Icons.Filled.LibraryMusic),
    Tab("Search", Icons.Filled.Search)
)

private fun fmtMs(ms: Long): String {
    if (ms <= 0) return "0:00"
    val s = ms / 1000
    return "${s / 60}:${String.format("%02d", s % 60)}"
}

// Shared track metadata for audio/video media items (top-level: usable anywhere).
private fun metaFor(t: YtTrack): androidx.media3.common.MediaMetadata {
    val b = androidx.media3.common.MediaMetadata.Builder()
        .setTitle(t.title)
        .setArtist(t.artist)
    try {
        if (t.thumbUrl.isNotBlank()) {
            b.setArtworkUri(android.net.Uri.parse(t.thumbUrl))
        }
    } catch (e: Exception) {
    }
    return b.build()
}

// True when the player failed on an HTTP block (403/410 throttling).
private fun isHttpBlock(error: PlaybackException): Boolean {
    var c: Throwable? = error.cause
    var depth = 0
    while (c != null && depth < 8) {
        val name = c.javaClass.name
        if (name.contains("InvalidResponseCode") || name.contains("HttpDataSource")) {
            return true
        }
        c = c.cause
        depth++
    }
    return error.errorCode == PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS
}

/** Enqueue a track download; safe to call from any composable scope. */
private fun kotlinx.coroutines.CoroutineScope.enqueueDownload(
    ctx: android.content.Context,
    track: YtTrack
) {
    this.launch {
        try {
            if (DownloadStore.isDownloaded(ctx, track.id)) return@launch
            val url = YoutubeRepository.audioUrl(track.watchUrl)
            if (url != null) {
                DownloadStore.enqueue(ctx, track, url)
                Log.i(TAG, "download started ${track.title}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "download failed", e)
        }
    }
}

class MainActivity : ComponentActivity() {
    private val notifPerm =
        registerForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
        ) { }

    private var themeMode by mutableStateOf("system")

    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        var uiReady = false
        splash.setKeepOnScreenCondition { !uiReady }
        super.onCreate(savedInstanceState)
        try {
            themeMode = getPreferences(MODE_PRIVATE).getString("theme", "system") ?: "system"
        } catch (e: Exception) {
        }
        // Media notification needs this on Android 13+.
        try {
            if (android.os.Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                notifPerm.launch(android.Manifest.permission.POST_NOTIFICATIONS)
            }
        } catch (e: Exception) {
        }
        setContent {
            val dark = when (themeMode) {
                "light" -> false
                "dark" -> true
                else -> isSystemInDarkTheme()
            }
            AppleMusicTheme(darkTheme = dark) {
                SystemBars(dark)
                AppleMusicApp(
                    onReady = { uiReady = true },
                    themeMode = themeMode,
                    onThemeMode = {
                        themeMode = it
                        try {
                            getPreferences(MODE_PRIVATE).edit().putString("theme", it).apply()
                        } catch (e: Exception) {
                        }
                    }
                )
            }
        }
    }
}

/** Status + nav bars follow the theme (fixes white bars in dark mode). */
@Composable
private fun SystemBars(dark: Boolean) {
    val view = LocalView.current
    DisposableEffect(dark) {
        try {
            val window = (view.context as android.app.Activity).window
            window.statusBarColor = android.graphics.Color.TRANSPARENT
            window.navigationBarColor = android.graphics.Color.TRANSPARENT
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        } catch (e: Exception) {
        }
        onDispose { }
    }
}

/** Waits for the media session, then hosts the app on the shared player. */
@OptIn(ExperimentalHazeMaterialsApi::class)
@Composable
fun AppleMusicApp(
    onReady: () -> Unit = {},
    themeMode: String = "system",
    onThemeMode: (String) -> Unit = {}
) {
    val context = LocalContext.current
    var controller by remember { mutableStateOf<androidx.media3.session.MediaController?>(null) }
    LaunchedEffect(Unit) {
        // Bind only: the service foregrounds itself once playback starts
        // (starting it foreground eagerly ANRs when nothing plays).
        controller = try {
            androidx.media3.session.MediaController.Builder(
                context,
                androidx.media3.session.SessionToken(
                    context,
                    android.content.ComponentName(context, PlaybackService::class.java)
                )
            ).buildAsync().awaitMedia()
        } catch (e: Exception) {
            Log.e(TAG, "controller connect failed", e)
            null
        }
    }
    DisposableEffect(Unit) {
        onDispose {
            try {
                controller?.release()
            } catch (e: Exception) {
            }
        }
    }
    val player = controller
    if (player == null) {
        IntroScreen()
    } else {
        AppleMusicAppContent(player, onReady, themeMode, onThemeMode)
    }
}

private suspend fun <T> com.google.common.util.concurrent.ListenableFuture<T>.awaitMedia(): T =
    kotlinx.coroutines.suspendCancellableCoroutine { cont ->
        com.google.common.util.concurrent.Futures.addCallback(
            this,
            object : com.google.common.util.concurrent.FutureCallback<T> {
                override fun onSuccess(result: T?) {
                    if (result == null) {
                        cont.resumeWithException(IllegalStateException("null controller"))
                    } else {
                        cont.resume(result)
                    }
                }

                override fun onFailure(t: Throwable) {
                    cont.resumeWithException(t)
                }
            },
            com.google.common.util.concurrent.MoreExecutors.directExecutor()
        )
        cont.invokeOnCancellation {
            try {
                cancel(false)
            } catch (e: Exception) {
            }
        }
    }

@OptIn(ExperimentalHazeMaterialsApi::class)
@Composable
fun AppleMusicAppContent(
    player: Player,
    onReady: () -> Unit = {},
    themeMode: String = "system",
    onThemeMode: (String) -> Unit = {}
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // Real player state — UI never guesses, it mirrors ExoPlayer
    var isPlaying by remember { mutableStateOf(false) }
    var playerState by remember { mutableIntStateOf(Player.STATE_IDLE) }
    var playerError by remember { mutableStateOf<String?>(null) }

    var selectedTab by remember { mutableIntStateOf(0) }
    var query by remember { mutableStateOf("") }
    var homeTracks by remember { mutableStateOf<List<YtTrack>>(emptyList()) }
    var homeLoading by remember { mutableStateOf(true) }
    var homeError by remember { mutableStateOf<String?>(null) }
    var homeTick by remember { mutableIntStateOf(0) }
    var live by remember { mutableStateOf(false) }
    var nowPlaying by remember { mutableStateOf<YtTrack?>(null) }
    var resolving by remember { mutableStateOf(false) }
    var showFullPlayer by remember { mutableStateOf(false) }
    // Video mode lives here (before the queue) so resolve callbacks can see it.
    var videoMode by remember { mutableStateOf(false) }
    var videoFollowTick by remember { mutableIntStateOf(0) }
    var primeTick by remember { mutableIntStateOf(0) }
    var videoOpts by remember { mutableStateOf<List<YoutubeRepository.VideoOption>>(emptyList()) }
    var videoLoading by remember { mutableStateOf(false) }
    var videoQualityH by remember { mutableIntStateOf(-1) }
    var dashUrl by remember { mutableStateOf("") }
    var dashCapH by remember { mutableIntStateOf(0) }

    // Quality rows for the picker: DASH caps when available, else muxed heights.
    fun qualityLabels(): List<String> {
        return if (dashUrl.isNotBlank()) {
            listOf("Auto", "1080p", "720p", "480p", "360p")
        } else {
            videoOpts.map { it.label }.distinct()
        }
    }

    fun currentQualityLabel(): String {
        if (dashUrl.isNotBlank()) {
            return if (dashCapH <= 0) "Auto" else "${dashCapH}p"
        }
        return if (videoQualityH > 0) "${videoQualityH}p" else "Auto"
    }

    fun playDash(t: YtTrack, url: String, capH: Int, fromPos: Long, autoplay: Boolean) {
        player.setMediaItem(
            MediaItem.Builder()
                .setUri(url)
                .setMediaId("v:" + t.id)
                .setMediaMetadata(metaFor(t))
                .setMimeType(androidx.media3.common.MimeTypes.APPLICATION_MPD)
                .build()
        )
        try {
            if (capH > 0) {
                player.trackSelectionParameters = player.trackSelectionParameters
                    .buildUpon()
                    .setMaxVideoSize(capH * 16 / 9, capH)
                    .build()
            } else {
                player.trackSelectionParameters = player.trackSelectionParameters
                    .buildUpon()
                    .setMaxVideoSize(Int.MAX_VALUE, Int.MAX_VALUE)
                    .build()
            }
        } catch (e: Exception) {
        }
        player.prepare()
        player.seekTo(fromPos)
        if (autoplay) {
            player.play()
        }
        dashCapH = capH
    }
    var announced by remember { mutableStateOf(false) }
    fun announce() { if (!announced) { announced = true; onReady() } }
    // Animated intro holds ~1.2s after data is ready, then fades away.
    var introDone by remember { mutableStateOf(false) }
    LaunchedEffect(announced) {
        if (announced) {
            delay(1200)
            introDone = true
        }
    }
    val hazeState = remember { HazeState() }
    var newTracks by remember { mutableStateOf<List<YtTrack>>(emptyList()) }
    val recent = remember { mutableStateListOf<YtTrack>() }
    var liked by remember { mutableStateOf<List<YtTrack>>(emptyList()) }
    // Likes load off the main thread (file IO must never block composition).
    LaunchedEffect(Unit) {
        try {
            liked = withContext(Dispatchers.IO) { LikedStore.load(context) }
        } catch (e: Exception) {
        }
    }
    var showQueue by remember { mutableStateOf(false) }
    var seeAllTitle by remember { mutableStateOf("") }
    var seeAllTracks by remember { mutableStateOf<List<YtTrack>>(emptyList()) }
    var showSeeAll by remember { mutableStateOf(false) }
    var searchFocusTick by remember { mutableIntStateOf(0) }
    var lastSearchTap by remember { mutableLongStateOf(0L) }
    var loggedIn by remember { mutableStateOf(false) }
    var loginFailed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        try {
            loggedIn = withContext(Dispatchers.IO) { YtSessionManager.isLoggedIn(context) }
        } catch (e: Exception) {
        }
    }
    var showSession by remember { mutableStateOf(false) }
    var dlItems by remember { mutableStateOf<List<Pair<YtTrack, File>>>(emptyList()) }
    var showDownloads by remember { mutableStateOf(false) }
    var showProfile by remember { mutableStateOf(false) }
    var dlLoc by remember { mutableStateOf(DownloadStore.location(context)) }

    fun clearSongCache() {
        scope.launch(Dispatchers.IO) {
            try {
                context.cacheDir
                    .listFiles { f -> f.isFile && f.name.startsWith("yt_") }
                    ?.forEach {
                        try {
                            it.delete()
                        } catch (e: Exception) {
                        }
                    }
            } catch (e: Exception) {
            }
        }
        homeTick++
    }
    var showPlaylist by remember { mutableStateOf<Playlist?>(null) }

    fun openPlaylist(id: String) {
        try {
            showPlaylist = PlaylistStore.list(context).find { it.id == id }
        } catch (e: Exception) {
        }
    }

    fun refreshDownloads() {
        scope.launch(Dispatchers.IO) {
            try {
                dlItems = DownloadStore.listAll(context)
            } catch (e: Exception) {
                dlItems = emptyList()
            }
        }
    }

    // Session cookies for the extractor + download engine warmth
    LaunchedEffect(Unit) {
        try {
            YoutubeRepository.initAppContext(context)
        } catch (e: Exception) {
        }
    }

    fun pushRecent(t: YtTrack) {
        recent.removeAll { it.id == t.id }
        recent.add(0, t)
        while (recent.size > 12) recent.removeLast()
    }

    fun toggleLike(t: YtTrack) {
        liked = if (liked.any { it.id == t.id }) liked.filter { it.id != t.id }
        else listOf(t) + liked
        val snapshot = liked
        scope.launch(Dispatchers.IO) {
            try {
                LikedStore.save(context, snapshot)
            } catch (e: Exception) {
            }
        }
    }

    fun isLiked(t: YtTrack) = liked.any { it.id == t.id }

    fun startPlaybackService() {
        try {
            androidx.core.content.ContextCompat.startForegroundService(
                context, android.content.Intent(context, PlaybackService::class.java)
            )
        } catch (e: Exception) {
            Log.w(TAG, "service start failed", e)
        }
    }

    val queue = remember {
        PlayerQueue(player, scope,
            onResolveStart = { resolving = true },
            onResolved = { t ->
                resolving = false
                playerError = null
                nowPlaying = t
                pushRecent(t)
                startPlaybackService()
                Log.i(TAG, "playing ${t.title}")
                // Warm the video options so audio->video flips instantly.
                scope.launch {
                    try {
                        YoutubeRepository.videoOptions(t.watchUrl)
                    } catch (e: Exception) {
                    }
                }
                // New track while watching video: follow it into video mode.
                if (videoMode) {
                    videoFollowTick++
                } else {
                    // Buffer the track after this one: gapless change.
                    primeTick++
                }
            },
            onError = { msg ->
                resolving = false
                playerError = msg
            })
    }

    // Auto-advance at track end (repeat/shuffle handled inside queue)
    LaunchedEffect(playerState) {
        if (playerState == Player.STATE_ENDED) queue.next()
    }

    // Gapless lookahead trigger (set by resolve callbacks above).
    LaunchedEffect(primeTick) {
        if (primeTick > 0 && !videoMode) {
            queue.primeNext()
        }
    }

    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) { playerState = state }
            override fun onIsPlayingChanged(v: Boolean) { isPlaying = v }
            override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
                // Player flipped gaplessly onto the primed item: adopt it.
                if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) {
                    queue.confirmAdvanced()
                }
            }
            override fun onPlayerError(error: PlaybackException) {
                Log.e(TAG, "player error", error)
                // YouTube 403/410 throttling: drop the stale URL, try the next host.
                if (isHttpBlock(error)) {
                    try {
                        queue.current?.let { YoutubeRepository.dropCachedUrl(it.watchUrl) }
                    } catch (e: Exception) {
                    }
                    playerError = "Retrying…"
                    if (!queue.retryWithNextUrl()) {
                        playerError = "YouTube blocked playback (403)"
                    }
                    return
                }
                playerError = error.message ?: "Playback error (${error.errorCode})"
            }
        }
        player.addListener(listener)
        // Player + session lifetimes belong to PlaybackService; only detach here.
        onDispose { player.removeListener(listener) }
    }

    // Position clock for seek bar + synced lyrics
    var position by remember { mutableLongStateOf(0L) }
    var duration by remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) {
        while (true) {
            position = player.currentPosition
            duration = player.duration.coerceAtLeast(0L)
            delay(500)
        }
    }

    // Lyrics follow the current track
    var lyrics by remember { mutableStateOf<LyricsState>(LyricsState.NotFound) }
    LaunchedEffect(nowPlaying) {
        val t = nowPlaying
        if (t == null || t.watchUrl.isBlank()) {
            lyrics = LyricsState.NotFound
        } else {
            lyrics = LyricsState.Loading
            lyrics = LyricsRepository.fetch(t.artist, t.title)
        }
    }

    fun playFile(track: YtTrack, file: File) {
        try {
            playerError = null
            resolving = false
            val t = track.copy(localPath = file.absolutePath)
            nowPlaying = t
            val metaBuilder = androidx.media3.common.MediaMetadata.Builder()
                .setTitle(t.title)
                .setArtist(t.artist)
            try {
                if (t.thumbUrl.isNotBlank()) {
                    metaBuilder.setArtworkUri(Uri.parse(t.thumbUrl))
                }
            } catch (e: Exception) {
            }
            player.setMediaItem(
                MediaItem.Builder()
                    .setUri(Uri.fromFile(file))
                    .setMediaId(t.id)
                    .setMediaMetadata(metaBuilder.build())
                    .build()
            )
            player.prepare()
            startPlaybackService()
            player.play()
            pushRecent(t)
            Log.i(TAG, "playing offline ${t.title}")
        } catch (e: Exception) {
            Log.e(TAG, "offline play failed", e)
            playerError = "Offline play failed"
        }
    }

    fun play(track: YtTrack) {
        if (resolving) return
        playerError = null
        // Offline first: downloaded songs play without network
        try {
            if (DownloadStore.isDownloaded(context, track.id)) {
                DownloadStore.fileFor(context, track.id)?.let { playFile(track, it); return }
            }
        } catch (e: Exception) {
        }
        if (track.watchUrl.isBlank()) { nowPlaying = track; return } // demo item
        val idx = queue.items.indexOfFirst { it.id == track.id }
        if (player.mediaItemCount > 0 && queue.current?.id == track.id) {
            if (player.isPlaying) player.pause() else player.play()
            return
        }
        nowPlaying = track
        if (queue.items.isEmpty()) queue.setQueue(listOf(track), 0)
        else if (idx == -1) queue.playTrack(track)
        else queue.playAt(idx)
    }

    fun togglePlay(track: YtTrack) {
        if (player.mediaItemCount == 0) play(track)
        else if (player.isPlaying) player.pause() else player.play()
    }

    fun playList(tracks: List<YtTrack>, index: Int = 0, shuffled: Boolean = false) {
        if (tracks.isEmpty()) return
        playerError = null
        val list = if (shuffled) tracks.shuffled() else tracks
        val i = index.coerceIn(list.indices)
        queue.setQueue(list, i)
        nowPlaying = list[i]
    }
    fun openSeeAll(title: String, tracks: List<YtTrack>) {
        seeAllTitle = title
        seeAllTracks = tracks
        showSeeAll = true
    }

    // ---- Video mode: the SAME session player swaps audio<->video streams,
    // so the music transport (play/pause/seek/prev/next) always drives video.
    fun enterVideo() {
        val t = nowPlaying
        if (t == null || t.watchUrl.isBlank()) {
            return
        }
        if (resolving || videoLoading) {
            return
        }
        videoMode = true
        videoLoading = true
        resolving = true
        scope.launch {
            try {
                val opts = YoutubeRepository.videoOptions(t.watchUrl)
                videoOpts = opts
                var dash = ""
                try {
                    dash = YoutubeRepository.videoDetails(t.watchUrl)?.dashUrl ?: ""
                } catch (e: Exception) {
                }
                dashUrl = dash
                val pos = player.currentPosition
                val playing = player.isPlaying
                if (dash.isNotBlank()) {
                    // DASH manifest: adaptive up to 1080p+, instant start.
                    playDash(t, dash, 0, pos, playing)
                    videoQualityH = -1
                } else {
                    dashCapH = 0
                    val url = opts.firstOrNull()?.url
                        ?: YoutubeRepository.videoUrl(t.watchUrl)
                    if (url != null) {
                        player.setMediaItem(
                            MediaItem.Builder()
                                .setUri(url)
                                .setMediaId("v:" + t.id)
                                .setMediaMetadata(metaFor(t))
                                .build()
                        )
                        player.prepare()
                        player.seekTo(pos)
                        if (playing) {
                            player.play()
                        }
                        videoQualityH = opts.firstOrNull()?.height ?: -1
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "enter video failed", e)
            } finally {
                videoLoading = false
                resolving = false
            }
        }
    }

    fun exitVideo(resume: Boolean = true) {
        videoMode = false
        val t = nowPlaying ?: return
        if (t.watchUrl.isBlank()) {
            return
        }
        resolving = true
        scope.launch {
            try {
                val pos = player.currentPosition
                val playing = player.isPlaying
                // Stream-URL cache makes this a memory hit in practice.
                val url = YoutubeRepository.audioUrl(t.watchUrl)
                if (url != null) {
                    player.setMediaItem(
                        MediaItem.Builder()
                            .setUri(url)
                            .setMediaId(t.id)
                            .setMediaMetadata(metaFor(t))
                            .build()
                    )
                    player.prepare()
                    player.seekTo(pos)
                    if (resume && playing) {
                        player.play()
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "exit video failed", e)
            } finally {
                resolving = false
            }
        }
    }

    // Quality picker entry point: DASH caps when available, else muxed URLs.
    fun pickQuality(label: String) {
        val t = nowPlaying ?: return
        val dash = dashUrl
        if (dash.isNotBlank()) {
            val cap = when (label) {
                "1080p" -> 1080
                "720p" -> 720
                "480p" -> 480
                "360p" -> 360
                else -> 0
            }
            playDash(t, dash, cap, player.currentPosition, player.isPlaying)
            return
        }
        val opt = videoOpts.firstOrNull { it.label == label } ?: return
        val ot = nowPlaying ?: return
        scope.launch {
            try {
                val pos = player.currentPosition
                val playing = player.isPlaying
                player.setMediaItem(
                    MediaItem.Builder()
                        .setUri(opt.url)
                        .setMediaId("v:" + ot.id)
                        .setMediaMetadata(metaFor(ot))
                        .build()
                )
                player.prepare()
                player.seekTo(pos)
                if (playing) {
                    player.play()
                }
                videoQualityH = opt.height
            } catch (e: Exception) {
                Log.e(TAG, "quality switch failed", e)
            }
        }
    }

    // Follows queue track changes while video mode is on.
    LaunchedEffect(videoFollowTick) {
        if (videoFollowTick > 0) {
            enterVideo()
        }
    }

    // Home: cache instantly (splash releases fast), refresh silently.
    // No demo data: loading spinner, then error + retry when offline.
    LaunchedEffect(homeTick) {
        homeLoading = homeTracks.isEmpty()
        homeError = null
        try {
            withContext(Dispatchers.IO) {
                SongCache.load(context, "home", HOME_CACHE_TTL)
            }?.let { cached ->
                homeTracks = cached
                live = true
                if (queue.items.isEmpty()) {
                    queue.replaceAll(cached)
                    if (nowPlaying == null) nowPlaying = cached.firstOrNull()
                }
                announce()
                Log.i(TAG, "home from cache (${cached.size})")
            }
        } catch (e: Exception) {
            Log.w(TAG, "cache read failed", e)
        }
        var attempt = 0
        var loaded = false
        while (attempt < 2 && !loaded) {
            attempt++
            try {
                val res = YoutubeRepository.searchSongs(HOME_QUERY, 25)
                if (res.isNotEmpty()) {
                    homeTracks = res
                    live = true
                    if (queue.items.isEmpty()) {
                        queue.replaceAll(res)
                        if (nowPlaying == null) nowPlaying = res.first()
                    }
                    try {
                        scope.launch(Dispatchers.IO) {
                            try {
                                SongCache.save(context, "home", res)
                            } catch (e: Exception) {
                            }
                        }
                    } catch (e: Exception) {
                    }
                    Log.i(TAG, "home loaded ${res.size} songs from YouTube")
                    loaded = true
                }
            } catch (e: Exception) {
                Log.w(TAG, "home load failed (attempt $attempt)", e)
                if (attempt < 2) {
                    delay(1500)
                }
            }
        }
        if (homeTracks.isEmpty()) {
            homeError = "Couldn't reach YouTube — check connection and retry"
        }
        homeLoading = false
        announce() // never trap the splash
    }

    // Reconnect reload: when the device regains network, refresh silently.
    DisposableEffect(Unit) {
        val cm = try {
            context.getSystemService(android.content.Context.CONNECTIVITY_SERVICE)
                as android.net.ConnectivityManager
        } catch (e: Exception) {
            null
        }
        val cb = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) {
                if (homeTracks.isEmpty() || !live) {
                    homeTick++
                }
            }
        }
        try {
            cm?.registerDefaultNetworkCallback(cb)
        } catch (e: Exception) {
        }
        onDispose {
            try {
                cm?.unregisterNetworkCallback(cb)
            } catch (e: Exception) {
            }
        }
    }

    // Update check: once a day, silent unless a newer release exists.
    var update by remember { mutableStateOf<UpdateCheck.Update?>(null) }
    LaunchedEffect(Unit) {
        try {
            if (!UpdateCheck.dueForCheck(context)) {
                return@LaunchedEffect
            }
            val latest = UpdateCheck.latest()
            UpdateCheck.markChecked(context)
            if (latest != null &&
                UpdateCheck.isNewer(UpdateCheck.currentVersion(context), latest.tag)
            ) {
                update = latest
            }
        } catch (e: Exception) {
        }
    }
    LaunchedEffect(Unit) {
        try {
            withContext(Dispatchers.IO) {
                SongCache.load(context, "new", 24 * 60 * 60 * 1000L)
            }?.let { newTracks = it }
        } catch (e: Exception) { }
        try {
            val fresh = YoutubeRepository.searchSongs("new hindi songs 2026", 12)
            if (fresh.isNotEmpty()) {
                newTracks = fresh
                try {
                    scope.launch(Dispatchers.IO) {
                        try {
                            SongCache.save(context, "new", fresh)
                        } catch (e: Exception) {
                        }
                    }
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "new releases failed", e)
        }
    }

    Box(Modifier.fillMaxSize()) {
    Scaffold(
        bottomBar = {
            // Apple liquid-glass bar: strong blur + hairline edge
            Column(
                Modifier
                    .hazeEffect(state = hazeState, style = HazeMaterials.regular())
                    .border(
                        1.dp,
                        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f),
                        RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp)
                    )
                    .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
            ) {
                nowPlaying?.let { t ->
                    FancyBar(
                        track = t,
                        isPlaying = isPlaying,
                        buffering = resolving || playerState == Player.STATE_BUFFERING,
                        position = position,
                        duration = duration,
                        error = playerError,
                        onOpen = { showFullPlayer = true },
                        onPrev = { queue.previous() },
                        onPlayPause = { togglePlay(t) },
                        onNext = { queue.next() }
                    )
                    Spacer(Modifier.height(4.dp))
                }
                NavigationBar(containerColor = Color.Transparent) {
                    tabs.forEachIndexed { i, tab ->
                        NavigationBarItem(
                            selected = selectedTab == i,
                            onClick = {
                                // Double-tap search icon: jump in with keyboard open
                                if (i == 4) {
                                    val now = System.currentTimeMillis()
                                    if (now - lastSearchTap < 350) searchFocusTick++
                                    lastSearchTap = now
                                }
                                selectedTab = i
                            },
                            icon = { Icon(tab.icon, contentDescription = tab.label) },
                            label = { Text(tab.label, style = MaterialTheme.typography.labelSmall) }
                        )
                    }
                }
            }
        }
    ) { pad ->
        // hazeSource: the scrolling content that glass bars blur
        Box(Modifier.padding(pad).hazeSource(state = hazeState)) {
            when (selectedTab) {
                0 -> ListenNowScreen(
                    tracks = homeTracks, recent = recent, fresh = newTracks, live = live,
                    loading = homeLoading, loadError = homeError,
                    onRetryLoad = { homeTick++ },
                    onPlay = ::play,
                    onPlayList = ::playList,
                    onMood = { mood -> query = mood; selectedTab = 4 },
                    onSeeAll = { title, list -> openSeeAll(title, list) },
                    onPlayNext = { queue.playNext(it) },
                    onAddQueue = { queue.addToQueue(it) },
                    likedOf = { isLiked(it) },
                    onToggleLike = { toggleLike(it) },
                    updateTag = update?.tag,
                    onUpdateTap = {
                        val u = update
                        if (u != null) {
                            try {
                                context.startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse(u.url))
                                )
                            } catch (e: Exception) {
                            }
                        }
                    }
                )
                4 -> SearchScreen(
                    query = query, onQuery = { query = it },
                    live = live, onPlay = ::play, focusTick = searchFocusTick,
                    onPlayNext = { queue.playNext(it) },
                    onAddQueue = { queue.addToQueue(it) },
                    likedOf = { isLiked(it) },
                    onToggleLike = { toggleLike(it) }
                )
                1 -> BrowseScreen(
                    newTracks = newTracks, onPlay = ::play,
                    onPlayNext = { queue.playNext(it) },
                    onAddQueue = { queue.addToQueue(it) },
                    likedOf = { isLiked(it) },
                    onToggleLike = { toggleLike(it) },
                    onMood = { mood -> query = mood; selectedTab = 4 },
                    onSeeAll = { title, list -> openSeeAll(title, list) }
                )
                2 -> RadioScreen(onStation = { q ->
                    query = q
                    scope.launch {
                        try {
                            val res = YoutubeRepository.searchSongs(q, 20)
                            if (res.isNotEmpty()) playList(res, 0)
                        } catch (e: Exception) {
                            Log.w(TAG, "station failed", e)
                        }
                    }
                })
                3 -> LibraryScreen(
                    liked = liked, recent = recent,
                    loggedIn = loggedIn, dlCount = dlItems.size,
                    active = selectedTab == 3,
                    onPlay = ::play,
                    onPlayNext = { queue.playNext(it) },
                    onAddQueue = { queue.addToQueue(it) },
                    likedOf = { isLiked(it) },
                    onToggleLike = { toggleLike(it) },
                    onSignIn = { loginFailed = false; showSession = true },
                    onSignOut = {
                        YtSessionManager.logout(context)
                        loggedIn = false
                    },
                    onOpenDownloads = { refreshDownloads(); showDownloads = true },
                    onOpenPlaylist = { openPlaylist(it) },
                    onOpenProfile = { showProfile = true }
                )
            }
        }
    }
        // Animated opening screen above everything
        AnimatedVisibility(
            visible = !introDone,
            enter = fadeIn(animationSpec = tween(300)),
            exit = fadeOut(animationSpec = tween(400))
        ) {
            IntroScreen()
        }
    }

    // Full Now Playing screen with lyrics
    nowPlaying?.let { t ->
        if (showFullPlayer) {
            FullPlayerSheet(
                track = t,
                thumbUrl = t.thumbUrl,
                player = player,
                isPlaying = isPlaying,
                buffering = resolving || playerState == Player.STATE_BUFFERING,
                position = position,
                duration = duration,
                error = playerError,
                lyrics = lyrics,
                shuffleOn = queue.shuffleOn,
                repeatMode = queue.repeatModeState,
                liked = isLiked(t),
                videoMode = videoMode,
                videoLoading = videoLoading,
                qualities = qualityLabels(),
                currentQuality = currentQualityLabel(),
                onPlayPause = { togglePlay(t) },
                onPrev = { queue.previous() },
                onNext = { queue.next() },
                onShuffle = { queue.toggleShuffle() },
                onRepeat = { queue.cycleRepeat() },
                onVideoToggle = { on ->
                    if (on) {
                        enterVideo()
                    } else {
                        exitVideo(true)
                    }
                },
                onQuality = { pickQuality(it) },
                onLike = { toggleLike(t) },
                onQueue = { showQueue = true },
                onSeek = { player.seekTo(it) },
                onDismiss = {
                    if (videoMode) {
                        exitVideo(true)
                    }
                    showFullPlayer = false
                }
            )
        }
    }

    // Up-next queue
    if (showQueue) {
        QueueSheet(
            queue = queue,
            onPlayAt = { queue.playAt(it) },
            onRemove = { queue.removeAt(it) },
            onDismiss = { showQueue = false }
        )
    }

    // Full-screen video retired: video now embeds in the player sheet.

    // Full-list browser for every "See All"
    if (showSeeAll) {
        SeeAllSheet(
            title = seeAllTitle, tracks = seeAllTracks,
            likedOf = { isLiked(it) },
            onPlay = { play(it) },
            onToggleLike = { toggleLike(it) },
            onAddQueue = { queue.addToQueue(it) },
            onPlayNext = { queue.playNext(it) },
            onDismiss = { showSeeAll = false }
        )
    }

    // YouTube login session
    if (showSession) {
        SessionSheet(
            loggedIn = loggedIn,
            loginFailed = loginFailed,
            onLoginDone = {
                scope.launch(Dispatchers.IO) {
                    val ok = try {
                        YtSessionManager.isLoggedIn(context)
                    } catch (e: Exception) {
                        false
                    }
                    loggedIn = ok
                    if (ok) {
                        loginFailed = false
                        showSession = false
                    } else {
                        loginFailed = true
                    }
                }
            },
            onLogout = {
                YtSessionManager.logout(context)
                loggedIn = false
                showSession = false
            },
            onDismiss = {
                loggedIn = YtSessionManager.isLoggedIn(context)
                showSession = false
            }
        )
    }

    // Profile + settings.
    if (showProfile) {
        ProfileSheet(
            loggedIn = loggedIn,
            themeMode = themeMode,
            dlLoc = dlLoc,
            dlCount = dlItems.size,
            onTheme = onThemeMode,
            onLoc = {
                dlLoc = it
                scope.launch(Dispatchers.IO) {
                    try {
                        DownloadStore.setLocation(context, it)
                    } catch (e: Exception) {
                    }
                }
            },
            onSignIn = {
                showProfile = false
                loginFailed = false
                showSession = true
            },
            onSignOut = {
                YtSessionManager.logout(context)
                loggedIn = false
            },
            onOpenDownloads = {
                showProfile = false
                refreshDownloads()
                showDownloads = true
            },
            onClearCache = { clearSongCache() },
            onDismiss = { showProfile = false }
        )
    }

    // Offline downloads browser
    if (showDownloads) {
        DownloadsSheet(
            items = dlItems,
            onPlayFile = { t, f ->
                showDownloads = false
                playFile(t, f)
            },
            onDelete = { t ->
                try {
                    DownloadStore.delete(context, t.id)
                } catch (e: Exception) {
                }
                refreshDownloads()
            },
            onDismiss = { showDownloads = false }
        )
    }

    // Spotify-style playlist screen
    showPlaylist?.let { pl ->
        PlaylistSheet(
            playlist = pl,
            isCurrentId = { queue.current?.id == it.id },
            likedOf = { isLiked(it) },
            onPlayList = { list, idx, sh -> playList(list, idx, sh) },
            onPlayNext = { queue.playNext(it) },
            onAddQueue = { queue.addToQueue(it) },
            onToggleLike = { toggleLike(it) },
            onRemove = { t ->
                try {
                    PlaylistStore.remove(context, pl.id, t.id)
                } catch (e: Exception) {
                }
                openPlaylist(pl.id)
            },
            onAddSuggested = { t ->
                try {
                    PlaylistStore.add(context, pl.id, t)
                } catch (e: Exception) {
                }
                openPlaylist(pl.id)
            },
            onDeletePlaylist = {
                try {
                    PlaylistStore.delete(context, pl.id)
                } catch (e: Exception) {
                }
                showPlaylist = null
            },
            onDismiss = { showPlaylist = null }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalHazeMaterialsApi::class)
@Composable
private fun FullPlayerSheet(
    track: YtTrack,
    thumbUrl: String,
    player: Player,
    isPlaying: Boolean,
    buffering: Boolean,
    position: Long,
    duration: Long,
    error: String?,
    lyrics: LyricsState,
    shuffleOn: Boolean,
    repeatMode: Int,
    liked: Boolean,
    videoMode: Boolean,
    videoLoading: Boolean,
    qualities: List<String>,
    currentQuality: String,
    onPlayPause: () -> Unit,
    onPrev: () -> Unit,
    onNext: () -> Unit,
    onShuffle: () -> Unit,
    onRepeat: () -> Unit,
    onVideoToggle: (Boolean) -> Unit,
    onQuality: (String) -> Unit,
    onLike: () -> Unit,
    onQueue: () -> Unit,
    onSeek: (Long) -> Unit,
    onDismiss: () -> Unit
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Color(0xFF121212),
        dragHandle = {
            Box(
                Modifier.padding(vertical = 8.dp).size(36.dp, 4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(Color.White.copy(alpha = 0.4f))
            )
        }
    ) {
        val dlscope = rememberCoroutineScope()
        val dlctx = LocalContext.current
        var domColor by remember(track.id) { mutableStateOf(Color(0xFF3A0A12)) }
        val domAnimated by animateColorAsState(
            targetValue = domColor, animationSpec = tween(800), label = "dom")
        LaunchedEffect(track.thumbUrl) {
            domColor = dominantColor(dlctx, track.thumbUrl)
        }
        AppleMusicTheme(darkTheme = true) {
        Box(Modifier.fillMaxWidth()) {
            // Blurred artwork base merged into the page (RenderEffect on S+).
            if (thumbUrl.isNotBlank()) {
                AsyncImage(
                    model = thumbUrl,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize().blur(70.dp)
                )
            }
            // Dominant-color lava wash over the blur.
            LavaBackground(base = domAnimated, modifier = Modifier.fillMaxSize())
            Surface(
                color = Color.Transparent,
                contentColor = Color.White,
                modifier = Modifier.fillMaxWidth()
            ) {
            LazyColumn(
                state = rememberLazyListState(),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
            item {
                // Session-driven embed: the music transport owns this picture.
                if (videoMode && track.watchUrl.isNotBlank()) {
                    InlineVideo(
                        player = player,
                        loading = videoLoading,
                        qualities = qualities,
                        currentQuality = currentQuality,
                        onQuality = onQuality,
                        modifier = Modifier.fillMaxWidth()
                            .aspectRatio(16f / 9f)
                            .clip(RoundedCornerShape(16.dp))
                    )
                } else if (thumbUrl.isNotBlank()) {
                    AsyncImage(
                        model = thumbUrl,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.size(280.dp).clip(RoundedCornerShape(16.dp))
                    )
                } else {
                    TrackArt("", track.id.hashCode(), 280.dp, 16.dp)
                }
                Spacer(Modifier.height(16.dp))
                // Live lyric ticker: one line at a time above the song name.
                if (lyrics is LyricsState.Synced) {
                    val lines = (lyrics as LyricsState.Synced).lines
                    val li = lines.indexOfLast { it.ms <= position }.coerceAtLeast(0)
                    Text(
                        lines.getOrNull(li)?.text ?: "",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(bottom = 4.dp)
                    )
                }
                Text(track.title, style = MaterialTheme.typography.titleLarge,
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(track.artist, style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(8.dp))
                SleekBar(positionMs = position, durationMs = duration, onSeek = onSeek)
                if (error != null) {
                    Text(error, style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error)
                }
                // Transport: shuffle + prev + play + next + repeat — all live
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    IconButton(onClick = onShuffle, modifier = Modifier.size(48.dp)) {
                        Icon(Icons.Filled.Shuffle, contentDescription = "Shuffle",
                            tint = if (shuffleOn) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(26.dp))
                    }
                    IconButton(onClick = onPrev, modifier = Modifier.size(52.dp)) {
                        Icon(Icons.Filled.SkipPrevious, contentDescription = "Previous",
                            modifier = Modifier.size(38.dp))
                    }
                    FilledIconButton(onClick = onPlayPause, modifier = Modifier.size(72.dp)) {
                        if (buffering) CircularProgressIndicator(
                            modifier = Modifier.size(28.dp), strokeWidth = 3.dp,
                            color = Color.White)
                        else Icon(
                            if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = if (isPlaying) "Pause" else "Play",
                            modifier = Modifier.size(40.dp))
                    }
                    IconButton(onClick = onNext, modifier = Modifier.size(52.dp)) {
                        Icon(Icons.Filled.SkipNext, contentDescription = "Next",
                            modifier = Modifier.size(38.dp))
                    }
                    IconButton(onClick = onRepeat, modifier = Modifier.size(48.dp)) {
                        Icon(
                            if (repeatMode == Player.REPEAT_MODE_ONE) Icons.Filled.RepeatOne
                            else Icons.Filled.Repeat,
                            contentDescription = "Repeat",
                            tint = if (repeatMode != Player.REPEAT_MODE_OFF)
                                MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(26.dp))
                    }
                }
                // Actions: video toggle + like + queue
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    TextButton(onClick = { onVideoToggle(!videoMode) }) {
                        Icon(
                            if (videoMode) Icons.Filled.MusicNote else Icons.Filled.OndemandVideo,
                            contentDescription = null,
                            tint = if (videoMode) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(if (videoMode) "Audio" else "Video")
                    }
                    IconButton(onClick = onLike) {
                        Icon(
                            if (liked) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                            contentDescription = "Like",
                            tint = if (liked) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    IconButton(onClick = { dlscope.enqueueDownload(dlctx, track) }) {
                        Icon(Icons.Filled.Download, contentDescription = "Download",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    TextButton(onClick = onQueue) {
                        Icon(Icons.Filled.QueueMusic, contentDescription = null,
                            modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Queue")
                    }
                }
                Divider(Modifier.padding(vertical = 8.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically) {
                    Text("Lyrics", style = MaterialTheme.typography.titleMedium)
                    Text("karaoke • via lrclib", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.height(4.dp))
            }
            // Karaoke visualizer (own scroller inside)
            item {
                LyricsView(
                    state = lyrics, positionMs = position, isPlaying = isPlaying,
                    modifier = Modifier.fillMaxWidth().height(420.dp)
                )
            }
            // Shazam-like details card.
            item {
                DetailsCard(track = track)
                Spacer(Modifier.height(32.dp))
            }
            } // LazyColumn
            } // content Surface
        } // bg Box
        } // dark theme
    }
}

/** 2x2 thumbnail mosaic for playlist covers, gradient fallback. */
@Composable
private fun MosaicArt(tracks: List<YtTrack>, size: Dp, corner: Dp = 12.dp) {
    if (tracks.isEmpty()) {
        Box(
            Modifier.size(size).clip(RoundedCornerShape(corner))
                .background(
                    Brush.linearGradient(
                        listOf(Color(0xFFFA243C), Color(0xFF7D0018))
                    )
                ),
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Filled.MusicNote, contentDescription = null,
                tint = Color.White.copy(alpha = 0.9f), modifier = Modifier.size(size * 0.4f))
        }
        return
    }
    Column(
        Modifier.size(size).clip(RoundedCornerShape(corner)).background(Color(0xFFE5E5EA))
    ) {
        for (r in 0 until 2) {
            Row(Modifier.weight(1f)) {
                for (c in 0 until 2) {
                    val t = tracks.getOrNull(r * 2 + c)
                    if (t != null && t.thumbUrl.isNotBlank()) {
                        AsyncImage(
                            model = t.thumbUrl, contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.weight(1f).fillMaxHeight()
                        )
                    } else {
                        val grad = ArtGradients[(r * 2 + c) % ArtGradients.size]
                        Box(
                            Modifier.weight(1f).fillMaxHeight()
                                .background(Brush.linearGradient(grad))
                        ) { }
                    }
                }
            }
        }
    }
}

/** Spotify-style playlist screen: header art, Play/Shuffle, songs, suggestions. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlaylistSheet(
    playlist: Playlist,
    isCurrentId: (YtTrack) -> Boolean,
    likedOf: (YtTrack) -> Boolean,
    onPlayList: (List<YtTrack>, Int, Boolean) -> Unit,
    onPlayNext: (YtTrack) -> Unit,
    onAddQueue: (YtTrack) -> Unit,
    onToggleLike: (YtTrack) -> Unit,
    onRemove: (YtTrack) -> Unit,
    onAddSuggested: (YtTrack) -> Unit,
    onDeletePlaylist: () -> Unit,
    onDismiss: () -> Unit
) {
    var sugg by remember(playlist.id) { mutableStateOf<List<YtTrack>>(emptyList()) }
    var suggLoading by remember(playlist.id) { mutableStateOf(false) }
    LaunchedEffect(playlist.id, playlist.tracks.size) {
        suggLoading = true
        try {
            val artists = playlist.tracks.take(8).map { it.artist }.distinct().take(2)
            val q = ((if (artists.isEmpty()) listOf("top") else artists) + "songs")
                .joinToString(" ")
            val res = YoutubeRepository.searchSongs(q, 12)
            sugg = res.filter { r -> playlist.tracks.none { it.id == r.id } }.take(5)
        } catch (e: Exception) {
            Log.w(TAG, "suggestions failed", e)
        } finally {
            suggLoading = false
        }
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ) {
        LazyColumn(Modifier.fillMaxWidth()) {
            item {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    MosaicArt(playlist.tracks, 96.dp)
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text("Playlist", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(playlist.name, style = MaterialTheme.typography.titleLarge,
                            maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text("${playlist.tracks.size} songs",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick = onDeletePlaylist) {
                        Icon(Icons.Filled.DeleteOutline, contentDescription = "Delete playlist")
                    }
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Button(
                        onClick = { onPlayList(playlist.tracks, 0, false) },
                        enabled = playlist.tracks.isNotEmpty(),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Filled.PlayArrow, contentDescription = null,
                            modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("Play")
                    }
                    OutlinedButton(
                        onClick = { onPlayList(playlist.tracks, 0, true) },
                        enabled = playlist.tracks.isNotEmpty(),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Filled.Shuffle, contentDescription = null,
                            modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("Shuffle")
                    }
                }
            }
            items(playlist.tracks, key = { it.id }) { t ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) {
                        TrackRow(
                            track = t, isCurrent = isCurrentId(t), liked = likedOf(t),
                            onPlay = { onPlayList(playlist.tracks, playlist.tracks.indexOfFirst { it.id == t.id }.coerceAtLeast(0), false) },
                            onPlayNext = { onPlayNext(t) },
                            onAddQueue = { onAddQueue(t) },
                            onToggleLike = { onToggleLike(t) }
                        )
                    }
                    IconButton(onClick = { onRemove(t) }) {
                        Icon(Icons.Filled.Close, contentDescription = "Remove")
                    }
                }
            }
            item {
                SectionHeader("Suggested")
            }
            if (suggLoading) {
                item {
                    Box(Modifier.fillMaxWidth().padding(24.dp),
                        contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(modifier = Modifier.size(28.dp))
                    }
                }
            } else if (sugg.isEmpty()) {
                item {
                    Text("Play more songs to get suggestions.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
                }
            } else {
                items(sugg, key = { it.id }) { t ->
                    ListItem(
                        headlineContent = { Text(t.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        supportingContent = { Text(t.artist, maxLines = 1) },
                        leadingContent = { TrackArt(t.thumbUrl, t.id.hashCode(), 52.dp, 8.dp) },
                        trailingContent = {
                            FilledTonalIconButton(onClick = { onAddSuggested(t) }) {
                                Icon(Icons.Filled.Add, contentDescription = "Add")
                            }
                        },
                        modifier = Modifier.clickable {
                            onPlayList(sugg, sugg.indexOfFirst { it.id == t.id }.coerceAtLeast(0), false)
                        }
                    )
                }
            }
            item { Spacer(Modifier.height(32.dp)) }
        }
    }
}

/** Picker: add a song into one of your playlists (or make a new one). */
/** Bottom sheet for naming a new playlist (keyboard-safe). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NewPlaylistSheet(
    onCreate: (String) -> Unit,
    onDismiss: () -> Unit
) {
    var name by remember { mutableStateOf("") }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ) {
        Text("New playlist", style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedTextField(
                value = name, onValueChange = { name = it },
                placeholder = { Text("Playlist name") },
                singleLine = true,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.weight(1f)
            )
            Spacer(Modifier.width(8.dp))
            Button(
                onClick = { if (name.isNotBlank()) onCreate(name.trim()) },
                enabled = name.isNotBlank()
            ) { Text("Create") }
        }
        Spacer(Modifier.height(32.dp))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlaylistPickerSheet(
    track: YtTrack,
    playlists: List<Playlist>,
    onPick: (String) -> Unit,
    onNew: (String) -> Unit,
    onDismiss: () -> Unit
) {
    var name by remember { mutableStateOf("") }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ) {
        Text("Add to playlist", style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
        LazyColumn(Modifier.fillMaxWidth()) {
            items(playlists, key = { it.id }) { p ->
                ListItem(
                    headlineContent = { Text(p.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    supportingContent = { Text("${p.tracks.size} songs") },
                    leadingContent = { MosaicArt(p.tracks, 52.dp, 8.dp) },
                    modifier = Modifier.clickable { onPick(p.id) }
                )
            }
            item {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    OutlinedTextField(
                        value = name, onValueChange = { name = it },
                        placeholder = { Text("New playlist name") },
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.weight(1f)
                    )
                    Spacer(Modifier.width(8.dp))
                    FilledIconButton(
                        onClick = { if (name.isNotBlank()) onNew(name) },
                        enabled = name.isNotBlank()
                    ) {
                        Icon(Icons.Filled.Add, contentDescription = "Create")
                    }
                }
                Spacer(Modifier.height(32.dp))
            }
        }
    }
}

/** Animated opening screen: Cresca mark springs in, wordmark fades up. */
@Composable
private fun IntroScreen() {
    var started by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { started = true }
    val scale by animateFloatAsState(
        targetValue = if (started) 1f else 0.5f,
        animationSpec = spring(dampingRatio = 0.55f, stiffness = 260f),
        label = "introScale"
    )
    val alpha by animateFloatAsState(
        targetValue = if (started) 1f else 0f,
        animationSpec = tween(450),
        label = "introAlpha"
    )
    val textAlpha by animateFloatAsState(
        targetValue = if (started) 1f else 0f,
        animationSpec = tween(600, delayMillis = 250),
        label = "introText"
    )
    Surface(
        color = Color.White,
        modifier = Modifier.fillMaxSize()
    ) {
        Column(
            Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Image(
                painter = painterResource(id = R.drawable.ic_splash),
                contentDescription = "Cresca",
                modifier = Modifier.size(128.dp)
                    .graphicsLayer(scaleX = scale, scaleY = scale, alpha = alpha)
            )
            Spacer(Modifier.height(20.dp))
            Text(
                "Cresca Music",
                style = MaterialTheme.typography.displaySmall,
                modifier = Modifier.graphicsLayer(alpha = textAlpha)
            )
            Spacer(Modifier.height(6.dp))
            Text(
                "Your music, flowing",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.graphicsLayer(alpha = textAlpha)
            )
        }
    }
}

/** Fancy floating music bar: glow card, live equalizer, round red play. */
@Composable
private fun FancyBar(
    track: YtTrack,
    isPlaying: Boolean,
    buffering: Boolean,
    position: Long,
    duration: Long,
    error: String?,
    onOpen: () -> Unit,
    onPrev: () -> Unit,
    onPlayPause: () -> Unit,
    onNext: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        tonalElevation = 6.dp,
        shadowElevation = 10.dp,
        modifier = Modifier.fillMaxWidth()
            .padding(horizontal = 10.dp)
            .clickable { onOpen() }
    ) {
        Column(Modifier.padding(start = 10.dp, end = 10.dp, top = 10.dp, bottom = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TrackArt(track.thumbUrl, track.id.hashCode(), 54.dp, 16.dp)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(track.title,
                            style = MaterialTheme.typography.bodyMedium.copy(
                                fontWeight = FontWeight.SemiBold),
                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false))
                        if (isPlaying) {
                            Spacer(Modifier.width(6.dp))
                            EqBars()
                        }
                    }
                    Text(
                        when {
                            buffering -> "Loading…"
                            error != null -> error
                            else -> track.artist
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = if (error != null) MaterialTheme.colorScheme.error
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis
                    )
                }
                IconButton(onClick = onPrev, modifier = Modifier.size(40.dp)) {
                    Icon(Icons.Filled.SkipPrevious, contentDescription = "Previous")
                }
                if (buffering) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(24.dp).padding(4.dp), strokeWidth = 2.dp)
                } else {
                    Surface(
                        shape = androidx.compose.foundation.shape.CircleShape,
                        color = Color(0xFFFA243C),
                        modifier = Modifier.size(44.dp).clickable { onPlayPause() }
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(
                                if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                                contentDescription = if (isPlaying) "Pause" else "Play",
                                tint = Color.White,
                                modifier = Modifier.size(26.dp)
                            )
                        }
                    }
                }
                IconButton(onClick = onNext, modifier = Modifier.size(40.dp)) {
                    Icon(Icons.Filled.SkipNext, contentDescription = "Next")
                }
            }
            Spacer(Modifier.height(8.dp))
            val frac = if (duration > 0) {
                (position.toFloat() / duration.toFloat()).coerceIn(0f, 1f)
            } else {
                0f
            }
            Box(
                Modifier.fillMaxWidth().height(3.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f))
            ) {
                Box(
                    Modifier.fillMaxHeight().fillMaxWidth(frac)
                        .background(MaterialTheme.colorScheme.primary)
                )
            }
        }
    }
}

/** Tiny animated equalizer shown while music plays. */
@Composable
private fun EqBars() {
    val inf = rememberInfiniteTransition(label = "eq")
    Row(
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.Bottom,
        modifier = Modifier.height(14.dp)
    ) {
        for (i in 0 until 4) {
            val h by inf.animateFloat(
                initialValue = 0.25f,
                targetValue = 1f,
                animationSpec = infiniteRepeatable(
                    animation = tween(durationMillis = 380 + i * 90, easing = { it }),
                    repeatMode = RepeatMode.Reverse
                ),
                label = "eq$i"
            )
            Canvas(Modifier.width(3.dp).fillMaxHeight(h)) {
                drawRoundRect(
                    color = Color(0xFFFA243C),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.5.dp.toPx())
                )
            }
        }
    }
}

/** Sleek seek bar: slim glowing track, tap or drag. */
@Composable
private fun SleekBar(
    positionMs: Long,
    durationMs: Long,
    onSeek: (Long) -> Unit
) {
    var dragging by remember { mutableStateOf(false) }
    var dragFrac by remember { mutableFloatStateOf(0f) }
    val frac = if (dragging) {
        dragFrac
    } else if (durationMs > 0) {
        (positionMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
    } else {
        0f
    }
    Box(
        Modifier.fillMaxWidth().height(26.dp)
            .pointerInput(durationMs) {
                detectTapGestures { offset ->
                    if (durationMs > 0 && size.width > 0) {
                        onSeek(((offset.x / size.width).coerceIn(0f, 1f) * durationMs).toLong())
                    }
                }
            }
            .pointerInput(durationMs) {
                detectHorizontalDragGestures(
                    onDragStart = { offset ->
                        if (durationMs > 0 && size.width > 0) {
                            dragging = true
                            dragFrac = (offset.x / size.width).coerceIn(0f, 1f)
                        }
                    },
                    onDragEnd = {
                        dragging = false
                        if (durationMs > 0) {
                            onSeek((dragFrac * durationMs).toLong())
                        }
                    },
                    onDragCancel = { dragging = false },
                    onHorizontalDrag = { change, _ ->
                        if (durationMs > 0 && size.width > 0) {
                            dragFrac = (change.position.x / size.width).coerceIn(0f, 1f)
                            change.consume()
                        }
                    }
                )
            }
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val cy = size.height / 2f
            val trackH = 4.dp.toPx()
            drawRoundRect(
                color = Color.White.copy(alpha = 0.22f),
                topLeft = androidx.compose.ui.geometry.Offset(0f, cy - trackH / 2f),
                size = androidx.compose.ui.geometry.Size(size.width, trackH),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(trackH / 2f)
            )
            val fw = size.width * frac
            if (fw > 0f) {
                val brush = Brush.horizontalGradient(
                    listOf(Color(0xFFFF2D55), Color(0xFFFA243C))
                )
                drawRoundRect(
                    brush = brush,
                    topLeft = androidx.compose.ui.geometry.Offset(0f, cy - trackH / 2f),
                    size = androidx.compose.ui.geometry.Size(fw, trackH),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(trackH / 2f)
                )
                // Glowing knob.
                drawCircle(
                    color = Color(0xFFFA243C).copy(alpha = 0.30f),
                    radius = 11.dp.toPx(),
                    center = androidx.compose.ui.geometry.Offset(fw, cy)
                )
                drawCircle(
                    color = Color.White,
                    radius = 6.dp.toPx(),
                    center = androidx.compose.ui.geometry.Offset(fw, cy)
                )
            }
        }
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(fmtMs(if (dragging) (dragFrac * durationMs).toLong() else positionMs),
            style = MaterialTheme.typography.bodySmall,
            color = Color.White.copy(alpha = 0.7f))
        Text(fmtMs(durationMs),
            style = MaterialTheme.typography.bodySmall,
            color = Color.White.copy(alpha = 0.7f))
    }
}

private fun fmtCompact(n: Long): String {
    if (n < 0) return "—"
    if (n < 1000) return n.toString()
    if (n < 1_000_000) {
        return String.format("%.1f", n / 1000f).trimEnd('0').trimEnd('.') + "K"
    }
    return String.format("%.1f", n / 1_000_000f).trimEnd('0').trimEnd('.') + "M"
}

/** Average thumbnail color, darkened for backgrounds. */
private suspend fun dominantColor(ctx: android.content.Context, url: String): Color =
    withContext(Dispatchers.IO) {
        try {
            if (url.isBlank()) {
                return@withContext Color(0xFF3A0A12)
            }
            val req = coil.request.ImageRequest.Builder(ctx)
                .data(url)
                .allowHardware(false)
                .build()
            val res = coil.Coil.imageLoader(ctx).execute(req)
            val bmp = (res.drawable as? android.graphics.drawable.BitmapDrawable)?.bitmap
                ?: return@withContext Color(0xFF3A0A12)
            val small = android.graphics.Bitmap.createScaledBitmap(bmp, 8, 8, true)
            var r = 0L
            var g = 0L
            var b = 0L
            for (x in 0 until 8) {
                for (y in 0 until 8) {
                    val px = small.getPixel(x, y)
                    r += android.graphics.Color.red(px)
                    g += android.graphics.Color.green(px)
                    b += android.graphics.Color.blue(px)
                }
            }
            small.recycle()
            var rf = r / 64f / 255f
            var gf = g / 64f / 255f
            var bf = b / 64f / 255f
            val mx = maxOf(rf, gf, bf)
            val mn = minOf(rf, gf, bf)
            if (mx > 0f) {
                val boost = 1f + 0.4f * (1f - (mx - mn) / mx)
                rf = (rf * boost).coerceAtMost(1f)
                gf = (gf * boost).coerceAtMost(1f)
                bf = (bf * boost).coerceAtMost(1f)
            }
            Color(rf * 0.5f, gf * 0.5f, bf * 0.5f)
        } catch (e: Exception) {
            Color(0xFF3A0A12)
        }
    }

/** Slow drifting blobs over the base color: lava-lamp wash. */
@Composable
private fun LavaBackground(base: Color, modifier: Modifier = Modifier) {
    val inf = rememberInfiniteTransition(label = "lava")
    val x1 by inf.animateFloat(0f, 1f,
        infiniteRepeatable(tween(11000), RepeatMode.Reverse), label = "lx1")
    val x2 by inf.animateFloat(0f, 1f,
        infiniteRepeatable(tween(14000), RepeatMode.Reverse), label = "lx2")
    val x3 by inf.animateFloat(0f, 1f,
        infiniteRepeatable(tween(9000), RepeatMode.Reverse), label = "lx3")
    Box(
        modifier.background(
            Brush.verticalGradient(
                listOf(
                    base.copy(alpha = 0.88f),
                    Color.Black.copy(alpha = 0.72f)
                )
            )
        )
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val r = size.minDimension * 0.30f
            drawCircle(Color.White.copy(alpha = 0.08f), r,
                androidx.compose.ui.geometry.Offset(size.width * x1, size.height * 0.22f))
            drawCircle(base.copy(alpha = 0.50f), r * 0.75f,
                androidx.compose.ui.geometry.Offset(size.width * (1f - x2), size.height * 0.55f))
            drawCircle(Color.White.copy(alpha = 0.05f), r,
                androidx.compose.ui.geometry.Offset(size.width * x3, size.height * 0.85f))
        }
    }
}

/** Shazam-like credits card. */
@Composable
private fun DetailsCard(track: YtTrack) {
    var details by remember(track.id) {
        mutableStateOf<YoutubeRepository.VideoDetails?>(null)
    }
    LaunchedEffect(track.id) {
        if (track.watchUrl.isNotBlank()) {
            details = try {
                YoutubeRepository.videoDetails(track.watchUrl)
            } catch (e: Exception) {
                null
            }
        }
    }
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = Color.White.copy(alpha = 0.08f),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(Modifier.padding(16.dp)) {
            Text("About this song",
                style = MaterialTheme.typography.titleSmall,
                color = Color.White.copy(alpha = 0.6f))
            Spacer(Modifier.height(8.dp))
            DetailRow("Artist", track.artist)
            details?.let { d ->
                if (d.views >= 0) {
                    DetailRow("Plays", fmtCompact(d.views))
                }
                if (d.likes > 0) {
                    DetailRow("Likes", fmtCompact(d.likes))
                }
                if (d.uploadDate.isNotBlank()) {
                    DetailRow("Released", d.uploadDate)
                }
                if (d.durationSec > 0) {
                    DetailRow("Duration", fmtMs(d.durationSec * 1000))
                }
                if (d.description.isNotBlank()) {
                    Spacer(Modifier.height(8.dp))
                    Text(d.description.take(220),
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.6f),
                        maxLines = 4, overflow = TextOverflow.Ellipsis)
                }
            }
            DetailRow("Source", "YouTube")
        }
    }
}

@Composable
private fun DetailRow(k: String, v: String) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 3.dp),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(k, style = MaterialTheme.typography.bodySmall,
            color = Color.White.copy(alpha = 0.55f))
        Spacer(Modifier.width(12.dp))
        Text(v, style = MaterialTheme.typography.bodySmall,
            color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/** Profile + settings: account, appearance, downloads, storage, about. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProfileSheet(
    loggedIn: Boolean,
    themeMode: String,
    dlLoc: String,
    dlCount: Int,
    onTheme: (String) -> Unit,
    onLoc: (String) -> Unit,
    onSignIn: () -> Unit,
    onSignOut: () -> Unit,
    onOpenDownloads: () -> Unit,
    onClearCache: () -> Unit,
    onDismiss: () -> Unit
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ) {
        LazyColumn(Modifier.fillMaxWidth()) {
            item {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Surface(
                        shape = androidx.compose.foundation.shape.CircleShape,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(56.dp)
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(
                                Icons.Filled.Person,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(32.dp)
                            )
                        }
                    }
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text("My Profile", style = MaterialTheme.typography.titleLarge)
                        Text(
                            if (loggedIn) "YouTube connected" else "Guest — not signed in",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
            item {
                SectionHeader("Account")
            }
            item {
                ListItem(
                    headlineContent = {
                        Text(if (loggedIn) "Sign out of YouTube" else "Sign in with YouTube")
                    },
                    supportingContent = {
                        Text(if (loggedIn) "Session lives only on this device"
                        else "Unlock your real library")
                    },
                    leadingContent = {
                        Icon(Icons.Filled.AccountCircle, contentDescription = null)
                    },
                    modifier = Modifier.clickable {
                        if (loggedIn) {
                            onSignOut()
                        } else {
                            onSignIn()
                        }
                    }
                )
            }
            item {
                SectionHeader("Appearance")
            }
            item {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    listOf("system" to "System", "light" to "Light", "dark" to "Dark").forEach { (v, label) ->
                        FilterChip(
                            selected = themeMode == v,
                            onClick = { onTheme(v) },
                            label = { Text(label) },
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            }
            item {
                SectionHeader("Downloads")
            }
            item {
                ListItem(
                    headlineContent = { Text("Saved songs ($dlCount)") },
                    supportingContent = { Text("Open offline library") },
                    leadingContent = {
                        Icon(Icons.Filled.DownloadForOffline, contentDescription = null)
                    },
                    modifier = Modifier.clickable { onOpenDownloads() }
                )
            }
            item {
                Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp)) {
                    Text("Save new downloads to",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(
                            selected = dlLoc != "device",
                            onClick = { onLoc("app") },
                            label = { Text("In-app") },
                            modifier = Modifier.weight(1f)
                        )
                        FilterChip(
                            selected = dlLoc == "device",
                            onClick = { onLoc("device") },
                            label = { Text("Device Music folder") },
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            }
            item {
                SectionHeader("Storage")
            }
            item {
                ListItem(
                    headlineContent = { Text("Clear song cache") },
                    supportingContent = { Text("Frees space; songs reload from YouTube") },
                    leadingContent = {
                        Icon(Icons.Filled.CleaningServices, contentDescription = null)
                    },
                    modifier = Modifier.clickable { onClearCache() }
                )
            }
            item {
                SectionHeader("About")
            }
            item {
                ListItem(
                    headlineContent = { Text("Cresca Music 0.5.0") },
                    supportingContent = {
                        Text("Live YouTube audio • karaoke lyrics • offline mode")
                    },
                    leadingContent = {
                        Icon(Icons.Filled.Info, contentDescription = null)
                    }
                )
                Spacer(Modifier.height(32.dp))
            }
        }
    }
}

@Composable
private fun LiveBadge(live: Boolean) {
    Text(
        if (live) "● LIVE — real YouTube results" else "○ connecting…",
        style = MaterialTheme.typography.bodySmall,
        color = if (live) Color(0xFF30D158) else MaterialTheme.colorScheme.onSurfaceVariant
    )
}

@Composable
private fun ListenNowScreen(
    tracks: List<YtTrack>, recent: List<YtTrack>, fresh: List<YtTrack>, live: Boolean,
    loading: Boolean, loadError: String?, onRetryLoad: () -> Unit,
    onPlay: (YtTrack) -> Unit,
    onPlayList: (List<YtTrack>, Int, Boolean) -> Unit,
    onMood: (String) -> Unit, onSeeAll: (String, List<YtTrack>) -> Unit,
    onPlayNext: (YtTrack) -> Unit, onAddQueue: (YtTrack) -> Unit,
    likedOf: (YtTrack) -> Boolean, onToggleLike: (YtTrack) -> Unit,
    updateTag: String? = null, onUpdateTap: () -> Unit = {}
) {
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 16.dp)
    ) {
        item {
            Text(
                "Listen Now",
                style = MaterialTheme.typography.displaySmall,
                modifier = Modifier.padding(start = 16.dp, top = 8.dp, end = 16.dp)
            )
            Box(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
                LiveBadge(live)
            }
            // Empty states: spinner while loading, retry when offline. No demo.
            if (tracks.isEmpty() && loading) {
                Box(
                    Modifier.fillMaxWidth().padding(vertical = 48.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator()
                        Spacer(Modifier.height(12.dp))
                        Text("Loading songs…",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            if (tracks.isEmpty() && !loading && loadError != null) {
                Column(
                    Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(loadError,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error)
                    Spacer(Modifier.height(12.dp))
                    Button(onClick = onRetryLoad) { Text("Retry") }
                }
            }
            Surface(
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.padding(16.dp).fillMaxWidth()
            ) {
                Box(
                    Modifier
                        .background(
                            Brush.linearGradient(
                                listOf(Color(0xFFFA243C), Color(0xFF7D0018))
                            )
                        )
                        .padding(20.dp)
                ) {
                    Column {
                        Text("FEATURED MIX", style = MaterialTheme.typography.labelSmall,
                            color = Color.White.copy(alpha = 0.8f))
                        Spacer(Modifier.height(4.dp))
                        Text("Your Daily Fix", style = MaterialTheme.typography.titleLarge,
                            color = Color.White)
                        Spacer(Modifier.height(12.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Button(
                                onClick = { onPlayList(tracks, 0, false) },
                                enabled = tracks.isNotEmpty(),
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = Color.White,
                                    contentColor = Color(0xFFFA243C)
                                )
                            ) {
                                Icon(Icons.Filled.PlayArrow, contentDescription = null,
                                    modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(4.dp))
                                Text("Play")
                            }
                            OutlinedButton(
                                onClick = { onPlayList(tracks, 0, true) },
                                enabled = tracks.isNotEmpty(),
                                colors = ButtonDefaults.outlinedButtonColors(
                                    contentColor = Color.White
                                ),
                                border = androidx.compose.foundation.BorderStroke(
                                    1.dp, Color.White.copy(alpha = 0.7f))
                            ) {
                                Icon(Icons.Filled.Shuffle, contentDescription = null,
                                    modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(4.dp))
                                Text("Shuffle")
                            }
                        }
                    }
                }
            }
            SectionHeader("Top Picks For You") { onSeeAll("Top Picks For You", tracks) }
        }
        if (updateTag != null) {
            item {
                Surface(
                    shape = RoundedCornerShape(16.dp),
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp)
                        .clickable { onUpdateTap() }
                ) {
                    Row(
                        Modifier.padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            Icons.Filled.SystemUpdate,
                            contentDescription = null,
                            tint = Color.White
                        )
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text("Update available: $updateTag",
                                style = MaterialTheme.typography.titleMedium,
                                color = Color.White)
                            Text("Tap to download the latest Cresca",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color.White.copy(alpha = 0.85f))
                        }
                    }
                }
            }
        }
        item {
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                itemsIndexed(tracks) { idx, t ->
                    Column(Modifier.width(150.dp).clickable { onPlay(t) }) {
                        TrackArt(t.thumbUrl, t.id.hashCode() + idx, 150.dp, 12.dp)
                        Spacer(Modifier.height(6.dp))
                        Text(t.title, style = MaterialTheme.typography.bodyMedium,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(t.artist, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            SectionHeader("Recently Played") {
                onSeeAll("Recently Played", recent.ifEmpty { tracks })
            }
        }
        val recentShown = recent.ifEmpty { tracks.take(6) }
        items(recentShown, key = { it.id }) { t ->
            TrackRow(
                track = t, isCurrent = false, liked = likedOf(t),
                onPlay = { onPlay(t) },
                onPlayNext = { onPlayNext(t) },
                onAddQueue = { onAddQueue(t) },
                onToggleLike = { onToggleLike(t) }
            )
        }
        if (fresh.isNotEmpty()) {
            item {
                SectionHeader("New Releases") { onSeeAll("New Releases", fresh) }
            }
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    itemsIndexed(fresh.take(10)) { idx, t ->
                        Column(Modifier.width(150.dp).clickable { onPlay(t) }) {
                            TrackArt(t.thumbUrl, t.id.hashCode() + idx + 99, 150.dp, 12.dp)
                            Spacer(Modifier.height(6.dp))
                            Text(t.title, style = MaterialTheme.typography.bodyMedium,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(t.artist, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
        // Pattern break below the songs: mood tiles that deep-search
        item {
            SectionHeader("Moods")
            MoodPatternRow(onMood = onMood)
            Spacer(Modifier.height(8.dp))
        }
    }
}

/** Song row with a working overflow menu. Used everywhere lists appear. */
@Composable
private fun TrackRow(
    track: YtTrack,
    isCurrent: Boolean,
    liked: Boolean,
    onPlay: () -> Unit,
    onPlayNext: () -> Unit,
    onAddQueue: () -> Unit,
    onToggleLike: () -> Unit
) {
    ListItem(
        headlineContent = {
            Text(track.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = if (isCurrent) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurface)
        },
        supportingContent = { Text(track.artist) },
        leadingContent = { TrackArt(track.thumbUrl, track.id.hashCode(), 52.dp, 8.dp) },
        trailingContent = {
            TrackMenu(
                track = track, liked = liked, onPlay = onPlay,
                onPlayNext = onPlayNext, onAddQueue = onAddQueue,
                onToggleLike = onToggleLike
            )
        },
        modifier = Modifier.clickable { onPlay() }
    )
}

@Composable
private fun TrackMenu(
    track: YtTrack,
    liked: Boolean,
    onPlay: () -> Unit,
    onPlayNext: () -> Unit,
    onAddQueue: () -> Unit,
    onToggleLike: () -> Unit
) {
    val context = LocalContext.current
    val dlscope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    var showPicker by remember { mutableStateOf(false) }
    var plists by remember { mutableStateOf<List<Playlist>>(emptyList()) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Filled.MoreVert, contentDescription = "More")
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text("Play") },
                leadingIcon = { Icon(Icons.Filled.PlayArrow, contentDescription = null) },
                onClick = { open = false; onPlay() }
            )
            DropdownMenuItem(
                text = { Text("Play next") },
                leadingIcon = { Icon(Icons.Filled.SkipNext, contentDescription = null) },
                onClick = { open = false; onPlayNext() }
            )
            DropdownMenuItem(
                text = { Text("Add to queue") },
                leadingIcon = { Icon(Icons.Filled.QueueMusic, contentDescription = null) },
                onClick = { open = false; onAddQueue() }
            )
            DropdownMenuItem(
                text = { Text(if (liked) "Unlike" else "Like") },
                leadingIcon = {
                    Icon(if (liked) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                        contentDescription = null)
                },
                onClick = { open = false; onToggleLike() }
            )
            DropdownMenuItem(
                text = { Text("Add to playlist") },
                leadingIcon = { Icon(Icons.Filled.PlaylistAdd, contentDescription = null) },
                onClick = {
                    open = false
                    dlscope.launch(Dispatchers.IO) {
                        val loaded = try {
                            PlaylistStore.list(context)
                        } catch (e: Exception) {
                            emptyList()
                        }
                        plists = loaded
                        showPicker = true
                    }
                }
            )
            DropdownMenuItem(
                text = { Text("Download") },
                leadingIcon = { Icon(Icons.Filled.Download, contentDescription = null) },
                onClick = { open = false; dlscope.enqueueDownload(context, track) }
            )
            DropdownMenuItem(
                text = { Text("Share") },
                leadingIcon = { Icon(Icons.Filled.Share, contentDescription = null) },
                onClick = {
                    open = false
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT,
                            "${track.title} - ${track.artist}\nhttps://music.youtube.com/watch?v=${track.id}")
                    }
                    context.startActivity(Intent.createChooser(send, "Share song"))
                }
            )
            DropdownMenuItem(
                text = { Text("Open in YouTube") },
                leadingIcon = { Icon(Icons.Filled.OpenInNew, contentDescription = null) },
                onClick = {
                    open = false
                    val url = track.watchUrl.ifBlank {
                        "https://music.youtube.com/watch?v=${track.id}"
                    }
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                }
            )
        }
    }
    if (showPicker) {
        PlaylistPickerSheet(
            track = track,
            playlists = plists,
            onPick = { id ->
                dlscope.launch(Dispatchers.IO) {
                    try {
                        PlaylistStore.add(context, id, track)
                        plists = PlaylistStore.list(context)
                    } catch (e: Exception) {
                    }
                    showPicker = false
                }
            },
            onNew = { name ->
                dlscope.launch(Dispatchers.IO) {
                    try {
                        val p = PlaylistStore.create(context, name)
                        PlaylistStore.add(context, p.id, track)
                        plists = PlaylistStore.list(context)
                    } catch (e: Exception) {
                    }
                    showPicker = false
                }
            },
            onDismiss = { showPicker = false }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun QueueSheet(
    queue: PlayerQueue,
    onPlayAt: (Int) -> Unit,
    onRemove: (Int) -> Unit,
    onDismiss: () -> Unit
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Up Next (${queue.items.size})", style = MaterialTheme.typography.titleLarge)
            if (queue.shuffleOn) {
                Text("shuffled", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary)
            }
        }
        LazyColumn(Modifier.fillMaxWidth()) {
            itemsIndexed(queue.items, key = { _, t -> t.id }) { idx, t ->
                ListItem(
                    headlineContent = {
                        Text(t.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            color = if (idx == queue.currentIndex)
                                MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurface)
                    },
                    supportingContent = { Text(t.artist, maxLines = 1) },
                    leadingContent = { TrackArt(t.thumbUrl, t.id.hashCode(), 48.dp, 8.dp) },
                    trailingContent = {
                        IconButton(onClick = { onRemove(idx) }) {
                            Icon(Icons.Filled.Close, contentDescription = "Remove")
                        }
                    },
                    modifier = Modifier.clickable { onPlayAt(idx) }
                )
            }
            item { Spacer(Modifier.height(32.dp)) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SeeAllSheet(
    title: String,
    tracks: List<YtTrack>,
    likedOf: (YtTrack) -> Boolean,
    onPlay: (YtTrack) -> Unit,
    onToggleLike: (YtTrack) -> Unit,
    onAddQueue: (YtTrack) -> Unit,
    onPlayNext: (YtTrack) -> Unit,
    onDismiss: () -> Unit
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ) {
        Text(title, style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
        LazyColumn(Modifier.fillMaxWidth()) {
            items(tracks, key = { it.id }) { t ->
                TrackRow(
                    track = t, isCurrent = false, liked = likedOf(t),
                    onPlay = { onPlay(t) },
                    onPlayNext = { onPlayNext(t) },
                    onAddQueue = { onAddQueue(t) },
                    onToggleLike = { onToggleLike(t) }
                )
            }
            item { Spacer(Modifier.height(32.dp)) }
        }
    }
}

private val stations = listOf(
    Triple("Arijit Radio", "arijit singh",
        listOf(Color(0xFFFA243C), Color(0xFF7D0018))),
    Triple("Lofi Radio", "lofi chill beats",
        listOf(Color(0xFF5E5CE6), Color(0xFF1B1B6B))),
    Triple("Workout Radio", "workout motivation songs",
        listOf(Color(0xFFFF9F0A), Color(0xFFB25000))),
    Triple("Party Radio", "party dance hits",
        listOf(Color(0xFFFF375F), Color(0xFFBF5AF2))),
    Triple("Romantic Radio", "romantic hindi songs",
        listOf(Color(0xFF64D2FF), Color(0xFF0A84FF))),
    Triple("2000s Hits", "2000s hindi hits",
        listOf(Color(0xFF30D158), Color(0xFF0B5C2A)))
)

@Composable
private fun BrowseScreen(
    newTracks: List<YtTrack>,
    onPlay: (YtTrack) -> Unit,
    onPlayNext: (YtTrack) -> Unit,
    onAddQueue: (YtTrack) -> Unit,
    likedOf: (YtTrack) -> Boolean,
    onToggleLike: (YtTrack) -> Unit,
    onMood: (String) -> Unit,
    onSeeAll: (String, List<YtTrack>) -> Unit
) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 16.dp)) {
        item {
            Text("Browse", style = MaterialTheme.typography.displaySmall,
                modifier = Modifier.padding(start = 16.dp, top = 8.dp, end = 16.dp, bottom = 12.dp))
        }
        item {
            // 2-column mood grid (rows of tiles)
            Column(Modifier.padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                (moods + stations.map { Triple(it.first, it.second, it.third) })
                    .chunked(2).forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp),
                            modifier = Modifier.fillMaxWidth()) {
                            row.forEach { (label, q, colors) ->
                                Box(
                                    Modifier.weight(1f).height(92.dp)
                                        .clip(RoundedCornerShape(16.dp))
                                        .background(Brush.linearGradient(colors))
                                        .clickable { onMood(q) }
                                        .padding(12.dp)
                                ) {
                                    Text(label, style = MaterialTheme.typography.titleMedium,
                                        color = Color.White,
                                        modifier = Modifier.align(Alignment.BottomStart))
                                }
                            }
                            if (row.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }
            }
        }
        if (newTracks.isNotEmpty()) {
            item {
                SectionHeader("New Releases") { onSeeAll("New Releases", newTracks) }
            }
            items(newTracks.take(8), key = { it.id }) { t ->
                TrackRow(
                    track = t, isCurrent = false, liked = likedOf(t),
                    onPlay = { onPlay(t) },
                    onPlayNext = { onPlayNext(t) },
                    onAddQueue = { onAddQueue(t) },
                    onToggleLike = { onToggleLike(t) }
                )
            }
        }
    }
}

@Composable
private fun RadioScreen(onStation: (String) -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 16.dp)) {
        item {
            Text("Radio", style = MaterialTheme.typography.displaySmall,
                modifier = Modifier.padding(start = 16.dp, top = 8.dp, end = 16.dp))
            Text("Endless stations built from live YouTube results. Tap to play.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
        }
        items(stations) { (label, q, colors) ->
            Surface(
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
                    .clickable { onStation(q) }
            ) {
                Box(
                    Modifier.background(Brush.linearGradient(colors)).padding(20.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Radio, contentDescription = null,
                            tint = Color.White, modifier = Modifier.size(40.dp))
                        Spacer(Modifier.width(16.dp))
                        Column {
                            Text(label, style = MaterialTheme.typography.titleLarge,
                                color = Color.White)
                            Text("Tap to start", style = MaterialTheme.typography.bodySmall,
                                color = Color.White.copy(alpha = 0.8f))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LibraryScreen(
    liked: List<YtTrack>,
    recent: List<YtTrack>,
    loggedIn: Boolean,
    dlCount: Int,
    active: Boolean,
    onPlay: (YtTrack) -> Unit,
    onPlayNext: (YtTrack) -> Unit,
    onAddQueue: (YtTrack) -> Unit,
    likedOf: (YtTrack) -> Boolean,
    onToggleLike: (YtTrack) -> Unit,
    onSignIn: () -> Unit,
    onSignOut: () -> Unit,
    onOpenDownloads: () -> Unit,
    onOpenPlaylist: (String) -> Unit,
    onOpenProfile: () -> Unit
) {
    val ctx = LocalContext.current
    var lists by remember { mutableStateOf<List<Playlist>>(emptyList()) }
    var showNew by remember { mutableStateOf(false) }
    // Reload every time the tab is visited (menus edit the store directly).
    LaunchedEffect(active) {
        if (active) {
            try {
                lists = withContext(Dispatchers.IO) { PlaylistStore.list(ctx) }
            } catch (e: Exception) {
            }
        }
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 16.dp)) {
        item {
            Text("Your Library", style = MaterialTheme.typography.displaySmall,
                modifier = Modifier.padding(start = 16.dp, top = 8.dp, end = 16.dp))
        }
        item {
            Surface(
                shape = RoundedCornerShape(16.dp),
                tonalElevation = 2.dp,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
                    .clickable { onOpenProfile() }
            ) {
                Row(
                    Modifier.padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Surface(
                        shape = androidx.compose.foundation.shape.CircleShape,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(48.dp)
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(
                                Icons.Filled.Person,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(28.dp)
                            )
                        }
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text("Profile & settings", style = MaterialTheme.typography.titleMedium)
                        Text("Account, appearance, downloads",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Icon(Icons.Filled.ChevronRight, contentDescription = null)
                }
            }
        }
        // YouTube account session
        item {
            Surface(
                shape = RoundedCornerShape(16.dp),
                tonalElevation = 2.dp,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
            ) {
                Row(
                    Modifier.padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Filled.AccountCircle, contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(40.dp)
                    )
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            if (loggedIn) "YouTube connected" else "Connect YouTube",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            if (loggedIn) "Session lives only on this device"
                            else "Sign in for your real library",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    if (loggedIn) {
                        TextButton(onClick = onSignOut) { Text("Sign out") }
                    } else {
                        Button(onClick = onSignIn) { Text("Sign in") }
                    }
                }
            }
        }
        // Offline downloads entry
        item {
            Surface(
                shape = RoundedCornerShape(16.dp),
                tonalElevation = 2.dp,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
                    .clickable { onOpenDownloads() }
            ) {
                Row(
                    Modifier.padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Filled.DownloadForOffline, contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(40.dp)
                    )
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text("Downloads", style = MaterialTheme.typography.titleMedium)
                        Text("$dlCount songs offline",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Icon(Icons.Filled.ChevronRight, contentDescription = null)
                }
            }
        }
        item { SectionHeader("Liked Songs") }
        if (liked.isEmpty()) {
            item {
                Text("Nothing liked yet — tap the heart on any song.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
            }
        } else {
            items(liked, key = { it.id }) { t ->
                TrackRow(
                    track = t, isCurrent = false, liked = true,
                    onPlay = { onPlay(t) },
                    onPlayNext = { onPlayNext(t) },
                    onAddQueue = { onAddQueue(t) },
                    onToggleLike = { onToggleLike(t) }
                )
            }
        }
        item {
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Playlists", style = MaterialTheme.typography.titleLarge)
                TextButton(onClick = { showNew = true }) {
                    Icon(Icons.Filled.Add, contentDescription = null,
                        modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("New")
                }
            }
        }
        if (lists.isEmpty()) {
            item {
                Text("No playlists yet — make one, or add songs from any menu.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
            }
        } else {
            items(lists, key = { it.id }) { p ->
                ListItem(
                    headlineContent = { Text(p.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    supportingContent = { Text("${p.tracks.size} songs") },
                    leadingContent = { MosaicArt(p.tracks, 52.dp, 8.dp) },
                    trailingContent = {
                        IconButton(onClick = { onOpenPlaylist(p.id) }) {
                            Icon(Icons.Filled.ChevronRight, contentDescription = "Open")
                        }
                    },
                    modifier = Modifier.clickable { onOpenPlaylist(p.id) }
                )
            }
        }
        item { SectionHeader("Recently Played") }
        if (recent.isEmpty()) {
            item {
                Text("Play something and it shows up here.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
            }
        } else {
            items(recent, key = { it.id }) { t ->
                TrackRow(
                    track = t, isCurrent = false, liked = likedOf(t),
                    onPlay = { onPlay(t) },
                    onPlayNext = { onPlayNext(t) },
                    onAddQueue = { onAddQueue(t) },
                    onToggleLike = { onToggleLike(t) }
                )
            }
        }
    }
    if (showNew) {
        NewPlaylistSheet(
            onCreate = { n ->
                try {
                    PlaylistStore.create(ctx, n)
                    lists = PlaylistStore.list(ctx)
                } catch (e: Exception) {
                }
                showNew = false
            },
            onDismiss = { showNew = false }
        )
    }
}

private val moods = listOf(
    Triple("Hindi Love", "arijit singh love songs",
        listOf(Color(0xFFFA243C), Color(0xFF7D0018))),
    Triple("Workout", "workout motivation songs",
        listOf(Color(0xFFFF9F0A), Color(0xFFB25000))),
    Triple("Lofi Chill", "lofi chill beats",
        listOf(Color(0xFF5E5CE6), Color(0xFF1B1B6B))),
    Triple("Party", "party dance hits",
        listOf(Color(0xFF30D158), Color(0xFF0B5C2A)))
)

/** Decorative dotted-pattern mood tiles (Apple-style mesh feel). */
@Composable
private fun MoodPatternRow(onMood: (String) -> Unit) {
    LazyRow(
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        items(moods) { (label, q, colors) ->
            Box(
                Modifier.width(150.dp).height(92.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(Brush.linearGradient(colors))
                    .clickable { onMood(q) }
                    .padding(12.dp)
            ) {
                // dot pattern overlay
                androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                    val step = 18.dp.toPx()
                    val r = 1.6.dp.toPx()
                    var y = step / 2
                    var row = 0
                    while (y < size.height) {
                        var x = step / 2 + (if (row % 2 == 1) step / 2 else 0f)
                        while (x < size.width) {
                            drawCircle(Color.White.copy(alpha = 0.22f), r,
                                androidx.compose.ui.geometry.Offset(x, y))
                            x += step
                        }
                        y += step
                        row++
                    }
                }
                Text(label, style = MaterialTheme.typography.titleMedium,
                    color = Color.White, modifier = Modifier.align(Alignment.BottomStart))
            }
        }
    }
}

@Composable
private fun SearchScreen(
    query: String, onQuery: (String) -> Unit, live: Boolean, onPlay: (YtTrack) -> Unit,
    focusTick: Int,
    onPlayNext: (YtTrack) -> Unit, onAddQueue: (YtTrack) -> Unit,
    likedOf: (YtTrack) -> Boolean, onToggleLike: (YtTrack) -> Unit
) {
    var results by remember { mutableStateOf<List<YtTrack>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    val context = LocalContext.current
    var error by remember { mutableStateOf<String?>(null) }
    var retryTick by remember { mutableIntStateOf(0) }
    // Double-tap on the Search tab icon focuses the bar with keyboard up
    val focusRequester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(focusTick) {
        if (focusTick > 0) {
            focusRequester.requestFocus()
            delay(200)
            keyboard?.show()
        }
    }

    // Debounced real YouTube search: cached results first, refresh after,
    // one automatic retry on failure, manual retry button on error.
    LaunchedEffect(query, retryTick) {
        if (query.length < 2) {
            results = emptyList(); error = null; searching = false; return@LaunchedEffect
        }
        val cacheKey = "q_" + query.trim().lowercase().hashCode()
        try {
            withContext(Dispatchers.IO) {
                SongCache.load(context, cacheKey, SEARCH_CACHE_TTL)
            }?.let { cached ->
                results = cached
                error = null
            }
        } catch (e: Exception) { }
        delay(800)
        searching = true
        error = null
        var fresh: List<YtTrack> = emptyList()
        var attempt = 0
        while (attempt < 2 && fresh.isEmpty()) {
            attempt++
            try {
                fresh = YoutubeRepository.searchSongs(query, 20)
            } catch (e: Exception) {
                Log.w(TAG, "search failed (attempt $attempt)", e)
                if (attempt < 2) {
                    delay(1500)
                }
            }
        }
        try {
            if (fresh.isNotEmpty()) {
                results = fresh
                val snapshot = fresh
                try {
                    withContext(Dispatchers.IO) {
                        SongCache.save(context, cacheKey, snapshot)
                    }
                } catch (e: Exception) {
                }
            } else if (results.isEmpty()) {
                error = "No songs found — check connection and retry"
            }
        } catch (e: Exception) {
            if (results.isEmpty()) {
                error = "Search failed — check connection and retry"
            }
        } finally {
            searching = false
        }
    }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp)) {
        item {
            Text("Search", style = MaterialTheme.typography.displaySmall)
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = query, onValueChange = onQuery,
                placeholder = { Text("Songs & artists") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                trailingIcon = { if (searching) CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp) },
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth().focusRequester(focusRequester)
            )
            Spacer(Modifier.height(8.dp))
            LiveBadge(live)
            if (error != null) {
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(error!!, style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.weight(1f))
                    TextButton(onClick = { retryTick++ }) { Text("Retry") }
                }
            }
            Spacer(Modifier.height(8.dp))
        }
        items(results, key = { it.id }) { t ->
            TrackRow(
                track = t, isCurrent = false, liked = likedOf(t),
                onPlay = { onPlay(t) },
                onPlayNext = { onPlayNext(t) },
                onAddQueue = { onAddQueue(t) },
                onToggleLike = { onToggleLike(t) }
            )
        }
    }
}

@Composable
private fun PlaceholderScreen(label: String) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(label, style = MaterialTheme.typography.displaySmall)
            Spacer(Modifier.height(8.dp))
            Text("Coming soon — Listen Now + Search are live on YouTube data.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SectionHeader(title: String, onSeeAll: (() -> Unit)? = null) {
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, style = MaterialTheme.typography.titleLarge)
        if (onSeeAll != null) {
            Text("See All", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.clickable { onSeeAll() })
        }
    }
}

/** Real YouTube thumbnail when available, gradient placeholder otherwise. */
@Composable
private fun TrackArt(thumbUrl: String, seed: Int, size: Dp, corner: Dp = 8.dp) {
    if (thumbUrl.isNotBlank()) {
        AsyncImage(
            model = thumbUrl,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.size(size).clip(RoundedCornerShape(corner))
        )
    } else {
        val grad = ArtGradients[kotlin.math.abs(seed) % ArtGradients.size]
        Box(
            Modifier.size(size).clip(RoundedCornerShape(corner))
                .background(Brush.linearGradient(grad)),
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Filled.MusicNote, contentDescription = null,
                tint = Color.White.copy(alpha = 0.9f))
        }
    }
}

@Preview(showBackground = true, name = "Apple Music Light")
@Composable
fun AppleLightPreview() {
    AppleMusicTheme(darkTheme = false) { AppleMusicApp() }
}

@Preview(showBackground = true, name = "Apple Music Dark")
@Composable
fun AppleDarkPreview() {
    AppleMusicTheme(darkTheme = true) { AppleMusicApp() }
}
