package com.cresca.app

import org.junit.Assert.*
import org.junit.Test

class MusicVideoScoreTest {

    private fun track(id: String, title: String, artist: String) =
        YtTrack(id, title, artist, "", "https://www.youtube.com/watch?v=$id")

    private val seed = track("SEED1234567", "Kesariya (From Brahmastra)", "Arijit Singh")

    @Test
    fun officialVideo_beatsLyricAndAudio() {
        val official = track(
            "OFFICIAL123",
            "Kesariya - Official Music Video | Ranbir, Alia | Arijit Singh",
            "Sony Music India"
        )
        val lyric = track("LYRIC123456", "Kesariya - Lyrical | Arijit Singh", "Sony Music India")
        val audio = track("AUDIO123456", "Kesariya (Audio) | Arijit Singh", "Sony Music India")
        val so = YoutubeRepository.scoreVideoCandidate(seed, official)
        assertTrue("official score $so", so > 0)
        assertTrue(so > YoutubeRepository.scoreVideoCandidate(seed, lyric))
        assertTrue(so > YoutubeRepository.scoreVideoCandidate(seed, audio))
    }

    @Test
    fun differentSong_rejected() {
        val other = track("OTHER123456", "Tum Hi Ho - Official Music Video", "Arijit Singh")
        assertTrue(YoutubeRepository.scoreVideoCandidate(seed, other) <= 0)
    }

    @Test
    fun sameId_rejected() {
        assertTrue(YoutubeRepository.scoreVideoCandidate(seed, seed) <= 0)
    }

    @Test
    fun coverAndRemix_sinkBelowOfficial() {
        val official = track("OFFICIAL123", "Kesariya (Official Music Video)", "Arijit Singh")
        val cover = track("COVER123456", "Kesariya Guitar Cover by Someone", "Someone")
        val remix = track("REMIX123456", "Kesariya Remix - DJ Someone", "DJ Someone")
        val so = YoutubeRepository.scoreVideoCandidate(seed, official)
        assertTrue(so > YoutubeRepository.scoreVideoCandidate(seed, cover))
        assertTrue(so > YoutubeRepository.scoreVideoCandidate(seed, remix))
    }
}
