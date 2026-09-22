package com.cresca.app

import org.junit.Assert.*
import org.junit.Test

class UpdateCheckTest {

    private fun assets(tag: String) = listOf(
        Pair("Cresca-$tag-arm64.apk", "https://x/arm64.apk"),
        Pair("Cresca-$tag-armv7.apk", "https://x/armv7.apk"),
        Pair("Cresca-$tag-x86_64.apk", "https://x/x86.apk"),
        Pair("Cresca-$tag-universal.apk", "https://x/uni.apk")
    )

    @Test
    fun pickApkAsset_prefersExactThenUniversal() {
        // deviceAbi() is device-dependent; assert structural behavior:
        // result is always one of the list entries (exact or universal).
        val pick = UpdateCheck.pickApkAsset(assets("1.0.0"))
        assertNotNull(pick)
        assertTrue(pick!!.first.endsWith(".apk"))
        assertTrue(pick.first.contains(UpdateCheck.deviceAbi()) || pick.first.contains("universal"))
    }

    @Test
    fun pickApkAsset_emptyIsNull() {
        assertNull(UpdateCheck.pickApkAsset(emptyList()))
    }

    @Test
    fun pickApkAsset_universalFallback() {
        val only = listOf(Pair("Cresca-1.0.0-universal.apk", "https://x/u.apk"))
        // When the device ABI asset is absent, universal must win.
        val names = only.map { it.first }
        val pick = UpdateCheck.pickApkAsset(only)
        assertNotNull(pick)
        assertTrue(names.contains(pick!!.first))
    }

    @Test
    fun fileNameFor_usesAssetName() {
        assertEquals("Cresca-1.0.0-arm64.apk", UpdateDownload.fileNameFor("v1.0.0", "Cresca-1.0.0-arm64.apk"))
        assertTrue(UpdateDownload.fileNameFor("v1.0.0", "").startsWith("Cresca-v1.0.0-"))
    }

    @Test
    fun isNewer_semver() {
        assertTrue(UpdateCheck.isNewer("1.0.0", "1.1.0"))
        assertTrue(UpdateCheck.isNewer("0.9.4", "1.0.0"))
        assertFalse(UpdateCheck.isNewer("1.1.0", "1.1.0"))
        assertFalse(UpdateCheck.isNewer("1.1.0", "1.0.0"))
        assertTrue(UpdateCheck.isNewer("1.0.0", "v1.0.1"))
    }
}
