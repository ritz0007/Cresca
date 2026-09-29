package com.cresca.app.spotify

import android.content.Context
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.Request
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * Spotify login via Authorization Code + PKCE (no client secret, no new
 * deps: browser Custom Tab / VIEW intent + OkHttp + org.json only).
 *
 * Setup (one time, owner only): create an app at
 * developer.spotify.com/dashboard, add redirect URI
 * `cresca://spotify-callback`. The client ID lives in gitignored
 * local.properties and is baked into BuildConfig XOR+Base64 — never in
 * the repo, never plaintext in the APK. Scopes are read-only:
 * playlists, saved tracks, top artists/tracks.
 */
object SpotifyAuth {
    private const val TAG = "SpotifyAuth"

    /** XOR key mirroring the Gradle-side obfuscation (obscurity, not crypto). */
    private const val OBF_KEY = "cresca-spotify-obf"

    const val REDIRECT_URI = "cresca://spotify-callback"
    private const val SCOPES =
        "playlist-read-private playlist-read-collaborative user-library-read " +
            "user-top-read user-read-private"

    private const val ENC_FILE = "spotify_enc"
    private const val K_ACCESS = "access"
    private const val K_REFRESH = "refresh"
    private const val K_EXPIRY = "expiry_ms"
    private const val PREFS = "cresca_prefs"
    private const val K_CLIENT_ID = "spotify_client_id"
    private const val K_VERIFIER = "spotify_verifier"
    private const val K_STATE = "spotify_state"

