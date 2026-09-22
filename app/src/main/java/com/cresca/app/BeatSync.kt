package com.cresca.app

import android.media.audiofx.Visualizer
import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay

/**
 * Gentle beat-sync for the player cover (no mic, no new permission).
 *
 * Attaches Android's output Visualizer to the player's audio session and
 * distills FFT bins into one 0..1 bass pulse with adaptive gain, smoothed
 * for a calm breathe-not-strobe feel. Anything failing (no session, old
 * device, SecurityException, emulator silence) degrades to a slow idle
 * sine — the cover never freezes. All state lives here; UI just reads it.
 */
object BeatProbe {
    @Volatile var beat: Float = 0f
    @Volatile var lastDataMs: Long = 0L
    @Volatile private var ref: Float = 1f

    /** Offer one FFT frame (binder thread). Bass bins drive the pulse. */
    fun offerFft(fft: ByteArray?) {
        try {
            if (fft == null || fft.size < 16) return
            // Bytes are real/imag pairs; bins 1..6 ≈ bass on 128 capture.
            var sum = 0f
            var n = 0
            var i = 2
            while (i < 14 && i + 1 < fft.size) {
                val re = fft[i].toInt()
                val im = fft[i + 1].toInt()
                sum += kotlin.math.sqrt((re * re + im * im).toFloat())
                n++
                i += 2
            }
            if (n == 0) return
            val instant = sum / n
            // Adaptive gain: chase the ceiling slowly, floor at sanity min.
            ref = maxOf(ref * 0.995f + instant * 0.005f, instant, 40f)
            beat = (instant / ref).coerceIn(0f, 1f)
            lastDataMs = android.os.SystemClock.elapsedRealtime()
        } catch (e: Exception) {
        }
    }

    fun reset() {
        try {
            beat = 0f
        } catch (e: Exception) {
        }
    }
}

/**
 * 0..1 cover pulseollower. Polls the probe at ~12Hz (cheap recompose) and
 * eases toward it; falls back to a slow idle breath when paused or dataless.
 */
@Composable
fun rememberBeatLevel(audioSessionId: Int, isPlaying: Boolean): Float {
    var level by remember { mutableFloatStateOf(0f) }

    DisposableEffect(audioSessionId) {
        var viz: Visualizer? = null
        try {
            if (audioSessionId != 0) {
                viz = Visualizer(audioSessionId)
                try {
                    viz.captureSize = Visualizer.getCaptureSizeRange()[0]
                } catch (e: Exception) {
                }
                viz.setDataCaptureListener(
                    object : Visualizer.OnDataCaptureListener {
                        override fun onWaveFormDataCapture(
                            visualizer: Visualizer?, waveform: ByteArray?, samplingRate: Int
                        ) {
                        }

                        override fun onFftDataCapture(
                            visualizer: Visualizer?, fft: ByteArray?, samplingRate: Int
                        ) {
                            BeatProbe.offerFft(fft)
                        }
                    },
                    Visualizer.getMaxCaptureRate() / 2, false, true
                )
                viz.enabled = true
            }
        } catch (e: Exception) {
            Log.d("BeatSync", "visualizer unavailable: ${e.message}")
            try {
                viz?.release()
            } catch (ignored: Exception) {
            }
            viz = null
        }
        onDispose {
            try {
                viz?.release()
            } catch (e: Exception) {
            }
        }
    }

    LaunchedEffect(isPlaying, audioSessionId) {
        try {
            while (true) {
                val now = try {
                    android.os.SystemClock.elapsedRealtime()
                } catch (e: Exception) {
                    0L
                }
                val idle = 0.22f + 0.10f * kotlin.math.sin(now / 900.0).toFloat()
                val target = try {
                    if (!isPlaying) idle * 0.6f
                    else if (now - BeatProbe.lastDataMs > 1500L) idle
                    else BeatProbe.beat.coerceIn(0f, 1f)
                } catch (e: Exception) {
                    idle
                }
                // Fast attack, slow release: punchy but never jittery.
                val k = if (target > level) 0.55f else 0.18f
                level = (level + (target - level) * k).coerceIn(0f, 1f)
                delay(80)
            }
        } catch (e: Exception) {
        }
    }
    return level
}
