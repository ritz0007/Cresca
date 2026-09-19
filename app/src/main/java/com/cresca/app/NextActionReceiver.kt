package com.cresca.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.media3.session.MediaController

object NextActionReceiver : BroadcastReceiver() {
    private var mediaController: MediaController? = null

    fun setMediaController(controller: MediaController) {
        mediaController = controller
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == "com.cresca.app.NEXT_ACTION") {
            mediaController?.seekToNext()
        }
    }
}