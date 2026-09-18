package com.cresca.app

import android.content.Intent
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Hosts playback outside the UI so songs keep playing with the app
 * backgrounded, and Android shows the system media notification
 * (pause/play/skip) plus lockscreen controls on supported devices.
 * On Android 16+ the notification is promoted to a Live Update chip
 * with a live progress bar.
 */
class PlaybackService : MediaSessionService() {

    private var session: MediaSession? = null
    private var liveProvider: LiveUpdateProvider? = null
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var progressJob: Job? = null

    override fun onCreate() {
        super.onCreate()
        // Small initial buffer = audible audio faster.
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(1500, 12000, 700, 1500)
            .build()
        val exo = ExoPlayer.Builder(this)
            .setLoadControl(loadControl)
            .build()
        val provider = LiveUpdateProvider(this)
        liveProvider = provider
        setMediaNotificationProvider(provider)
        session = MediaSession.Builder(this, exo)
            .setCallback(Callback())
            .build()
        exo.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (isPlaying) {
                    startProgressTicker()
                } else {
                    progressJob?.cancel()
                    progressJob = null
                }
            }

            override fun onMediaItemTransition(item: androidx.media3.common.MediaItem?, reason: Int) {
                pushProgressNow()
            }
        })
    }

    // Live Updates only refresh progress on state changes by default;
    // tick the progress bar while music plays.
    private fun startProgressTicker() {
        progressJob?.cancel()
        progressJob = serviceScope.launch {
            try {
                while (true) {
                    delay(10000)
                    pushProgressNow()
                }
            } catch (e: Exception) {
            }
        }
    }

    private fun pushProgressNow() {
        try {
            val s = session ?: return
            val p = s.player
            if (!p.isPlaying) {
                return
            }
            liveProvider?.refreshProgress(s)
        } catch (e: Exception) {
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return session
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val p = session?.player
        if (p == null || !p.playWhenReady || p.mediaItemCount == 0) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        try {
            progressJob?.cancel()
            serviceScope.cancel()
        } catch (e: Exception) {
        }
        session?.run {
            player.release()
            release()
        }
        session = null
        super.onDestroy()
    }

    private inner class Callback : MediaSession.Callback
}
