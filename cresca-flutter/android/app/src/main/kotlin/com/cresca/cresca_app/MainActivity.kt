package com.cresca.cresca_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.graphics.Color
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Live Updates (Y2) + promoted permission helper (Y3), Flutter port of
 * the native LiveUpdateProvider: API-36-gated ProgressStyle chip
 * (status-bar chip, top-ranked drawer entry, lockscreen progress),
 * driven from Dart on a 10 s ticker + transport events. Older APIs:
 * every call is a silent no-op (audio_service notification covers
 * controls there). Transport actions route back through the standard
 * media-button receiver audio_service already owns.
 */
class MainActivity : AudioServiceActivity() {
    companion object {
        private const val TAG = "LiveUpdate"
        private const val CHANNEL = "cresca.live_updates"
        private const val FX_CHANNEL = "cresca.audiofx"
        private const val VOL_CHANNEL = "cresca.system_volume"
        private const val VOL_EVENTS = "cresca.system_volume/events"
        private const val NOTIF_CHANNEL = "com.cresca.playback.live"
        private const val NOTIF_ID = 0xC8E5CA
        private const val DEVICE_CHANNEL = "cresca.device"
    }

    private var liveTitle = "Cresca Music"
    private var liveArtist = ""
    private var liveDurSec = 1
    private var livePosSec = 0
    private var livePlaying = false

