package com.cresca.app

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Checks GitHub releases for a newer Cresca build.
 * Public repo endpoint: no auth needed.
 */
object UpdateCheck {
    private const val TAG = "UpdateCheck"
    const val REPO = "ritz0007/Cresca"
    const val PREFS = "cresca_prefs"
    private const val KEY_LAST = "update_last_check"
    private const val INTERVAL_MS = 24 * 60 * 60 * 1000L

    data class Update(val tag: String, val url: String)

    fun currentVersion(ctx: Context): String {
        return try {
            val pm = ctx.packageManager
            pm.getPackageInfo(ctx.packageName, 0)?.versionName ?: "0.0.0"
        } catch (e: Exception) {
            "0.0.0"
        }
    }

    fun dueForCheck(ctx: Context): Boolean {
        return try {
            val last = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getLong(KEY_LAST, 0L)
            System.currentTimeMillis() - last > INTERVAL_MS
        } catch (e: Exception) {
            true
        }
    }

    fun markChecked(ctx: Context) {
        try {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putLong(KEY_LAST, System.currentTimeMillis()).apply()
        } catch (e: Exception) {
        }
    }

    suspend fun latest(): Update? =
        withContext(Dispatchers.IO) {
            try {
                val client = OkHttpClient.Builder()
                    .connectTimeout(15, TimeUnit.SECONDS)
                    .readTimeout(15, TimeUnit.SECONDS)
                    .build()
                val req = Request.Builder()
                    .url("https://api.github.com/repos/" + REPO + "/releases/latest")
                    .header("User-Agent", "Cresca")
                    .header("Accept", "application/vnd.github+json")
                    .get().build()
                client.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) {
                        return@withContext null
                    }
                    val json = JSONObject(resp.body?.string() ?: "")
                    val tag = json.optString("tag_name", "")
                    val url = json.optString("html_url", "")
                    if (tag.isBlank() || url.isBlank()) {
                        return@withContext null
                    }
                    Update(tag, url)
                }
            } catch (e: Exception) {
                Log.w(TAG, "update check failed", e)
                null
            }
        }

    // True when latest is a higher dotted version than current.
    fun isNewer(current: String, latest: String): Boolean {
        try {
            fun parts(v: String): List<Int> {
                val clean = v.trim().trimStart('v', 'V')
                return clean.split(".", "-", "_").map { it.toIntOrNull() ?: 0 }
            }
            val c = parts(current)
            val l = parts(latest)
            val n = maxOf(c.size, l.size)
            for (i in 0 until n) {
                val a = if (i < c.size) c[i] else 0
                val b = if (i < l.size) l[i] else 0
                if (b != a) {
                    return b > a
                }
            }
            return false
        } catch (e: Exception) {
            return false
        }
    }
}
