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

    data class Update(val tag: String, val url: String, val apkUrl: String = "", val apkName: String = "")

    /** Device ABI slug matching release asset names (arm64/armv7/x86_64). */
    internal fun deviceAbi(): String {
        return try {
            val abis = android.os.Build.SUPPORTED_ABIS ?: arrayOf()
            when {
                abis.contains("arm64-v8a") -> "arm64"
                abis.contains("armeabi-v7a") -> "armv7"
                abis.contains("x86_64") -> "x86_64"
                else -> "universal"
            }
        } catch (e: Exception) {
            "universal"
        }
    }

    /** Pick the direct APK asset for this device (exact ABI, else universal). */
    internal fun pickApkAsset(names: List<Pair<String, String>>): Pair<String, String>? {
        return try {
            if (names.isEmpty()) return null
            val abi = deviceAbi()
            names.firstOrNull { it.first.contains("-$abi.apk") }
                ?: names.firstOrNull { it.first.contains("-universal.apk") }
        } catch (e: Exception) {
            null
        }
    }

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
            // Primary: latest non-draft release. Fallback: newest entry of
            // the releases list (covers API hiccups on the /latest alias).
            try {
                fetchRelease(
                    "https://api.github.com/repos/" + REPO + "/releases/latest",
                    single = true
                )?.let { return@withContext it }
            } catch (e: Exception) {
            }
            try {
                fetchRelease(
                    "https://api.github.com/repos/" + REPO + "/releases?per_page=5",
                    single = false
                )
            } catch (e: Exception) {
                Log.w(TAG, "update check failed", e)
                null
            }
        }

    private fun client(): OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    private fun fetchRelease(url: String, single: Boolean): Update? {
        return try {
            val req = Request.Builder()
                .url(url)
                .header("User-Agent", "Cresca")
                .header("Accept", "application/vnd.github+json")
                .header("Cache-Control", "no-cache")
                .get().build()
            client().newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return null
                val text = resp.body?.string() ?: return null
                if (single) {
                    parseRelease(JSONObject(text))
                } else {
                    val arr = try {
                        org.json.JSONArray(text)
                    } catch (e: Exception) {
                        return null
                    }
                    for (i in 0 until arr.length()) {
                        try {
                            parseRelease(arr.optJSONObject(i) ?: continue)?.let { return it }
                        } catch (e: Exception) {
                        }
                    }
                    null
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "update fetch failed", e)
            null
        }
    }

    /** Pure: one release JSON → Update, or null (drafts/missing fields). Testable. */
    internal fun parseRelease(json: JSONObject): Update? {
        return try {
            if (json.optBoolean("draft", false)) return null
            val tag = json.optString("tag_name", "")
            val url = json.optString("html_url", "")
            if (tag.isBlank() || url.isBlank()) return null
            // Direct APK asset for this device (seamless download).
            var apkUrl = ""
            var apkName = ""
            try {
                val assets = json.optJSONArray("assets")
                if (assets != null) {
                    val names = ArrayList<Pair<String, String>>()
                    for (i in 0 until assets.length()) {
                        val a = assets.optJSONObject(i) ?: continue
                        val n = a.optString("name", "")
                        val u = a.optString("browser_download_url", "")
                        if (n.endsWith(".apk") && u.isNotBlank()) names.add(Pair(n, u))
                    }
                    val pick = pickApkAsset(names)
                    if (pick != null) {
                        apkName = pick.first
                        apkUrl = pick.second
                    }
                }
            } catch (e: Exception) {
            }
            Update(tag, url, apkUrl, apkName)
        } catch (e: Exception) {
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
