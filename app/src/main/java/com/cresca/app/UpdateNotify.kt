package com.cresca.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Update-available alerts: system notification + in-app banner data.
 * The daily GitHub check was silent (banner only, easily missed, and the
 * check needs network) — now a heads-up notification fires the moment a
 * newer release is found, tapping opens the release page.
 */
object UpdateNotify {
    private const val TAG = "UpdateNotify"
    private const val CHANNEL = "cresca_updates"
    private const val NOTIF_ID = 9001
    private const val KEY_NOTIFIED = "update_notified_tag"

    private fun channel(ctx: Context) {
        try {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            try {
                nm.getNotificationChannel(CHANNEL)?.let { return }
            } catch (e: Exception) {
            }
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    "App updates",
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "New Cresca releases"
                }
            )
        } catch (e: Exception) {
            Log.w(TAG, "channel failed", e)
        }
    }

    private fun alreadyNotified(ctx: Context, tag: String): Boolean {
        return try {
            ctx.getSharedPreferences(UpdateCheck.PREFS, Context.MODE_PRIVATE)
                .getString(KEY_NOTIFIED, "") == tag
        } catch (e: Exception) {
            false
        }
    }

    private fun markNotified(ctx: Context, tag: String) {
        try {
            ctx.getSharedPreferences(UpdateCheck.PREFS, Context.MODE_PRIVATE)
                .edit().putString(KEY_NOTIFIED, tag).apply()
        } catch (e: Exception) {
        }
    }

    /** Post a heads-up notification once per release tag. Never throws. */
    fun notifyIfNewer(ctx: Context, update: UpdateCheck.Update?) {
        try {
            if (update == null || update.tag.isBlank() || update.url.isBlank()) return
            if (alreadyNotified(ctx, update.tag)) return
            // POST_NOTIFICATIONS gate: no permission -> skip silently.
            if (Build.VERSION.SDK_INT >= 33) {
                try {
                    val granted = androidx.core.content.ContextCompat.checkSelfPermission(
                        ctx, android.Manifest.permission.POST_NOTIFICATIONS
                    ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    if (!granted) return
                } catch (e: Exception) {
                }
            }
            channel(ctx)
            val open = try {
                PendingIntent.getActivity(
                    ctx, 0,
                    Intent(Intent.ACTION_VIEW, Uri.parse(update.url)).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    },
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            } catch (e: Exception) {
                return
            }
            val notif = try {
                NotificationCompat.Builder(ctx, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentTitle("Cresca update available: ${update.tag}")
                    .setContentText("Tap to download the latest release")
                    .setContentIntent(open)
                    .setAutoCancel(true)
                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                    .build()
            } catch (e: Exception) {
                return
            }
            try {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIF_ID, notif)
                markNotified(ctx, update.tag)
                Log.i(TAG, "notified ${update.tag}")
            } catch (e: Exception) {
                Log.w(TAG, "notify failed", e)
            }
        } catch (e: Exception) {
        }
    }
}
