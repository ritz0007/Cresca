package com.cresca.app

import android.content.Context
import android.util.Log
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.IOException

/**
 * Google refuses sign-in from identifiable embedded browsers ("This browser
 * or app may not be secure"). Two fingerprints give the WebView away:
 *  1. the `; wv` token in the User-Agent (plus desktop-UA/client-hint
 *     mismatch when faking desktop), and
 *  2. the `X-Requested-With: <package>` header WebView adds on requests.
 *
 * This client fixes both: the UA is the device's stock WebView UA minus the
 * `; wv` token (version + client hints stay self-consistent), and main-frame
 * GETs are re-issued without `X-Requested-With` while cookies sync both ways
 * with the WebView store (so Done/capture keeps working). Non-GET requests
 * pass through untouched (POST bodies aren't visible to interception).
 */
object LoginWebView {
    private const val TAG = "LoginWeb"

    private val http = okhttp3.OkHttpClient.Builder()
        .connectTimeout(20, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(20, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(20, java.util.concurrent.TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(true)
        .build()

    /** Stock WebView UA minus the embedded-browser token. Pure, tested. */
    internal fun loginUserAgent(defaultUa: String): String {
        return try {
            var ua = defaultUa.trim()
            if (ua.isBlank()) {
                return "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 " +
                    "(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
            }
            // "Version/4.0 Chrome/… Mobile Safari/…; wv" -> drop "; wv".
            ua = ua.replace("; wv", "")
            ua
        } catch (e: Exception) {
            defaultUa
        }
    }

    /** Request headers minus the package-identifying one. Pure, tested. */
    internal fun filteredHeaders(
        original: Map<String, String>,
        cookie: String,
        userAgent: String
    ): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        try {
            for ((k, v) in original) {
                if (k.equals("X-Requested-With", ignoreCase = true)) continue
                if (k.equals("User-Agent", ignoreCase = true)) continue
                if (k.equals("Cookie", ignoreCase = true)) continue
                out[k] = v
            }
            out["User-Agent"] = userAgent
            if (cookie.isNotBlank()) out["Cookie"] = cookie
        } catch (e: Exception) {
        }
        return out
    }

    fun create(ctx: Context, onDone: () -> Unit): WebView {
        val wv = WebView(ctx)
        val cm = try {
            CookieManager.getInstance()
        } catch (e: Exception) {
            null
        }
        try {
            cm?.setAcceptCookie(true)
        } catch (e: Exception) {
        }
        // Device-consistent UA: stock string minus the `; wv` token, so
        // version + client hints match what a real browser would send.
        val cleanUa = try {
            loginUserAgent(android.webkit.WebSettings.getDefaultUserAgent(ctx))
        } catch (e: Exception) {
            loginUserAgent("")
        }
        try {
            wv.settings.javaScriptEnabled = true
            wv.settings.domStorageEnabled = true
            wv.settings.userAgentString = cleanUa
            wv.settings.mediaPlaybackRequiresUserGesture = false
        } catch (e: Exception) {
        }
        try {
            cm?.setAcceptThirdPartyCookies(wv, true)
        } catch (e: Exception) {
        }
        wv.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView?,
                request: WebResourceRequest?
            ): WebResourceResponse? {
                try {
                    if (request == null) return null
                    val url = request.url?.toString() ?: return null
                    if (!url.startsWith("http")) return null
                    // Only GET is re-issuable (no POST bodies visible here).
                    if (!request.method.equals("GET", ignoreCase = true)) return null
                    val cookie = try {
                        cm?.getCookie(url) ?: ""
                    } catch (e: Exception) {
                        ""
                    }
                    val headers = filteredHeaders(request.requestHeaders ?: emptyMap(), cookie, cleanUa)
                    val builder = okhttp3.Request.Builder().url(url).get()
                    for ((k, v) in headers) {
                        try {
                            builder.header(k, v)
                        } catch (e: Exception) {
                        }
                    }
                    val resp = http.newCall(builder.build()).execute()
                    try {
                        // Sync session cookies back into the WebView store.
                        for (h in resp.headers("Set-Cookie")) {
                            try {
                                cm?.setCookie(url, h)
                            } catch (e: Exception) {
                            }
                        }
                    } catch (e: Exception) {
                    }
                    val code = resp.code
                    val msg = try {
                        resp.message
                    } catch (e: Exception) {
                        ""
                    }
                    val ctype = resp.header("Content-Type") ?: "text/html"
                    val semi = ctype.indexOf(";")
                    val mime = (if (semi > 0) ctype.substring(0, semi) else ctype).trim()
                        .ifBlank { "text/html" }
                    val enc = try {
                        val m = Regex("charset=([^;]+)").find(ctype)
                        m?.groupValues?.get(1)?.trim() ?: "utf-8"
                    } catch (e: Exception) {
                        "utf-8"
                    }
                    val respHeaders = LinkedHashMap<String, String>()
                    try {
                        for (name in resp.headers.names()) {
                            if (name.equals("Set-Cookie", ignoreCase = true)) continue
                            try {
                                respHeaders[name] = resp.headers[name] ?: continue
                            } catch (e: Exception) {
                            }
                        }
                    } catch (e: Exception) {
                    }
                    val body = try {
                        resp.body?.byteStream()
                    } catch (e: Exception) {
                        null
                    } ?: return null
                    // Ownership of the stream passes to WebView; do NOT
                    // close the response here (that would cut the body).
                    return WebResourceResponse(mime, enc, code, msg, respHeaders, body)
                } catch (e: Exception) {
                    return null
                }
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                try {
                    cm?.flush()
                } catch (e: Exception) {
                }
                super.onPageFinished(view, url)
            }
        }
        try {
            wv.loadUrl("https://music.youtube.com")
        } catch (e: Exception) {
        }
        return wv
    }
}
