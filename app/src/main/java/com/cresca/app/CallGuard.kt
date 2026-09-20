package com.cresca.app

import android.content.Context
import android.media.AudioManager
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.media3.common.Player

/**
 * Crash-proof phone-call handling.
 *
 * Root cause of the play-during-call crash (ExoPlayer #7977 pattern):
 * starting a track calls startForegroundService(), but while a call holds
 * audio focus the player can never start: the media notification never goes
 * ongoing, startForeground() never happens in time, and the system kills
 * the app with RemoteServiceException ("did not then call
 * Service.startForeground()"). The fix: never start the playback service
 * mid-call — prepare the player, wait, and start everything after the call.
 *
 * Other breakpoints fixed:
 * - Direct OnModeChangedListener reference inside a composable crashes on
 *   API 26-30 (class verification) and mainExecutor doesn't exist on 26/27.
 * - Old code called player.play()/pause() without checking controller state
 *   and auto-resumed even when the user had paused mid-call.
 * - Playing a NEW song while already in a call raced the mode listener
 *   (pause immediately after resolve -> stuck spinner / IllegalState).
 *
 * This helper isolates the API-31 surface, never throws, and only
 * auto-resumes when playback was active at call start.
 */
object CallGuard {

    /** Pure tap-routing decision (unit-tested, no Android needed). */
    enum class CallPlayAction { START_NOW, DEFER_UNTIL_CALL_END }

    object CallPlaybackGate {
        /** Play taps during a call must defer (focus locked -> REQUEST_FAILED). */
        fun actionForTap(isInCall: Boolean): CallPlayAction =
            if (isInCall) CallPlayAction.DEFER_UNTIL_CALL_END
            else CallPlayAction.START_NOW

        /**
         * Foreground-service starts during a call crash the app: the player
         * can't go ongoing without audio focus, so startForeground() never
         * lands in time (RemoteServiceException). Only start off-call.
         */
        fun shouldStartForegroundService(isInCall: Boolean): Boolean = !isInCall
    }

    fun isCallMode(mode: Int): Boolean {
        return try {
            mode == AudioManager.MODE_IN_CALL ||
                mode == AudioManager.MODE_IN_COMMUNICATION ||
                mode == AudioManager.MODE_RINGTONE
        } catch (e: Exception) {
            false
        }
    }

    fun isInCall(ctx: Context): Boolean {
        return try {
            val am = ctx.getSystemService(AudioManager::class.java) ?: return false
            isCallMode(am.mode)
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Register pause-on-call / resume-after-call. Returns an unregister
     * lambda. Never throws. No-op on API < 31 (ExoPlayer audio-focus still
     * ducks/pauses via PlaybackService attributes).
     *
     * [onCallEnded] fires (main thread, ~400ms after the stack settles) on
     * every return to MODE_NORMAL — the app uses it to start playback that
     * was tapped mid-call (foreground service + play are only safe now).
     */
    fun register(
        ctx: Context,
        player: Player,
        onCallEnded: () -> Unit = {}
    ): () -> Unit {
        try {
            if (Build.VERSION.SDK_INT < 31) return {}
            val am = try {
                ctx.getSystemService(AudioManager::class.java)
            } catch (e: Exception) {
                null
            } ?: return {}
            val exec = try {
                ctx.mainExecutor
            } catch (e: Exception) {
                return {}
            }
            return registerApi31(am, exec, player, onCallEnded)
        } catch (e: Exception) {
            return {}
        }
    }

    @RequiresApi(31)
    private fun registerApi31(
        am: AudioManager,
        exec: java.util.concurrent.Executor,
        player: Player,
        onCallEnded: () -> Unit
    ): () -> Unit {
        try {
            var resumeAfterCall = false
            var userPausedDuringCall = false
            val listener = AudioManager.OnModeChangedListener { mode ->
                try {
                    if (isCallMode(mode)) {
                        val wasPlaying = try {
                            player.isPlaying
                        } catch (e: Exception) {
                            false
                        }
                        // Only remember resume when we actually paused for the call.
                        resumeAfterCall = wasPlaying
                        userPausedDuringCall = false
                        if (wasPlaying) {
                            try {
                                player.pause()
                            } catch (e: Exception) {
                            }
                        }
                    } else if (mode == AudioManager.MODE_NORMAL) {
                        if (resumeAfterCall && !userPausedDuringCall) {
                            resumeAfterCall = false
                            try {
                                // Small delay: telecom stack still settling; avoids
                                // IllegalState / focus-reject crashes on some ROMs.
                                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                                    try {
                                        player.play()
                                    } catch (e: Exception) {
                                    }
                                    try {
                                        onCallEnded()
                                    } catch (e: Exception) {
                                    }
                                }, 400)
                            } catch (e: Exception) {
                                try {
                                    player.play()
                                } catch (ignored: Exception) {
                                }
                                try {
                                    onCallEnded()
                                } catch (ignored: Exception) {
                                }
                            }
                        } else {
                            resumeAfterCall = false
                            // Still notify: taps parked mid-call start here.
                            try {
                                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                                    try {
                                        onCallEnded()
                                    } catch (e: Exception) {
                                    }
                                }, 400)
                            } catch (e: Exception) {
                                try {
                                    onCallEnded()
                                } catch (ignored: Exception) {
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                }
            }
            try {
                am.addOnModeChangedListener(exec, listener)
            } catch (e: Exception) {
                return {}
            }
            return {
                try {
                    am.removeOnModeChangedListener(listener)
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
            return {}
        }
    }
}
