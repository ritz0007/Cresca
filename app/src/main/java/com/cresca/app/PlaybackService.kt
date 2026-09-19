package com.cresca.app

import android.content.Intent
import android.os.Bundle
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
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
        // Smooth + non-stop: cached datasource reuses streamed bytes on
        // replay/prefetch (SimpMusic pattern), bigger buffers survive
        // network dips, audio attributes keep focus handling sane.
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(2000, 30000, 1000, 2000)
            .setTargetBufferBytes(C.LENGTH_UNSET)
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
        val httpFactory = DefaultHttpDataSource.Factory()
            .setConnectTimeoutMs(25000)
            .setReadTimeoutMs(25000)
            .setAllowCrossProtocolRedirects(true)
            .setUserAgent("Cresca/1.0 (Android)")
        val cacheSource = try {
            val cache = ExoCache.get(this)
            CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(
                    DefaultDataSource.Factory(this, httpFactory)
                )
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        } catch (e: Exception) {
            null
        }
        val mediaSourceFactory = if (cacheSource != null) {
            DefaultMediaSourceFactory(this).setDataSourceFactory(cacheSource)
        } else {
            DefaultMediaSourceFactory(this)
        }
        val exo = ExoPlayer.Builder(this)
            .setLoadControl(loadControl)
            .setMediaSourceFactory(mediaSourceFactory)
            .setHandleAudioBecomingNoisy(true)
            .build()
        try {
            exo.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                true
            )
            exo.setWakeMode(C.WAKE_MODE_NETWORK)
        } catch (e: Exception) {
        }
        val provider = LiveUpdateProvider(this)
        liveProvider = provider
        setMediaNotificationProvider(provider)
        session = MediaSession.Builder(this, exo)
            .setCallback(SessionCallback())
            .build()
        // Prev + Like + Next custom buttons: ALWAYS visible in the system
        // notification on every API level (standard prev/next only appear
        // when the player buffer holds them; ours resolve via the queue).
        try {
            session?.setCustomLayout(listOf(prevButton(), likeButton(), nextButton()))
        } catch (e: Exception) {
        }
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

    private fun likeButton(): CommandButton {
        return try {
            CommandButton.Builder()
                .setDisplayName("Like")
                .setIconResId(android.R.drawable.star_big_on)
                .setSessionCommand(SessionCommand("cresca_like", Bundle.EMPTY))
                .build()
        } catch (e: Exception) {
            CommandButton.Builder()
                .setDisplayName("Like")
                .setSessionCommand(SessionCommand("cresca_like", Bundle.EMPTY))
                .build()
        }
    }

    private fun nextButton(): CommandButton {
        return try {
            CommandButton.Builder()
                .setDisplayName("Next")
                .setIconResId(android.R.drawable.ic_media_next)
                .setSessionCommand(SessionCommand("cresca_next", Bundle.EMPTY))
                .build()
        } catch (e: Exception) {
            CommandButton.Builder()
                .setDisplayName("Next")
                .setSessionCommand(SessionCommand("cresca_next", Bundle.EMPTY))
                .build()
        }
    }

    private fun prevButton(): CommandButton {
        return try {
            CommandButton.Builder()
                .setDisplayName("Previous")
                .setIconResId(android.R.drawable.ic_media_previous)
                .setSessionCommand(SessionCommand("cresca_prev", Bundle.EMPTY))
                .build()
        } catch (e: Exception) {
            CommandButton.Builder()
                .setDisplayName("Previous")
                .setSessionCommand(SessionCommand("cresca_prev", Bundle.EMPTY))
                .build()
        }
    }

    private inner class SessionCallback : MediaSession.Callback {
        override fun onCustomCommand(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            customCommand: SessionCommand,
            args: Bundle
        ): com.google.common.util.concurrent.ListenableFuture<SessionResult> {
            try {
                when (customCommand.customAction) {
                    "cresca_like" -> {
                        try {
                            NextActionReceiver.onLikeToggle?.invoke()
                        } catch (e: Exception) {
                        }
                        return com.google.common.util.concurrent.Futures.immediateFuture(
                            SessionResult(SessionResult.RESULT_SUCCESS)
                        )
                    }
                    "cresca_next" -> {
                        try {
                            NextActionReceiver.onNext?.invoke()
                        } catch (e: Exception) {
                        }
                        return com.google.common.util.concurrent.Futures.immediateFuture(
                            SessionResult(SessionResult.RESULT_SUCCESS)
                        )
                    }
                    "cresca_prev" -> {
                        try {
                            NextActionReceiver.onPrev?.invoke()
                        } catch (e: Exception) {
                        }
                        return com.google.common.util.concurrent.Futures.immediateFuture(
                            SessionResult(SessionResult.RESULT_SUCCESS)
                        )
                    }
                }
            } catch (e: Exception) {
            }
            return super.onCustomCommand(session, controller, customCommand, args)
        }
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

    }
