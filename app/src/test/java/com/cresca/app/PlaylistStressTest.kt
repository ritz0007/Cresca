package com.cresca.app

import org.junit.Assert.*
import org.junit.Test

/**
 * Unit + stress tests for playlist breakpoints (the add-to-playlist crash).
 * Pure JSON logic only (no Context): corrupt files, dup ids, concurrent
 * edits, caps, blank rows — all must never throw and never lose valid data.
 */
class PlaylistStressTest {

    private fun track(id: String, title: String = "T$id") =
        YtTrack(id, title, "Artist", "http://thumb/$id", "https://watch/$id")

    private fun pl(id: String, name: String = "P$id", tracks: List<YtTrack> = emptyList()) =
        Playlist(id, name, tracks, 123L)

    @Test
    fun parse_emptyAndBlank() {
        assertTrue(PlaylistStore.parseJson("").isEmpty())
        assertTrue(PlaylistStore.parseJson("   ").isEmpty())
        assertTrue(PlaylistStore.parseJson("[]").isEmpty())
        assertTrue(PlaylistStore.parseJson("null").isEmpty())
    }

    @Test
    fun parse_corruptNeverThrows() {
        val bad = listOf(
            "{not json",
            "[{bad",
            "[1,2,3]",
            "[{\"id\":\"\"}]",
            "[{\"id\":\"a\"}]",
            "[[[[",
            "garbage".repeat(100)
        )
        for (b in bad) {
            try {
                PlaylistStore.parseJson(b)
            } catch (e: Exception) {
                fail("parseJson threw for $b")
            }
        }
    }

    @Test
    fun roundTrip_preservesData() {
        val lists = listOf(
            pl("p1", "Hits", listOf(track("a"), track("b"))),
            pl("p2", "Chill", listOf(track("c")))
        )
        val json = PlaylistStore.toJson(lists)
        val back = PlaylistStore.parseJson(json)
        assertEquals(2, back.size)
        assertEquals("Hits", back[0].name)
        assertEquals(2, back[0].tracks.size)
        assertEquals("a", back[0].tracks[0].id)
    }

    @Test
    fun parse_dedupsIdsAndDropsBlanks() {
        val json = PlaylistStore.toJson(
            listOf(
                pl("dup", "A", listOf(track("x"))),
                pl("dup", "B", listOf(track("y"))),
                pl("", "NoId"),
                pl("ok", "", listOf(track("z"))),
                pl("ok2", "Good", listOf(track("t"), track("t"), track(""), track("u")))
            )
        )
        val back = PlaylistStore.parseJson(json)
        // toJson already drops blanks/dups, so parse sees clean data.
        assertTrue(back.none { it.id.isBlank() || it.name.isBlank() })
        val ok2 = back.firstOrNull { it.id == "ok2" }
        assertNotNull(ok2)
        assertEquals(ok2!!.tracks.map { it.id }.toSet().size, ok2.tracks.size)
    }

    @Test
    fun addTrack_dedupsAndRejectsBlanks() {
        val lists = listOf(pl("p", "P", listOf(track("a"))))
        // Duplicate -> null (no-op, caller returns false, never crashes).
        assertNull(PlaylistStore.addedTrack(lists, "p", track("a")))
        // Blank ids -> null.
        assertNull(PlaylistStore.addedTrack(lists, "", track("b")))
        assertNull(PlaylistStore.addedTrack(lists, "p", track("")))
        // Missing playlist -> null.
        assertNull(PlaylistStore.addedTrack(lists, "nope", track("b")))
        // Happy path appends.
        val next = PlaylistStore.addedTrack(lists, "p", track("b"))
        assertNotNull(next)
        assertEquals(2, next!!.first { it.id == "p" }.tracks.size)
    }

    @Test
    fun stress_randomPlaylists() {
        val rnd = java.util.Random(99)
        repeat(500) {
            val nLists = rnd.nextInt(6)
            val lists = (0 until nLists).map { i ->
                val nT = rnd.nextInt(15)
                pl(
                    "pl_${it}_$i",
                    "Name $i ${"x".repeat(rnd.nextInt(150))}",
                    (0 until nT).map { j ->
                        // Include blanks/dups/odd chars to fuzz.
                        val id = when (rnd.nextInt(6)) {
                            0 -> ""
                            1 -> "dup"
                            else -> "t${rnd.nextInt(8)}"
                        }
                        track(id, "Title $j\n\t\u2603")
                    }
                )
            }
            val json = try {
                PlaylistStore.toJson(lists)
            } catch (e: Exception) {
                fail("toJson threw")
                return@repeat
            }
            val back = try {
                PlaylistStore.parseJson(json)
            } catch (e: Exception) {
                fail("parseJson threw")
                return@repeat
            }
            // Invariants hold after fuzz.
            assertTrue(back.size <= 200)
            assertTrue(back.all { it.id.isNotBlank() && it.name.isNotBlank() })
            assertTrue(back.map { it.id }.toSet().size == back.size)
            for (p in back) {
                assertTrue(p.tracks.size <= 2000)
                assertTrue(p.tracks.all { it.id.isNotBlank() })
                assertEquals(p.tracks.map { it.id }.toSet().size, p.tracks.size)
            }
            // Adds never throw.
            try {
                PlaylistStore.addedTrack(back, back.firstOrNull()?.id ?: "x", track("new_$it"))
            } catch (e: Exception) {
                fail("addedTrack threw")
            }
        }
    }

    @Test
    fun stress_hugePlaylist_caps() {
        val big = (0 until 5000).map { track("t$it") }
        val lists = listOf(pl("p", "Big", big))
        val json = PlaylistStore.toJson(lists)
        val back = PlaylistStore.parseJson(json)
        assertTrue(back[0].tracks.size <= 2000)
        // Full playlist rejects new adds (no unbounded growth crash).
        assertNull(PlaylistStore.addedTrack(back, "p", track("one_more")))
    }

    @Test
    fun toJson_neverThrowsOnWeirdStrings() {
        val weird = listOf(
            pl("p", "\"quotes\" \\ slash \n newline \u0000", listOf(track("a", "t\u0001\u007f\u2603"))),
            pl("p2", "x".repeat(500), listOf(track("b")))
        )
        try {
            val j = PlaylistStore.toJson(weird)
            PlaylistStore.parseJson(j)
        } catch (e: Exception) {
            fail("weird strings threw")
        }
    }
}
