package com.cresca.app

import android.content.Context
import android.content.SharedPreferences
import android.webkit.CookieManager
import android.webkit.WebView
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// Encrypted on-device store for the YouTube login session.
object YtSessionManager {
    private const val FILE = "yt_session_enc"
    private const val KEY_COOKIES = "cookies"
    private const val KEY_VISITOR = "visitor"
    private const val KEY_POTOKEN = "po_token"
    private const val MUSIC_URL = "https://music.youtube.com"

    /**
     * Flip to true to force login before any InnerTube fetch (user-requested
     * mandatory login for PO-token). Default false during scaffold so
     * logged-out users keep working via NewPipe fallback while the token
     * path is proven; set true once BotGuard fetch is wired to WebView.
     */
    const val MANDATORY_LOGIN_FOR_INNERTUBE = false

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

    /** PO-token (BotGuard) from the logged-in account. Short-lived; refresh via WebView. */
    fun savePoToken(ctx: Context, token: String) {
        try {
            prefs(ctx).edit().putString(KEY_POTOKEN, token).apply()
        } catch (e: Exception) {
        }
    }

    fun loadPoToken(ctx: Context): String {
        return try {
            prefs(ctx).getString(KEY_POTOKEN, "") ?: ""
        } catch (e: Exception) {
            ""
        }
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

    /** Gate for mandatory-login mode: true when fetches may proceed. */
    fun canFetchInnerTube(ctx: Context): Boolean {
        if (!MANDATORY_LOGIN_FOR_INNERTUBE) return true
        return try {
            isLoggedIn(ctx)
        } catch (e: Exception) {
            false
        }
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
        // Hardened login surface (undetectable embedded browser); the Done
        // + capture flow in SessionSheet is unchanged.
        return LoginWebView.create(ctx, onDone)
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
        // Session health for InnerTube fast path (never throws, never blocks).
        try {
            val hasLogin = try { raw.contains("SAPISID") || raw.contains("SID") } catch (e: Exception) { false }
            val hasVisitor = visitor.isNotBlank()
            val hasPo = try { loadPoToken(app).isNotBlank() } catch (e: Exception) { false }
            android.util.Log.d("YtSession", "capture login=$hasLogin visitor=$hasVisitor poToken=$hasPo")
            if (!hasPo) {
                // BotGuard PO-token solving (zemer-cipher / WebView challenge)
                // is TODO: player/search already attach the token when present
                // and work without it for most content. This stub keeps the
                // login flow unblocked while the solver is built.
                android.util.Log.d("YtSession", "poToken absent — fast path runs without it; solver TODO")
            }
        } catch (e: Exception) {
        }
    }
}
