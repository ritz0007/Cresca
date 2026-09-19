package com.cresca.app

import android.content.Context
import android.content.Intent
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * On-device crash log (no network, no analytics — privacy promise kept).
 * Installs as the default uncaught handler, chains to the previous one so
 * the system still shows the crash dialog, and keeps the last 5 crashes in
 * filesDir/crash/. The user can share the latest log from Profile so a real
 * stack trace can be fixed instead of guessed.
 */
object CrashLog {
    private const val TAG = "CrashLog"
    private const val DIR = "crash"
    private const val KEEP = 5

    @Volatile private var installed = false

    fun install(ctx: Context) {
        if (installed) return
        installed = true
        try {
            val app = ctx.applicationContext
            val prev = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { t, e ->
                try {
                    write(app, t, e)
                } catch (ignored: Exception) {
                }
                try {
                    prev?.uncaughtException(t, e)
                } catch (ignored: Exception) {
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "install failed", e)
        }
    }

    fun write(ctx: Context, thread: Thread, error: Throwable) {
        try {
            val dir = File(ctx.applicationContext.filesDir, DIR).apply { mkdirs() }
            val stamp = try {
                SimpleDateFormat("yyyy-MM-dd_HH-mm-ss", Locale.US).format(Date())
            } catch (e: Exception) {
                System.currentTimeMillis().toString()
            }
            val info = StringBuilder()
            info.append("time=").append(stamp).append('\n')
            info.append("thread=").append(thread.name).append('\n')
            try {
                val pi = ctx.applicationContext.packageManager
                    .getPackageInfo(ctx.applicationContext.packageName, 0)
                info.append("version=").append(pi.versionName)
                    .append(" (").append(pi.versionCode).append(")\n")
                info.append("sdk=").append(android.os.Build.VERSION.SDK_INT).append('\n')
                info.append("device=").append(android.os.Build.MANUFACTURER)
                    .append(' ').append(android.os.Build.MODEL).append('\n')
            } catch (e: Exception) {
            }
            info.append(Log.getStackTraceString(error))
            File(dir, "crash-$stamp.log").writeText(info.toString())
            // Ring buffer: keep the newest few.
            try {
                val all = dir.listFiles { f -> f.isFile && f.name.startsWith("crash-") }
                    ?.sortedBy { it.name } ?: emptyList()
                for (i in 0 until (all.size - KEEP).coerceAtLeast(0)) {
                    try {
                        all[i].delete()
                    } catch (e: Exception) {
                    }
                }
            } catch (e: Exception) {
            }
        } catch (e: Exception) {
            Log.w(TAG, "write failed", e)
        }
    }

    /** Newest crash log text, or null when the app never crashed. */
    fun latest(ctx: Context): String? {
        return try {
            val dir = File(ctx.applicationContext.filesDir, DIR)
            dir.listFiles { f -> f.isFile && f.name.startsWith("crash-") }
                ?.maxByOrNull { it.name }
                ?.readText()
        } catch (e: Exception) {
            null
        }
    }

    fun shareLatest(ctx: Context) {
        try {
            val text = latest(ctx) ?: return
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_SUBJECT, "Cresca crash log")
                putExtra(Intent.EXTRA_TEXT, text.take(100 * 1024))
            }
            ctx.startActivity(
                Intent.createChooser(send, "Share crash log").apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
        } catch (e: Exception) {
            Log.w(TAG, "share failed", e)
        }
    }
}
