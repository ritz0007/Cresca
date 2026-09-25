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
import androidx.compose.animation.togetherWith
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.Velocity
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyHorizontalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.itemsIndexed
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
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
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
import androidx.compose.ui.text.style.TextAlign
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
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import java.io.File

private const val TAG = "Cresca"
private const val HOME_CACHE_TTL = 12 * 60 * 60 * 1000L
private const val SEARCH_CACHE_TTL = 30 * 60 * 1000L

private data class Tab(val label: String, val icon: ImageVector)

/**
 * See All opens a full page (not a sheet). Query/kiosk kinds paginate
 * endlessly via extractor continuations; static kind shows a fixed list.
 */
private data class SeeAllRequest(
    val title: String,
    val subtitle: String = "",
    val query: String = "",
    val music: Boolean = true,
    val kiosk: Boolean = false,
    val static: List<YtTrack> = emptyList()
)

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

// HD artwork: maxres for YouTube ids (falls back to the thumb when
// missing), untouched otherwise.
private fun hdThumb(t: YtTrack): String {
    try {
        if (t.id.length == 11 && t.id.all {
                it.isLetterOrDigit() || it == '-' || it == '_'
            }
        ) {
            return "https://i.ytimg.com/vi/${t.id}/maxresdefault.jpg"
        }
    } catch (e: Exception) {
    }
    return t.thumbUrl
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
        // Crash log first so even startup crashes are captured (on-device only).
        try {
            CrashLog.install(this)
        } catch (e: Exception) {
        }
        val splash = installSplashScreen()
        var uiReady = false
        splash.setKeepOnScreenCondition { !uiReady }
        super.onCreate(savedInstanceState)
        // Edge-to-edge: the full player bleeds artwork under the status
        // bar (Scaffold + sheets already consume insets as padding).
        try {
            androidx.core.view.WindowCompat.setDecorFitsSystemWindows(window, false)
        } catch (e: Exception) {
        }
        try {
            themeMode = getPreferences(MODE_PRIVATE).getString("theme", "system") ?: "system"
        } catch (e: Exception) {
        }
        // Media notification needs this on Android 13+; Live Updates chip
        // needs the promoted permission on Android 16+ (else the card
        // never promotes and actions stay hidden in the drawer).
        try {
            if (android.os.Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                notifPerm.launch(android.Manifest.permission.POST_NOTIFICATIONS)
            }
        } catch (e: Exception) {
        }
        try {
            if (android.os.Build.VERSION.SDK_INT >= 36) {
                val promoted = "android.permission.POST_PROMOTED_NOTIFICATIONS"
                if (checkSelfPermission(promoted) !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED
                ) {
                    notifPerm.launch(promoted)
                }
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

/** Status + nav bars follow the page: in the full player they go fully
 * transparent so the thumbnail art covers the status bar and melts into
 * the backdrop (no square edges); everywhere else they wear the solid app
 * surface so icons always stay readable. */
@Composable
private fun SystemBars(dark: Boolean, barColor: Color? = null, immersivePlayer: Boolean = false) {
    val view = LocalView.current
    DisposableEffect(dark, barColor, immersivePlayer) {
        try {
            val window = (view.context as android.app.Activity).window
            if (immersivePlayer) {
                window.statusBarColor = android.graphics.Color.TRANSPARENT
                window.navigationBarColor = android.graphics.Color.TRANSPARENT
                // Icon tone from the artwork luminance.
                val dom = barColor
                val lightBars = if (dom != null) {
                    (dom.red * 0.2126f + dom.green * 0.7152f + dom.blue * 0.0722f) > 0.45f
                } else !dark
                WindowCompat.getInsetsController(window, view).apply {
                    isAppearanceLightStatusBars = lightBars
                    isAppearanceLightNavigationBars = lightBars
                }
            } else if (barColor != null) {
                val argb = android.graphics.Color.argb(
                    255,
                    (barColor.red * 255).toInt().coerceIn(0, 255),
                    (barColor.green * 255).toInt().coerceIn(0, 255),
                    (barColor.blue * 255).toInt().coerceIn(0, 255)
                )
                window.statusBarColor = argb
                window.navigationBarColor = argb
                // Dark artwork -> light icons.
                val lightBars = (barColor.red * 0.2126 + barColor.green * 0.7152 + barColor.blue * 0.0722) > 0.45f
                WindowCompat.getInsetsController(window, view).apply {
                    isAppearanceLightStatusBars = lightBars
                    isAppearanceLightNavigationBars = lightBars
                }
            } else {
                window.statusBarColor = android.graphics.Color.TRANSPARENT
                window.navigationBarColor = android.graphics.Color.TRANSPARENT
                WindowCompat.getInsetsController(window, view).apply {
                    // Fallback theme color: dark = light icons, light = dark icons
                    val lightBars = !dark
                    isAppearanceLightStatusBars = lightBars
                    isAppearanceLightNavigationBars = lightBars
                }
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
    val dark = when (themeMode) {
        "light" -> false
        "dark" -> true
        else -> isSystemInDarkTheme()
    }

    var selectedTab by remember { mutableIntStateOf(0) }
    var query by remember { mutableStateOf("") }
    var homeTracks by remember { mutableStateOf<List<YtTrack>>(emptyList()) }
    // YT Music style variety: per-section rails loaded in parallel.
    var homeSections by remember { mutableStateOf<Map<String, List<YtTrack>>>(emptyMap()) }
    // Endless explore: rails appended as the user scrolls (never ends).
    var endlessRails by remember { mutableStateOf<List<HomeSection>>(emptyList()) }
    var loadingMoreRails by remember { mutableStateOf(false) }
    // Every refresh rotates Top Picks seeds (page always changes).
    var refreshCount by remember { mutableIntStateOf(kotlin.random.Random.nextInt(0, 1000)) }
    var isRefreshing by remember { mutableStateOf(false) }
    // See All source per rail title (powers endless full pages).
    var railSources by remember { mutableStateOf<Map<String, SeeAllRequest>>(emptyMap()) }
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
    var upcomingTick by remember { mutableIntStateOf(0) }
    // Parked mid-call taps: true when the user asked to play while a call
    // held focus. onCallEnded starts the service + plays (never mid-call).
    // (Declared up here: playDash below also parks.)
    var callPendingPlay by remember { mutableStateOf(false) }
    var userPausedMidCall by remember { mutableStateOf(false) }

    // Quality rows for the picker: DASH caps when available, else muxed heights.
    fun qualityLabels(): List<String> {
        return if (dashUrl.isNotBlank()) {
            listOf("Auto", "1080p", "720p", "480p", "360p")
        } else {
            videoOpts.map { it.label }.distinct()
        }
    }

    // Saved ceiling: 720p default. ABR still adapts DOWN inside the cap on
    // bottleneck (ExoPlayer treats maxVideoSize as a ceiling, not a lock).
    fun qualityCapPref(): Int {
        return try {
            when (context.getSharedPreferences("cresca_prefs", android.content.Context.MODE_PRIVATE)
                .getString("video_quality", "720p")) {
                "1080p" -> 1080
                "720p" -> 720
                "480p" -> 480
                "360p" -> 360
                else -> 0
            }
        } catch (e: Exception) {
            720
        }
    }

    fun saveQualityPref(label: String) {
        try {
            context.getSharedPreferences("cresca_prefs", android.content.Context.MODE_PRIVATE)
                .edit().putString("video_quality", label).apply()
        } catch (e: Exception) {
        }
    }

    /** Best muxed option at or under the ceiling (0 = uncapped best). */
    fun pickMuxed(
        opts: List<YoutubeRepository.VideoOption>,
        capH: Int
    ): YoutubeRepository.VideoOption? {
        return try {
            if (opts.isEmpty()) return null
            if (capH <= 0) return opts.firstOrNull()
            opts.filter { it.height in 1..capH }.maxByOrNull { it.height }
                ?: opts.minByOrNull { it.height }
        } catch (e: Exception) {
            opts.firstOrNull()
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
                // Stable key: DASH manifest URLs are signed per resolve.
                .setCustomCacheKey("ytv:" + t.id)
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
            val defer = try {
                CallGuard.isInCall(context)
            } catch (e: Exception) {
                false
            }
            if (defer) {
                callPendingPlay = true
                playerError = "On call — starts when the call ends"
                try {
                    player.pause()
                } catch (e: Exception) {
                }
            } else player.play()
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
    // Likes + real history load off the main thread (file IO must never
    // block composition). Recent is the lifetime list (300, persisted).
    LaunchedEffect(Unit) {
        try {
            liked = withContext(Dispatchers.IO) { LikedStore.load(context) }
        } catch (e: Exception) {
        }
        try {
            val hist = withContext(Dispatchers.IO) { RecentStore.load(context) }
            if (hist.isNotEmpty()) {
                recent.clear()
                recent.addAll(hist)
            }
        } catch (e: Exception) {
        }
    }
    var showQueue by remember { mutableStateOf(false) }
    // See All is a full page (not a sheet) with endless pagination.
    var seeAllPage by remember { mutableStateOf<SeeAllRequest?>(null) }
    var searchFocusTick by remember { mutableIntStateOf(0) }
    var lastSearchTap by remember { mutableLongStateOf(0L) }
    var loggedIn by remember { mutableStateOf(false) }
    var loginFailed by remember { mutableStateOf(false) }
    // YT-side taste (liked + history pulled after login). Seeds for
    // recommendations only — never merged into local liked/recent.
    var ytSeeds by remember { mutableStateOf<List<YtTrack>>(emptyList()) }
    LaunchedEffect(Unit) {
        try {
            loggedIn = withContext(Dispatchers.IO) { YtSessionManager.isLoggedIn(context) }
        } catch (e: Exception) {
        }
        try {
            val cached = withContext(Dispatchers.IO) { RecentStore.load(context, "yt_seeds.json") }
            if (cached.isNotEmpty()) ytSeeds = cached
        } catch (e: Exception) {
        }
    }
    // After login, pull YT liked + history once for better suggestions.
    LaunchedEffect(loggedIn) {
        if (!loggedIn) return@LaunchedEffect
        try {
            val (likedYt, histYt) = withContext(Dispatchers.IO) { YoutubeRepository.ytLibrary(50) }
            val merged = (likedYt + histYt).distinctBy { it.id }.take(100)
            if (merged.isNotEmpty()) {
                ytSeeds = merged
                val snapshot = merged
                scope.launch(Dispatchers.IO) {
                    try {
                        RecentStore.save(context, snapshot, "yt_seeds.json")
                    } catch (e: Exception) {
                    }
                }
                // Fresh taste available: rebuild rails once.
                try {
                    homeTick++
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "yt library pull failed", e)
        }
    }
    var showSession by remember { mutableStateOf(false) }
    var dlItems by remember { mutableStateOf<List<Pair<YtTrack, File>>>(emptyList()) }
    var showDownloads by remember { mutableStateOf(false) }
    var showProfile by remember { mutableStateOf(false) }
    var dlLoc by remember { mutableStateOf(DownloadStore.location(context)) }
    // Motion: single kill-switch for the whole motion language.
    // Persisted, default ON. Screens read it for press/stagger/shimmer.
    var motionOn by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        try {
            motionOn = withContext(Dispatchers.IO) { Motion.isOn(context) }
        } catch (e: Exception) {
        }
    }
    // Playback engine: fast (on-device InnerTube, default) vs stable
    // (NewPipe scrape fallback). Persisted; applied to YoutubeRepository
    // on launch + toggle. Fast never strands the user: every call falls
    // back to NewPipe on empty/failure and logs why.
    var engineFast by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        try {
            val v = withContext(Dispatchers.IO) {
                try {
                    val prefs = context.getSharedPreferences("cresca_prefs", android.content.Context.MODE_PRIVATE)
                    // Default true for fresh installs; stored choice wins.
                    if (prefs.contains("engine_fast")) prefs.getBoolean("engine_fast", true)
                    else true
                } catch (e: Exception) {
                    true
                }
            }
            engineFast = v
            try {
                YoutubeRepository.useInnerTube = v
                Log.i(TAG, "engine ${if (v) "fast-InnerTube" else "stable-NewPipe"}")
            } catch (e: Exception) {
            }
        } catch (e: Exception) {
        }
    }

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

    // Artwork-dominant color drives the player + system bars.
    var playerDom by remember { mutableStateOf(Color(0xFF3A0A12)) }
    LaunchedEffect(nowPlaying?.id) {
        val t = nowPlaying
        playerDom = try {
            if (t != null && t.thumbUrl.isNotBlank()) {
                dominantColor(context, t.thumbUrl)
            } else {
                Color(0xFF3A0A12)
            }
        } catch (e: Exception) {
            Color(0xFF3A0A12)
        }
    }
    SystemBars(
        dark,
        if (showFullPlayer) playerDom else MaterialTheme.colorScheme.background,
        immersivePlayer = showFullPlayer
    )

    fun openPlaylist(id: String) {
        // Store I/O off main (file JSON ANRs). State assigns on Main
        // (Compose snapshot crash fix: never set state from IO thread).
        scope.launch(Dispatchers.IO) {
            val found = try {
                PlaylistStore.list(context).find { it.id == id }
            } catch (e: Exception) {
                null
            }
            try {
                withContext(Dispatchers.Main) { showPlaylist = found }
            } catch (e: Exception) {
            }
        }
    }

    fun refreshDownloads() {
        scope.launch(Dispatchers.IO) {
            val items = try {
                DownloadStore.listAll(context)
            } catch (e: Exception) {
                emptyList()
            }
            try {
                withContext(Dispatchers.Main) { dlItems = items }
            } catch (e: Exception) {
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

    /** Real history: newest first, persisted lifetime list (300). */
    fun pushRecent(t: YtTrack) {
        if (t.id.isEmpty()) return
        recent.removeAll { it.id == t.id }
        recent.add(0, t)
        while (recent.size > RecentStore.MAX) recent.removeLast()
        val snapshot = recent.toList()
        scope.launch(Dispatchers.IO) {
            try {
                RecentStore.save(context, snapshot)
            } catch (e: Exception) {
            }
        }
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
        // Crash gate: starting playback mid-call kills the app — the player
        // can't take audio focus, the notification never goes ongoing, and
        // the system fires RemoteServiceException for the missing
        // startForeground() (ExoPlayer #7977 pattern). Start only off-call;
        // parked taps resume via onCallEnded below.
        try {
            if (!CallGuard.CallPlaybackGate.shouldStartForegroundService(
                    CallGuard.isInCall(context)
                )
            ) {
                return
            }
        } catch (e: Exception) {
        }
        try {
            androidx.core.content.ContextCompat.startForegroundService(
                context, android.content.Intent(context, PlaybackService::class.java)
            )
        } catch (e: Exception) {
            Log.w(TAG, "service start failed", e)
        }
    }

    // Parked mid-call taps are declared near the top (before playDash).
    // This helper only records the tap + hint.
    fun noteTapDuringCall(): Boolean {
        return try {
            if (CallGuard.isInCall(context)) {
                callPendingPlay = true
                playerError = "On call — starts when the call ends"
                true
            } else false
        } catch (e: Exception) {
            false
        }
    }

    // Non-stop guard: consecutive auto-skips. Stops after 5 so a fully
    // dead queue surfaces an error instead of spinning forever.
    var autoSkipErrors by remember { mutableIntStateOf(0) }
    // Session-restore state (Spotify-style cold start, no autoplay).
    var restoredPos by remember { mutableLongStateOf(0L) }
    var sessionRestored by remember { mutableStateOf(false) }
    var restoreSeekDone by remember { mutableStateOf(false) }

    // Holder breaks the local-fun forward-reference cycle: queue callbacks
    // run later and must be able to call back into the queue.
    val queueHolder = remember { arrayOfNulls<PlayerQueue>(1) }
    val queue = remember {
        PlayerQueue(player, scope,
            onResolveStart = { resolving = true },
            onResolved = { t ->
                resolving = false
                playerError = null
                autoSkipErrors = 0
                nowPlaying = t
                pushRecent(t)
                startPlaybackService()
                // Persist last session via holder (avoids self-reference).
                scope.launch {
                    try {
                        val q = queueHolder[0]
                        val pos = try {
                            player.currentPosition
                        } catch (e: Exception) {
                            0L
                        }
                        if (q != null) {
                            PlaybackStateStore.save(
                                context, q.snapshot(), q.currentIndex,
                                t, pos, q.shuffleOn, q.repeatModeState
                            )
                        }
                    } catch (e: Exception) {
                    }
                }
                Log.i(TAG, "playing ${t.title}")
                // Every change tops Up Next back up to ~20 related tracks
                // (trigger-state: refreshUpcoming is declared below).
                upcomingTick++
                // BG store next + prev + charts + taste-predicted songs
                // (4 GB cache) so skips stream instantly, even offline-ish.
                // Deferred 3s + same-track guard: the critical next-skip
                // resolve must never queue behind ~30 background POSTs.
                // (skipNext() has no own warmer; this covers every change.)
                scope.launch(Dispatchers.IO) {
                    try {
                        delay(3000)
                        val q = queueHolder[0] ?: return@launch
                        try {
                            if (q.current?.id != t.id) return@launch
                        } catch (e: Exception) {
                        }
                        Precache.warmPredicted(
                            context, q.upcomingIds(5),
                            try {
                                liked
                            } catch (e: Exception) {
                                emptyList()
                            },
                            try {
                                recent.toList()
                            } catch (e: Exception) {
                                emptyList()
                            },
                            try {
                                q.previousIds(3)
                            } catch (e: Exception) {
                                emptyList()
                            },
                            try {
                                homeSections["Charts Right Now"] ?: emptyList()
                            } catch (e: Exception) {
                                emptyList()
                            }
                        )
                    } catch (e: Exception) {
                    }
                }
                // Video options resolve on demand in enterVideo() (5h cache):
                // warming here cost 1 RTT per audio track for a sheet the user
                // may never open. Removed for instant audio path.
                // New track while watching video: follow it into video mode.
                if (videoMode) {
                    videoFollowTick++
                    // Pre-resolve the NEXT video while this one plays: the
                    // flip then memory-hits (5h/inf caches) instead of paying
                    // 2 fetches. On-demand still (current track only warms N+1).
                    scope.launch(Dispatchers.IO) {
                        try {
                            val q = queueHolder[0] ?: return@launch
                            val nx = q.upcomingIds(1).firstOrNull() ?: return@launch
                            if (nx.watchUrl.isBlank()) return@launch
                            try {
                                YoutubeRepository.videoOptions(nx.watchUrl)
                            } catch (e: Exception) {
                            }
                            try {
                                YoutubeRepository.videoDetails(nx.watchUrl)
                            } catch (e: Exception) {
                            }
                        } catch (e: Exception) {
                        }
                    }
                } else {
                    // Buffer the track after this one: gapless change.
                    primeTick++
                }
            },
            onError = { msg ->
                resolving = false
                // Non-stop: unplayable track -> skip forward automatically.
                val q = queueHolder[0]
                if (autoSkipErrors < 5 && (q?.hasNext() == true)) {
                    autoSkipErrors++
                    playerError = "Skipping unavailable song…"
                    scope.launch {
                        delay(600)
                        try {
                            q?.next()
                        } catch (e: Exception) {
                            playerError = msg
                        }
                    }
                } else {
                    playerError = msg
                }
            },
            onExhausted = { t ->
                // Queue ran dry: autoplay related tracks of the current song.
                scope.launch(Dispatchers.IO) {
                    try {
                        val q = queueHolder[0] ?: return@launch
                        val rel = try {
                            YoutubeRepository.autoplayFor(t, 20)
                        } catch (e: Exception) {
                            emptyList()
                        }.filter { r -> q.snapshot().none { it.id == r.id } }
                        if (rel.isEmpty()) return@launch
                        withContext(Dispatchers.Main) {
                            try {
                                q.appendAuto(rel)
                                autoSkipErrors = 0
                                playerError = null
                                Log.i(TAG, "autoplay ${rel.size} related")
                                q.next()
                            } catch (e: Exception) {
                            }
                        }
                    } catch (e: Exception) {
                    }
                }
            }).also { queueHolder[0] = it }
    }

    // Queue never issues play() mid-call (focus locked); it prepares + pauses
    // and the UI resumes after the call via onCallEnded.
    LaunchedEffect(queue) {
        try {
            queue.deferPlay = {
                try {
                    CallGuard.isInCall(context)
                } catch (e: Exception) {
                    false
                }
            }
        } catch (e: Exception) {
        }
    }

    // Keep ~20 upcoming tracks after every change (related autoplay).
    var upcomingJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    fun saveSessionNow() {
        scope.launch {
            try {
                val t = nowPlaying ?: return@launch
                if (queue.items.isEmpty()) return@launch
                val pos = try {
                    player.currentPosition
                } catch (e: Exception) {
                    0L
                }
                PlaybackStateStore.save(
                    context, queue.snapshot(), queue.currentIndex,
                    t, pos, queue.shuffleOn, queue.repeatModeState
                )
            } catch (e: Exception) {
            }
        }
    }
    fun refreshUpcoming() {
        try {
            upcomingJob?.cancel()
        } catch (e: Exception) {
        }
        upcomingJob = scope.launch {
            try {
                val cur = queue.current ?: return@launch
                // Infinite fixed-20: refill when ≤5 remain (15th of 20).
                // Append-only (no clearAutoTail): the list the user sees is
                // stable; fresh related-of-current tops it back to 20.
                // (Was: refill at <10 with tail replacement — the "queue
                // isn't persistent" churn.)
                if (queue.upcomingCount() > 5) return@launch
                if (queue.current?.id != cur.id) return@launch
                val rel = withContext(Dispatchers.IO) {
                    try {
                        YoutubeRepository.autoplayFor(cur, 30)
                    } catch (e: Exception) {
                        emptyList()
                    }
                }
                if (queue.current?.id != cur.id) return@launch
                val fresh = rel.filter { r -> queue.snapshot().none { it.id == r.id } }
                    .take((20 - queue.upcomingCount()).coerceAtLeast(0))
                Log.i(TAG, "related ${rel.size}, fresh ${fresh.size}")
                if (fresh.isNotEmpty()) {
                    queue.appendAuto(fresh)
                    Log.i(TAG, "upcoming topped to ${queue.upcomingCount()}")
                }
            } catch (e: Exception) {
            }
        }
    }
    // Smart shuffle: preference-scored order (liked/recent/same artist),
    // randomized within score tiers so it still feels like a shuffle.
    fun applySmartShuffle() {
        try {
            val q = queue
            if (q.items.size < 2 || q.currentIndex == -1) return
            val likedA = liked.map { it.artist.lowercase() }.toSet()
            val recentA = recent.take(8).map { it.artist.lowercase() }
            val curA = q.current?.artist?.lowercase() ?: ""
            val rnd = kotlin.random.Random(System.currentTimeMillis())
            val rest = q.items.indices.filter { it != q.currentIndex }.map { idx ->
                val t = q.items[idx]
                var s = 0
                val ta = t.artist.lowercase()
                if (ta in likedA) s += 3
                val ri = recentA.indexOf(ta)
                if (ri >= 0) s += 2 - ri / 4
                if (ta.isNotEmpty() && ta == curA) s += 2
                Pair(s, idx)
            }.sortedWith(compareByDescending<Pair<Int, Int>> { it.first }
                .thenBy { rnd.nextInt() })
            q.applyOrder(listOf(q.currentIndex) + rest.map { it.second })
            Log.i(TAG, "smart shuffle applied")
        } catch (e: Exception) {
            Log.w(TAG, "smart shuffle failed", e)
        }
    }
    fun cycleShuffleUi() {
        try {
            val m = queue.cycleShuffle()
            if (m == PlayerQueue.SHUFFLE_SMART) {
                applySmartShuffle()
            }
            refreshUpcoming()
            saveSessionNow()
        } catch (e: Exception) {
        }
    }

    // Up Next top-up trigger (set by resolve callbacks above).
    LaunchedEffect(upcomingTick) {
        if (upcomingTick > 0) {
            Log.i(TAG, "upcoming check")
            refreshUpcoming()
        }
    }

    // Auto-advance at track end (repeat/shuffle handled inside queue).
    // Dead-end fix: last track + repeat OFF previously sat in ENDED with
    // the seek bar stuck at the end. Now rewind to 0 and pause (replay).
    LaunchedEffect(playerState) {
        if (playerState == Player.STATE_ENDED) {
            if (queue.hasNext()) {
                queue.next()
            } else {
                try {
                    player.seekTo(0)
                    player.pause()
                } catch (e: Exception) {
                }
            }
        }
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
                        // Hosts exhausted: fall through to auto-skip below.
                        if (autoSkipErrors < 5 && queue.hasNext()) {
                            autoSkipErrors++
                            playerError = "Skipping blocked song…"
                            scope.launch {
                                delay(600)
                                try {
                                    queue.next()
                                } catch (e: Exception) {
                                }
                            }
                        } else {
                            playerError = "YouTube blocked playback (403)"
                        }
                    } else {
                        autoSkipErrors = 0
                    }
                    return
                }
                // Any other error (network/decoding/DASH): never dead-end the
                // mini-player. Retry once via resolve, else skip forward.
                if (autoSkipErrors < 5 && queue.hasNext()) {
                    autoSkipErrors++
                    playerError = "Skipping… (${error.errorCode})"
                    scope.launch {
                        delay(800)
                        try {
                            queue.next()
                        } catch (e: Exception) {
                            playerError = error.message ?: "Playback error (${error.errorCode})"
                        }
                    }
                } else {
                    playerError = error.message ?: "Playback error (${error.errorCode})"
                }
            }
        }
        player.addListener(listener)
        // Player + session lifetimes belong to PlaybackService; only detach here.
        onDispose { player.removeListener(listener) }
    }

    // Position clock for seek bar + synced lyrics (150ms: karaoke needs
    // tight sync; reads are cheap binder calls, no work when idle).
    var position by remember { mutableLongStateOf(0L) }
    var duration by remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) {
        while (true) {
            try {
                position = try {
                    player.currentPosition
                } catch (e: Exception) {
                    0L
                }
                duration = try {
                    player.duration.coerceAtLeast(0L)
                } catch (e: Exception) {
                    0L
                }
            } catch (e: Exception) {
                // Controller released (config change / dispose): stop the clock.
                break
            }
            delay(150)
        }
    }

    // Phone calls win: pause while in a call, resume after (if playing).
    // Crash-proof via CallGuard (isolates API-31 surface, never throws).
    // Parked mid-call taps start here: service + play are only safe now
    // that focus is unlocked (starting them mid-call = RemoteService crash).
    DisposableEffect(player) {
        val unregister = try {
            CallGuard.register(context, player) {
                try {
                    if (callPendingPlay && !userPausedMidCall && nowPlaying != null) {
                        callPendingPlay = false
                        playerError = null
                        startPlaybackService()
                        try {
                            player.play()
                        } catch (e: Exception) {
                        }
                        Log.i(TAG, "resumed parked playback after call")
                    } else {
                        callPendingPlay = false
                    }
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
            {}
        }
        onDispose {
            try {
                unregister()
            } catch (e: Exception) {
            }
        }
    }

    // Lyrics follow the current track (duration disambiguates matches).
    // lyricsZeroDur: first fetch ran before the stream reported a duration
    // (player.duration unknown at track change) → refetch once the real
    // duration arrives, else mistimed records stick ("lyrics run faster").
    var lyrics by remember { mutableStateOf<LyricsState>(LyricsState.NotFound) }
    var lyricsZeroDur by remember { mutableStateOf(false) }
    LaunchedEffect(nowPlaying) {
        val t = nowPlaying
        lyricsZeroDur = false
        if (t == null || t.watchUrl.isBlank()) {
            lyrics = LyricsState.NotFound
        } else {
            lyrics = LyricsState.Loading
            // Player duration may still be unknown right at track change;
            // wait so duration scoring has real data (up to ~5s).
            var dur = 0L
            for (i in 0 until 10) {
                try {
                    dur = player.duration.coerceAtLeast(0L)
                } catch (e: Exception) {
                }
                if (dur > 30000L) break
                delay(500)
            }
            if (nowPlaying?.id != t.id) return@LaunchedEffect
            if (dur <= 30000L) lyricsZeroDur = true
            lyrics = LyricsRepository.fetch(t.artist, t.title, dur)
        }
    }
    // Duration arrived late: one background re-match with real data; swap
    // only on a strictly better (Synced) hit, never blank the screen.
    LaunchedEffect(nowPlaying?.id, duration) {
        val t = nowPlaying ?: return@LaunchedEffect
        if (!lyricsZeroDur || duration <= 30000L) return@LaunchedEffect
        if (lyrics !is LyricsState.Synced) {
            lyricsZeroDur = false
            return@LaunchedEffect
        }
        lyricsZeroDur = false
        try {
            val better = withContext(Dispatchers.IO) {
                LyricsRepository.fetch(t.artist, t.title, duration)
            }
            if (nowPlaying?.id == t.id && better is LyricsState.Synced) {
                lyrics = better
                Log.i(TAG, "lyrics re-matched on duration")
            }
        } catch (e: Exception) {
        }
    }

    // ---- Spotify/Apple Music style resume: restore last queue + position
    // on cold start WITHOUT autoplaying. Mini-player shows the track.
    LaunchedEffect(Unit) {
        try {
            val saved = PlaybackStateStore.load(context)
            if (saved != null && saved.tracks.isNotEmpty() && nowPlaying == null) {
                val idx = queue.setQueueSilent(
                    saved.tracks, saved.index, saved.shuffleOn, saved.repeatMode
                )
                val track = queue.items.getOrNull(idx)
                if (track != null) {
                    nowPlaying = track
                    restoredPos = saved.positionMs
                    sessionRestored = true
                    // Prime the restored track instantly: lazy cresca:// URI,
                    // no resolve. NOTE: MediaController must be touched on
                    // the app thread.
                    scope.launch(Dispatchers.Main) {
                        try {
                            if (nowPlaying?.id != track.id) return@launch
                            if (player.mediaItemCount != 0) return@launch
                            player.setMediaItem(
                                MediaItem.Builder()
                                    .setUri(ResolvingDataSource.uriFor(track.id))
                                    .setMediaId(track.id)
                                    .setCustomCacheKey("yt:" + track.id)
                                    .setMediaMetadata(metaFor(track))
                                    .build()
                            )
                            player.prepare()
                            val seekTo = restoredPos.coerceAtLeast(0L)
                            if (seekTo > 5000L) {
                                try {
                                    player.seekTo(seekTo)
                                } catch (e: Exception) {
                                }
                            }
                            player.pause()
                            restoreSeekDone = true
                        } catch (e: Exception) {
                            Log.w(TAG, "restore prime failed", e)
                        }
                    }
                    Log.i(TAG, "session restored ${track.title} @${saved.positionMs}")
                }
            } else {
                sessionRestored = true
            }
        } catch (e: Exception) {
            sessionRestored = true
        }
    }

    // 5s position ticker (SimpMusic mayBeSaveRecentPosition pattern):
    // covers kills with no lifecycle edge.
    LaunchedEffect(nowPlaying) {
        while (nowPlaying != null) {
            delay(5000)
            try {
                val t = nowPlaying ?: break
                if (queue.items.isEmpty()) continue
                val pos = try {
                    player.currentPosition
                } catch (e: Exception) {
                    continue
                }
                // Don't persist the ENDED dead zone.
                if (pos <= 0L) continue
                PlaybackStateStore.save(
                    context, queue.snapshot(), queue.currentIndex,
                    t, pos, queue.shuffleOn, queue.repeatModeState
                )
            } catch (e: Exception) {
            }
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
            if (CallGuard.CallPlaybackGate.actionForTap(
                    try {
                        CallGuard.isInCall(context)
                    } catch (e: Exception) {
                        false
                    }
                ) == CallGuard.CallPlayAction.START_NOW
            ) {
                player.play()
            } else {
                callPendingPlay = true
                playerError = "On call — starts when the call ends"
                try {
                    player.pause()
                } catch (e: Exception) {
                }
            }
            pushRecent(t)
            Log.i(TAG, "playing offline ${t.title}")
        } catch (e: Exception) {
            Log.e(TAG, "offline play failed", e)
            playerError = "Offline play failed"
        }
    }

    fun play(track: YtTrack) {
        // Stuck fix: never drop taps while resolving. Cancel the stale
        // resolve so the new tap wins instantly (generation token in queue).
        queue.cancelPending()
        resolving = false
        playerError = null
        autoSkipErrors = 0
        userPausedMidCall = false
        // Mid-call tap: park it ("starts when the call ends"). The queue
        // still resolves + prepares (paused); the service start waits.
        noteTapDuringCall()
        if (track.watchUrl.isBlank()) { nowPlaying = track; return }
        val idx = queue.items.indexOfFirst { it.id == track.id }
        if (player.mediaItemCount > 0 && queue.current?.id == track.id) {
            if (player.isPlaying) player.pause() else player.play()
            return
        }
        nowPlaying = track
        // Offline-first check off the main thread (file I/O).
        scope.launch(Dispatchers.IO) {
            val offline: File? = try {
                if (DownloadStore.isDownloaded(context, track.id)) {
                    DownloadStore.fileFor(context, track.id)
                } else null
            } catch (e: Exception) {
                null
            }
            if (offline != null) {
                playFile(track, offline)
                return@launch
            }
            if (queue.items.isEmpty()) queue.setQueue(listOf(track), 0)
            else if (queue.items.indexOfFirst { it.id == track.id } == -1) queue.playTrack(track)
            else queue.playAt(queue.items.indexOfFirst { it.id == track.id })
        }
    }

    fun togglePlay(track: YtTrack) {
        if (player.mediaItemCount == 0) play(track)
        else if (player.isPlaying) {
            try {
                if (CallGuard.isInCall(context)) userPausedMidCall = true
            } catch (e: Exception) {
            }
            player.pause()
        } else if (noteTapDuringCall()) {
            userPausedMidCall = false
            // Parked: prepared item stays paused until the call ends.
        } else player.play()
    }

    fun playList(tracks: List<YtTrack>, index: Int = 0, shuffled: Boolean = false) {
        if (tracks.isEmpty()) return
        queue.cancelPending()
        resolving = false
        playerError = null
        autoSkipErrors = 0
        userPausedMidCall = false
        noteTapDuringCall()
        val list = if (shuffled) tracks.shuffled() else tracks
        val i = index.coerceIn(list.indices)
        queue.setQueue(list, i)
        nowPlaying = list[i]
    }

    // Instant skip: optimistic UI (no missed taps on rapid press) + primed
    // ExoPlayer item plays immediately while resolve finishes in background.
    fun skipNext() {
        try {
            resolving = true
            playerError = null
            userPausedMidCall = false
            noteTapDuringCall()
            queue.next()
            // Optimistic: show the new current instantly (resolve confirms).
            try {
                queue.current?.let { nowPlaying = it }
            } catch (e: Exception) {
            }
            // No warmer here: onResolved() already warms (deferred 3s,
            // same-track guard) for every track change including skips.
            // A second warmPredicted per skip doubled background resolves
            // (~28 POSTs) and slowed the next skip's critical resolve.
        } catch (e: Exception) {
            try {
                queue.next()
            } catch (ignored: Exception) {
            }
        }
    }

    fun skipPrev() {
        try {
            resolving = true
            playerError = null
            userPausedMidCall = false
            noteTapDuringCall()
            queue.previous()
            try {
                queue.current?.let { nowPlaying = it }
            } catch (e: Exception) {
            }
        } catch (e: Exception) {
            try {
                queue.previous()
            } catch (ignored: Exception) {
            }
        }
    }

    // Notification / Live Update actions: Next + Prev + Like must always
    // work from the shade (wired after skip helpers: no forward refs).
    DisposableEffect(player) {
        try {
            NextActionReceiver.setMediaController(
                player as? androidx.media3.session.MediaController
            )
        } catch (e: Exception) {
        }
        try {
            NextActionReceiver.onNext = {
                try {
                    skipNext()
                } catch (e: Exception) {
                }
            }
            NextActionReceiver.onPrev = {
                try {
                    skipPrev()
                } catch (e: Exception) {
                }
            }
            NextActionReceiver.onLikeToggle = {
                try {
                    nowPlaying?.let { toggleLike(it) }
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
        }
        onDispose {
            try {
                NextActionReceiver.clear()
            } catch (e: Exception) {
            }
        }
    }
    fun openSeeAll(req: SeeAllRequest) {
        seeAllPage = req
        // Charts/rails the user opens get stored: probable replays stream
        // from disk next time (4 GB budget, LRU-kept).
        try {
            val static = req.static
            if (static.isNotEmpty()) {
                scope.launch(Dispatchers.IO) {
                    try {
                        Precache.warmUpcoming(context, static.take(8), 8)
                    } catch (e: Exception) {
                    }
                }
            }
        } catch (e: Exception) {
        }
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
                // Parallel: options + details were 2 sequential fetchPage()
                // calls (4-6s flips). One wave, ~1 RTT.
                val optsDef = async(Dispatchers.IO) {
                    try {
                        YoutubeRepository.videoOptions(t.watchUrl)
                    } catch (e: Exception) {
                        emptyList()
                    }
                }
                val dashDef = async(Dispatchers.IO) {
                    try {
                        YoutubeRepository.videoDetails(t.watchUrl)?.dashUrl ?: ""
                    } catch (e: Exception) {
                        ""
                    }
                }
                val opts = optsDef.await()
                videoOpts = opts
                val dash = dashDef.await()
                dashUrl = dash
                Log.i(TAG, "enterVideo opts=${opts.size} dash=${dash.isNotBlank()} cap=${qualityCapPref()}")
                val pos = player.currentPosition
                val playing = player.isPlaying
                if (dash.isNotBlank()) {
                    // DASH manifest: adaptive under the saved ceiling
                    // (720p default); ABR drops lower only on bottleneck.
                    val cap = qualityCapPref()
                    playDash(t, dash, cap, pos, playing)
                    videoQualityH = -1
                } else {
                    dashCapH = 0
                    val cap = qualityCapPref()
                    val opt = pickMuxed(opts, cap)
                    val url = opt?.url
                        ?: YoutubeRepository.videoUrl(t.watchUrl)
                    if (url != null) {
                        player.setMediaItem(
                            MediaItem.Builder()
                                .setUri(url)
                                .setMediaId("v:" + t.id)
                                .setCustomCacheKey("ytv:" + t.id)
                                .setMediaMetadata(metaFor(t))
                                .build()
                        )
                        player.prepare()
                        player.seekTo(pos)
                        if (playing) {
                            player.play()
                        }
                        videoQualityH = opt?.height ?: -1
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
                // Lazy URI: no resolve, instant flip back to audio.
                player.setMediaItem(
                    MediaItem.Builder()
                        .setUri(ResolvingDataSource.uriFor(t.id))
                        .setMediaId(t.id)
                        .setCustomCacheKey("yt:" + t.id)
                        .setMediaMetadata(metaFor(t))
                        .build()
                )
                player.prepare()
                player.seekTo(pos)
                if (resume && playing) {
                    player.play()
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
        saveQualityPref(label)
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
                        .setCustomCacheKey("ytv:" + ot.id)
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

    // Home, SimpMusic-shaped: Quick/Top Picks first (ROTATED every refresh so
    // the page always changes), then charts / new / moods / mixes rails.
    // Cache first (splash releases fast), network refresh after.
    // No demo data: spinner while loading, error + retry when offline.
    LaunchedEffect(homeTick) {
        val seed = HomeFeed.topSeed(refreshCount)
        homeLoading = homeTracks.isEmpty() && homeSections.isEmpty()
        homeError = null
        isRefreshing = homeTracks.isNotEmpty() || homeSections.isNotEmpty()
        endlessRails = emptyList()
        // 1) Instant caches for top + core sections.
        try {
            withContext(Dispatchers.IO) {
                val top = SongCache.load(context, "home_top", HOME_CACHE_TTL)
                    ?: SongCache.load(context, "home", HOME_CACHE_TTL)
                val map = HashMap<String, List<YtTrack>>()
                for (s in HomeFeed.CORE + HomeFeed.RELEASED) {
                    try {
                        SongCache.load(context, s.cacheKey, HomeFeed.SECTION_TTL_MS)?.let {
                            if (it.isNotEmpty()) map[s.title] = it
                        }
                    } catch (e: Exception) {
                    }
                }
                // Fast-engine browse shelves cached under home_browse_<hash>;
                // the hash→title map lives in prefs (titles aren't filename-safe).
                try {
                    val keys = context.getSharedPreferences("cresca_prefs", android.content.Context.MODE_PRIVATE)
                        .getStringSet("home_browse_keys", emptySet()) ?: emptySet()
                    for (entry in keys) {
                        try {
                            val sep = entry.indexOf("|")
                            if (sep < 1) continue
                            val title = entry.substring(sep + 1)
                            if (title.isBlank() || map.containsKey(title)) continue
                            SongCache.load(context, "home_browse_" + entry.substring(0, sep), HomeFeed.SECTION_TTL_MS)?.let {
                                if (it.isNotEmpty()) map[title] = it
                            }
                        } catch (e: Exception) {
                        }
                    }
                } catch (e: Exception) {
                }
                Pair(top, map)
            }.let { (cachedTop, cachedMap) ->
                if (cachedTop != null && cachedTop.isNotEmpty()) {
                    homeTracks = cachedTop
                    live = true
                    if (queue.items.isEmpty() && nowPlaying == null) {
                        queue.replaceAll(cachedTop)
                        nowPlaying = cachedTop.firstOrNull()
                    }
                    announce()
                }
                if (cachedMap.isNotEmpty()) {
                    homeSections = cachedMap
                    live = true
                    announce()
                }
                if (cachedTop != null) Log.i(TAG, "home from cache (${cachedTop.size}, ${cachedMap.size} rails)")
            }
        } catch (e: Exception) {
            Log.w(TAG, "cache read failed", e)
        }
        // Register See All sources for cached rails.
        try {
            val src = railSources.toMutableMap()
            src["Top Picks For You"] = SeeAllRequest("Top Picks For You", seed.subtitle, seed.query)
            for (s in HomeFeed.CORE + HomeFeed.RELEASED) {
                if (s.query == "__charts__") {
                    src[s.title] = SeeAllRequest(s.title, s.subtitle, kiosk = true)
                } else if (s.query == "__released__") {
                    // Static playlist snapshot (filled below / from cache).
                    src[s.title] = SeeAllRequest(s.title, s.subtitle, static = homeSections[s.title] ?: emptyList())
                } else {
                    src[s.title] = SeeAllRequest(s.title, s.subtitle, s.query)
                }
            }
            railSources = src
        } catch (e: Exception) {
        }
        // 2) Network refresh: Top Picks ALWAYS reload (rotating seed), so a
        // refresh visibly changes the page. YT Music song search.
        // Fast path: staged 2-frame write kept (software-renderer ANR guard)
        // but breathers trimmed 300/150/200ms -> 60/40/0ms for instant paint.
        var attempt = 0
        var loaded = false
        val homeNetT0 = try { android.os.SystemClock.elapsedRealtime() } catch (e: Exception) { 0L }
        while (attempt < 2 && !loaded) {
            attempt++
            try {
                val res = YoutubeRepository.searchMusic(seed.query, 25)
                if (res.isNotEmpty()) {
                    // Staged write: software renderers take seconds to
                    // upload 25 fresh images in one frame (input ANR). Two
                    // smaller frames stay under the timeout, same content.
                    homeTracks = res.take(10)
                    live = true
                    try {
                        delay(60)
                    } catch (e: Exception) {
                    }
                    homeTracks = res
                    try {
                        delay(40)
                    } catch (e: Exception) {
                    }
                    if (queue.items.isEmpty() && nowPlaying == null) {
                        queue.replaceAll(res)
                        nowPlaying = res.first()
                    }
                    try {
                        scope.launch(Dispatchers.IO) {
                            try {
                                SongCache.save(context, "home_top", res)
                                SongCache.save(context, "home", res)
                            } catch (e: Exception) {
                            }
                        }
                    } catch (e: Exception) {
                    }
                    Log.i(TAG, "top picks loaded ${res.size} (${seed.query})")
                    loaded = true
                    try {
                        Log.d(TAG, "home top picks ${try { android.os.SystemClock.elapsedRealtime() - homeNetT0 } catch (e: Exception) { -1 }}ms")
                    } catch (e: Exception) {
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "top picks failed (attempt $attempt)", e)
                if (attempt < 2) {
                    delay(800)
                }
            }
        }
        if (homeTracks.isEmpty() && homeSections.isEmpty()) {
            homeError = "Couldn't reach YouTube — check connection and retry"
        }
        homeLoading = false
        isRefreshing = false
        announce() // never trap the splash
        // 3) Other rails in background, 3 at a time: charts kiosk first,
        // then core, then related mixes + personalized (history-driven,
        // like SimpMusic's personalized shelves).
        // Fast engine first: ONE browse call (FEmusic_home) fills several
        // shelves at once; the per-rail jobs below only fetch titles still
        // missing (their `continue` guards prune automatically).
        try {
            if (YoutubeRepository.useInnerTube) {
                val shelves = try {
                    withContext(Dispatchers.IO) { YoutubeRepository.homeShelves(8, 12) }
                } catch (e: Exception) {
                    Log.d(TAG, "home browse failed: ${e.message}")
                    emptyMap()
                }
                if (shelves.isNotEmpty()) {
                    val cur = homeSections.toMutableMap()
                    val src = railSources.toMutableMap()
                    val keyEntries = HashSet<String>()
                    for ((title, tracks) in shelves) {
                        try {
                            if (tracks.isEmpty() || !cur[title].isNullOrEmpty()) continue
                            cur[title] = tracks
                            src[title] = SeeAllRequest(title, "YouTube Music", "$title songs")
                            val h = title.hashCode().toString()
                            keyEntries.add("$h|$title")
                            val snapshot = tracks
                            scope.launch(Dispatchers.IO) {
                                try {
                                    SongCache.save(context, "home_browse_$h", snapshot)
                                } catch (e: Exception) {
                                }
                            }
                        } catch (e: Exception) {
                        }
                    }
                    if (cur.size != homeSections.size) {
                        homeSections = cur
                        railSources = src
                        live = true
                        announce()
                    }
                    if (keyEntries.isNotEmpty()) {
                        scope.launch(Dispatchers.IO) {
                            try {
                                val prefs = context.getSharedPreferences("cresca_prefs", android.content.Context.MODE_PRIVATE)
                                val merged = HashSet(prefs.getStringSet("home_browse_keys", emptySet()) ?: emptySet())
                                merged.addAll(keyEntries)
                                prefs.edit().putStringSet("home_browse_keys", merged).apply()
                            } catch (e: Exception) {
                            }
                        }
                    }
                    Log.i(TAG, "home browse merged ${shelves.size} shelves")
                }
            }
        } catch (e: Exception) {
            Log.d(TAG, "home browse merge failed: ${e.message}")
        }
        try {
            val jobs = ArrayList<suspend () -> Pair<String, List<YtTrack>>?>()
            // Released: curated YT playlist (not a search). Always refreshes
            // so new drops land; cache keeps cold starts instant.
            if (homeSections[HomeFeed.RELEASED.title].isNullOrEmpty()) {
                jobs.add({
                    try {
                        val res = YoutubeRepository.playlistTracks(HomeFeed.RELEASED_PLAYLIST_ID, 25)
                        if (res.isNotEmpty()) {
                            try {
                                SongCache.save(context, HomeFeed.RELEASED.cacheKey, res)
                            } catch (e: Exception) {
                            }
                            try {
                                val src = railSources.toMutableMap()
                                src[HomeFeed.RELEASED.title] =
                                    SeeAllRequest(HomeFeed.RELEASED.title, HomeFeed.RELEASED.subtitle, static = res)
                                railSources = src
                            } catch (e: Exception) {
                            }
                            Pair(HomeFeed.RELEASED.title, res)
                        } else null
                    } catch (e: Exception) {
                        Log.w(TAG, "released rail failed", e)
                        null
                    }
                })
            }
            if (homeSections["Charts Right Now"].isNullOrEmpty()) {
                jobs.add({
                    try {
                        val res = YoutubeRepository.trendingMusic(12)
                        if (res.isNotEmpty()) {
                            try {
                                SongCache.save(context, "home_charts", res)
                            } catch (e: Exception) {
                            }
                            Pair("Charts Right Now", res)
                        } else null
                    } catch (e: Exception) {
                        Log.w(TAG, "charts rail failed", e)
                        null
                    }
                })
            }
            for (s in HomeFeed.CORE.drop(1)) {
                if (!homeSections[s.title].isNullOrEmpty()) continue
                jobs.add({
                    try {
                        val res = YoutubeRepository.searchMusic(s.query, 12)
                        if (res.isNotEmpty()) {
                            try {
                                SongCache.save(context, s.cacheKey, res)
                            } catch (e: Exception) {
                            }
                            Pair(s.title, res)
                        } else null
                    } catch (e: Exception) {
                        Log.w(TAG, "rail ${s.title} failed", e)
                        null
                    }
                })
            }
            // Related mixes from recent listening (SimpMusic radio-style).
            try {
                val seeds = recent.toList().filter { it.watchUrl.isNotBlank() }.take(2)
                for ((ri, st) in seeds.withIndex()) {
                    val key = "Because you played " + st.title.take(32)
                    if (!homeSections[key].isNullOrEmpty()) continue
                    jobs.add({
                        try {
                            val rel = YoutubeRepository.relatedTracks(st.watchUrl, 12)
                            if (rel.isNotEmpty()) {
                                try {
                                    SongCache.save(context, "home_mix_$ri", rel)
                                } catch (e: Exception) {
                                }
                                val src2 = railSources.toMutableMap()
                                src2[key] = SeeAllRequest(
                                    "More like this", st.title,
                                    st.artist + " songs"
                                )
                                railSources = src2
                                Pair(key, rel)
                            } else null
                        } catch (e: Exception) {
                            null
                        }
                    })
                }
            } catch (e: Exception) {
            }
            // Personalized artist rails from library + YT seeds.
            try {
                for (s in HomeFeed.personalized(liked + ytSeeds, recent.toList())) {
                    if (!homeSections[s.title].isNullOrEmpty()) continue
                    jobs.add({
                        try {
                            val res = YoutubeRepository.searchMusic(s.query, 12)
                            if (res.isNotEmpty()) {
                                try {
                                    SongCache.save(context, s.cacheKey, res)
                                } catch (e: Exception) {
                                }
                                val src3 = railSources.toMutableMap()
                                src3[s.title] = SeeAllRequest(s.title, s.subtitle, s.query)
                                railSources = src3
                                Pair(s.title, res)
                            } else null
                        } catch (e: Exception) {
                            null
                        }
                    })
                }
            } catch (e: Exception) {
            }
            // Parallel rails in batches of 4: tuned OkHttp pool (12 conns,
            // 16/host) sustains this without YouTube throttling; one retry
            // wins. Was sequential + 700ms/rail (~9s for 13 rails) — now
            // ~3 waves. UI paints incrementally per wave for instant feel.
            val railsT0 = try { android.os.SystemClock.elapsedRealtime() } catch (e: Exception) { 0L }
            try {
                for (chunk in jobs.chunked(4)) {
                    try {
                        val doneList = coroutineScope {
                            chunk.map { job ->
                                async(Dispatchers.IO) {
                                    var done: Pair<String, List<YtTrack>>? = null
                                    var attempt = 0
                                    while (attempt < 2 && done == null) {
                                        attempt++
                                        try {
                                            done = job()
                                        } catch (e: Exception) {
                                            if (attempt < 2) delay(800)
                                        }
                                    }
                                    done
                                }
                            }.awaitAll().filterNotNull()
                        }
                        if (doneList.isNotEmpty()) {
                            val cur = homeSections.toMutableMap()
                            for (done in doneList) cur[done.first] = done.second
                            homeSections = cur
                            live = true
                        }
                    } catch (e: Exception) {
                    }
                    try {
                        delay(120)
                    } catch (e: Exception) {
                    }
                }
            } catch (e: Exception) {
            }
            try {
                Log.d(TAG, "home rails done ${try { android.os.SystemClock.elapsedRealtime() - railsT0 } catch (e: Exception) { -1 }}ms")
            } catch (e: Exception) {
            }
            // Heal SeeAll sources: parallel related/personalized jobs mutate
            // railSources off-main and can lose each other's keys (read-modify-
            // write race). Re-register anything present in homeSections here
            // on Main so every rail stays tappable.
            try {
                val src = railSources.toMutableMap()
                var touched = false
                for ((title, tracks) in homeSections) {
                    if (tracks.isNullOrEmpty() || src.containsKey(title)) continue
                    val core = try { HomeFeed.CORE.firstOrNull { it.title == title } } catch (e: Exception) { null }
                    if (core != null) {
                        src[title] = if (core.query == "__charts__") SeeAllRequest(title, core.subtitle, kiosk = true)
                        else SeeAllRequest(title, core.subtitle, core.query)
                    } else {
                        src[title] = SeeAllRequest(title, "", "$title songs")
                    }
                    touched = true
                }
                if (touched) railSources = src
            } catch (e: Exception) {
            }
        } catch (e: Exception) {
            Log.w(TAG, "rails refresh failed", e)
        }
    }

    // Endless explore: append the next discovery rail (cache first, then
    // network). Cycles forever with per-cycle variety.
    fun loadNextRail() {
        if (loadingMoreRails) return
        loadingMoreRails = true
        scope.launch {
            try {
                val pos = endlessRails.size
                val cycle = refreshCount
                val s = HomeFeed.discoveryAt(pos, cycle)
                if (homeSections[s.title].isNullOrEmpty()) {
                    val cached: List<YtTrack>? = try {
                        withContext(Dispatchers.IO) {
                            SongCache.load(context, s.cacheKey, HomeFeed.SECTION_TTL_MS)
                        }
                    } catch (e: Exception) {
                        null
                    }
                    if (!cached.isNullOrEmpty()) {
                        val cur = homeSections.toMutableMap()
                        cur[s.title] = cached
                        homeSections = cur
                        val src = railSources.toMutableMap()
                        src[s.title] = SeeAllRequest(s.title, s.subtitle, s.query)
                        railSources = src
                    }
                }
                if (homeSections[s.title].isNullOrEmpty()) {
                    val res: List<YtTrack> = try {
                        YoutubeRepository.searchMusic(s.query, 12)
                    } catch (e: Exception) {
                        Log.w(TAG, "discovery rail ${s.title} failed", e)
                        emptyList()
                    }
                    if (res.isNotEmpty()) {
                        try {
                            withContext(Dispatchers.IO) {
                                SongCache.save(context, s.cacheKey, res)
                            }
                        } catch (e: Exception) {
                        }
                        val cur = homeSections.toMutableMap()
                        cur[s.title] = res
                        homeSections = cur
                        val src = railSources.toMutableMap()
                        src[s.title] = SeeAllRequest(s.title, s.subtitle, s.query)
                        railSources = src
                        live = true
                    }
                }
                if (!endlessRails.any { it.title == s.title } &&
                    !homeSections[s.title].isNullOrEmpty()
                ) {
                    endlessRails = endlessRails + s
                }
            } catch (e: Exception) {
                Log.w(TAG, "loadNextRail failed", e)
            } finally {
                loadingMoreRails = false
            }
        }
    }

    fun doRefreshHome() {
        refreshCount++
        homeTick++
    }

    // Reconnect reload: when the device regains network, refresh silently.
    // registerDefaultNetworkCallback fires onAvailable immediately for the
    // current network: ignore that first fire or every cold start pays
    // for a cancelled + duplicate home load (extra extractor traffic).
    val netArmed = remember { java.util.concurrent.atomic.AtomicBoolean(false) }
    DisposableEffect(Unit) {
        val cm = try {
            context.getSystemService(android.content.Context.CONNECTIVITY_SERVICE)
                as android.net.ConnectivityManager
        } catch (e: Exception) {
            null
        }
        val cb = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) {
                if (!netArmed.getAndSet(true)) return
                if ((homeTracks.isEmpty() && homeSections.isEmpty()) || !live) {
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

    // Personalized rails fill in late once likes / YT seeds arrive
    // (homeTick may have run before stores finished loading off-main).
    LaunchedEffect(liked.size, ytSeeds.size) {
        try {
            if (liked.isEmpty() && ytSeeds.isEmpty()) return@LaunchedEffect
            val personal = HomeFeed.personalized(liked + ytSeeds, recent.toList())
                .filter { homeSections[it.title].isNullOrEmpty() }
            if (personal.isEmpty()) return@LaunchedEffect
            // Sequential: avoids extractor throttling bursts.
            for (s in personal.take(2)) {
                try {
                    val res: List<YtTrack> = withContext(Dispatchers.IO) {
                        YoutubeRepository.searchMusic(s.query, 12)
                    }
                    if (res.isNotEmpty()) {
                        try {
                            withContext(Dispatchers.IO) {
                                SongCache.save(context, s.cacheKey, res)
                            }
                        } catch (e: Exception) {
                        }
                        val cur = homeSections.toMutableMap()
                        cur[s.title] = res
                        homeSections = cur
                    }
                } catch (e: Exception) {
                }
                try {
                    delay(700)
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
        }
    }

    // Update check: once a day automatically (banner + system
    // notification), plus a manual "Check for updates" in Settings that
    // bypasses the daily gate and reports the result on screen.
    var update by remember { mutableStateOf<UpdateCheck.Update?>(null) }
    var updateChecking by remember { mutableStateOf(false) }
    var updateStatus by remember { mutableStateOf("") }
    // Seamless update: direct APK download for this device, installer on
    // completion. Release page only when no matching asset exists.
    // (watchUpdateDownload first: local funs can't forward-reference.)
    // Download watcher: live % in Settings + one-shot installer pop when
    // the file lands (covers missed/denied notifications).
    fun watchUpdateDownload(tag: String) {
        scope.launch(Dispatchers.IO) {
            try {
                var offered = false
                while (true) {
                    delay(2000)
                    try {
                        val done = UpdateDownload.downloadedFile(context)
                        if (done != null) {
                            withContext(Dispatchers.Main) {
                                updateStatus = "Downloaded — tap to install"
                            }
                            if (!offered) {
                                offered = true
                                if (UpdateDownload.takeOffer(context, tag)) {
                                    withContext(Dispatchers.Main) {
                                        try {
                                            UpdateDownload.installFile(context, done)
                                        } catch (e: Exception) {
                                        }
                                    }
                                }
                            }
                            return@launch
                        }
                        if (!UpdateDownload.hasActiveDownload(context)) return@launch
                        val p = UpdateDownload.queryProgress(context)
                        if (p != null) {
                            val pct = if (p.second > 0L) {
                                ((p.first * 100L) / p.second).toInt().coerceIn(0, 100)
                            } else -1
                            withContext(Dispatchers.Main) {
                                updateStatus = if (pct >= 0) "Downloading $tag… $pct%"
                                else "Downloading $tag…"
                            }
                        }
                    } catch (e: Exception) {
                        return@launch
                    }
                }
            } catch (e: Exception) {
            }
        }
    }
    fun downloadUpdate(u: UpdateCheck.Update?) {
        if (u == null) return
        scope.launch(Dispatchers.IO) {
            try {
                val ready = UpdateDownload.downloadedFile(context)
                if (ready != null) {
                    withContext(Dispatchers.Main) {
                        updateStatus = "Downloaded — opening installer…"
                        try {
                            UpdateDownload.installFile(context, ready)
                        } catch (e: Exception) {
                        }
                    }
                    return@launch
                }
            } catch (e: Exception) {
            }
            if (u.apkUrl.isBlank()) {
                withContext(Dispatchers.Main) {
                    try {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(u.url)))
                    } catch (e: Exception) {
                    }
                }
                return@launch
            }
            withContext(Dispatchers.Main) {
                updateStatus = "Downloading ${u.tag}…"
            }
            val ok = try {
                UpdateDownload.startDownload(context, u)
            } catch (e: Exception) {
                false
            }
            if (ok) {
                watchUpdateDownload(u.tag)
            }
            if (!ok) {
                withContext(Dispatchers.Main) {
                    updateStatus = "Download failed — opening release page"
                    try {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(u.url)))
                    } catch (e: Exception) {
                    }
                }
            }
        }
    }
    fun runUpdateCheck(manual: Boolean) {
        if (updateChecking) return
        updateChecking = true
        if (manual) updateStatus = "Checking…"
        scope.launch {
            try {
                if (!manual && !UpdateCheck.dueForCheck(context)) {
                    return@launch
                }
                val latest = UpdateCheck.latest()
                UpdateCheck.markChecked(context)
                val current = try {
                    UpdateCheck.currentVersion(context)
                } catch (e: Exception) {
                    "0.0.0"
                }
                if (latest != null && UpdateCheck.isNewer(current, latest.tag)) {
                    update = latest
                    if (manual) updateStatus = "Update available: ${latest.tag}"
                    try {
                        UpdateNotify.notifyIfNewer(context, latest)
                    } catch (e: Exception) {
                    }
                } else if (manual) {
                    updateStatus = if (latest == null) {
                        "Couldn't reach updates — try again"
                    } else {
                        "You're up to date ($current)"
                    }
                }
            } catch (e: Exception) {
                if (manual) updateStatus = "Couldn't reach updates — try again"
            } finally {
                updateChecking = false
            }
        }
    }
    LaunchedEffect(Unit) {
        runUpdateCheck(false)
        // Missed completion (notification denied/dismissed): offer the
        // finished APK once instead of leaving it silent in Downloads.
        scope.launch(Dispatchers.IO) {
            try {
                val done = UpdateDownload.downloadedFile(context)
                if (done != null) {
                    val prefs = context.getSharedPreferences("cresca_prefs", android.content.Context.MODE_PRIVATE)
                    val tag = prefs.getString("update_download_tag", "") ?: ""
                    withContext(Dispatchers.Main) {
                        updateStatus = "Downloaded — tap to install"
                    }
                    if (UpdateDownload.takeOffer(context, tag)) {
                        withContext(Dispatchers.Main) {
                            try {
                                UpdateDownload.installFile(context, done)
                            } catch (e: Exception) {
                            }
                        }
                    }
                } else if (UpdateDownload.hasActiveDownload(context)) {
                    val prefs = context.getSharedPreferences("cresca_prefs", android.content.Context.MODE_PRIVATE)
                    watchUpdateDownload(prefs.getString("update_download_tag", "") ?: "")
                }
            } catch (e: Exception) {
            }
        }
    }
    // New releases = latest uploads from YOUR artists' channels
    // (newest-first feeds), refetched when the library changes.
    LaunchedEffect(liked.size) {
        try {
            withContext(Dispatchers.IO) {
                SongCache.load(context, "new", 24 * 60 * 60 * 1000L)
            }?.let { newTracks = it }
        } catch (e: Exception) { }
        try {
            val artists = (HomeFeed.artistSeeds(liked + recent + ytSeeds, 8) +
                listOf("Arijit Singh", "Shreya Ghoshal", "AP Dhillon"))
                .distinct()
            val fresh = YoutubeRepository.newReleases(artists, 12)
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

    // Top Picks from recent taste: collectively last 10 played -> related
    // tracks each (vibe, not same-singer), shuffled. Falls back to home.
    var topVibe by remember { mutableStateOf<List<YtTrack>>(emptyList()) }
    LaunchedEffect(recent.size, homeTracks.size) {
        try {
            val seeds = try {
                recent.toList().take(10).filter { it.watchUrl.isNotBlank() }
            } catch (e: Exception) {
                emptyList()
            }
            if (seeds.size < 2) {
                topVibe = emptyList()
                return@LaunchedEffect
            }
            val pool = ArrayList<YtTrack>()
            withContext(Dispatchers.IO) {
                // 3 related per seed max (network-bounded), sequential.
                for (s in seeds.take(10)) {
                    try {
                        val rel = YoutubeRepository.relatedTracks(s.watchUrl, 3)
                        for (r in rel) {
                            if (pool.none { it.id == r.id } &&
                                seeds.none { it.id == r.id }
                            ) pool.add(r)
                        }
                    } catch (e: Exception) {
                    }
                    if (pool.size >= 24) break
                }
            }
            val shuffled = try {
                pool.shuffled().take(12)
            } catch (e: Exception) {
                pool.take(12)
            }
            if (shuffled.size >= 4) topVibe = shuffled
        } catch (e: Exception) {
        }
    }

    // Ambient motion kill-switch for every row/card/skeleton below.
    androidx.compose.runtime.CompositionLocalProvider(LocalMotion provides motionOn) {
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
                        liked = isLiked(t),
                        onOpen = { showFullPlayer = true },
                        onPrev = { skipPrev() },
                        onPlayPause = { togglePlay(t) },
                        onNext = { skipNext() },
                        onLike = { toggleLike(t) }
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
            // Tab flow: lateral drift in swipe direction + fade (nothing
            // when motion is off). Direction comes free from the transition.
            androidx.compose.animation.AnimatedContent(
                targetState = selectedTab,
                transitionSpec = {
                    val fwd = targetState > initialState
                    Motion.tabEnter(motionOn, fwd) togetherWith
                        Motion.tabExit(motionOn, fwd)
                },
                label = "tabs"
            ) { tab ->
            when (tab) {
                0 -> ListenNowScreen(
                    tracks = homeTracks, recent = recent, live = live,
                    loading = homeLoading, loadError = homeError,
                    sections = homeSections,
                    topPicks = if (topVibe.size >= 4) topVibe else homeTracks,
                    onRetryLoad = { doRefreshHome() },
                    onRefresh = { doRefreshHome() },
                    refreshing = isRefreshing,
                    onLoadMoreRails = { loadNextRail() },
                    loadingMore = loadingMoreRails,
                    endlessCount = endlessRails.size,
                    railRequest = { title -> railSources[title] },
                    onPlay = ::play,
                    onPlayList = ::playList,
                    onMood = { mood -> query = mood; selectedTab = 4 },
                    onSeeAll = { req -> openSeeAll(req) },
                    onPlayNext = { queue.playNext(it) },
                    onAddQueue = { queue.addToQueue(it) },
                    likedOf = { isLiked(it) },
                    onToggleLike = { toggleLike(it) },
                    updateTag = update?.tag,
                    onUpdateTap = {
                        downloadUpdate(update)
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
                    onSeeAll = { req -> openSeeAll(req) }
                )
                2 -> RadioScreen(onStation = { q ->
                    query = q
                    scope.launch {
                        try {
                            // Music-only: plain search leaks episodes/random videos.
                            val res = YoutubeRepository.searchMusic(q, 20)
                            if (res.isNotEmpty()) playList(res, 0)
                        } catch (e: Exception) {
                            Log.w(TAG, "station failed", e)
                        }
                    }
                })
                3 -> LibraryScreen(
                    liked = liked, recent = recent,
                    loggedIn = loggedIn, dlCount = dlItems.size,
                    active = tab == 3,
                    onPlay = ::play,
                    onPlayNext = { queue.playNext(it) },
                    onAddQueue = { queue.addToQueue(it) },
                    likedOf = { isLiked(it) },
                    onToggleLike = { toggleLike(it) },
                    onSignIn = { loginFailed = false; showSession = true },
                    onSignOut = {
                        scope.launch(Dispatchers.IO) {
                            try {
                                YtSessionManager.logout(context)
                            } catch (e: Exception) {
                            }
                            loggedIn = false
                        }
                    },
                    onOpenDownloads = { refreshDownloads(); showDownloads = true },
                    onOpenPlaylist = { openPlaylist(it) },
                    onOpenProfile = { showProfile = true }
                )
            }
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
                smartShuffle = queue.shuffleMode == PlayerQueue.SHUFFLE_SMART,
                repeatMode = queue.repeatModeState,
                liked = isLiked(t),
                videoMode = videoMode,
                videoLoading = videoLoading,
                qualities = qualityLabels(),
                currentQuality = currentQualityLabel(),
                onPlayPause = { togglePlay(t) },
                onPrev = { skipPrev() },
                onNext = { skipNext() },
                onShuffle = { cycleShuffleUi() },
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
                onPlayNext = { queue.playNext(t) },
                onAddQueue = { queue.addToQueue(t) },
                onSeek = { player.seekTo(it) },
                domColor = playerDom,
                onDismiss = {
                    // Video keeps streaming behind the mini-player / other
                    // tabs / background: only the Audio toggle exits video.
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
            onDismiss = { showQueue = false },
            onReordered = { saveSessionNow() }
        )
    }

    // Full-screen video retired: video now embeds in the player sheet.

    // See All is a full page with endless pagination (not a sheet).
    seeAllPage?.let { req ->
        SeeAllScreen(
            req = req,
            likedOf = { isLiked(it) },
            onPlay = { play(it) },
            onPlayList = { list, idx -> playList(list, idx, false) },
            onToggleLike = { toggleLike(it) },
            onAddQueue = { queue.addToQueue(it) },
            onPlayNext = { queue.playNext(it) },
            onBack = { seeAllPage = null }
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
                scope.launch(Dispatchers.IO) {
                    try {
                        YtSessionManager.logout(context)
                    } catch (e: Exception) {
                    }
                    loggedIn = false
                    showSession = false
                }
            },
            onDismiss = {
                scope.launch(Dispatchers.IO) {
                    val ok = try {
                        YtSessionManager.isLoggedIn(context)
                    } catch (e: Exception) {
                        false
                    }
                    loggedIn = ok
                    showSession = false
                }
            }
        )
    }

    // Profile + settings.
    if (showProfile) {
        ProfileSheet(
            loggedIn = loggedIn,
            engineFast = engineFast,
            onEngine = { fast ->
                engineFast = fast
                scope.launch(Dispatchers.IO) {
                    try {
                        context.getSharedPreferences("cresca_prefs", android.content.Context.MODE_PRIVATE)
                            .edit().putBoolean("engine_fast", fast).apply()
                    } catch (e: Exception) {
                    }
                    try {
                        YoutubeRepository.useInnerTube = fast
                    } catch (e: Exception) {
                    }
                }
                try {
                    Log.i(TAG, "engine switched to ${if (fast) "fast-InnerTube" else "stable-NewPipe"}")
                } catch (e: Exception) {
                }
            },
            themeMode = themeMode,
            motionOn = motionOn,
            onMotion = { on ->
                motionOn = on
                scope.launch(Dispatchers.IO) {
                    try {
                        Motion.setOn(context, on)
                    } catch (e: Exception) {
                    }
                }
            },
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
                scope.launch(Dispatchers.IO) {
                    try {
                        YtSessionManager.logout(context)
                    } catch (e: Exception) {
                    }
                    loggedIn = false
                }
            },
            onOpenDownloads = {
                showProfile = false
                refreshDownloads()
                showDownloads = true
            },
            onClearCache = { clearSongCache() },
            updateTag = update?.tag,
            updateChecking = updateChecking,
            updateStatus = updateStatus,
            onCheckUpdate = { runUpdateCheck(true) },
            onUpdateTap = {
                downloadUpdate(update)
            },
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
                scope.launch(Dispatchers.IO) {
                    try {
                        DownloadStore.delete(context, t.id)
                    } catch (e: Exception) {
                    }
                    try {
                        dlItems = DownloadStore.listAll(context)
                    } catch (e: Exception) {
                    }
                }
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
                scope.launch(Dispatchers.IO) {
                    try {
                        PlaylistStore.remove(context, pl.id, t.id)
                    } catch (e: Exception) {
                    }
                    openPlaylist(pl.id)
                }
            },
            onAddSuggested = { t ->
                scope.launch(Dispatchers.IO) {
                    try {
                        PlaylistStore.add(context, pl.id, t)
                    } catch (e: Exception) {
                    }
                    openPlaylist(pl.id)
                }
            },
            onDeletePlaylist = {
                scope.launch(Dispatchers.IO) {
                    try {
                        PlaylistStore.delete(context, pl.id)
                    } catch (e: Exception) {
                    }
                    try {
                        withContext(Dispatchers.Main) { showPlaylist = null }
                    } catch (e: Exception) {
                    }
                }
            },
            onDismiss = { showPlaylist = null }
        )
    }
}

/** Live lyric line overlaid on artwork (title lives below, on the blend). */
@Composable
private fun androidx.compose.foundation.layout.BoxScope.ThumbnailOverlay(
    lyrics: LyricsState,
    position: Long,
    durationMs: Long = 0L
) {
    val overlay = remember(lyrics, position, durationMs) {
        try {
            overlayState(lyrics, position, durationMs)
        } catch (e: Exception) {
            OverlayState("", 0f, false)
        }
    }
    Column(
        Modifier.align(Alignment.BottomStart)
            .fillMaxWidth()
            .padding(start = 20.dp, end = 20.dp, bottom = 14.dp),
        horizontalAlignment = Alignment.Start
    ) {
        if (overlay.line.isNotBlank()) {
            // Box-rolling ticker: each line rolls up into place.
            androidx.compose.animation.AnimatedContent(
                targetState = overlay.line,
                transitionSpec = {
                    (slideInVertically(tween(280)) { h -> h } + fadeIn(tween(280))) togetherWith
                        (slideOutVertically(tween(280)) { h -> -h } + fadeOut(tween(280)))
                },
                label = "overlayRoll"
            ) { rolled ->
                Text(
                    rolled,
                    style = MaterialTheme.typography.bodyMedium.copy(
                        fontWeight = FontWeight.SemiBold
                    ),
                    color = MaterialTheme.colorScheme.primary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(bottom = 4.dp)
                )
            }
        }
        if (overlay.showDots) {
            OverlayDots(frac = overlay.dotsFrac)
            Spacer(Modifier.height(4.dp))
        }
        // Title/artist live BELOW the art now (on the blurred blend):
        // this overlay carries the live lyric line only, never a black box.
    }
}

/** Overlay snapshot: current line + dots fill (pure, unit-friendly). */
private data class OverlayState(
    val line: String,
    val dotsFrac: Float,
    val showDots: Boolean
)

private fun overlayState(
    lyrics: LyricsState,
    positionMs: Long,
    durationMs: Long
): OverlayState {
    if (lyrics !is LyricsState.Synced || lyrics.lines.isEmpty()) {
        return OverlayState("", 0f, false)
    }
    val pos = positionMs.coerceAtLeast(0L)
    val sorted = lyrics.lines.filter { it.text.isNotBlank() }.sortedBy { it.ms }
    if (sorted.isEmpty()) return OverlayState("", 0f, false)
    val line = sorted.indexOfLast { it.ms <= pos }
        .takeIf { it >= 0 }?.let { sorted[it].text } ?: ""
    return try {
        val rows = buildLyricRows(sorted, durationMs)
        val ai = sorted.indexOfLast { it.ms <= pos }
        val ar = activeRowIndex(rows, ai, pos)
        val dots = rows.getOrNull(ar) as? LyricRow.Dots
        if (dots != null) {
            val span = (dots.toMs - dots.fromMs).coerceAtLeast(1L)
            val frac = ((pos - dots.fromMs).toFloat() / span.toFloat()).coerceIn(0f, 1f)
            OverlayState(line, frac, true)
        } else OverlayState(line, 0f, false)
    } catch (e: Exception) {
        OverlayState(line, 0f, false)
    }
}

/** Compact dots for the thumbnail overlay (mirrors the karaoke row). */@Composable
private fun OverlayDots(frac: Float) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.Start),
        verticalAlignment = Alignment.CenterVertically
    ) {
        val filled = (frac.coerceIn(0f, 1f) * 3).toInt().coerceIn(0, 3)
        for (d in 0 until 3) {
            Box(
                modifier = Modifier
                    .size(7.dp)
                    .background(
                        color = if (d < filled) Color.White
                        else Color.White.copy(alpha = 0.25f),
                        shape = androidx.compose.foundation.shape.CircleShape
                    )
            )
        }
    }
}

/** Video mode meta block: name + live lyric BELOW the video, never on it. */
@Composable
private fun VideoMeta(
    track: YtTrack,
    lyrics: LyricsState,
    position: Long,
    durationMs: Long = 0L
) {
    val overlay = remember(lyrics, position, durationMs) {
        try {
            overlayState(lyrics, position, durationMs)
        } catch (e: Exception) {
            OverlayState("", 0f, false)
        }
    }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        if (overlay.line.isNotBlank()) {
            androidx.compose.animation.AnimatedContent(
                targetState = overlay.line,
                transitionSpec = {
                    (slideInVertically(tween(280)) { h -> h } + fadeIn(tween(280))) togetherWith
                        (slideOutVertically(tween(280)) { h -> -h } + fadeOut(tween(280)))
                },
                label = "videoMetaRoll"
            ) { rolled ->
                Text(
                    rolled,
                    style = MaterialTheme.typography.bodyMedium.copy(
                        fontWeight = FontWeight.SemiBold
                    ),
                    color = MaterialTheme.colorScheme.primary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(bottom = 4.dp)
                )
            }
        }
        if (overlay.showDots) {
            OverlayDots(frac = overlay.dotsFrac)
            Spacer(Modifier.height(4.dp))
        }
        Text(
            track.title,
            style = MaterialTheme.typography.titleLarge.copy(
                fontWeight = FontWeight.Bold
            ),
            maxLines = 2, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center
        )
        Text(
            track.artist,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center
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
    smartShuffle: Boolean = false,
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
    onPlayNext: () -> Unit = {},
    onAddQueue: () -> Unit = {},
    onSeek: (Long) -> Unit,
    onDismiss: () -> Unit,
    domColor: Color = Color(0xFF3A0A12)
) {
    // Ferry for the live video frame (InlineVideo grabs → bg below reads).
    val videoFrameHolder = remember { arrayOfNulls<android.graphics.Bitmap>(1) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Color(0xFF121212),
        // Zero content insets: the artwork must bleed under the status
        // bar (the default safe-drawing padding paints the black strip).
        contentWindowInsets = { androidx.compose.foundation.layout.WindowInsets(0, 0, 0, 0) },
        // No slot handle: the art owns the status bar edge-to-edge, and a
        // floating handle rides over it (see art item below).
        dragHandle = null
    ) {
        val dlscope = rememberCoroutineScope()
        val dlctx = LocalContext.current
        // Shared dominant color (also drives the system bars); eased here.
        val domAnimated by animateColorAsState(
            targetValue = domColor, animationSpec = tween(800), label = "dom")
        // The sheet lives in a dialog window with its own system bars:
        // make them transparent + tone the icons from the artwork so the
        // thumbnail truly owns the status bar (no black strip on top).
        val sheetView = LocalView.current
        DisposableEffect(sheetView, domAnimated) {
            try {
                val w = try {
                    (sheetView.parent as?
                        androidx.compose.ui.window.DialogWindowProvider)?.window
                } catch (e: Exception) {
                    null
                }
                if (w != null) {
                    // Edge-to-edge dialog: content draws under the status
                    // bar so the thumbnail covers it (activity flag alone
                    // can't move dialog content).
                    try {
                        WindowCompat.setDecorFitsSystemWindows(w, false)
                    } catch (e: Exception) {
                    }
                    w.statusBarColor = android.graphics.Color.TRANSPARENT
                    w.navigationBarColor = android.graphics.Color.TRANSPARENT
                    // Icon tone from ARTWORK brightness, not the darkened
                    // theme color: domAnimated is the boosted color × 0.5, so
                    // scale back up. Dark art -> white icons and vice versa.
                    val lum = domAnimated.red * 0.2126f +
                        domAnimated.green * 0.7152f + domAnimated.blue * 0.0722f
                    val artLum = (lum * 2.2f).coerceIn(0f, 1f)
                    try {
                        WindowCompat.getInsetsController(w, sheetView).apply {
                            isAppearanceLightStatusBars = artLum > 0.5f
                            isAppearanceLightNavigationBars = artLum > 0.5f
                        }
                    } catch (e: Exception) {
                    }
                }
            } catch (e: Exception) {
            }
            onDispose { }
        }
        AppleMusicTheme(darkTheme = true) {
        Box(Modifier.fillMaxWidth()) {
            // Backdrop is the blurred thumbnail itself (ArtBackdrop below);
            // no lava wash — the sheet is pure artwork tones.
            // Blurred-zoom backdrop: the same thumbnail, zoomed + frosted,
            // fills the whole sheet behind name/lyrics/about so the square
            // edge dissolves everywhere (Spotify-style). Keyed to the track:
            // art + backdrop crossfade as one, never mismatched. In video
            // mode the live video frame does the same job (never a still).
            val vf = try {
                videoFrameHolder[0]
            } catch (e: Exception) {
                null
            }
            if (videoMode && vf != null) {
                VideoBackdrop(frame = vf)
            } else if (!videoMode) {
                ArtBackdrop(track = track, thumbUrl = thumbUrl)
            }
            Surface(
                color = Color.Transparent,
                contentColor = Color.White,
                modifier = Modifier.fillMaxWidth()
            ) {
            LazyColumn(
                state = rememberLazyListState(),
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
            // Full-bleed artwork: edge to edge, top of sheet to the name.
            // Sharp HD layer, frosted blur veil above it (readability),
            // dark scrim melting into the page behind name + lyrics.
            item(key = "art") {
                if (videoMode && track.watchUrl.isNotBlank()) {
                    // Session-driven embed: the music transport owns this
                    // picture. Controls ride below it, right side.
                    var videoFrame by remember(track.id) { mutableStateOf<android.graphics.Bitmap?>(null) }
                    DisposableEffect(track.id) {
                        onDispose {
                            videoFrame = null
                        }
                    }
                    InlineVideo(
                        player = player,
                        loading = videoLoading,
                        qualities = qualities,
                        currentQuality = currentQuality,
                        onQuality = onQuality,
                        modifier = Modifier.fillMaxWidth(),
                        videoKey = track.id,
                        // Never recycle here: Compose may still be drawing
                        // the previous frame (use-after-recycle crash).
                        onFrameGrab = { bmp -> videoFrame = bmp }
                    )
                    // Live-blur video backdrop state for the sheet bg below.
                    videoFrameHolder[0] = videoFrame
                } else {
                    val actx = LocalContext.current
                    val hd = remember(track.id) { hdThumb(track) }
                    var hdOk by remember(track.id) { mutableStateOf(true) }
                    Box(Modifier.fillMaxWidth()) {
                        // Beat breathe (bass pulse, idle fallback). Song
                        // changes slide below — never a pop.
                        val sessionId = try {
                            (player as? androidx.media3.exoplayer.ExoPlayer)?.audioSessionId ?: 0
                        } catch (e: Exception) {
                            0
                        }
                        val beat = rememberBeatLevel(sessionId, isPlaying)
                        // Whisper-gentle: ~1% breathe on the bass pulse.
                        val beatScale = (1f + 0.012f * beat).coerceIn(0.9f, 1.04f)
                        // Floating grab handle over the art (the sheet slot
                        // handle is gone so art owns the status edge).
                        Box(
                            Modifier.align(Alignment.TopCenter)
                                .windowInsetsPadding(
                                    androidx.compose.foundation.layout.WindowInsets.statusBars)
                                .padding(top = 6.dp)
                                .size(36.dp, 4.dp)
                                .clip(RoundedCornerShape(2.dp))
                                .background(Color.White.copy(alpha = 0.55f))
                        )
                        // Song change: new cover slides in from the left and
                        // dissolves into the blurred backdrop beneath — the
                        // sharp layer carries a bottom fade mask, so it has
                        // no edge to seam against the background (no scrim,
                        // no black box anywhere on the art).
                        androidx.compose.animation.AnimatedContent(
                            targetState = track.id,
                            transitionSpec = {
                                (androidx.compose.animation.slideInHorizontally(
                                    androidx.compose.animation.core.tween(450)) { -it } +
                                    androidx.compose.animation.fadeIn(
                                        androidx.compose.animation.core.tween(450))) togetherWith
                                    (androidx.compose.animation.slideOutHorizontally(
                                        androidx.compose.animation.core.tween(450)) { it } +
                                        androidx.compose.animation.fadeOut(
                                            androidx.compose.animation.core.tween(450)))
                            },
                            label = "artSlide"
                        ) {
                            AsyncImage(
                                model = coil.request.ImageRequest.Builder(actx)
                                    .data(if (hdOk) hd else thumbUrl)
                                    .build(),
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                onError = { hdOk = false },
                                modifier = Modifier.fillMaxWidth().aspectRatio(1f)
                                    .graphicsLayer(
                                        scaleX = beatScale,
                                        scaleY = beatScale,
                                        alpha = 0.99f,
                                        compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen
                                    )
                                    .drawWithContent {
                                        drawContent()
                                        drawRect(
                                            brush = Brush.verticalGradient(
                                                0.58f to Color.Black,
                                                1f to Color.Transparent
                                            ),
                                            blendMode = androidx.compose.ui.graphics.BlendMode.DstIn
                                        )
                                    }
                            )
                        }
                        // Live lyric line only (title lives below, on blend).
                        ThumbnailOverlay(
                            lyrics = lyrics,
                            position = position,
                            durationMs = duration
                        )
                    }
                }
            }
            // (Melt tail retired: ArtBackdrop now carries the blend under
            // the whole sheet, edge to About.)
            // Video mode: name + live lyric BELOW the video (never on it).
            if (videoMode && track.watchUrl.isNotBlank()) {
                item(key = "videometa") {
                    VideoMeta(
                        track = track,
                        lyrics = lyrics,
                        position = position,
                        durationMs = duration
                    )
                }
            }
            item(key = "body") {
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                // Name sits BELOW the art, on the blurred blend
                // (reference-style). Skipped in video mode: VideoMeta owns
                // the name there (no duplicates).
                Spacer(Modifier.height(10.dp))
                if (!videoMode) {
                androidx.compose.animation.AnimatedContent(
                    targetState = track.id,
                    transitionSpec = {
                        (androidx.compose.animation.slideInVertically(
                            androidx.compose.animation.core.tween(320)) { h -> h } +
                            androidx.compose.animation.fadeIn(
                                androidx.compose.animation.core.tween(320))) togetherWith
                            (androidx.compose.animation.slideOutVertically(
                                androidx.compose.animation.core.tween(320)) { h -> -h } +
                                androidx.compose.animation.fadeOut(
                                    androidx.compose.animation.core.tween(320)))
                    },
                    label = "songSwap"
                ) {
                    Column(
                        Modifier.fillMaxWidth(),
                        horizontalAlignment = Alignment.Start
                    ) {
                        Text(
                            track.title,
                            style = MaterialTheme.typography.titleLarge.copy(
                                fontWeight = FontWeight.Bold,
                                shadow = Shadow(
                                    color = Color.Black.copy(alpha = 0.6f),
                                    offset = Offset(0f, 2f),
                                    blurRadius = 8f
                                )
                            ),
                            color = Color.White,
                            maxLines = 2, overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            track.artist,
                            style = MaterialTheme.typography.bodyMedium.copy(
                                shadow = Shadow(
                                    color = Color.Black.copy(alpha = 0.6f),
                                    offset = Offset(0f, 2f),
                                    blurRadius = 8f
                                )
                            ),
                            color = Color.White.copy(alpha = 0.85f),
                            maxLines = 1, overflow = TextOverflow.Ellipsis
                        )
                    }
                }
                }
                Spacer(Modifier.height(10.dp))
                // Video mode has its own below-video block (videometa item).
                SleekBar(positionMs = position, durationMs = duration, onSeek = onSeek)
                androidx.compose.animation.AnimatedVisibility(
                    visible = error != null,
                    enter = Motion.fadeRise(LocalMotion.current),
                    label = "playerError"
                ) {
                if (error != null) {
                    Text(error, style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error)
                }
                }
                // Transport: shuffle + prev + play + next + repeat — all live
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // 2nd tap = smart shuffle (preference-ordered Up Next).
                    IconButton(onClick = onShuffle, modifier = Modifier.size(48.dp).pressScale(LocalMotion.current)) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(
                                if (smartShuffle) Icons.Filled.AutoAwesome
                                else Icons.Filled.Shuffle,
                                contentDescription = if (smartShuffle) "Smart shuffle on"
                                else if (shuffleOn) "Shuffle on" else "Shuffle off",
                                tint = if (shuffleOn) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(26.dp)
                            )
                            if (smartShuffle) {
                                Text("smart", style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.primary)
                            }
                        }
                    }
                    IconButton(onClick = onPrev, modifier = Modifier.size(52.dp).pressScale(LocalMotion.current)) {
                        Icon(Icons.Filled.SkipPrevious, contentDescription = "Previous",
                            modifier = Modifier.size(38.dp))
                    }
                    FilledIconButton(onClick = onPlayPause, modifier = Modifier.size(72.dp).pressScale(LocalMotion.current, 0.9f)) {
                        if (buffering) CircularProgressIndicator(
                            modifier = Modifier.size(28.dp), strokeWidth = 3.dp,
                            color = Color.White)
                        else androidx.compose.animation.AnimatedContent(
                            targetState = isPlaying, label = "pp"
                        ) { playing ->
                            Icon(
                                if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                                contentDescription = if (playing) "Pause" else "Play",
                                modifier = Modifier.size(40.dp))
                        }
                    }
                    IconButton(onClick = onNext, modifier = Modifier.size(52.dp).pressScale(LocalMotion.current)) {
                        Icon(Icons.Filled.SkipNext, contentDescription = "Next",
                            modifier = Modifier.size(38.dp))
                    }
                    IconButton(onClick = onRepeat, modifier = Modifier.size(48.dp).pressScale(LocalMotion.current)) {
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
                // Actions: video toggle + like + download + queue + more.
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
                    IconButton(onClick = onLike, modifier = Modifier.pressScale(LocalMotion.current)) {
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
                    // 3-dot overflow: share, playlist, queue, video-site.
                    var moreOpen by remember { mutableStateOf(false) }
                    var showPlPicker by remember { mutableStateOf(false) }
                    var plLists by remember { mutableStateOf<List<Playlist>>(emptyList()) }
                    Box {
                        IconButton(onClick = { moreOpen = true }) {
                            Icon(
                                Icons.Filled.MoreVert, contentDescription = "More options",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        DropdownMenu(expanded = moreOpen, onDismissRequest = { moreOpen = false }) {
                            DropdownMenuItem(
                                text = { Text(if (liked) "Unlike" else "Like") },
                                leadingIcon = {
                                    Icon(
                                        if (liked) Icons.Filled.Favorite
                                        else Icons.Filled.FavoriteBorder,
                                        contentDescription = null
                                    )
                                },
                                onClick = { moreOpen = false; onLike() }
                            )
                            DropdownMenuItem(
                                text = { Text("Add to playlist") },
                                leadingIcon = {
                                    Icon(Icons.Filled.PlaylistAdd, contentDescription = null)
                                },
                                onClick = {
                                    moreOpen = false
                                    dlscope.launch(Dispatchers.IO) {
                                        val loaded = try {
                                            PlaylistStore.list(dlctx)
                                        } catch (e: Exception) {
                                            emptyList()
                                        }
                                        withContext(Dispatchers.Main) {
                                            plLists = loaded
                                            showPlPicker = true
                                        }
                                    }
                                }
                            )
                            DropdownMenuItem(
                                text = { Text("Play next") },
                                leadingIcon = {
                                    Icon(Icons.Filled.SkipNext, contentDescription = null)
                                },
                                onClick = { moreOpen = false; onPlayNext() }
                            )
                            DropdownMenuItem(
                                text = { Text("Add to queue") },
                                leadingIcon = {
                                    Icon(Icons.Filled.QueueMusic, contentDescription = null)
                                },
                                onClick = { moreOpen = false; onAddQueue() }
                            )
                            DropdownMenuItem(
                                text = { Text("Download") },
                                leadingIcon = {
                                    Icon(Icons.Filled.Download, contentDescription = null)
                                },
                                onClick = {
                                    moreOpen = false
                                    dlscope.enqueueDownload(dlctx, track)
                                }
                            )
                            DropdownMenuItem(
                                text = { Text("Share") },
                                leadingIcon = {
                                    Icon(Icons.Filled.Share, contentDescription = null)
                                },
                                onClick = {
                                    moreOpen = false
                                    try {
                                        val send = Intent(Intent.ACTION_SEND).apply {
                                            type = "text/plain"
                                            putExtra(
                                                Intent.EXTRA_TEXT,
                                                "${track.title} - ${track.artist}\n" +
                                                    "https://music.youtube.com/watch?v=${track.id}"
                                            )
                                        }
                                        dlctx.startActivity(
                                            Intent.createChooser(send, "Share song")
                                        )
                                    } catch (e: Exception) {
                                    }
                                }
                            )
                            DropdownMenuItem(
                                text = { Text("Open in YouTube") },
                                leadingIcon = {
                                    Icon(Icons.Filled.OpenInNew, contentDescription = null)
                                },
                                onClick = {
                                    moreOpen = false
                                    try {
                                        val url = track.watchUrl.ifBlank {
                                            "https://music.youtube.com/watch?v=${track.id}"
                                        }
                                        dlctx.startActivity(
                                            Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                        )
                                    } catch (e: Exception) {
                                    }
                                }
                            )
                        }
                    }
                    if (showPlPicker) {
                        PlaylistPickerSheet(
                            track = track,
                            playlists = plLists,
                            onPick = { id ->
                                dlscope.launch(Dispatchers.IO) {
                                    try {
                                        PlaylistStore.add(dlctx, id, track)
                                        val reloaded = PlaylistStore.list(dlctx)
                                        withContext(Dispatchers.Main) {
                                            plLists = reloaded
                                            showPlPicker = false
                                        }
                                    } catch (e: Exception) {
                                        withContext(Dispatchers.Main) {
                                            showPlPicker = false
                                        }
                                    }
                                }
                            },
                            onNew = { name ->
                                dlscope.launch(Dispatchers.IO) {
                                    try {
                                        val p = PlaylistStore.create(dlctx, name)
                                        PlaylistStore.add(dlctx, p.id, track)
                                        val reloaded = PlaylistStore.list(dlctx)
                                        withContext(Dispatchers.Main) {
                                            plLists = reloaded
                                            showPlPicker = false
                                        }
                                    } catch (e: Exception) {
                                        withContext(Dispatchers.Main) {
                                            showPlPicker = false
                                        }
                                    }
                                }
                            },
                            onDismiss = { showPlPicker = false }
                        )
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
            } // body column
            } // body item
            // Karaoke visualizer (own scroller inside, tap line to seek).
            item {
                LyricsView(
                    state = lyrics, positionMs = position, isPlaying = isPlaying,
                    modifier = Modifier.fillMaxWidth().height(420.dp),
                    onLineClick = { ms ->
                        try {
                            onSeek(ms.coerceAtLeast(0L))
                        } catch (e: Exception) {
                        }
                    },
                    durationMs = duration
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
            val res = YoutubeRepository.searchMusic(q, 12)
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
            itemsIndexed(playlist.tracks, key = { i, x -> "$i-${x.id}" }) { _, t ->
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
                itemsIndexed(sugg, key = { i, x -> "$i-${x.id}" }) { _, t ->
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
            itemsIndexed(playlists, key = { i, x -> "$i-${x.id}" }) { _, p ->
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
                painter = painterResource(id = R.drawable.cresca_logo),
                contentDescription = "Cresca",
                modifier = Modifier.fillMaxWidth(0.72f)
                    .graphicsLayer(scaleX = scale, scaleY = scale, alpha = alpha)
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

/** Fancy floating music bar: glow card, live equalizer, round red play.
 * Swipe left = next, swipe right = prev (animated glide + snap-back). */
@Composable
private fun FancyBar(
    track: YtTrack,
    isPlaying: Boolean,
    buffering: Boolean,
    position: Long,
    duration: Long,
    error: String?,
    liked: Boolean = false,
    onOpen: () -> Unit,
    onPrev: () -> Unit,
    onPlayPause: () -> Unit,
    onNext: () -> Unit,
    onLike: () -> Unit = {}
) {
    val swipeScope = rememberCoroutineScope()
    // Glide offset follows the finger; snaps back with an ease on release.
    val offsetX = remember(track.id) {
        androidx.compose.animation.core.Animatable(0f)
    }
    var dragDir by remember(track.id) { mutableIntStateOf(0) }
    Surface(
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        tonalElevation = 6.dp,
        shadowElevation = 10.dp,
        // Card stays pinned: only the inner content glides (see Row below).
        modifier = Modifier.fillMaxWidth()
            .padding(horizontal = 10.dp)
            .pointerInput(track.id) {
                var acc = 0f
                detectHorizontalDragGestures(
                    onDragStart = {
                        acc = 0f
                        dragDir = 0
                    },
                    onDragEnd = {
                        val fire: (() -> Unit)? = try {
                            when {
                                acc < -80 -> onNext
                                acc > 80 -> onPrev
                                else -> null
                            }
                        } catch (e: Exception) {
                            null
                        }
                        try {
                            // Snap back smoothly, then fire (feels physical).
                            swipeScope.launch {
                                try {
                                    offsetX.animateTo(
                                        0f,
                                        androidx.compose.animation.core.tween(260)
                                    )
                                } catch (e: Exception) {
                                    try {
                                        offsetX.snapTo(0f)
                                    } catch (ignored: Exception) {
                                    }
                                }
                                try {
                                    dragDir = 0
                                } catch (e: Exception) {
                                }
                                try {
                                    fire?.invoke()
                                } catch (e: Exception) {
                                }
                            }
                        } catch (e: Exception) {
                            try {
                                fire?.invoke()
                            } catch (ignored: Exception) {
                            }
                            acc = 0f
                        }
                        acc = 0f
                    },
                    onDragCancel = {
                        acc = 0f
                        dragDir = 0
                        swipeScope.launch {
                            try {
                                offsetX.animateTo(
                                    0f, androidx.compose.animation.core.tween(260)
                                )
                            } catch (e: Exception) {
                                try {
                                    offsetX.snapTo(0f)
                                } catch (ignored: Exception) {
                                }
                            }
                        }
                    },
                    onHorizontalDrag = { change, dragAmount ->
                        acc += dragAmount
                        try {
                            dragDir = when {
                                acc < -24 -> -1
                                acc > 24 -> 1
                                else -> 0
                            }
                        } catch (e: Exception) {
                        }
                        swipeScope.launch {
                            try {
                                offsetX.snapTo(
                                    (offsetX.value + dragAmount).coerceIn(-220f, 220f)
                                )
                            } catch (e: Exception) {
                            }
                        }
                        try {
                            change.consume()
                        } catch (e: Exception) {
                        }
                    }
                )
            }
            .clickable { onOpen() }
    ) {
        Box {
            // Direction peek: chevrons fade in as you drag.
            if (dragDir != 0) {
                val peekAlpha = try {
                    (kotlin.math.abs(offsetX.value) / 80f).coerceIn(0f, 1f)
                } catch (e: Exception) {
                    0f
                }
                Box(
                    Modifier.fillMaxWidth().align(Alignment.Center)
                        .padding(horizontal = 18.dp),
                    contentAlignment = if (dragDir < 0) Alignment.CenterEnd
                    else Alignment.CenterStart
                ) {
                    Icon(
                        if (dragDir < 0) Icons.Filled.SkipNext
                        else Icons.Filled.SkipPrevious,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary.copy(alpha = peekAlpha),
                        modifier = Modifier.size(30.dp)
                    )
                }
            }
        Column(Modifier.padding(start = 10.dp, end = 10.dp, top = 10.dp, bottom = 8.dp)) {
            // Only this row glides with the finger; the card + progress stay put.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.graphicsLayer {
                    translationX = try {
                        offsetX.value
                    } catch (e: Exception) {
                        0f
                    }
                    alpha = try {
                        (1f - kotlin.math.abs(offsetX.value) / 500f).coerceIn(0.45f, 1f)
                    } catch (e: Exception) {
                        1f
                    }
                }
            ) {
                TrackArt(track.thumbUrl, track.id.hashCode(), 54.dp, 16.dp)
                Spacer(Modifier.width(12.dp))
                // Song swap: title/artist crossfade+rise on every change.
                androidx.compose.animation.AnimatedContent(
                    targetState = track.id,
                    transitionSpec = {
                        (androidx.compose.animation.fadeIn(
                            androidx.compose.animation.core.tween(280)) +
                            androidx.compose.animation.slideInVertically(
                                androidx.compose.animation.core.tween(280)) { h -> h / 2 }) togetherWith
                            androidx.compose.animation.fadeOut(
                                androidx.compose.animation.core.tween(200))
                    },
                    label = "miniSwap",
                    modifier = Modifier.weight(1f)
                ) {
                    Column {
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
                }
                // Mini-player like shortcut (no need to open the sheet).
                IconButton(onClick = onLike, modifier = Modifier.size(40.dp).pressScale(LocalMotion.current)) {
                    Icon(
                        if (liked) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                        contentDescription = if (liked) "Unlike" else "Like",
                        tint = if (liked) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(24.dp)
                    )
                }
                if (buffering) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(24.dp).padding(4.dp), strokeWidth = 2.dp)
                } else {
                    Surface(
                        shape = androidx.compose.foundation.shape.CircleShape,
                        color = Color(0xFFFA243C),
                        modifier = Modifier.size(44.dp).pressScale(LocalMotion.current, 0.9f).clickable { onPlayPause() }
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            androidx.compose.animation.AnimatedContent(
                                targetState = isPlaying, label = "ppmini"
                            ) { playing ->
                                Icon(
                                    if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                                    contentDescription = if (playing) "Pause" else "Play",
                                    tint = Color.White,
                                    modifier = Modifier.size(26.dp)
                                )
                            }
                        }
                    }
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
        } // direction-peek Box
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
        for (i in 0 until 3) {
            val h by inf.animateFloat(
                initialValue = 0.3f,
                targetValue = 1f,
                animationSpec = infiniteRepeatable(
                    animation = tween(durationMillis = 650 + i * 140, easing = { it }),
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
    // Scrub feel: knob swells + glow deepens while held.
    val motion = LocalMotion.current
    val knobR by animateFloatAsState(
        targetValue = if (dragging && motion) 8.5f else 6f,
        animationSpec = tween(160), label = "knob"
    )
    val glowR by animateFloatAsState(
        targetValue = if (dragging && motion) 15f else 11f,
        animationSpec = tween(160), label = "knobGlow"
    )
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
                    radius = glowR.dp.toPx(),
                    center = androidx.compose.ui.geometry.Offset(fw, cy)
                )
                drawCircle(
                    color = Color.White,
                    radius = knobR.dp.toPx(),
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
    engineFast: Boolean = false,
    onEngine: (Boolean) -> Unit = {},
    themeMode: String,
    motionOn: Boolean = true,
    onMotion: (Boolean) -> Unit = {},
    dlLoc: String,
    dlCount: Int,
    onTheme: (String) -> Unit,
    onLoc: (String) -> Unit,
    onSignIn: () -> Unit,
    onSignOut: () -> Unit,
    onOpenDownloads: () -> Unit,
    onClearCache: () -> Unit,
    updateTag: String? = null,
    updateChecking: Boolean = false,
    updateStatus: String = "",
    onCheckUpdate: () -> Unit = {},
    onUpdateTap: () -> Unit = {},
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
                        color = Color.Black,
                        modifier = Modifier.size(56.dp)
                    ) {
                        Image(
                            painter = painterResource(id = R.drawable.cresca_icon),
                            contentDescription = "Cresca",
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize()
                        )
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
                SectionHeader("Playback engine")
            }
            item {
                Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp)) {
                    Text(
                        if (engineFast) "Fast — on-device InnerTube (instant, needs login for best reliability)"
                        else "Stable — NewPipe extraction (compatible everywhere)",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(
                            selected = !engineFast,
                            onClick = { onEngine(false) },
                            label = { Text("Stable") },
                            modifier = Modifier.weight(1f)
                        )
                        FilterChip(
                            selected = engineFast,
                            onClick = { onEngine(true) },
                            label = { Text("Fast") },
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
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
                            modifier = Modifier.weight(1f).pressScale(motionOn)
                        )
                    }
                }
            }
            item {
                Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp)) {
                    Text("Motion",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(
                            selected = motionOn,
                            onClick = { onMotion(true) },
                            label = { Text("On") },
                            modifier = Modifier.weight(1f)
                        )
                        FilterChip(
                            selected = !motionOn,
                            onClick = { onMotion(false) },
                            label = { Text("Off") },
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
                val pctx = LocalContext.current
                var hasCrash by remember { mutableStateOf(false) }
                // Real installed version (never a hardcoded string that rots).
                var appVer by remember { mutableStateOf("") }
                LaunchedEffect(Unit) {
                    hasCrash = try {
                        withContext(Dispatchers.IO) {
                            CrashLog.latest(pctx) != null
                        }
                    } catch (e: Exception) {
                        false
                    }
                    appVer = try {
                        withContext(Dispatchers.IO) {
                            UpdateCheck.currentVersion(pctx)
                        }
                    } catch (e: Exception) {
                        ""
                    }
                }
                ListItem(
                    headlineContent = {
                        Text(
                            if (appVer.isNotBlank()) "Cresca Music $appVer"
                            else "Cresca Music"
                        )
                    },
                    supportingContent = {
                        Text("Live YouTube audio • karaoke lyrics • offline mode")
                    },
                    leadingContent = {
                        Icon(Icons.Filled.Info, contentDescription = null)
                    }
                )
                if (updateTag != null) {
                    ListItem(
                        headlineContent = { Text("Update available: $updateTag") },
                        supportingContent = { Text("Tap to download the latest release") },
                        leadingContent = {
                            Icon(Icons.Filled.SystemUpdate, contentDescription = null)
                        },
                        modifier = Modifier.clickable { onUpdateTap() }
                    )
                }
                ListItem(
                    headlineContent = { Text("Check for updates") },
                    supportingContent = {
                        Text(
                            when {
                                updateChecking -> "Checking…"
                                updateStatus.isNotBlank() -> updateStatus
                                else -> "Latest check: automatic, once a day"
                            }
                        )
                    },
                    leadingContent = {
                        if (updateChecking) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(24.dp), strokeWidth = 2.dp
                            )
                        } else {
                            Icon(Icons.Filled.Refresh, contentDescription = null)
                        }
                    },
                    modifier = Modifier.clickable {
                        if (!updateChecking) onCheckUpdate()
                    }
                )
                if (hasCrash) {
                    ListItem(
                        headlineContent = { Text("Share crash log") },
                        supportingContent = {
                            Text("Sends the last crash report (stays on device until you share)")
                        },
                        leadingContent = {
                            Icon(Icons.Filled.BugReport, contentDescription = null)
                        },
                        modifier = Modifier.clickable {
                            try {
                                CrashLog.shareLatest(pctx)
                            } catch (e: Exception) {
                            }
                        }
                    )
                }
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
    tracks: List<YtTrack>, recent: List<YtTrack>, live: Boolean,
    loading: Boolean, loadError: String?,
    onRetryLoad: () -> Unit, onRefresh: () -> Unit, refreshing: Boolean,
    onLoadMoreRails: () -> Unit, loadingMore: Boolean, endlessCount: Int,
    railRequest: (String) -> SeeAllRequest?,
    onPlay: (YtTrack) -> Unit,
    onPlayList: (List<YtTrack>, Int, Boolean) -> Unit,
    onMood: (String) -> Unit, onSeeAll: (SeeAllRequest) -> Unit,
    onPlayNext: (YtTrack) -> Unit, onAddQueue: (YtTrack) -> Unit,
    likedOf: (YtTrack) -> Boolean, onToggleLike: (YtTrack) -> Unit,
    updateTag: String? = null, onUpdateTap: () -> Unit = {},
    sections: Map<String, List<YtTrack>> = emptyMap(),
    topPicks: List<YtTrack> = emptyList(),
    resumeTrack: YtTrack? = null,
    resumePosMs: Long = 0L,
    onResume: (YtTrack) -> Unit = {}
) {
    // Pull-down-to-refresh (hard pull): no refresh button; drag from the top.
    val listState = rememberLazyListState()
    var pullPx by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(refreshing) {
        if (!refreshing) {
            try {
                pullPx = 0f
            } catch (e: Exception) {
            }
        }
    }
    // Slow release without fling: finger lifts past threshold -> refresh.
    LaunchedEffect(listState.isScrollInProgress, pullPx) {
        try {
            if (!listState.isScrollInProgress && pullPx > 200f && !refreshing && !loading) {
                pullPx = 0f
                onRefresh()
            }
        } catch (e: Exception) {
        }
    }
    val nested = remember(listState, refreshing, loading) {
        object : NestedScrollConnection {
            override fun onPreScroll(
                available: Offset,
                source: NestedScrollSource
            ): Offset {
                try {
                    val atTop = try {
                        listState.firstVisibleItemIndex == 0 &&
                            listState.firstVisibleItemScrollOffset == 0
                    } catch (e: Exception) {
                        true
                    }
                    // Accept every input source (Drag is deprecated alias of
                    // UserInput on newer Compose; old check never matched).
                    if (atTop && available.y > 0 && !refreshing && !loading) {
                        pullPx = (pullPx + available.y * 0.6f).coerceIn(0f, 340f)
                        // Consume so the list stays pinned while pulling.
                        return available
                    }
                    if (pullPx > 0f && available.y < 0) {
                        val consume = minOf(-available.y, pullPx)
                        pullPx -= consume
                        return Offset(0f, -consume)
                    }
                } catch (e: Exception) {
                }
                return Offset.Zero
            }

            override suspend fun onPreFling(available: Velocity): Velocity {
                try {
                    // Hard pull threshold (~200px): release to refresh.
                    if (pullPx > 200f && !refreshing && !loading) {
                        pullPx = 0f
                        try {
                            onRefresh()
                        } catch (e: Exception) {
                        }
                    } else {
                        pullPx = 0f
                    }
                } catch (e: Exception) {
                }
                return super.onPreFling(available)
            }

            override suspend fun onPostFling(
                consumed: Velocity,
                available: Velocity
            ): Velocity {
                try {
                    if (pullPx > 200f && !refreshing && !loading) {
                        pullPx = 0f
                        try {
                            onRefresh()
                        } catch (e: Exception) {
                        }
                    }
                } catch (e: Exception) {
                }
                return super.onPostFling(consumed, available)
            }
        }
    }
    Box(Modifier.fillMaxSize().nestedScroll(nested)) {
    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 16.dp)
    ) {
        item {
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Listen Now", style = MaterialTheme.typography.displaySmall)
                if (refreshing || loading) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp), strokeWidth = 2.dp
                    )
                }
            }
            Text(
                "Pull down hard to refresh",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 2.dp)
            )
            // Empty states: spinner while loading, retry when offline. No demo.
            if (tracks.isEmpty() && loading) {
                if (LocalMotion.current) HomeSkeleton()
                else Box(
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
            androidx.compose.animation.AnimatedVisibility(
                visible = tracks.isEmpty() && !loading && loadError != null,
                enter = Motion.fadeRise(LocalMotion.current),
                label = "homeError"
            ) {
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
            }
            SectionHeader(
                "Top Picks For You",
                onSeeAll = {
                    val picks = if (topPicks.isNotEmpty()) topPicks else tracks
                    onSeeAll(
                        railRequest("Top Picks For You")
                            ?: SeeAllRequest("Top Picks For You", static = picks)
                    )
                },
                trailing = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(
                            onClick = {
                                val picks = if (topPicks.isNotEmpty()) topPicks else tracks
                                if (picks.isNotEmpty()) onPlayList(picks, 0, false)
                            },
                            enabled = (if (topPicks.isNotEmpty()) topPicks else tracks).isNotEmpty(),
                            modifier = Modifier.size(36.dp)
                        ) {
                            Icon(Icons.Filled.PlayArrow, contentDescription = "Play all")
                        }
                        IconButton(
                            onClick = {
                                val picks = if (topPicks.isNotEmpty()) topPicks else tracks
                                if (picks.isNotEmpty()) onPlayList(picks, 0, true)
                            },
                            enabled = (if (topPicks.isNotEmpty()) topPicks else tracks).isNotEmpty(),
                            modifier = Modifier.size(36.dp)
                        ) {
                            Icon(Icons.Filled.Shuffle, contentDescription = "Shuffle")
                        }
                    }
                }
            )
        }
        if (updateTag != null) {
            item {
                androidx.compose.animation.AnimatedVisibility(
                    visible = true,
                    enter = Motion.fadeRise(LocalMotion.current),
                    label = "updateBanner"
                ) {
                Surface(
                    shape = RoundedCornerShape(16.dp),
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp)
                        .pressScale(LocalMotion.current)
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
        }
        // Top Picks: recent-taste vibe (last 10 related, shuffled), 2X grid.
        // Tap queues the visible dozen so Up Next is the curated list.
        item {
            val picks = if (topPicks.isNotEmpty()) topPicks else tracks
            TopPicksGrid(
                tracks = picks.take(12),
                onPlayList = { list, idx -> onPlayList(list, idx, false) }
            )
        }
        // Recently Played = only songs actually played (persisted lifetime
        // list). Never backfill with home tracks — that was the "random
        // songs I never played" bug. Empty history hides the section.
        if (recent.isNotEmpty()) {
            item {
                SectionHeader(
                    "Recently Played",
                    onSeeAll = {
                        onSeeAll(SeeAllRequest("Recently Played", static = recent.toList()))
                    }
                )
            }
            // Recently Played cascade: 4 songs per column, new columns
            // scroll horizontally (never long vertical rows).
            item {
                RecentCascade(
                    tracks = recent.take(16),
                    likedOf = likedOf,
                    onPlayList = { list, idx -> onPlayList(list, idx, false) },
                    onPlayNext = onPlayNext,
                    onAddQueue = onAddQueue,
                    onToggleLike = onToggleLike
                )
            }
        }
        // (New Releases home rail removed: the curated Released playlist
        // rail is the single fresh-drops shelf. Browse tab keeps its own.)
        // YT Music variety rails: Released (curated playlist, pinned first) /
        // Charts / Trending / Punjabi / Lofi / Workout / Party / Romantic +
        // mixes + personalized. Staggered cascade entrance (60ms/rail).
        val railOrder = (listOf(HomeFeed.RELEASED.title) + HomeFeed.CORE.map { it.title } + sections.keys)
            .distinct()
            .filter { it != "Top Picks For You" && it != "New Releases" }
        for ((ri, railTitle) in railOrder.withIndex()) {
            val rail = sections[railTitle] ?: continue
            if (rail.isEmpty()) continue
            item {
                androidx.compose.animation.AnimatedVisibility(
                    visible = true,
                    enter = if (LocalMotion.current) (
                        androidx.compose.animation.fadeIn(
                            androidx.compose.animation.core.tween(
                                300, delayMillis = (ri * 60).coerceAtMost(420))) +
                        androidx.compose.animation.slideInVertically(
                            androidx.compose.animation.core.tween(
                                300, delayMillis = (ri * 60).coerceAtMost(420))) { it / 4 }
                    ) else androidx.compose.animation.fadeIn(
                        androidx.compose.animation.core.tween(1)),
                    label = "rail$ri"
                ) {
                val sub = try {
                    (HomeFeed.CORE + HomeFeed.RELEASED).firstOrNull { it.title == railTitle }?.subtitle ?: ""
                } catch (e: Exception) {
                    ""
                }
                Column {
                    SectionHeader(
                        railTitle,
                        onSeeAll = {
                            onSeeAll(railRequest(railTitle) ?: SeeAllRequest(railTitle, static = rail))
                        }
                    )
                    if (sub.isNotBlank()) {
                        Text(sub,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 16.dp, bottom = 4.dp))
                    }
                }
                }
            }
            item {
                androidx.compose.animation.AnimatedVisibility(
                    visible = true,
                    enter = androidx.compose.animation.fadeIn(
                        androidx.compose.animation.core.tween(
                            280, delayMillis = (ri * 60).coerceAtMost(420))),
                    label = "railrow$ri"
                ) {
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    val railList = rail.take(12)
                    itemsIndexed(railList) { idx, t ->
                        Column(Modifier.width(150.dp).pressScale(LocalMotion.current).clickable { onPlayList(railList, idx, false) }) {
                            TrackArt(t.thumbUrl, t.id.hashCode() + idx + railTitle.hashCode(), 150.dp, 12.dp)
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
        }
        // Pattern break below the songs: mood tiles that deep-search
        item {
            SectionHeader("Moods")
            MoodPatternRow(onMood = onMood)
            Spacer(Modifier.height(8.dp))
        }
        // Endless explore: reaching the bottom appends the next discovery
        // rail forever (auto-loads when visible, button as fallback).
        item(key = "endless-footer") {
            LaunchedEffect(endlessCount) {
                onLoadMoreRails()
            }
            Box(
                Modifier.fillMaxWidth().padding(vertical = 16.dp),
                contentAlignment = Alignment.Center
            ) {
                if (loadingMore) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator(modifier = Modifier.size(28.dp), strokeWidth = 3.dp)
                        Spacer(Modifier.height(8.dp))
                        Text("Exploring more…",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                } else {
                    OutlinedButton(onClick = onLoadMoreRails) {
                        Icon(Icons.Filled.Explore, contentDescription = null,
                            modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Explore more")
                    }
                }
            }
        }
    }
    // Pull indicator: grows with the hard pull, spins while refreshing,
    // fades (not snaps) on release.
    androidx.compose.animation.AnimatedVisibility(
        visible = pullPx > 8f || refreshing,
        exit = androidx.compose.animation.fadeOut(
            androidx.compose.animation.core.tween(250)),
        label = "pullInd"
    ) {
    if (pullPx > 8f || refreshing) {
        val p = try {
            (pullPx / 200f).coerceIn(0f, 1f)
        } catch (e: Exception) {
            0f
        }
        Box(
            Modifier.fillMaxWidth().padding(top = 10.dp),
            contentAlignment = Alignment.TopCenter
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.graphicsLayer {
                    translationY = -40f * (1f - p) - 10f
                    alpha = 0.4f + 0.6f * p
                }
            ) {
                if (refreshing) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(22.dp), strokeWidth = 2.5.dp
                    )
                    Text(
                        "Refreshing…",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                } else if (pullPx > 200f) {
                    Text(
                        "Release to refresh",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.primary
                    )
                } else {
                    Text(
                        "Pull harder to refresh",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                }
            }
        }
    }
    } // pull-to-refresh Box
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
    onToggleLike: () -> Unit,
    compact: Boolean = false,
    modifier: Modifier = Modifier
) {
    val motion = LocalMotion.current
    ListItem(        headlineContent = {
            Text(track.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = if (isCurrent) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurface)
        },
        supportingContent = { Text(track.artist, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        leadingContent = {
            TrackArt(
                track.thumbUrl, track.id.hashCode(),
                if (compact) 44.dp else 52.dp, 8.dp
            )
        },
        trailingContent = {
            TrackMenu(
                track = track, liked = liked, onPlay = onPlay,
                onPlayNext = onPlayNext, onAddQueue = onAddQueue,
                onToggleLike = onToggleLike
            )
        },
        // Note: list placement animation (animateItem) doesn't exist in
        // this BOM's foundation version — lists rely on stagger + fades.
        // Only press physics here (scope-free).
        modifier = modifier
            .pressScale(motion)
            .clickable { onPlay() }
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
                        withContext(Dispatchers.Main) {
                            plists = loaded
                            showPicker = true
                        }
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
                        val reloaded = PlaylistStore.list(context)
                        withContext(Dispatchers.Main) {
                            plists = reloaded
                            showPicker = false
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            showPicker = false
                        }
                    }
                }
            },
            onNew = { name ->
                dlscope.launch(Dispatchers.IO) {
                    try {
                        val p = PlaylistStore.create(context, name)
                        PlaylistStore.add(context, p.id, track)
                        val reloaded = PlaylistStore.list(context)
                        withContext(Dispatchers.Main) {
                            plists = reloaded
                            showPicker = false
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            showPicker = false
                        }
                    }
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
    onDismiss: () -> Unit,
    onReordered: () -> Unit = {}
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
            Text("Queue (${queue.items.size})", style = MaterialTheme.typography.titleLarge)
            val shuffleLabel = when (queue.shuffleMode) {
                PlayerQueue.SHUFFLE_SMART -> "smart shuffled"
                PlayerQueue.SHUFFLE_ON -> "shuffled"
                else -> null
            }
            if (shuffleLabel != null) {
                Text(shuffleLabel, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary)
            }
        }
        // prev songs == current song == next songs (play order).
        val po = try {
            queue.playOrder()
        } catch (e: Exception) {
            emptyList()
        }
        val curPos = po.indexOf(queue.currentIndex)
        // Chronological prev so the whole list is one contiguous play
        // order (makes manual drag reorder math trivial).
        val prev: List<Int>
        val next: List<Int>
        if (curPos == -1) {
            prev = queue.items.indices.filter { it < queue.currentIndex }
            next = queue.items.indices.filter { it > queue.currentIndex }
        } else {
            prev = po.subList(0, curPos)
            next = po.subList(curPos + 1, po.size)
        }
        // Opens at Now Playing: scroll up for prev, down for next.
        val startIndex = if (prev.isEmpty()) 0 else prev.size + 1
        val listState = rememberLazyListState(
            initialFirstVisibleItemIndex = startIndex.coerceAtLeast(0)
        )
        // Manual shuffle: long-press the handle and drag rows around.
        var rowPx by remember { mutableIntStateOf(0) }
        var dragIdx by remember { mutableStateOf<Int?>(null) }
        var dragPos by remember { mutableStateOf<Int?>(null) }
        var dragAcc by remember { mutableFloatStateOf(0f) }
        fun beginDrag(idx: Int, orderPos: Int) {
            dragIdx = idx
            dragPos = orderPos
            dragAcc = 0f
        }
        fun moveDrag(dy: Float) {
            val dp = dragPos
            if (dp == null || rowPx <= 0) return
            dragAcc += dy
            val step = (dragAcc / rowPx).toInt()
            if (step != 0) {
                val size = try {
                    queue.playOrder().size
                } catch (e: Exception) {
                    return
                }
                if (size <= 0) return
                val target = (dp + step).coerceIn(0, size - 1)
                if (target != dp) {
                    queue.moveInOrder(dp, target)
                    dragPos = target
                    dragAcc -= (target - dp) * rowPx
                } else {
                    dragAcc = 0f
                }
            }
        }
        fun endDrag() {
            dragIdx = null
            dragPos = null
            dragAcc = 0f
            onReordered()
        }
        LazyColumn(Modifier.fillMaxWidth(), state = listState) {
            if (prev.isNotEmpty()) {
                item(key = "q-prev-h") {
                    Text("Previous (${prev.size})",
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 4.dp))
                }
                items(prev, key = { "q-prev-$it" }) { idx ->
                    val t = queue.items.getOrNull(idx) ?: return@items
                    val orderPos = try {
                        po.indexOf(idx)
                    } catch (e: Exception) {
                        -1
                    }
                    QueueRow(
                        t = t, isCurrent = false,
                        dragging = dragIdx == idx,
                        onSize = { h -> if (rowPx == 0 && h > 0) rowPx = h },
                        onDragStart = { beginDrag(idx, orderPos) },
                        onDrag = { dy -> moveDrag(dy) },
                        onDragEnd = { endDrag() },
                        onPlay = { onPlayAt(idx) },
                        onRemove = { onRemove(idx) }
                    )
                }
            }
            item(key = "q-cur-h") {
                Text("Now Playing",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 4.dp))
            }
            queue.current?.let { t ->
                item(key = "q-cur") {
                    QueueRow(t, true, false, {}, {}, {}, {}, { }, { })
                }
            }
            item(key = "q-next-h") {
                Text("Up Next (${next.size})",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 4.dp))
            }
            if (next.isNotEmpty()) {
                items(next, key = { "q-next-$it" }) { idx ->
                    val t = queue.items.getOrNull(idx) ?: return@items
                    val orderPos = try {
                        po.indexOf(idx)
                    } catch (e: Exception) {
                        -1
                    }
                    QueueRow(
                        t = t, isCurrent = false,
                        dragging = dragIdx == idx,
                        onSize = { h -> if (rowPx == 0 && h > 0) rowPx = h },
                        onDragStart = { beginDrag(idx, orderPos) },
                        onDrag = { dy -> moveDrag(dy) },
                        onDragEnd = { endDrag() },
                        onPlay = { onPlayAt(idx) },
                        onRemove = { onRemove(idx) }
                    )
                }
            } else {
                item(key = "q-next-empty") {
                    Text("Related songs appear here as you listen.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
                }
            }
            item { Spacer(Modifier.height(32.dp)) }
        }
    }
}

@Composable
private fun QueueRow(
    t: YtTrack,
    isCurrent: Boolean,
    dragging: Boolean = false,
    onSize: (Int) -> Unit = {},
    onDragStart: () -> Unit = {},
    onDrag: (Float) -> Unit = {},
    onDragEnd: () -> Unit = {},
    onPlay: () -> Unit,
    onRemove: () -> Unit,
    modifier: Modifier = Modifier
) {
    val motion = LocalMotion.current
    // Drag lift: rises + grows while held, settles on drop.
    val lift by animateFloatAsState(
        targetValue = if (dragging && motion) 1f else 0f,
        animationSpec = tween(180), label = "lift"
    )
    ListItem(
        headlineContent = {
            Text(t.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = if (isCurrent) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurface)
        },
        supportingContent = { Text(t.artist, maxLines = 1) },
        leadingContent = { TrackArt(t.thumbUrl, t.id.hashCode(), 48.dp, 8.dp) },
        trailingContent = {
            if (isCurrent) {
                Icon(Icons.Filled.Equalizer, contentDescription = "Playing",
                    tint = MaterialTheme.colorScheme.primary)
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    // Long-press and drag to shuffle manually.
                    Icon(
                        Icons.Filled.DragHandle, contentDescription = "Reorder",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.pointerInput(t.id) {
                            detectDragGesturesAfterLongPress(
                                onDragStart = { onDragStart() },
                                onDragEnd = { onDragEnd() },
                                onDragCancel = { onDragEnd() },
                                onDrag = { _, dragAmount -> onDrag(dragAmount.y) }
                            )
                        }
                    )
                    IconButton(onClick = onRemove) {
                        Icon(Icons.Filled.Close, contentDescription = "Remove")
                    }
                }
            }
        },
        modifier = modifier
            .onGloballyPositioned { onSize(it.size.height) }
            .graphicsLayer(
                scaleX = 1f + 0.03f * lift,
                scaleY = 1f + 0.03f * lift,
                shadowElevation = 12f * lift
            )
            .let { m ->
                val m2 = if (dragging) m.background(MaterialTheme.colorScheme.primaryContainer) else m
                if (isCurrent) m2 else m2.pressScale(motion).clickable { onPlay() }
            }
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SeeAllScreen(
    req: SeeAllRequest,
    likedOf: (YtTrack) -> Boolean,
    onPlay: (YtTrack) -> Unit,
    onPlayList: (List<YtTrack>, Int) -> Unit,
    onToggleLike: (YtTrack) -> Unit,
    onAddQueue: (YtTrack) -> Unit,
    onPlayNext: (YtTrack) -> Unit,
    onBack: () -> Unit
) {
    var items by remember(req) { mutableStateOf<List<YtTrack>>(req.static) }
    var loadingMore by remember(req) { mutableStateOf(false) }
    var exhausted by remember(req) { mutableStateOf(req.static.isNotEmpty()) }
    var firstLoading by remember(req) { mutableStateOf(req.static.isEmpty()) }
    // Stateful endless pager (extractor continuation, SimpMusic pattern).
    val pager = remember(req) {
        when {
            req.kiosk -> YoutubeRepository.KioskPager()
            req.query.isNotBlank() -> YoutubeRepository.SearchPager(req.query, req.music)
            else -> null
        }
    }
    val listState = rememberLazyListState()
    val loadScope = rememberCoroutineScope()
    fun loadMoreNow() {
        val p = pager ?: return
        if (loadingMore || exhausted) return
        loadingMore = true
        loadScope.launch(Dispatchers.IO) {
            try {
                val more = p.loadMore()
                if (more.isNotEmpty()) {
                    items = items + more
                }
                exhausted = p.exhausted
            } catch (e: Exception) {
            } finally {
                loadingMore = false
            }
        }
    }
    // Initial page for query/kiosk kinds.
    LaunchedEffect(req) {
        val p = pager ?: return@LaunchedEffect
        firstLoading = true
        try {
            val first = p.loadMore()
            items = first
            exhausted = p.exhausted
        } catch (e: Exception) {
        } finally {
            firstLoading = false
        }
    }
    // Endless: near the bottom, fetch the next continuation page.
    LaunchedEffect(listState, items.size) {
        try {
            val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1
            if (last >= items.size - 4 && !loadingMore && !exhausted && pager != null) {
                loadMoreNow()
            }
        } catch (e: Exception) {
        }
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(req.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (req.subtitle.isNotBlank()) {
                            Text(req.subtitle, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(
                        onClick = { if (items.isNotEmpty()) onPlayList(items, 0) },
                        enabled = items.isNotEmpty()
                    ) {
                        Icon(Icons.Filled.PlayArrow, contentDescription = "Play all")
                    }
                    IconButton(
                        onClick = {
                            // Shuffle-play the loaded items.
                            val sh = items.shuffled()
                            if (sh.isNotEmpty()) onPlayList(sh, 0)
                        },
                        enabled = items.isNotEmpty()
                    ) {
                        Icon(Icons.Filled.Shuffle, contentDescription = "Shuffle")
                    }
                }
            )
        }
    ) { pad ->
        if (firstLoading && items.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(pad), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator()
                    Spacer(Modifier.height(12.dp))
                    Text("Loading songs…", style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize().padding(pad),
                contentPadding = PaddingValues(bottom = 16.dp)
            ) {
                itemsIndexed(items, key = { i, x -> "$i-${x.id}" }) { _, t ->
                    TrackRow(
                        track = t, isCurrent = false, liked = likedOf(t),
                        onPlay = { onPlay(t) },
                        onPlayNext = { onPlayNext(t) },
                        onAddQueue = { onAddQueue(t) },
                        onToggleLike = { onToggleLike(t) }
                    )
                }
                if (loadingMore) {
                    item {
                        Box(Modifier.fillMaxWidth().padding(16.dp),
                            contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(modifier = Modifier.size(28.dp))
                        }
                    }
                } else if (!exhausted && pager != null && items.isNotEmpty()) {
                    item {
                        Box(Modifier.fillMaxWidth().padding(8.dp),
                            contentAlignment = Alignment.Center) {
                            TextButton(onClick = { loadMoreNow() }) {
                                Text("${items.size} loaded — tap for more")
                            }
                        }
                    }
                }
                if (items.isEmpty()) {
                    item {
                        Box(Modifier.fillMaxWidth().padding(32.dp),
                            contentAlignment = Alignment.Center) {
                            Text("Nothing here yet — check connection and go back.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
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
    onSeeAll: (SeeAllRequest) -> Unit
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
                SectionHeader("New Releases") {
                    onSeeAll(SeeAllRequest("New Releases", static = newTracks))
                }
            }
            itemsIndexed(newTracks.take(8), key = { i, x -> "$i-${x.id}" }) { _, t ->
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
                    .pressScale(LocalMotion.current)
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
    val libScope = rememberCoroutineScope()
    var lists by remember { mutableStateOf<List<Playlist>>(emptyList()) }
    var showNew by remember { mutableStateOf(false) }
    var showLikedFolder by remember { mutableStateOf(false) }
    var showRecentFolder by remember { mutableStateOf(false) }
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
        // Liked + Recently Played folders + user playlists: 2 in a row,
        // 2.5x art (130dp). History lives ONLY in its folder (no rows).
        item {
            val allFolders = ArrayList<Playlist>()
            try {
                allFolders.add(
                    Playlist(
                        id = "__liked__",
                        name = "Liked Songs",
                        tracks = try {
                            liked
                        } catch (e: Exception) {
                            emptyList()
                        },
                        createdAt = 0L
                    )
                )
            } catch (e: Exception) {
            }
            try {
                allFolders.add(
                    Playlist(
                        id = "__recent__",
                        name = "Recently Played",
                        tracks = try {
                            recent
                        } catch (e: Exception) {
                            emptyList()
                        },
                        createdAt = 0L
                    )
                )
            } catch (e: Exception) {
            }
            try {
                allFolders.addAll(lists)
            } catch (e: Exception) {
            }
            if (allFolders.size <= 1 && lists.isEmpty()) {
                Text(
                    "No playlists yet — make one, or add songs from any menu.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp)
                )
            } else {
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                    allFolders.chunked(2).forEach { row ->
                        Row(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            row.forEach { p ->
                                val isLikedFolder = p.id == "__liked__"
                                val isRecentFolder = p.id == "__recent__"
                                Column(
                                    Modifier.weight(1f)
                                        .clip(RoundedCornerShape(16.dp))
                                        .clickable {
                                            try {
                                                if (isLikedFolder) {
                                                    showLikedFolder = true
                                                } else if (isRecentFolder) {
                                                    showRecentFolder = true
                                                } else {
                                                    onOpenPlaylist(p.id)
                                                }
                                            } catch (e: Exception) {
                                            }
                                        }
                                ) {
                                    if (isLikedFolder) {
                                        LikedFolderArt(
                                            count = p.tracks.size,
                                            size = 130.dp
                                        )
                                    } else if (isRecentFolder) {
                                        RecentFolderArt(
                                            tracks = p.tracks,
                                            size = 130.dp
                                        )
                                    } else {
                                        MosaicArt(p.tracks, 130.dp, 16.dp)
                                    }
                                    Spacer(Modifier.height(8.dp))
                                    Text(
                                        p.name,
                                        style = MaterialTheme.typography.titleMedium,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        "${p.tracks.size} songs",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 1
                                    )
                                    Spacer(Modifier.height(12.dp))
                                }
                            }
                            if (row.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
    if (showNew) {
        NewPlaylistSheet(
            onCreate = { n ->
                libScope.launch(Dispatchers.IO) {
                    val reloaded = try {
                        PlaylistStore.create(ctx, n)
                        PlaylistStore.list(ctx)
                    } catch (e: Exception) {
                        try {
                            PlaylistStore.list(ctx)
                        } catch (ignored: Exception) {
                            emptyList()
                        }
                    }
                    try {
                        withContext(Dispatchers.Main) {
                            lists = reloaded
                            showNew = false
                        }
                    } catch (e: Exception) {
                    }
                }
            },
            onDismiss = { showNew = false }
        )
    }
    // Liked Songs folder (virtual playlist, not in PlaylistStore).
    if (showLikedFolder) {
        val likedPl = try {
            Playlist(
                id = "__liked__",
                name = "Liked Songs",
                tracks = liked,
                createdAt = 0L
            )
        } catch (e: Exception) {
            Playlist("__liked__", "Liked Songs", emptyList(), 0L)
        }
        PlaylistSheet(
            playlist = likedPl,
            isCurrentId = { false },
            likedOf = { true },
            onPlayList = { list, idx, _ ->
                try {
                    if (list.isNotEmpty()) onPlay(list[idx.coerceIn(list.indices)])
                } catch (e: Exception) {
                }
            },
            onPlayNext = onPlayNext,
            onAddQueue = onAddQueue,
            onToggleLike = onToggleLike,
            onRemove = { t ->
                try {
                    onToggleLike(t)
                } catch (e: Exception) {
                }
            },
            onAddSuggested = { t ->
                try {
                    onPlay(t)
                } catch (e: Exception) {
                }
            },
            onDeletePlaylist = {},
            onDismiss = { showLikedFolder = false }
        )
    }
    // Recently Played folder (virtual playlist: whole history in one place).
    if (showRecentFolder) {
        val recentPl = try {
            Playlist(
                id = "__recent__",
                name = "Recently Played",
                tracks = recent,
                createdAt = 0L
            )
        } catch (e: Exception) {
            Playlist("__recent__", "Recently Played", emptyList(), 0L)
        }
        PlaylistSheet(
            playlist = recentPl,
            isCurrentId = { false },
            likedOf = { t ->
                try {
                    likedOf(t)
                } catch (e: Exception) {
                    false
                }
            },
            onPlayList = { list, idx, _ ->
                try {
                    if (list.isNotEmpty()) onPlay(list[idx.coerceIn(list.indices)])
                } catch (e: Exception) {
                }
            },
            onPlayNext = onPlayNext,
            onAddQueue = onAddQueue,
            onToggleLike = onToggleLike,
            onRemove = { },
            onAddSuggested = { t ->
                try {
                    onPlay(t)
                } catch (e: Exception) {
                }
            },
            onDeletePlaylist = {},
            onDismiss = { showRecentFolder = false }
        )
    }
}

/** Big heart-gradient art for the Liked Songs folder (130dp, 2.5x). */
@Composable
private fun LikedFolderArt(count: Int, size: Dp) {
    Box(
        Modifier.size(size).clip(RoundedCornerShape(16.dp))
            .background(
                Brush.linearGradient(
                    listOf(Color(0xFFFA243C), Color(0xFF7D0018))
                )
            ),
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                Icons.Filled.Favorite,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.95f),
                modifier = Modifier.size(size * 0.34f)
            )
            Spacer(Modifier.height(4.dp))
            Text(
                "$count",
                style = MaterialTheme.typography.titleMedium,
                color = Color.White.copy(alpha = 0.9f)
            )
        }
    }
}

/** Big history-gradient art for the Recently Played folder (130dp). */
@Composable
private fun RecentFolderArt(tracks: List<YtTrack>, size: Dp) {
    if (tracks.isNotEmpty()) {
        MosaicArt(tracks, size, 16.dp)
        return
    }
    Box(
        Modifier.size(size).clip(RoundedCornerShape(16.dp))
            .background(
                Brush.linearGradient(
                    listOf(Color(0xFF5E5CE6), Color(0xFF1B1B6B))
                )
            ),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            Icons.Filled.History,
            contentDescription = null,
            tint = Color.White.copy(alpha = 0.95f),
            modifier = Modifier.size(size * 0.34f)
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
                    .pressScale(LocalMotion.current)
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
    var suggestions by remember { mutableStateOf<List<String>>(emptyList()) }
    val context = LocalContext.current
    var error by remember { mutableStateOf<String?>(null) }
    var retryTick by remember { mutableIntStateOf(0) }
    val searchScope = rememberCoroutineScope()
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
                searchScope.launch(Dispatchers.IO) {
                    try {
                        Precache.warmSearchTop(context, cached)
                    } catch (e: Exception) {
                    }
                }
            }
        } catch (e: Exception) { }
        // Fast debounce 250ms (was 800ms): cached paint is already on
        // screen, network should chase typing, not lag a word behind.
        delay(250)
        searching = true
        error = null
        var fresh: List<YtTrack> = emptyList()
        val searchT0 = try { android.os.SystemClock.elapsedRealtime() } catch (e: Exception) { 0L }
        var attempt = 0
        while (attempt < 2 && fresh.isEmpty()) {
            attempt++
            try {
                // Music-only shelf: plain search leaks episodes/random videos.
                fresh = YoutubeRepository.searchMusic(query, 20)
            } catch (e: Exception) {
                Log.w(TAG, "search failed (attempt $attempt)", e)
                if (attempt < 2) {
                    delay(800)
                }
            }
        }
        try {
            if (fresh.isNotEmpty()) {
                results = fresh
                val snapshot = fresh
                try {
                    Log.d(TAG, "search '$query' ${snapshot.size} hits ${try { android.os.SystemClock.elapsedRealtime() - searchT0 } catch (e: Exception) { -1 }}ms")
                } catch (e: Exception) {
                }
                // Persist cache on IO, then warm top-4 OFF the critical path:
                // warmSearchTop resolves 4x audioUrls (each a fetchPage) and
                // must not hold `searching=true` or block the paint.
                try {
                    withContext(Dispatchers.IO) {
                        SongCache.save(context, cacheKey, snapshot)
                    }
                } catch (e: Exception) {
                }
                try {
                    searchScope.launch(Dispatchers.IO) {
                        try {
                            Precache.warmSearchTop(context, snapshot)
                        } catch (e: Exception) {
                        }
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

    // As-you-type suggestions (fast engine only; silent in stable mode).
    // 180ms chase delay — shorter than the 250ms search debounce so chips
    // land before results and a tap narrows the query instantly.
    LaunchedEffect(query) {
        val q = query.trim()
        if (q.length < 2) {
            suggestions = emptyList()
            return@LaunchedEffect
        }
        delay(180)
        try {
            val s = withContext(Dispatchers.IO) {
                YoutubeRepository.suggestions(q)
            }
            if (query.trim() == q) suggestions = s
        } catch (e: Exception) {
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
            androidx.compose.animation.AnimatedVisibility(
                visible = error != null,
                enter = Motion.fadeRise(LocalMotion.current),
                label = "searchError"
            ) {
            if (error != null) {
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(error!!, style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.weight(1f))
                    TextButton(onClick = { retryTick++ }) { Text("Retry") }
                }
            }
            }
            if (searching && results.isEmpty() && error == null) {
                Spacer(Modifier.height(8.dp))
                SearchSkeleton()
            }
            if (suggestions.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                // Horizontal chip strip (own LazyRow; parent is a LazyColumn
                // item so nested-scroll is one-directional, no jitter).
                androidx.compose.foundation.lazy.LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    items(suggestions.size) { i ->
                        val s = suggestions[i]
                        FilterChip(
                            selected = false,
                            onClick = { onQuery(s) },
                            label = { Text(s, maxLines = 1) },
                            leadingIcon = {
                                Icon(Icons.Filled.Search, contentDescription = null,
                                    modifier = Modifier.size(16.dp))
                            },
                            modifier = Modifier.pressScale(LocalMotion.current)
                        )
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
        }
        itemsIndexed(results, key = { i, x -> "$i-${x.id}" }) { _, t ->
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
private fun SectionHeader(
    title: String,
    onSeeAll: (() -> Unit)? = null,
    trailing: @Composable RowScope.() -> Unit = {}
) {
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.weight(1f))
        trailing()
        if (onSeeAll != null) {
            Text("See All", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.clickable { onSeeAll() }
                    .padding(start = 8.dp))
        }
    }
}

/** Recently Played cascade: 4 songs per column, horizontal columns.
 * Tap queues the visible history list (not a lone track). */
@Composable
private fun RecentCascade(
    tracks: List<YtTrack>,
    likedOf: (YtTrack) -> Boolean,
    onPlayList: (List<YtTrack>, Int) -> Unit,
    onPlayNext: (YtTrack) -> Unit,
    onAddQueue: (YtTrack) -> Unit,
    onToggleLike: (YtTrack) -> Unit
) {
    if (tracks.isEmpty()) {
        Text(
            "Play something and it shows up here.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp)
        )
        return
    }
    LazyHorizontalGrid(
        rows = GridCells.Fixed(4),
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.height(320.dp).fillMaxWidth()
    ) {
        itemsIndexed(tracks, key = { i, x -> "$i-${x.id}" }) { idx, t ->
            TrackRow(
                track = t, isCurrent = false, liked = likedOf(t),
                onPlay = { onPlayList(tracks, idx) },
                onPlayNext = { onPlayNext(t) },
                onAddQueue = { onAddQueue(t) },
                onToggleLike = { onToggleLike(t) },
                compact = true,
                // No grid placement anim in this foundation version.
                modifier = Modifier.width(320.dp)
            )
        }
    }
}

/** Top Picks 2-row grid: album art only + short song name below.
 * Tap queues the visible dozen (not a lone track). */
@Composable
private fun TopPicksGrid(
    tracks: List<YtTrack>,
    onPlayList: (List<YtTrack>, Int) -> Unit
) {
    if (tracks.isEmpty()) return
    LazyHorizontalGrid(
        rows = GridCells.Fixed(2),
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier.height(420.dp).fillMaxWidth()
    ) {
        itemsIndexed(tracks, key = { i, x -> "$i-${x.id}" }) { idx, t ->
            Column(
                Modifier.width(160.dp).pressScale(LocalMotion.current).clickable { onPlayList(tracks, idx) },
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                TrackArt(t.thumbUrl, t.id.hashCode(), 160.dp, 20.dp)
                Spacer(Modifier.height(6.dp))
                Text(
                    t.title.take(22),
                    style = MaterialTheme.typography.bodyMedium.copy(
                        fontWeight = FontWeight.SemiBold
                    ),
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center
                )
            }
        }
    }
}

/**
 * Full-sheet blurred-zoom backdrop for the player: the same thumbnail,
 * zoomed past its edges and frosted, so art melts into name/lyrics/about
 * with no square edge anywhere. Keyed to the track — art and backdrop
 * crossfade as one on song change, never mismatched. Static layer (no
 * per-frame work); skipped in video mode.
 */
@Composable
private fun ArtBackdrop(track: YtTrack, thumbUrl: String) {
    val ctx = LocalContext.current
    val hd = remember(track.id) { hdThumb(track) }
    var hdOk by remember(track.id) { mutableStateOf(true) }
    Box(Modifier.fillMaxSize()) {
        AsyncImage(
            model = coil.request.ImageRequest.Builder(ctx)
                .data(if (hdOk) hd else thumbUrl)
                .crossfade(450)
                .build(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            onError = { hdOk = false },
            modifier = Modifier.fillMaxSize()
                .graphicsLayer(scaleX = 1.35f, scaleY = 1.35f)
                .blur(60.dp)
        )
        // Settle it down: readable text, lava still breathing through.
        Box(
            Modifier.fillMaxSize()
                .background(Color.Black.copy(alpha = 0.45f))
        )
    }
}

/** Real YouTube thumbnail when available, gradient placeholder otherwise. */
@Composable
private fun VideoBackdrop(frame: android.graphics.Bitmap) {
    // Live video frame, zoomed past its edges + frosted. The bitmap object
    // swaps every few seconds; Compose crossfades the swap (same as art).
    // Defensive: never draw a dead bitmap (a recycled frame would kill the
    // draw pass with IllegalStateException).
    val safe = try {
        !frame.isRecycled && frame.width > 0 && frame.height > 0
    } catch (e: Exception) {
        false
    }
    if (!safe) return
    key(frame.hashCode()) {
        Image(
            bitmap = frame.asImageBitmap(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize()
                .graphicsLayer(scaleX = 1.35f, scaleY = 1.35f)
                .blur(60.dp)
        )
    }
    Box(
        Modifier.fillMaxSize()
            .background(Color.Black.copy(alpha = 0.45f))
    )
}
@Composable
private fun ShimmerBox(modifier: Modifier, motion: Boolean) {    if (!motion) {
        Box(modifier.background(MaterialTheme.colorScheme.surfaceVariant))
        return
    }
    val inf = rememberInfiniteTransition(label = "shimmer")
    val a by inf.animateFloat(
        0.35f, 0.75f,
        infiniteRepeatable(tween(900), RepeatMode.Restart), label = "shimmerA"
    )
    Box(modifier.background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = a)))
}

/** First-load skeleton: title bar + card rows. Replaces the lone spinner. */
@Composable
private fun HomeSkeleton() {
    val motion = LocalMotion.current
    Column(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        ShimmerBox(
            Modifier.padding(horizontal = 16.dp).fillMaxWidth(0.55f).height(30.dp)
                .clip(RoundedCornerShape(8.dp)), motion
        )
        Spacer(Modifier.height(14.dp))
        repeat(2) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                repeat(3) {
                    Column(Modifier.weight(1f)) {
                        ShimmerBox(
                            Modifier.fillMaxWidth().aspectRatio(1f)
                                .clip(RoundedCornerShape(12.dp)), motion
                        )
                        Spacer(Modifier.height(6.dp))
                        ShimmerBox(
                            Modifier.fillMaxWidth(0.8f).height(14.dp)
                                .clip(RoundedCornerShape(4.dp)), motion
                        )
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

/** Search first-load skeleton rows. */
@Composable
private fun SearchSkeleton() {
    val motion = LocalMotion.current
    Column(Modifier.fillMaxWidth()) {
        repeat(5) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                ShimmerBox(Modifier.size(52.dp).clip(RoundedCornerShape(8.dp)), motion)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    ShimmerBox(
                        Modifier.fillMaxWidth(0.7f).height(16.dp)
                            .clip(RoundedCornerShape(4.dp)), motion
                    )
                    Spacer(Modifier.height(6.dp))
                    ShimmerBox(
                        Modifier.fillMaxWidth(0.45f).height(13.dp)
                            .clip(RoundedCornerShape(4.dp)), motion
                    )
                }
            }
        }
    }
}
@Composable
private fun TrackArt(thumbUrl: String, seed: Int, size: Dp, corner: Dp = 8.dp) {
    if (thumbUrl.isNotBlank()) {
        val ctx = LocalContext.current
        // Sharp art: thumbs arrive as hqdefault (480px, blurry on big cards).
        // Derive maxresdefault from the video id in the URL; same hdOk flip
        // pattern as the player art (Coil 2.6 takes no URL fallback).
        val hd = remember(thumbUrl) {
            try {
                Regex("/vi/([A-Za-z0-9_-]{11})/").find(thumbUrl)
                    ?.groupValues?.get(1)?.let { "https://i.ytimg.com/vi/$it/maxresdefault.jpg" }
            } catch (e: Exception) {
                null
            }
        }
        var hdOk by remember(thumbUrl) { mutableStateOf(true) }
        AsyncImage(
            model = coil.request.ImageRequest.Builder(ctx)
                .data(if (hdOk && hd != null) hd else thumbUrl)
                .size(640)
                .crossfade(true)
                .build(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            onError = { hdOk = false },
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
