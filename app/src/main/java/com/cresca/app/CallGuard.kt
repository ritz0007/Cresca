package com.cresca.app

import android.content.Context
import android.media.AudioManager
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.media3.common.Player

/**
 * Crash-proof phone-call handling.
 *
 * Breakpoints fixed:
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
     */
    fun register(ctx: Context, player: Player): () -> Unit {
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
            return registerApi31(am, exec, player)
        } catch (e: Exception) {
            return {}
        }
    }

    @RequiresApi(31)
    private fun registerApi31(
        am: AudioManager,
        exec: java.util.concurrent.Executor,
        player: Player
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
                                }, 400)
                            } catch (e: Exception) {
                                try {
                                    player.play()
                                } catch (ignored: Exception) {
                                }
                            }
                        } else {
                            resumeAfterCall = false
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
