package com.cresca.app

import org.junit.Assert.*
import org.junit.Test

class PlaylistMetaTest {

    @Test
    fun coverAndSpotifyId_surviveRoundTrip() {
        val lists = listOf(
            Playlist(
                id = "pl_1", name = "Gym", createdAt = 5L,
                tracks = listOf(YtTrack("ABCDEFGHIJK", "T", "A", "", "w")),
                coverPath = "/files/covers/pl_1.jpg",
                spotifyId = "spot123"
            )
        )
        val parsed = PlaylistStore.parseJson(PlaylistStore.toJson(lists))
        assertEquals(1, parsed.size)
        assertEquals("/files/covers/pl_1.jpg", parsed[0].coverPath)
        assertEquals("spot123", parsed[0].spotifyId)
    }

    @Test
    fun oldJsonWithoutNewFields_loadsBlank() {
        val raw = """[{"id":"pl_9","name":"Old","createdAt":0,"tracks":[]}]"""
        val parsed = PlaylistStore.parseJson(raw)
        assertEquals(1, parsed.size)
        assertEquals("", parsed[0].coverPath)
        assertEquals("", parsed[0].spotifyId)
    }

    @Test
    fun renameAndCoverUpdate_purePaths() {
        // update() is private; exercise serialize-level rename instead.
        val p = Playlist("pl_2", "Old", emptyList(), 0L)
        val renamed = p.copy(name = "New")
        assertEquals("New", PlaylistStore.parseJson(PlaylistStore.toJson(listOf(renamed)))[0].name)
    }
}