    private val http = okhttp3.OkHttpClient.Builder()
        .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(12, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(12, java.util.concurrent.TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    private fun encPrefs(ctx: Context) = EncryptedSharedPreferences.create(
        ctx.applicationContext,
        ENC_FILE,
        MasterKey.Builder(ctx.applicationContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Built-in ID decoded from BuildConfig (empty on clones without local.properties). */
    private fun builtInId(): String {
        return try {
            val obf = com.cresca.app.BuildConfig.SPOTIFY_CLIENT_ID_OBF
            if (obf.isBlank()) return ""
            val b = java.util.Base64.getDecoder().decode(obf)
            val key = OBF_KEY.toByteArray(Charsets.UTF_8)
            for (i in b.indices) b[i] = (b[i].toInt() xor key[i % key.size].toInt()).toByte()
            String(b, Charsets.UTF_8).takeIf { it.isNotBlank() } ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    /** True when the APK ships a built-in client ID (one-tap login, no manual entry). */
    fun hasBuiltInId(): Boolean {
        return try {
            builtInId().isNotBlank()
        } catch (e: Exception) {
            false
        }
    }

    /** Effective client ID: manual Profile override, else the built-in baked ID. */
    fun clientId(ctx: Context): String {
        return try {
            val p = prefs(ctx)
            val over = try {
                p.getString(K_CLIENT_ID, "") ?: ""
            } catch (e: Exception) {
                ""
            }
            val builtIn = builtInId()
            if (over.isNotBlank() && over == builtIn) {
                // Redundant plaintext copy of the baked ID (typed before the
                // baked build existed): drop it so only the obfuscated copy lives on.
                try {
                    p.edit().remove(K_CLIENT_ID).apply()
                } catch (e: Exception) {
                }
                builtIn
            } else if (over.isNotBlank()) {
                over
            } else {
                builtIn
            }
        } catch (e: Exception) {
            try {
                builtInId()
            } catch (e2: Exception) {
                ""
            }
        }
    }

    fun setClientId(ctx: Context, id: String) {
        try {
            prefs(ctx).edit().putString(K_CLIENT_ID, id.trim()).apply()
        } catch (e: Exception) {
        }
    }

    /** PKCE verifier: 64 random bytes, base64url, no padding. */
    internal fun newVerifier(): String {
        val bytes = ByteArray(64)
        SecureRandom().nextBytes(bytes)
        // java.util.Base64 (not android.util): plain JVM in unit tests, API 26+ on device.
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    /** S256 challenge for a verifier (pure, unit-tested). */
    internal fun challenge(verifier: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(verifier.toByteArray(Charsets.US_ASCII))
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
    }

    internal fun newState(): String {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    /** Starts login: persists verifier/state, returns the URL to open. Null when no client ID. */
    fun authUrl(ctx: Context): String? {
        val id = clientId(ctx)
        if (id.isBlank()) return null
        return try {
            val verifier = newVerifier()
            val state = newState()
            prefs(ctx).edit()
                .putString(K_VERIFIER, verifier)
                .putString(K_STATE, state)
                .apply()
            "https://accounts.spotify.com/authorize" +
                "?client_id=${android.net.Uri.encode(id)}" +
                "&response_type=code" +
                "&redirect_uri=${android.net.Uri.encode(REDIRECT_URI)}" +
                "&scope=${android.net.Uri.encode(SCOPES)}" +
                // Always re-show consent: stale grants (fewer scopes) are
                // otherwise reused silently and playlist reads 403 forever.
                "&show_dialog=true" +
                "&code_challenge_method=S256" +
                "&code_challenge=${android.net.Uri.encode(challenge(verifier))}" +
                "&state=${android.net.Uri.encode(state)}"
        } catch (e: Exception) {
            Log.w(TAG, "authUrl failed", e)
            null
        }
    }

    /** Redirect callback store: activity parks the code, Compose consumes it. */
    object Link {
        @Volatile var pendingCode: String? = null
        @Volatile var pendingState: String? = null
    }

    /** Exchanges a callback code for tokens. Returns true on success. */
    suspend fun exchange(ctx: Context, code: String, state: String?): Boolean =
        withContext(Dispatchers.IO) {
            try {
                val app = ctx.applicationContext
                val savedState = try {
                    prefs(app).getString(K_STATE, "")
                } catch (e: Exception) {
                    ""
                }
                if (!savedState.isNullOrEmpty() && !state.isNullOrEmpty() && savedState != state) {
                    Log.w(TAG, "state mismatch")
                    return@withContext false
                }
                val verifier = try {
                    prefs(app).getString(K_VERIFIER, "") ?: ""
                } catch (e: Exception) {
                    ""
                }
                if (verifier.isBlank()) return@withContext false
                val body = FormBody.Builder()
                    .add("grant_type", "authorization_code")
                    .add("code", code)
                    .add("redirect_uri", REDIRECT_URI)
                    .add("client_id", clientId(app))
                    .add("code_verifier", verifier)
                    .build()
                val req = Request.Builder()
                    .url("https://accounts.spotify.com/api/token")
                    .post(body)
                    .header("Content-Type", "application/x-www-form-urlencoded")
                    .build()
                http.newCall(req).execute().use { resp ->
                    val text = resp.body?.string() ?: return@withContext false
                    if (!resp.isSuccessful) {
                        Log.w(TAG, "exchange http ${resp.code}")
                        return@withContext false
                    }
                    saveTokenJson(app, JSONObject(text))
                    try {
                        prefs(app).edit()
                            .remove(K_VERIFIER).remove(K_STATE).apply()
                    } catch (e: Exception) {
                    }
                    true
                }
            } catch (e: Exception) {
                Log.w(TAG, "exchange failed", e)
                false
            }
        }

    private fun saveTokenJson(ctx: Context, o: JSONObject) {
        val access = o.optString("access_token", "")
        if (access.isBlank()) return
        val refresh = o.optString("refresh_token", "")
        val expiresIn = o.optLong("expires_in", 3600L)
        val expiry = System.currentTimeMillis() + expiresIn * 1000L
        val keepRefresh = try {
            if (refresh.isNotBlank()) refresh else encPrefs(ctx).getString(K_REFRESH, "")
        } catch (e: Exception) {
            refresh
        }
        encPrefs(ctx).edit()
            .putString(K_ACCESS, access)
            .putString(K_REFRESH, keepRefresh ?: "")
            .putLong(K_EXPIRY, expiry)
            .apply()
    }

    /** Valid access token, refreshing once when expired. "" when logged out. */
    suspend fun accessToken(ctx: Context): String = withContext(Dispatchers.IO) {
        try {
            val app = ctx.applicationContext
            val p = encPrefs(app)
            val expiry = try {
                p.getLong(K_EXPIRY, 0L)
            } catch (e: Exception) {
                0L
            }
            val current = try {
                p.getString(K_ACCESS, "") ?: ""
            } catch (e: Exception) {
                ""
            }
            if (current.isNotBlank() && System.currentTimeMillis() < expiry - 60_000L) {
                return@withContext current
            }
            val refresh = try {
                p.getString(K_REFRESH, "") ?: ""
            } catch (e: Exception) {
                ""
            }
            if (refresh.isBlank()) return@withContext ""
            val body = FormBody.Builder()
                .add("grant_type", "refresh_token")
                .add("refresh_token", refresh)
                .add("client_id", clientId(app))
                .build()
            val req = Request.Builder()
                .url("https://accounts.spotify.com/api/token")
                .post(body)
                .build()
            http.newCall(req).execute().use { resp ->
                val text = resp.body?.string() ?: return@withContext ""
                if (!resp.isSuccessful) {
                    Log.w(TAG, "refresh http ${resp.code}")
                    return@withContext ""
                }
                saveTokenJson(app, JSONObject(text))
                try {
                    encPrefs(app).getString(K_ACCESS, "") ?: ""
                } catch (e: Exception) {
                    ""
                }
            }
        } catch (e: Exception) {
            ""
        }
    }

    fun isLoggedIn(ctx: Context): Boolean {
        return try {
            val p = encPrefs(ctx.applicationContext)
            val access = p.getString(K_ACCESS, "") ?: ""
            val refresh = p.getString(K_REFRESH, "") ?: ""
            access.isNotBlank() || refresh.isNotBlank()
        } catch (e: Exception) {
            false
        }
    }

    fun logout(ctx: Context) {
        try {
            encPrefs(ctx.applicationContext).edit().clear().apply()
        } catch (e: Exception) {
        }
    }
}
