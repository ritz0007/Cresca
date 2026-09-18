package com.cresca.app

import android.content.Context
import android.content.SharedPreferences
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// Encrypted on-device store for the YouTube login session.
object YtSessionManager {
    private const val FILE = "yt_session_enc"
    private const val KEY_COOKIES = "cookies"
    private const val KEY_VISITOR = "visitor"
    private const val MUSIC_URL = "https://music.youtube.com"

    private fun prefs(ctx: Context): SharedPreferences {
        val app = ctx.applicationContext
        val masterKey = MasterKey.Builder(app)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            app,
            FILE,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    fun saveSession(ctx: Context, cookies: String, visitorData: String) {
        prefs(ctx).edit()
            .putString(KEY_COOKIES, cookies)
            .putString(KEY_VISITOR, visitorData)
            .apply()
    }

    fun loadCookies(ctx: Context): String {
        return try {
            prefs(ctx).getString(KEY_COOKIES, "") ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    fun loadVisitorData(ctx: Context): String {
        return try {
            prefs(ctx).getString(KEY_VISITOR, "") ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    fun isLoggedIn(ctx: Context): Boolean {
        val c = loadCookies(ctx)
        return c.contains("SAPISID") || c.contains("SID")
    }

    fun logout(ctx: Context) {
        try {
            prefs(ctx).edit().remove(KEY_COOKIES).remove(KEY_VISITOR).apply()
        } catch (e: Exception) {
        }
        try {
            CookieManager.getInstance().removeAllCookies(null)
            CookieManager.getInstance().flush()
        } catch (e: Exception) {
        }
    }

    fun loginWebView(ctx: Context, onDone: () -> Unit): WebView {
        val wv = WebView(ctx)
        try {
            CookieManager.getInstance().setAcceptCookie(true)
        } catch (e: Exception) {
        }
        wv.settings.javaScriptEnabled = true
        wv.settings.domStorageEnabled = true
        // Desktop UA: Google blocks logins from embedded-WebView agents.
        try {
            wv.settings.userAgentString =
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        } catch (e: Exception) {
        }
        try {
            CookieManager.getInstance().setAcceptThirdPartyCookies(wv, true)
        } catch (e: Exception) {
        }
        wv.webViewClient = WebViewClient()
        wv.loadUrl(MUSIC_URL)
        return wv
    }

    suspend fun capture(ctx: Context) {
        val app = ctx.applicationContext
        // CookieManager must be read on the main thread.
        val raw = withContext(Dispatchers.Main) {
            try {
                CookieManager.getInstance().getCookie(MUSIC_URL) ?: ""
            } catch (e: Exception) {
                ""
            }
        }
        var visitor = try {
            loadVisitorData(app)
        } catch (e: Exception) {
            ""
        }
        // Best effort: keep VISITOR_INFO1_LIVE value as visitor data when present.
        try {
            val parts = raw.split(";")
            for (i in parts.indices) {
                val part = parts[i].trim()
                val eq = part.indexOf("=")
                if (eq > 0) {
                    val name = part.substring(0, eq).trim()
                    val value = part.substring(eq + 1).trim()
                    if (name == "VISITOR_INFO1_LIVE" && value.isNotEmpty()) {
                        visitor = value
                    }
                }
            }
        } catch (e: Exception) {
        }
        try {
            withContext(Dispatchers.IO) {
                saveSession(app, raw, visitor)
            }
        } catch (e: Exception) {
        }
    }
}
