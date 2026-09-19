package com.cresca.app

import org.junit.Assert.*
import org.junit.Test

/**
 * Unit + stress tests for the home suggestion engine (pure Kotlin, no
 * Android framework needed). Run: gradle :app:testDebugUnitTest
 */
class HomeFeedTest {

    private fun track(id: String, title: String, artist: String) =
        YtTrack(id, title, artist, "", "https://www.youtube.com/watch?v=$id")

    @Test
    fun topSeed_rotatesEveryRefresh() {
        val seen = HashSet<String>()
        for (i in 0 until HomeFeed.TOP_SEEDS.size * 3) {
            seen.add(HomeFeed.topSeed(i).query)
        }
        // All seeds reachable, rotation is periodic.
        assertEquals(HomeFeed.TOP_SEEDS.map { it.query }.toSet(), seen)
        assertEquals(
            HomeFeed.topSeed(0).query,
            HomeFeed.topSeed(HomeFeed.TOP_SEEDS.size).query
        )
        // Consecutive refreshes differ.
        assertNotEquals(
            HomeFeed.topSeed(7).query,
            HomeFeed.topSeed(8).query
        )
    }

    @Test
    fun discovery_cyclesForeverWithVariety() {
        // 200 positions across cycles: every slot resolves, never crashes.
        val titles = (0 until 200).map { HomeFeed.discoveryAt(it, it / 14).title }
        assertEquals(200, titles.size)
        assertTrue(titles.all { it.isNotBlank() })
        // Different cycles shift the start (no identical repeats back-to-back).
        val c0 = (0 until 14).map { HomeFeed.discoveryAt(it, 0).cacheKey }
        val c1 = (0 until 14).map { HomeFeed.discoveryAt(it, 1).cacheKey }
        assertNotEquals(c0, c1)
    }

    @Test
    fun artistSeeds_dropsLabelsKeepsSingers() {
        val tracks = listOf(
            track("a", "T1", "Sony Music India"),
            track("b", "T2", "Tips Official and 3 more"),
            track("c", "T3", "Arijit Singh"),
            track("d", "T4", "Shreya Ghoshal, Sunidhi Chauhan"),
            track("e", "T5", "YouTube"),
            track("f", "T6", "Sagar Bairagi")
        )
        val seeds = HomeFeed.artistSeeds(tracks, 8)
        assertTrue(seeds.contains("Arijit Singh"))
        assertTrue(seeds.contains("Shreya Ghoshal"))
        assertTrue(seeds.contains("Sagar Bairagi"))
        assertTrue(seeds.none { it.contains("Sony", true) || it.contains("Tips", true) })
        assertTrue(seeds.none { it.equals("YouTube", true) })
    }

    @Test
    fun artistSeeds_stress_randomBlobs() {
        // Stress: 500 random artist blobs must never crash or leak labels.
        val rnd = java.util.Random(42)
        val words = listOf(
            "Arijit", "Singh", "Music", "Official", "Shreya", "T-Series",
            "Love", "Records", "Atif", "Aslam", "VEVO", "Neha", "&", ",",
            "and", "Films", "Kakkar", "XYZ", "123"
        )
        repeat(500) {
            val parts = (1..4).map { words[rnd.nextInt(words.size)] }
            val name = parts.joinToString(" ")
            val out = HomeFeed.artistSeeds(listOf(track("x$it", "T", name)), 4)
            assertTrue(out.size <= 4)
            assertTrue(out.none { it.contains("VEVO", true) })
            assertTrue(out.all { it.length in 3..40 })
        }
    }

    @Test
    fun personalized_buildsMoreLikeSections() {
        val liked = listOf(track("a", "T1", "Arijit Singh"))
        val out = HomeFeed.personalized(liked, emptyList(), 2)
        assertEquals(1, out.size)
        assertEquals("More like Arijit Singh", out[0].title)
        assertEquals("Arijit Singh songs", out[0].query)
        // Empty library -> no sections (callers fall back to defaults).
        assertTrue(HomeFeed.personalized(emptyList(), emptyList()).isEmpty())
    }

    @Test
    fun topTracks_neverEmptySeeds() {
        assertTrue(HomeFeed.TOP_SEEDS.isNotEmpty())
        assertTrue(HomeFeed.CORE.isNotEmpty())
        assertTrue(HomeFeed.DISCOVERY_POOL.size >= 10)
        assertTrue(HomeFeed.CORE.any { it.query == "__charts__" })
    }
}