    // Real audio effects (Audio Pipeline sheet): platform Equalizer +
    // LoudnessEnhancer attached to just_audio's audio session. Created
    // lazily on Dart's attach(sessionId); released on release() or a
    // new attach. Every call is a silent false/null on unsupported
    // devices — never a crash, never a fake success.
    private var fxEq: android.media.audiofx.Equalizer? = null
    private var fxLoud: android.media.audiofx.LoudnessEnhancer? = null
    private var fxSession = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        liveTitle = call.argument<String>("title")
                            ?.take(120).ifNullOrBlank("Cresca Music")
                        liveArtist = call.argument<String>("artist")
                            ?.take(120) ?: ""
                        liveDurSec = (call.argument<Int>("durationSec")
                            ?: 1).coerceAtLeast(1)
                        livePosSec = 0
                        livePlaying = true
                        result.success(post())
                    }
                    "progress" -> {
                        livePosSec = (call.argument<Int>("posSec")
                            ?: livePosSec).coerceAtLeast(0)
                        livePlaying =
                            call.argument<Boolean>("playing")
                                ?: livePlaying
                        // R3 repair (see LiveUpdates.progress): Dart's
                        // track-change duration is usually still null
                        // (start posts a 1 s card); a later known
                        // duration refreshes the Segment before re-post.
                        // Stale/older callers omit it — harmless no-op.
                        val dur = (call.argument<Int>("durationSec")
                            ?: 0).coerceAtLeast(0)
                        if (dur > 0) {
                            liveDurSec = dur.coerceAtLeast(1)
                            livePosSec =
                                livePosSec.coerceIn(0, liveDurSec)
                        }
                        result.success(post())
                    }
                    "stop" -> {
                        cancel()
                        result.success(true)
                    }
                    "canPromote" -> result.success(canPromote())
                    "openNotificationSettings" -> {
                        openNotificationSettings()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.w(TAG, "channel failed", e)
                try {
                    result.success(false)
                } catch (_: Exception) {
                }
            }
        }
        // Device ABI (updates): Build.SUPPORTED_ABIS for APK picking.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getSupportedAbis" ->
                        result.success(Build.SUPPORTED_ABIS.toList())
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.w(TAG, "device failed", e)
                try {
                    result.success(listOf("universal"))
                } catch (_: Exception) {
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, FX_CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "attach" -> {
                        val sid =
                            call.argument<Int>("sessionId") ?: 0
                        result.success(attachFx(sid))
                    }
                    "setBand" -> {
                        val band =
                            call.argument<Int>("band") ?: -1
                        val levelMb =
                            call.argument<Int>("levelMb") ?: 0
                        result.success(setFxBand(band, levelMb))
                    }
                    "setEnabled" -> {
                        val on =
                            call.argument<Boolean>("enabled")
                                ?: false
                        result.success(setFxEnabled(on))
                    }
                    "setBoost" -> {
                        val gainMb =
                            call.argument<Int>("gainMb") ?: 0
                        result.success(setFxBoost(gainMb))
                    }
                    "release" -> {
                        releaseFx()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.w(TAG, "audiofx failed", e)
                try {
                    result.success(false)
                } catch (_: Exception) {
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, VOL_CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getVolume" -> {
                        try {
                            val am = volAm()
                            if (am == null) {
                                result.success(mapOf(
                                    "volume" to 0, "max" to 1
                                ))
                            } else {
                                val max = try {
                                    am.getStreamMaxVolume(
                                        AudioManager.STREAM_MUSIC
                                    )
                                } catch (_: Exception) {
                                    1
                                }.coerceAtLeast(1)
                                val vol = try {
                                    am.getStreamVolume(
                                        AudioManager.STREAM_MUSIC
                                    )
                                } catch (_: Exception) {
                                    0
                                }.coerceIn(0, max)
                                result.success(mapOf(
                                    "volume" to vol, "max" to max
                                ))
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "system_volume failed", e)
                            try {
                                result.success(mapOf(
                                    "volume" to 0, "max" to 1
                                ))
                            } catch (_: Exception) {
                            }
                        }
                    }
                    "setVolume" -> {
                        try {
                            val am = volAm()
                            if (am == null) {
                                result.success(false)
                            } else {
                                val max = try {
                                    am.getStreamMaxVolume(
                                        AudioManager.STREAM_MUSIC
                                    )
                                } catch (_: Exception) {
                                    1
                                }.coerceAtLeast(1)
                                val raw = call.argument<Any>("volume")
                                val want = when (raw) {
                                    is Number -> raw.toInt()
                                    else -> 0
                                }.coerceIn(0, max)
                                am.setStreamVolume(
                                    AudioManager.STREAM_MUSIC,
                                    want, 0
                                )
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "system_volume failed", e)
                            try {
                                result.success(false)
                            } catch (_: Exception) {
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.w(TAG, "system_volume failed", e)
                try {
                    result.success(false)
                } catch (_: Exception) {
                }
            }
        }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger, VOL_EVENTS
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                private var volObserver: ContentObserver? = null
                override fun onListen(
                    args: Any?, sink: EventChannel.EventSink
                ) {
                    try {
                        try {
                            sink.success(volNormalized())
                        } catch (_: Exception) {
                        }
                        val obs =
                            object : ContentObserver(
                                Handler(Looper.getMainLooper())
                            ) {
                                override fun onChange(
                                    selfChange: Boolean
                                ) {
                                    try {
                                        sink.success(volNormalized())
                                    } catch (e: Exception) {
                                        Log.w(
                                            TAG,
                                            "system_volume failed", e
                                        )
                                    }
                                }
                            }
                        volObserver = obs
                        try {
                            contentResolver.registerContentObserver(
                                Settings.System.CONTENT_URI,
                                true, obs
                            )
                        } catch (e: Exception) {
                            Log.w(TAG, "system_volume failed", e)
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "system_volume failed", e)
                    }
                }
                override fun onCancel(args: Any?) {
                    try {
                        volObserver?.let {
                            contentResolver
                                .unregisterContentObserver(it)
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "system_volume failed", e)
                    }
                    volObserver = null
                }
            }
        )
    }

    /** Attaches EQ + boost to [sessionId]. Returns band info or null. */
    private fun attachFx(sessionId: Int): Map<String, Any>? {
        releaseFx()
        if (sessionId <= 0) return null
        return try {
            val eq = android.media.audiofx.Equalizer(0, sessionId)
            val n = eq.numberOfBands.toInt().coerceIn(1, 16)
            val range = eq.bandLevelRange
            val freqs = (0 until n).map {
                try {
                    eq.getCenterFreq(it.toShort())
                } catch (_: Exception) {
                    0
                }
            }
            val loud = try {
                android.media.audiofx.LoudnessEnhancer(sessionId)
            } catch (_: Exception) {
                null
            }
            fxEq = eq
            fxLoud = loud
            fxSession = sessionId
            try {
                eq.enabled = true
            } catch (_: Exception) {
            }
            try {
                loud?.enabled = true
            } catch (_: Exception) {
            }
            mapOf(
                "bands" to n,
                "minMb" to range[0].toInt(),
                "maxMb" to range[1].toInt(),
                "freqs" to freqs,
                "hasBoost" to (loud != null)
            )
        } catch (e: Exception) {
            Log.w(TAG, "attachFx failed", e)
            releaseFx()
            null
        }
    }

    private fun setFxBand(band: Int, levelMb: Int): Boolean {
        val eq = fxEq ?: return false
        return try {
            val n = eq.numberOfBands.toInt()
            if (band < 0 || band >= n) return false
            val range = eq.bandLevelRange
            val lv = levelMb
                .coerceIn(range[0].toInt(), range[1].toInt())
                .toShort()
            eq.setBandLevel(band.toShort(), lv)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun setFxEnabled(on: Boolean): Boolean {
        return try {
            var ok = false
            try {
                fxEq?.enabled = on
                if (fxEq != null) ok = true
            } catch (_: Exception) {
            }
            try {
                fxLoud?.enabled = on
                if (fxLoud != null) ok = true
            } catch (_: Exception) {
            }
            ok
        } catch (_: Exception) {
            false
        }
    }

    private fun setFxBoost(gainMb: Int): Boolean {
        val loud = fxLoud ?: return false
        return try {
            loud.setTargetGain(gainMb.coerceIn(0, 4000))
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun releaseFx() {
        try {
            fxEq?.release()
        } catch (_: Exception) {
        }
        try {
            fxLoud?.release()
        } catch (_: Exception) {
        }
        fxEq = null
        fxLoud = null
        fxSession = 0
    }

    private fun volAm(): AudioManager? = try {
        getSystemService(Context.AUDIO_SERVICE) as AudioManager
    } catch (e: Exception) {
        Log.w(TAG, "system_volume failed", e)
        null
    }

    private fun volNormalized(): Double = try {
        val am = volAm() ?: return 1.0
        val max = try {
            am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        } catch (_: Exception) {
            1
        }.coerceAtLeast(1)
        val vol = try {
            am.getStreamVolume(AudioManager.STREAM_MUSIC)
        } catch (_: Exception) {
            max
        }.coerceIn(0, max)
        (vol.toDouble() / max.toDouble()).coerceIn(0.0, 1.0)
    } catch (e: Exception) {
        Log.w(TAG, "system_volume failed", e)
        1.0
    }

    private fun nm(): NotificationManager? = try {
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    } catch (e: Exception) {
        null
    }

    private fun canPromote(): Boolean {
        if (Build.VERSION.SDK_INT < 36) return false
        return try {
            nm()?.canPostPromotedNotifications() == true
        } catch (e: Exception) {
            false
        }
    }

    /** Posts (or refreshes) the Live Update. False when not applicable. */
    private fun post(): Boolean {
        if (Build.VERSION.SDK_INT < 36) return false
        if (!canPromote()) return false
        return try {
            val manager = nm() ?: return false
            try {
                manager.createNotificationChannel(
                    NotificationChannel(
                        NOTIF_CHANNEL, "Cresca Live Updates",
                        NotificationManager.IMPORTANCE_DEFAULT
                    )
                )
            } catch (e: Exception) {
            }
            val pos = livePosSec.coerceIn(0, liveDurSec)
            val style = Notification.ProgressStyle()
                .setProgressSegments(
                    mutableListOf(
                        Notification.ProgressStyle.Segment(liveDurSec)
                            .setColor(Color.LTGRAY)
                    )
                )
                .setProgress(pos)
                .setStyledByProgress(true)
            val open = packageManager
                .getLaunchIntentForPackage(packageName)?.let {
                    PendingIntent.getActivity(
                        this, 0, it,
                        PendingIntent.FLAG_IMMUTABLE or
                            PendingIntent.FLAG_UPDATE_CURRENT
                    )
                }
            val builder = Notification.Builder(this, NOTIF_CHANNEL)
                .setContentTitle(liveTitle)
                .setContentText(liveArtist)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .setStyle(style)
                .addExtras(Bundle().apply {
                    putBoolean("android.requestPromotedOngoing", true)
                })
            if (open != null) builder.setContentIntent(open)
            try {
                builder.addAction(mediaButtonAction(
                    KeyEvent.KEYCODE_MEDIA_PREVIOUS,
                    "Previous", android.R.drawable.ic_media_previous, 201
                ))
            } catch (e: Exception) {
            }
            try {
                builder.addAction(
                    if (livePlaying) mediaButtonAction(
                        KeyEvent.KEYCODE_MEDIA_PAUSE,
                        "Pause", android.R.drawable.ic_media_pause, 202
                    ) else mediaButtonAction(
                        KeyEvent.KEYCODE_MEDIA_PLAY,
                        "Play", android.R.drawable.ic_media_play, 202
                    )
                )
            } catch (e: Exception) {
            }
            try {
                builder.addAction(mediaButtonAction(
                    KeyEvent.KEYCODE_MEDIA_NEXT,
                    "Next", android.R.drawable.ic_media_next, 203
                ))
            } catch (e: Exception) {
            }
            manager.notify(NOTIF_ID, builder.build())
            true
        } catch (e: Exception) {
            Log.w(TAG, "post failed", e)
            false
        }
    }

    private fun mediaButtonAction(
        keyCode: Int, title: String, iconRes: Int, code: Int
    ): Notification.Action {
        val down = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
            setPackage(packageName)
            putExtra(
                Intent.EXTRA_KEY_EVENT,
                KeyEvent(KeyEvent.ACTION_DOWN, keyCode)
            )
        }
        val up = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
            setPackage(packageName)
            putExtra(
                Intent.EXTRA_KEY_EVENT,
                KeyEvent(KeyEvent.ACTION_UP, keyCode)
            )
        }
        // Down drives the toggle; up keeps the dispatcher balanced.
        val pi = PendingIntent.getBroadcast(
            this, code, down,
            PendingIntent.FLAG_IMMUTABLE or
                PendingIntent.FLAG_UPDATE_CURRENT
        )
        try {
            PendingIntent.getBroadcast(
                this, code + 1000, up,
                PendingIntent.FLAG_IMMUTABLE or
                    PendingIntent.FLAG_UPDATE_CURRENT
            )
        } catch (e: Exception) {
        }
        return Notification.Action.Builder(
            android.graphics.drawable.Icon
                .createWithResource(this, iconRes),
            title, pi
        ).build()
    }

    private fun cancel() {
        try {
            nm()?.cancel(NOTIF_ID)
        } catch (e: Exception) {
        }
    }

    private fun openNotificationSettings() {
        try {
            val intent =
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                }
            startActivity(intent)
        } catch (e: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_SETTINGS))
            } catch (_: Exception) {
            }
        }
    }

    private fun String?.ifNullOrBlank(fallback: String): String =
        if (this.isNullOrBlank()) fallback else this
}
