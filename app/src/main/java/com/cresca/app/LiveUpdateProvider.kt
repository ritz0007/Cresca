package com.cresca.app

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.media3.session.CommandButton
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaNotification
import androidx.media3.session.MediaSession
import com.google.common.collect.ImmutableList

/**
 * Media notification with Android Live Updates (Dynamic Island style).
 *
 * On API 36+ this rebuilds Media3's notification as a promoted ongoing
 * ProgressStyle notification: status-bar chip, top-ranked drawer entry,
 * lockscreen presence, progress bar tracking the song. Older APIs get
 * Media3's default notification untouched.
 */
class LiveUpdateProvider(ctx: Context) : MediaNotification.Provider {

    companion object {
        private const val TAG = "LiveUpdate"
        const val LIVE_UPDATE_SDK = 36
    }

    private val app = ctx.applicationContext
    private val base: DefaultMediaNotificationProvider =
        DefaultMediaNotificationProvider.Builder(ctx).build()
    private val notifications: NotificationManager =
        app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    @Volatile private var lastId: Int = 0
    @Volatile private var lastBase: Notification? = null

    override fun createNotification(
        session: MediaSession,
        customLayout: ImmutableList<CommandButton>,
        actionFactory: MediaNotification.ActionFactory,
        callback: MediaNotification.Provider.Callback
    ): MediaNotification {
        val built = base.createNotification(session, customLayout, actionFactory, callback)
        if (Build.VERSION.SDK_INT < LIVE_UPDATE_SDK) {
            return built
        }
        return try {
            lastId = built.notificationId
            lastBase = built.notification
            if (!canPromote()) {
                return built
            }
            MediaNotification(built.notificationId, buildLive(session, built.notification))
        } catch (e: Exception) {
            Log.w(TAG, "live update failed, default notification", e)
            built
        }
    }

    override fun handleCustomCommand(
        session: MediaSession,
        action: String,
        extras: Bundle
    ): Boolean {
        return base.handleCustomCommand(session, action, extras)
    }

    /** Re-posts progress while playing (provider is only re-queried on state changes). */
    fun refreshProgress(session: MediaSession) {
        if (Build.VERSION.SDK_INT < LIVE_UPDATE_SDK) {
            return
        }
        try {
            val b = lastBase ?: return
            if (!canPromote()) {
                return
            }
            notifications.notify(lastId, buildLive(session, b))
        } catch (e: Exception) {
            Log.w(TAG, "progress refresh failed", e)
        }
    }

    private fun canPromote(): Boolean {
        if (Build.VERSION.SDK_INT < LIVE_UPDATE_SDK) {
            return false
        }
        return try {
            notifications.canPostPromotedNotifications()
        } catch (e: Exception) {
            false
        }
    }

    private fun buildLive(session: MediaSession, b: Notification): Notification {
        val player = session.player
        val durMs = try {
            player.duration.coerceAtLeast(0L)
        } catch (e: Exception) {
            0L
        }
        val posMs = try {
            player.currentPosition.coerceAtLeast(0L)
        } catch (e: Exception) {
            0L
        }
        val durSec = ((durMs / 1000).toInt()).coerceAtLeast(1)
        val posSec = ((posMs / 1000).toInt()).coerceIn(0, durSec)
        val title = b.extras.getString(Notification.EXTRA_TITLE, "Cresca Music")
        val artist = b.extras.getString(Notification.EXTRA_TEXT, "")

        val style = Notification.ProgressStyle()
            .setProgressSegments(
                mutableListOf(
                    Notification.ProgressStyle.Segment(durSec).setColor(Color.LTGRAY)
                )
            )
            .setProgress(posSec)
            .setStyledByProgress(true)

        val builder = Notification.Builder(app, b.channelId)
            .setContentTitle(title)
            .setContentText(artist)
            .setOngoing(true)
            .setStyle(style)
            .addExtras(Bundle().apply {
                putBoolean("android.requestPromotedOngoing", true)
            })
        try {
            val icon = b.smallIcon
            if (icon != null) {
                builder.setSmallIcon(icon)
            }
        } catch (e: Exception) {
        }
        try {
            val intent = b.contentIntent
            if (intent != null) {
                builder.setContentIntent(intent)
            }
        } catch (e: Exception) {
        }
        try {
            val actions = b.actions
            val scored = ArrayList<Triple<Int, Int, Notification.Action>>()
            var hasNext = false
            var hasPrev = false
            var hasPlay = false
            if (actions != null) {
                for (i in 0 until actions.size) {
                    val a = actions[i] ?: continue
                    val ai = try {
                        a.actionIntent
                    } catch (e: Exception) {
                        null
                    }
                    if (ai == null) {
                        continue
                    }
                    val aicon: Icon? = try {
                        a.getIcon()
                    } catch (e: Exception) {
                        null
                    }
                    val atitle = try {
                        a.title
                    } catch (e: Exception) {
                        null
                    } ?: ""
                    if (aicon == null) {
                        continue
                    }
                    val low = atitle.toString().lowercase()
                    if (low.contains("next")) hasNext = true
                    if (low.contains("prev")) hasPrev = true
                    if (low.startsWith("play") || low.startsWith("pause")) hasPlay = true
                    val rank = when {
                        low.startsWith("play") || low.startsWith("pause") -> 0
                        low.contains("next") -> 1
                        low.contains("prev") -> 2
                        else -> 3
                    }
                    scored.add(Triple(rank, i, Notification.Action.Builder(aicon, atitle, ai).build()))
                }
            }
            // Add synthetic Next action if missing (for Live Updates card).
            if (!hasNext && hasPlay) {
                // Create a proper PendingIntent for Next that triggers a broadcast
                // to seek to next via the MediaController.
                val nextIntent = Intent("com.cresca.app.NEXT_ACTION")
                    .setPackage(app.packageName)
                val ai = PendingIntent.getBroadcast(
                    app,
                    0,
                    nextIntent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
                val aicon = Icon.createWithResource(app, android.R.drawable.ic_media_next)
                scored.add(Triple(1, Int.MAX_VALUE, Notification.Action.Builder(aicon, "Next", ai).build()))
                hasNext = true
            }
            scored.sortWith(compareBy({ it.first }, { it.second }))
            for ((_, _, act) in scored) {
                builder.addAction(act)
            }
        } catch (e: Exception) {
        }
        return builder.build()
    }
}
