package com.cresca.app

import org.junit.Assert.*
import org.junit.Test

class DisplayArtistTest {

    private fun t(title: String, artist: String) =
        YtTrack("ABCDEFGHIJK", title, artist, "", "https://www.youtube.com/watch?v=ABCDEFGHIJK")

    @Test
    fun labelUploaderBecomesUnknown() {
        assertEquals("Unknown Artist", t("Main Na Raha Mera", "Song").displayArtist())
        assertEquals("Unknown Artist", t("Tum Hi Ho", "Video").displayArtist())
        assertEquals("Unknown Artist", t("X", "YouTube").displayArtist())
    }

    @Test
    fun dashPrefixExtractsSinger() {
        // Label kept when sane (better than echoing the song title).
        assertEquals(
            "Sony Music India",
            t("Kesariya - Official Video", "Sony Music India").displayArtist()
        )
        // Bare junk with no dash info collapses to Unknown.
        assertEquals(
            "Unknown Artist",
            t("Tum Hi Ho", "Song").displayArtist()
        )
    }

    @Test
    fun realArtistUntouched() {
        assertEquals("Arijit Singh", t("Kesariya", "Arijit Singh").displayArtist())
        assertEquals("Unknown Artist", t("X", "").displayArtist())
    }

    @Test
    fun artistLikeGate() {
        assertTrue(isArtistLike("Arijit Singh"))
        assertFalse(isArtistLike("Song"))
        assertFalse(isArtistLike("Video"))
        assertFalse(isArtistLike("Unknown Artist"))
    }
}
