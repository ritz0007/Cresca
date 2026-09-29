package com.cresca.app

import com.cresca.app.spotify.SpotifyApi
import com.cresca.app.spotify.SpotifyAuth
import com.cresca.app.spotify.SpotifyImport
import com.cresca.app.spotify.SpotifyTrack
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SpotifyParseTest {

    @Test
    fun pkceChallenge_rfc7636Vector() {
        val v = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        assertEquals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", SpotifyAuth.challenge(v))
    }

    @Test
    fun pkceChallenge_urlSafeNoPadding() {
        val c = SpotifyAuth.challenge(SpotifyAuth.newVerifier())
        assertEquals(43, c.length)
        assertFalse(c.contains("+") || c.contains("/") || c.contains("="))
    }

    @Test
    fun parseTrack_bareTopTrack() {
        val o = JSONObject()
            .put("id", "abc123")
            .put("name", "Kesariya")
            .put("type", "track")
            .put("artists", org.json.JSONArray().put(JSONObject().put("name", "Arijit Singh")))
            .put("album", JSONObject().put("name", "Brahmastra"))
        val t = SpotifyApi.parseTrack(o)!!
        assertEquals("Kesariya", t.name)
        assertEquals(listOf("Arijit Singh"), t.artists)
        assertEquals("Brahmastra", t.album)
    }

    @Test
    fun parseTrack_playlistWrapperAndEpisodeDropped() {
        val track = JSONObject()
            .put("id", "x")
            .put("name", "Blinding Lights")
            .put("type", "track")
            .put("artists", org.json.JSONArray().put(JSONObject().put("name", "The Weeknd")))
        val wrapped = JSONObject().put("track", track)
        assertNotNull(SpotifyApi.parseTrack(wrapped))
        val episode = JSONObject()
            .put("id", "e1")
            .put("name", "Daily Podcast Ep 12")
            .put("type", "episode")
            .put("artists", org.json.JSONArray().put(JSONObject().put("name", "Someone")))
        assertNull(SpotifyApi.parseTrack(episode))
    }

    @Test
    fun parseTrack_noArtistDropped() {
        val o = JSONObject()
            .put("id", "x")
            .put("name", "Nameless")
            .put("type", "track")
            .put("artists", org.json.JSONArray())
        assertNull(SpotifyApi.parseTrack(o))
    }

    @Test
    fun parsePlaylist_roundTrip() {
        val o = JSONObject()
            .put("id", "pl1")
            .put("name", "  Gym Mix  ")
            .put("tracks", JSONObject().put("total", 42))
        val p = SpotifyApi.parsePlaylist(o)!!
        assertEquals("Gym Mix", p.name)
        assertEquals(42, p.total)
        assertNull(SpotifyApi.parsePlaylist(JSONObject().put("id", "").put("name", "x")))
    }

    @Test
    fun queryFor_titlePlusFirstArtist() {
        val q = SpotifyImport.queryFor(
            SpotifyTrack("id", "Kesariya", listOf("Arijit Singh", "Pritam"), "Brahmastra")
        )
        assertEquals("Kesariya Arijit Singh", q)
    }
}
