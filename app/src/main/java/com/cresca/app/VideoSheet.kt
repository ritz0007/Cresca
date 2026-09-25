package com.cresca.app

import android.content.Context
import android.content.ContextWrapper
import android.util.Log
import android.view.ViewGroup
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.HighQuality
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView

private const val VIDEO_TAG = "VideoSheet"

// Bottom sheets/dialogs wrap the Activity; unwrap to reach it.
private fun Context.findActivity(): android.app.Activity? {
    var c: Context? = this
    while (c != null) {
        if (c is android.app.Activity) {
            return c
        }
        c = (c as? ContextWrapper)?.baseContext
    }
    return null
}

/**
 * Session-driven embed (YT Music style): a bare video surface on the shared
 * session player. Play/pause/seek/prev/next all live on the music controls;
 * expand + quality sit BELOW the picture, right side.
 *
 * Surface is a TextureView so periodic frame grabs can feed the blurred
 * live-video backdrop ([onFrameGrab], ~160px, every 3s while playing).
 */
@Composable
fun InlineVideo(
    player: Player,
    loading: Boolean,
    qualities: List<String>,
    currentQuality: String,
    onQuality: (String) -> Unit,
    modifier: Modifier = Modifier,
    onFrameGrab: (android.graphics.Bitmap?) -> Unit = {},
    videoKey: String = ""
) {
    val context = LocalContext.current
    var expanded by remember { mutableStateOf(false) }
    var showQuality by remember { mutableStateOf(false) }
    // PlayerView (SurfaceView): proven auto-fit rendering — no manual
    // matrices (the TextureView experiment stretched/froze). Live frames
    // for the blurred bg come from PixelCopy on its surface: read-only,
    // zero interference with the output path.
    val pvRef = remember { arrayOfNulls<PlayerView>(1) }
    // First-frame gate: spinner stays until pixels actually render (not
    // just until the URL resolves), so a starved track never looks stuck.
    var hasFrame by remember { mutableStateOf(false) }

    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onRenderedFirstFrame() {
                try {
                    hasFrame = true
                } catch (e: Exception) {
                }
            }
        }
        try {
            player.addListener(listener)
        } catch (e: Exception) {
        }
        onDispose {
            try {
                player.removeListener(listener)
            } catch (e: Exception) {
            }
        }
    }

    // PixelCopy frame grabs for the blurred video backdrop (160x90,
    // every 3s while playing). Destination bitmaps are fresh per grab and
    // handed to Compose, never recycled here. Never throws.
    val pcHandler = remember {
        try {
            android.os.Handler(android.os.Looper.getMainLooper())
        } catch (e: Exception) {
            null
        }
    }
    LaunchedEffect(player, videoKey) {
        // New video: wait for the first rendered frame (spinner covers it).
        hasFrame = false
        try {
            while (true) {
                kotlinx.coroutines.delay(3000)
                try {
                    val pv = pvRef[0] ?: continue
                    if (!player.isPlaying) continue
                    val sv = try {
                        pv.videoSurfaceView as? android.view.SurfaceView
                    } catch (e: Exception) {
                        null
                    } ?: continue
                    val surf = try {
                        sv.holder?.surface
                    } catch (e: Exception) {
                        null
                    } ?: continue
                    try {
                        if (!surf.isValid) continue
                    } catch (e: Exception) {
                        continue
                    }
                    val h = try {
                        pcHandler
                    } catch (e: Exception) {
                        null
                    } ?: continue
                    val dst = try {
                        android.graphics.Bitmap.createBitmap(160, 90, android.graphics.Bitmap.Config.ARGB_8888)
                    } catch (e: Exception) {
                        null
                    } ?: continue
                    try {
                        android.view.PixelCopy.request(
                            surf,
                            dst,
                            { res ->
                                try {
                                    if (res == android.view.PixelCopy.SUCCESS) {
                                        onFrameGrab(dst)
                                    } else {
                                        dst.recycle()
                                    }
                                } catch (e: Exception) {
                                    try {
                                        dst.recycle()
                                    } catch (ignored: Exception) {
                                    }
                                }
                            },
                            h
                        )
                    } catch (e: Exception) {
                        try {
                            dst.recycle()
                        } catch (ignored: Exception) {
                        }
                    }
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
        }
    }

    @Composable
    fun VideoSurface(surfaceModifier: Modifier) {
        AndroidView(
            factory = { ctx ->
                PlayerView(ctx).apply {
                    this.player = player
                    useController = false
                    layoutParams = ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                    )
                    pvRef[0] = this
                }
            },
            onRelease = {
                try {
                    if (pvRef[0] === it) pvRef[0] = null
                } catch (e: Exception) {
                }
                it.player = null
            },
            modifier = surfaceModifier
        )
    }

    @Composable
    fun SurfaceButtons(isExpanded: Boolean, onToggleExpand: () -> Unit) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(8.dp),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box {
                IconButton(onClick = { showQuality = true }) {
                    Icon(
                        Icons.Filled.HighQuality,
                        contentDescription = "Quality",
                        tint = Color.White
                    )
                }
                DropdownMenu(
                    expanded = showQuality,
                    onDismissRequest = { showQuality = false }
                ) {
                    if (qualities.isEmpty()) {
                        DropdownMenuItem(
                            text = { Text("Auto") },
                            onClick = { showQuality = false }
                        )
                    } else {
                        qualities.forEach { q ->
                            DropdownMenuItem(
                                text = { Text(q) },
                                trailingIcon = {
                                    if (q == currentQuality) {
                                        Icon(
                                            Icons.Filled.Check,
                                            contentDescription = null
                                        )
                                    }
                                },
                                onClick = {
                                    showQuality = false
                                    if (q != currentQuality) {
                                        onQuality(q)
                                    }
                                }
                            )
                        }
                    }
                }
            }
            IconButton(onClick = onToggleExpand) {
                Icon(
                    if (isExpanded) Icons.Filled.FullscreenExit else Icons.Filled.Fullscreen,
                    contentDescription = if (isExpanded) "Collapse" else "Expand",
                    tint = Color.White
                )
            }
        }
    }

    if (!expanded) {
        Column(modifier = modifier) {
            Box(
                Modifier.fillMaxWidth().aspectRatio(16f / 9f)
                    .background(Color.Black)
            ) {
                VideoSurface(Modifier.fillMaxSize())
                // Spinner until the first frame renders (resolve alone
                // isn't enough: a starved track would look frozen).
                if (loading || !hasFrame) {
                    CircularProgressIndicator(
                        Modifier.align(Alignment.Center),
                        color = Color.White
                    )
                }
            }
            // Controls live below the picture, right side (never on it).
            SurfaceButtons(isExpanded = false, onToggleExpand = { expanded = true })
        }
    } else {
        // Fullscreen video rotates to landscape; back to portrait after.
        DisposableEffect(Unit) {
            val a = context.findActivity()
            Log.i(VIDEO_TAG, "expand: activity=" + (a != null))
            a?.requestedOrientation =
                android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            onDispose {
                Log.i(VIDEO_TAG, "collapse")
                a?.requestedOrientation =
                    android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
        }
        Dialog(
            onDismissRequest = { expanded = false },
            properties = DialogProperties(
                usePlatformDefaultWidth = false,
                decorFitsSystemWindows = false
            )
        ) {
            Column(
                modifier = Modifier.fillMaxSize().background(Color.Black)
            ) {
                Box(
                    Modifier.fillMaxWidth().weight(1f)
                ) {
                    VideoSurface(Modifier.fillMaxSize())
                    if (loading || !hasFrame) {
                        CircularProgressIndicator(
                            Modifier.align(Alignment.Center),
                            color = Color.White
                        )
                    }
                }
                SurfaceButtons(isExpanded = true, onToggleExpand = { expanded = false })
            }
        }
    }
}

