package com.cresca.app

import org.junit.Assert.*
import org.junit.Test

class LoginWebViewTest {

    @Test
    fun loginUserAgent_stripsWvToken() {
        val stock = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Version/4.0 Chrome/126.0.0.0 Mobile Safari/537.36; wv"
        val clean = LoginWebView.loginUserAgent(stock)
        assertFalse(clean.contains("; wv"))
        assertFalse(clean.contains(" wv"))
        assertTrue(clean.contains("Chrome/126.0.0.0"))
    }

    @Test
    fun loginUserAgent_blankFallsBack() {
        val clean = LoginWebView.loginUserAgent("   ")
        assertTrue(clean.isNotBlank())
        assertFalse(clean.contains("wv"))
    }

    @Test
    fun filteredHeaders_dropsPackageHeader() {
        val orig = mapOf(
            "Accept" to "text/html",
            "X-Requested-With" to "com.cresca.app",
            "x-requested-with" to "com.cresca.app",
            "User-Agent" to "old",
            "Cookie" to "stale=1"
        )
        val out = LoginWebView.filteredHeaders(orig, "SID=abc", "UA-NEW")
        assertFalse(out.keys.any { it.equals("X-Requested-With", ignoreCase = true) })
        assertEquals("UA-NEW", out["User-Agent"])
        assertEquals("SID=abc", out["Cookie"])
        assertEquals("text/html", out["Accept"])
    }

    @Test
    fun filteredHeaders_emptyCookieOmitsIt() {
        val out = LoginWebView.filteredHeaders(mapOf("A" to "b"), "", "UA")
        assertFalse(out.containsKey("Cookie"))
        assertEquals("UA", out["User-Agent"])
    }
}
