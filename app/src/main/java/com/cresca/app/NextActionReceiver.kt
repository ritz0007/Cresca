package com.cresca.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.media3.session.MediaController

/**
 * Notification / Live Update action receiver (Next + Prev + Like).
 *
 * The synthetic actions in [LiveUpdateProvider] fire broadcasts here.
 * MainActivity wires real behavior via [onNext]/[onPrev]/[onLikeToggle]
 * (queue skip + liked store). Falls back to MediaController seek when the
 * activity is gone but the session lives (background shade taps).
 */
object NextActionReceiver : BroadcastReceiver() {
    const val ACTION_NEXT = "com.cresca.app.NEXT_ACTION"
    const val ACTION_PREV = "com.cresca.app.PREV_ACTION"
    const val ACTION_LIKE = "com.cresca.app.LIKE_ACTION"

    private const val TAG = "MediaAction"

    @Volatile private var mediaController: MediaController? = null
    @Volatile var onNext: (() -> Unit)? = null
    @Volatile var onPrev: (() -> Unit)? = null
    @Volatile var onLikeToggle: (() -> Unit)? = null

    fun setMediaController(controller: MediaController?) {
        try {
            mediaController = controller
        } catch (e: Exception) {
        }
    }

    fun clear() {
        try {
            onNext = null
            onPrev = null
            onLikeToggle = null
        } catch (e: Exception) {
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        try {
            when (intent.action) {
                ACTION_NEXT -> {
                    try {
                        onNext?.invoke() ?: run {
                            try {
                                mediaController?.seekToNext()
                            } catch (e: Exception) {
                                Log.w(TAG, "next fallback failed", e)
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "next failed", e)
                    }
                }
                ACTION_PREV -> {
                    try {
                        onPrev?.invoke() ?: run {
                            try {
                                mediaController?.seekToPrevious()
                            } catch (e: Exception) {
                                Log.w(TAG, "prev fallback failed", e)
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "prev failed", e)
                    }
                }
                ACTION_LIKE -> {
                    try {
                        onLikeToggle?.invoke()
                    } catch (e: Exception) {
                        Log.w(TAG, "like failed", e)
                    }
                }
            }
        } catch (e: Exception) {
        }
    }
}