/** Full-screen music-video player: resolves a muxed stream and plays it with controls. */
@Composable
fun VideoSheet(watchUrl: String, title: String, artist: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val vplayer = remember { ExoPlayer.Builder(context).build() }

    DisposableEffect(vplayer) {
        onDispose { vplayer.release() }
    }

    var loading by remember(watchUrl) { mutableStateOf(true) }
    var error by remember(watchUrl) { mutableStateOf<String?>(null) }

    LaunchedEffect(watchUrl) {
        loading = true
        error = null
        try {
            val url = YoutubeRepository.videoUrl(watchUrl)
            if (url != null) {
                vplayer.setMediaItem(MediaItem.fromUri(url))
                vplayer.prepare()
                vplayer.play()
            } else {
                error = "Could not resolve video stream"
            }
        } catch (e: Exception) {
            Log.e(VIDEO_TAG, "video resolve failed", e)
            error = "Video failed: ${e.message}"
        } finally {
            loading = false
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false
        )
    ) {
        MaterialTheme(colorScheme = darkColorScheme()) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black)
            ) {
                AndroidView(
                    factory = { ctx ->
                        PlayerView(ctx).apply {
                            player = vplayer
                            useController = true
                            layoutParams = ViewGroup.LayoutParams(
                                ViewGroup.LayoutParams.MATCH_PARENT,
                                ViewGroup.LayoutParams.MATCH_PARENT
                            )
                        }
                    },
                    onRelease = { it.player = null },
                    modifier = Modifier.fillMaxSize()
                )
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    IconButton(onClick = onDismiss) {
                        Icon(
                            Icons.Filled.Close,
                            contentDescription = "Close",
                            tint = Color.White
                        )
                    }
                    Spacer(Modifier.width(8.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            title,
                            style = MaterialTheme.typography.titleMedium,
                            color = Color.White,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            artist,
                            style = MaterialTheme.typography.bodyMedium,
                            color = Color.White.copy(alpha = 0.7f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
                if (loading) {
                    CircularProgressIndicator(Modifier.align(Alignment.Center))
                }
                if (error != null) {
                    Column(
                        modifier = Modifier.align(Alignment.Center),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Text(
                            error!!,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.error
                        )
                        Spacer(Modifier.height(12.dp))
                        Button(onClick = onDismiss) { Text("Close") }
                    }
                }
            }
        }
    }
}
