package com.cresca.app

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.FileProvider
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import java.io.File

/**
 * Seamless updates: notification tap / Settings downloads the APK for THIS
 * device's ABI straight from the release assets (no browser, no release
 * page), then one more tap installs it. Falls back to the release page
 * when no matching asset exists.
 */
object UpdateDownload {
    private const val TAG = "UpdateDL"
    private const val PREFS = "cresca_prefs"
    private const val KEY_DL_ID = "update_download_id"
    private const val KEY_DL_TAG = "update_download_tag"
    private const val KEY_DL_NAME = "update_download_name"
    private const val CHANNEL = "cresca_updates"
    private const val NOTIF_ID = 9001
    private const val READY_ID = 9002
    const val ACTION_DOWNLOAD = "com.cresca.app.UPDATE_DOWNLOAD"
    const val AUTHORITY_SUFFIX = ".fileprovider"

    fun fileNameFor(tag: String, apkName: String): String {
        return try {
            if (apkName.isNotBlank()) apkName
            else "Cresca-$tag-${UpdateCheck.deviceAbi()}.apk"
        } catch (e: Exception) {
            "Cresca-$tag.apk"
        }
    }

    /** Enqueue the APK download. Returns false when there is nothing to fetch. */
    fun startDownload(ctx: Context, update: UpdateCheck.Update?): Boolean {
        try {
            if (update == null || update.apkUrl.isBlank()) return false
            val app = ctx.applicationContext
            val name = fileNameFor(update.tag, update.apkName)
            // Avoid double-enqueue for the same tag.
            try {
                val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                if (prefs.getString(KEY_DL_TAG, "") == update.tag &&
                    prefs.getLong(KEY_DL_ID, -1L) >= 0L
                ) {
                    return true
                }
            } catch (e: Exception) {
            }
            val req = try {
                DownloadManager.Request(Uri.parse(update.apkUrl))
                    .setTitle("Cresca ${update.tag}")
                    .setDescription("Downloading update…")
                    .setNotificationVisibility(
                        DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                    )
                    .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name)
                    .setMimeType("application/vnd.android.package-archive")
            } catch (e: Exception) {
                return false
            }
            val dm = try {
                app.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            } catch (e: Exception) {
                return false
            }
            val id = try {
                dm.enqueue(req)
            } catch (e: Exception) {
                return false
            }
            try {
                app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .putLong(KEY_DL_ID, id)
                    .putString(KEY_DL_TAG, update.tag)
                    .putString(KEY_DL_NAME, name)
                    .apply()
            } catch (e: Exception) {
            }
            progressNote(app, update.tag)
            Log.i(TAG, "downloading ${update.tag} -> $name")
            return true
        } catch (e: Exception) {
            return false
        }
    }

    private fun progressNote(ctx: Context, tag: String) {
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                try {
                    val granted = androidx.core.content.ContextCompat.checkSelfPermission(
                        ctx, android.Manifest.permission.POST_NOTIFICATIONS
                    ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    if (!granted) return
                } catch (e: Exception) {
                }
            }
            ensureChannel(ctx)
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(
                NOTIF_ID,
                NotificationCompat.Builder(ctx, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_sys_download)
                    .setContentTitle("Downloading Cresca $tag…")
                    .setContentText("The installer appears when it finishes")
                    .setOngoing(true)
                    .setPriority(NotificationCompat.PRIORITY_LOW)
                    .build()
            )
        } catch (e: Exception) {
        }
    }

    internal fun installFile(ctx: Context, file: File): Boolean {
        return try {
            if (!file.exists()) return false
            val uri = FileProvider.getUriForFile(
                ctx.applicationContext, ctx.packageName + AUTHORITY_SUFFIX, file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            ctx.applicationContext.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "install launch failed", e)
            false
        }
    }

    internal fun downloadedFile(ctx: Context): File? {
        return try {
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val name = prefs.getString(KEY_DL_NAME, "") ?: ""
            if (name.isBlank()) return null
            val f = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                name
            )
            if (f.exists() && f.length() > 0L) f else null
        } catch (e: Exception) {
            null
        }
    }

    internal fun clearRecord(ctx: Context) {
        try {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .remove(KEY_DL_ID).remove(KEY_DL_TAG).remove(KEY_DL_NAME).apply()
        } catch (e: Exception) {
        }
    }

    private fun ensureChannel(ctx: Context) {
        try {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            try {
                nm.getNotificationChannel(CHANNEL)?.let { return }
            } catch (e: Exception) {
            }
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "App updates", NotificationManager.IMPORTANCE_DEFAULT)
            )
        } catch (e: Exception) {
        }
    }

    internal fun notifyReady(ctx: Context, tag: String, file: File) {
        try {
            ensureChannel(ctx)
            val uri = FileProvider.getUriForFile(
                ctx.applicationContext, ctx.packageName + AUTHORITY_SUFFIX, file
            )
            val install = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val pi = PendingIntent.getActivity(
                ctx, 1, install,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            try {
                nm.cancel(NOTIF_ID)
            } catch (e: Exception) {
            }
            nm.notify(
                READY_ID,
                NotificationCompat.Builder(ctx, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentTitle("Cresca $tag downloaded")
                    .setContentText("Tap to install")
                    .setContentIntent(pi)
                    .setAutoCancel(true)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .build()
            )
        } catch (e: Exception) {
        }
    }
}

/**
 * Manifest receiver: notification tap starts the download; system download
 * completion fires the tap-to-install notification. Never throws.
 */
class UpdateActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            val app = context.applicationContext
            when (intent.action) {
                UpdateDownload.ACTION_DOWNLOAD -> {
                    val tag = intent.getStringExtra("tag") ?: ""
                    val apkUrl = intent.getStringExtra("apkUrl") ?: ""
                    val apkName = intent.getStringExtra("apkName") ?: ""
                    val page = intent.getStringExtra("page") ?: ""
                    if (apkUrl.isBlank()) {
                        // No direct asset: old behavior (release page).
                        try {
                            if (page.isNotBlank()) {
                                app.startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse(page)).apply {
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                )
                            }
                        } catch (e: Exception) {
                        }
                        return
                    }
                    val ok = UpdateDownload.startDownload(
                        app, UpdateCheck.Update(tag, page, apkUrl, apkName)
                    )
                    if (!ok && page.isNotBlank()) {
                        try {
                            app.startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(page)).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                            )
                        } catch (e: Exception) {
                        }
                    }
                }
                DownloadManager.ACTION_DOWNLOAD_COMPLETE -> {
                    val id = try {
                        intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
                    } catch (e: Exception) {
                        -1L
                    }
                    val want = try {
                        app.getSharedPreferences("cresca_prefs", Context.MODE_PRIVATE)
                            .getLong("update_download_id", -2L)
                    } catch (e: Exception) {
                        -2L
                    }
                    if (id < 0L || id != want) return
                    val tag = try {
                        app.getSharedPreferences("cresca_prefs", Context.MODE_PRIVATE)
                            .getString("update_download_tag", "") ?: ""
                    } catch (e: Exception) {
                        ""
                    }
                    val file = UpdateDownload.downloadedFile(app)
                    UpdateDownload.clearRecord(app)
                    if (file != null) {
                        UpdateDownload.notifyReady(app, tag, file)
                    }
                }
            }
        } catch (e: Exception) {
        }
    }
}
