package com.cresca.app

import org.junit.Assert.*
import org.junit.Test

/**
 * Vibe-based autoplay breakpoints: queue must match song vibe (shared
 * words/mood/related graph), never loop one singer.
 */
class VibeQueueTest {

    private fun track(id: String, title: String, artist: String) =
        YtTrack(id, title, artist, "", "https://www.youtube.com/watch?v=$id")

    @Test
    fun vibeQueries_useTitleNotArtist() {
        val qs = YoutubeRepository.vibeQueries(
            track("a", "Tere Bina (Official Video)", "Arijit Singh")
        )
        assertTrue(qs.isNotEmpty())
        // No artist-stuffed query (the old same-singer bug).
        assertTrue(qs.none { it.contains("Arijit", true) && it.contains("songs", true) && it.split(" ").size <= 3 })
        assertTrue(qs.all { it.isNotBlank() })
    }

    @Test
    fun rankByVibe_penalizesSameArtist() {
        val seed = track("s", "Tere Bina Love Song", "Arijit Singh")
        val same = track("a", "Tere Bina Love Song Cover", "Arijit Singh")
        val vibe = track("b", "Tere Bina Love Melody", "Shreya Ghoshal")
        val ranked = YoutubeRepository.rankByVibe(seed, listOf(same, vibe))
        // Vibe match (different singer, shared words) outranks same-singer.
        assertEquals("b", ranked[0].id)
    }

    @Test
    fun rankByVibe_stress() {
        val rnd = java.util.Random(21)
        repeat(300) {
            val seed = track("s$it", "Love Party Lofi Song $it", "Singer $it")
            val pool = (0 until 20).map { j ->
                track("c${it}_$j", "Love Song $j ${rnd.nextInt(100)}", "Singer ${rnd.nextInt(5)}")
            }
            val out = try {
                YoutubeRepository.rankByVibe(seed, pool)
            } catch (e: Exception) {
                fail("rankByVibe threw")
                return@repeat
            }
            assertEquals(20, out.size)
            assertEquals(pool.map { it.id }.toSet(), out.map { it.id }.toSet())
        }
    }

    @Test
    fun vibeQueries_stress() {
        val rnd = java.util.Random(33)
        val words = listOf("Love", "Party", "(Official Video)", "Lofi", "Tere", "Bina", "Remix", "HD")
        repeat(500) {
            val title = (1..5).map { words[rnd.nextInt(words.size)] }.joinToString(" ")
            val qs = try {
                YoutubeRepository.vibeQueries(track("x$it", title, "Some Artist"))
            } catch (e: Exception) {
                fail("vibeQueries threw")
                return@repeat
            }
            assertTrue(qs.size <= 3)
            assertTrue(qs.all { it.isNotBlank() })
        }
    }
}
