package com.cresca.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log

/**
 * Unknown-apps install permission: the classic silent failure is tapping
 * "install" with this OFF — the system swallows the intent and nothing
 * happens. Check first, deep-link to the exact settings page otherwise.
 */
object UpdateInstall {
    private const val TAG = "UpdateInstall"

    /** True when firing an APK install intent can actually work. */
    fun canInstall(ctx: Context): Boolean {
        return try {
            if (Build.VERSION.SDK_INT < 26) return true
            ctx.packageManager.canRequestPackageInstalls()
        } catch (e: Exception) {
            true
        }
    }

    /** Opens this app's "Install unknown apps" settings page. False when it can't. */
    fun openUnknownAppsSettings(ctx: Context): Boolean {
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + ctx.packageName)
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.applicationContext.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "settings open failed", e)
            try {
                val fallback = Intent(Settings.ACTION_SECURITY_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                ctx.applicationContext.startActivity(fallback)
                true
            } catch (e2: Exception) {
                false
            }
        }
    }
}
