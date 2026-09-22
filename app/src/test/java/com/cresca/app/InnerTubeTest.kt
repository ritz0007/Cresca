package com.cresca.app

import com.cresca.app.innertube.InnerTubeApi
import com.cresca.app.innertube.InnerTubeAuth
import com.cresca.app.innertube.TubeClient
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class InnerTubeTest {

    private fun musicItemJson(
        videoId: String = "dQw4w9WgXcQ",
        title: String = "Never Gonna Give You Up",
        subtitle: String = "Rick Astley • Album • 3:33"
    ): JSONObject {
        val flex0 = JSONObject().put(
            "musicResponsiveListItemFlexColumnRenderer",
            JSONObject().put(
                "text",
                JSONObject().put(
                    "runs",
                    org.json.JSONArray().put(JSONObject().put("text", title))
                )
            )
        )
        val flex1 = JSONObject().put(
            "musicResponsiveListItemFlexColumnRenderer",
            JSONObject().put(
                "text",
                JSONObject().put(
                    "runs",
                    org.json.JSONArray().put(JSONObject().put("text", subtitle))
                )
            )
        )
        return JSONObject()
            .put("playlistItemData", JSONObject().put("videoId", videoId))
            .put("flexColumns", org.json.JSONArray().put(JSONObject().put(flex0.keys().next(), flex0.getJSONObject(flex0.keys().next()))).put(JSONObject().put(flex1.keys().next(), flex1.getJSONObject(flex1.keys().next()))))
            .put(
                "thumbnail",
                JSONObject().put(
                    "musicThumbnailRenderer",
                    JSONObject().put(
                        "thumbnail",
                        JSONObject().put(
                            "thumbnails",
                            org.json.JSONArray().put(JSONObject().put("url", "https://i.ytimg.com/vi/$videoId/hqdefault.jpg"))
                        )
                    )
                )
            )
    }

    @Test
    fun parseSearch_hourLongComp_dropped() {
        val root = JSONObject().put(
            "contents",
            JSONObject().put(
                "musicResponsiveListItemRenderer",
                musicItemJson(subtitle = "Various • Compilation • 1:12:45")
            )
        )
        assertTrue(InnerTubeApi.parseSearch(root, 10).isEmpty())
    }

    @Test
    fun parseSearch_liveBadge_dropped() {
        val item = musicItemJson()
            .put(
                "badges",
                org.json.JSONArray().put(
                    JSONObject().put(
                        "metadataBadgeRenderer",
                        JSONObject().put("label", "LIVE")
                    )
                )
            )
        // No duration segment + LIVE badge = unplayable stream, dropped.
        val noDur = JSONObject(item.toString())
        noDur.put(
            "flexColumns",
            org.json.JSONArray().put(
                JSONObject().put(
                    "musicResponsiveListItemFlexColumnRenderer",
                    JSONObject().put(
                        "text",
                        JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", "Live Radio")))
                    )
                )
            ).put(
                JSONObject().put(
                    "musicResponsiveListItemFlexColumnRenderer",
                    JSONObject().put(
                        "text",
                        JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", "Some Channel")))
                    )
                )
            )
        )
        val root = JSONObject().put("contents", JSONObject().put("musicResponsiveListItemRenderer", noDur))
        assertTrue(InnerTubeApi.parseSearch(root, 10).isEmpty())
    }

    @Test
    fun isMusicJunk_episodesAndShorts() {
        assertTrue(isMusicJunk("Mohini Episode 12", "Serial Vibes"))
        assertTrue(isMusicJunk("Mohini Ep. 5", "Someone"))
        assertTrue(isMusicJunk("Show S01E03", "Channel"))
        assertTrue(isMusicJunk("Anything", "Podcast"))
        assertTrue(isMusicJunk("Anything", "Episode"))
        assertTrue(isShortsUrl("https://www.youtube.com/shorts/dQw4w9WgXcQ"))
        assertFalse(isShortsUrl("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        assertFalse(isMusicJunk("Mohini", "Arijit Singh"))
        assertFalse(isMusicJunk("Tum Mile (Lofi Flip)", "Lofi"))
    }

    @Test
    fun sharpThumb_upscales() {
        assertEquals(
            "https://yt3.googleusercontent.com/x=w544-h544-l90-rj",
            InnerTubeApi.sharpThumb("https://yt3.googleusercontent.com/x=w120-h120-l90-rj")
        )
        assertEquals("https://i.ytimg.com/vi/abc/hqdefault.jpg", InnerTubeApi.sharpThumb("https://i.ytimg.com/vi/abc/hqdefault.jpg"))
        assertEquals("", InnerTubeApi.sharpThumb(""))
    }

    @Test
    fun parseRadioPanels_gatesJunk() {
        fun panel(id: String, title: String, artist: String, len: String = "3:33"): JSONObject {
            return JSONObject()
                .put("videoId", id)
                .put("title", JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", title))))
                .put("shortBylineText", JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", artist))))
                .put("lengthText", JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", len))))
                .put("thumbnail", JSONObject().put("thumbnails", org.json.JSONArray()))
        }
        val root = JSONObject().put(
            "contents",
            JSONObject().put(
                "x",
                org.json.JSONArray()
                    .put(JSONObject().put("playlistPanelVideoRenderer", panel("dQw4w9WgXcQ", "Good Song", "Singer")))
                    .put(JSONObject().put("playlistPanelVideoRenderer", panel("9bZkp7q19f0", "Mohini Episode 2", "Serial")))
                    .put(JSONObject().put("playlistPanelVideoRenderer", panel("kJQP7kiw5Fk", "Hour Mix", "DJ", "1:12:00")))
            )
        )
        val out = InnerTubeApi.parseRadioPanels(root, "AAAAAAAAAAA", 10)
        assertEquals(1, out.size)
        assertEquals("dQw4w9WgXcQ", out[0].id)
    }

    @Test
    fun isLiveBadge_labels() {
        val live = JSONObject().put(
            "badges",
            org.json.JSONArray().put(
                JSONObject().put("metadataBadgeRenderer", JSONObject().put("label", "Upcoming"))
            )
        )
        assertTrue(InnerTubeApi.isLiveBadge(live))
        assertFalse(InnerTubeApi.isLiveBadge(JSONObject()))
    }

    @Test
    fun parseSearch_musicItem_mapsTrack() {
        val root = JSONObject().put(
            "contents",
            JSONObject().put(
                "section",
                JSONObject().put("musicResponsiveListItemRenderer", musicItemJson())
            )
        )
        val out = InnerTubeApi.parseSearch(root, 10)
        assertEquals(1, out.size)
        assertEquals("dQw4w9WgXcQ", out[0].id)
        assertEquals("Never Gonna Give You Up", out[0].title)
        assertEquals("Rick Astley", out[0].artist)
        assertEquals("https://www.youtube.com/watch?v=dQw4w9WgXcQ", out[0].watchUrl)
    }

    @Test
    fun parseSearch_badVideoId_dropped() {
        val bad = musicItemJson(videoId = "short")
        val root = JSONObject().put("x", JSONObject().put("musicResponsiveListItemRenderer", bad))
        assertTrue(InnerTubeApi.parseSearch(root, 10).isEmpty())
    }

    @Test
    fun parseSearch_videoRenderer_fallback() {
        val vr = JSONObject()
            .put("videoId", "9bZkp7q19f0")
            .put("title", JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", "Gangnam Style"))))
            .put("ownerText", JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", "PSY"))))
            .put(
                "thumbnail",
                JSONObject().put(
                    "thumbnails",
                    org.json.JSONArray().put(JSONObject().put("url", "https://i.ytimg.com/vi/9bZkp7q19f0/hqdefault.jpg"))
                )
            )
        val root = JSONObject().put("y", JSONObject().put("videoRenderer", vr))
        val out = InnerTubeApi.parseSearch(root, 10)
        assertEquals(1, out.size)
        assertEquals("9bZkp7q19f0", out[0].id)
        assertEquals("PSY", out[0].artist)
    }

    @Test
    fun auth_emptyCookies_noHash() {
        assertNull(InnerTubeAuth.sapisidHash(""))
        assertNull(InnerTubeAuth.sapisidHash("VISITOR_INFO1_LIVE=abc"))
    }

    @Test
    fun auth_sapisid_hashFormat() {
        val h = InnerTubeAuth.sapisidHash("VISITOR_INFO1_LIVE=x; SAPISID=AbC123_-; SID=y", 1700000000L)
        assertNotNull(h)
        assertTrue(h!!.startsWith("1700000000_"))
        assertEquals(1700000000L.toString().length + 1 + 40, h.length)
    }

    @Test
    fun clients_haveKeys() {
        for (c in listOf(TubeClient.WEB_REMIX, TubeClient.ANDROID_MUSIC, TubeClient.ANDROID_VR, TubeClient.WEB)) {
            assertTrue(c.clientName.isNotBlank())
            assertTrue(c.clientVersion.isNotBlank())
            assertTrue(c.apiKey.startsWith("AIza"))
        }
    }

    @Test
    fun diagnoseKeys_listsRenderers() {
        val root = JSONObject()
            .put("contents", JSONObject().put("musicShelfRenderer", JSONObject()))
        val d = InnerTubeApi.diagnoseKeys(root)
        assertTrue(d.contains("musicShelfRenderer"))
        assertTrue(d.contains("contents"))
    }

    @Test
    fun parseShelves_bareShapes() {
        // Item without wrapper key (flexColumns directly on the object).
        val bare = JSONObject()
            .put("playlistItemData", JSONObject().put("videoId", "dQw4w9WgXcQ"))
            .put(
                "flexColumns",
                org.json.JSONArray()
                    .put(
                        JSONObject().put(
                            "musicResponsiveListItemFlexColumnRenderer",
                            JSONObject().put(
                                "text",
                                JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", "Bare Song")))
                            )
                        )
                    )
                    .put(
                        JSONObject().put(
                            "musicResponsiveListItemFlexColumnRenderer",
                            JSONObject().put(
                                "text",
                                JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", "Bare Artist • Album")))
                            )
                        )
                    )
            )
        val shelf = JSONObject()
            .put("header", JSONObject().put("title", "Bare Shelf"))
            .put("contents", JSONObject().put("contents", org.json.JSONArray().put(bare)))
        val root = JSONObject().put("musicCarouselShelfRenderer", shelf)
        val out = InnerTubeApi.parseShelves(root, 8, 12)
        assertEquals(1, out.size)
        assertEquals("Bare Shelf", out.keys.first())
        assertEquals("Bare Song", out.values.first()[0].title)
    }

    @Test
    fun parseTwoRow_mapsTrack() {
        val r = JSONObject()
            .put("navigationEndpoint", JSONObject().put("watchEndpoint", JSONObject().put("videoId", "9bZkp7q19f0")))
            .put("title", JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", "Gangnam Style"))))
            .put("subtitle", JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", "PSY • Album"))))
            .put(
                "thumbnailRenderer",
                JSONObject().put(
                    "musicThumbnailRenderer",
                    JSONObject().put(
                        "thumbnail",
                        JSONObject().put(
                            "thumbnails",
                            org.json.JSONArray().put(JSONObject().put("url", "https://i.ytimg.com/vi/9bZkp7q19f0/hqdefault.jpg"))
                        )
                    )
                )
            )
        val t = InnerTubeApi.parseTwoRowItem(r)
        assertNotNull(t)
        assertEquals("9bZkp7q19f0", t!!.id)
        assertEquals("Gangnam Style", t.title)
        assertEquals("PSY", t.artist)
    }

    @Test
    fun parseTwoRow_badId_null() {
        val r = JSONObject().put("title", JSONObject().put("simpleText", "No nav"))
        assertNull(InnerTubeApi.parseTwoRowItem(r))
    }

    @Test
    fun parseShelves_mapsShelf() {
        val item = JSONObject().put(
            "musicResponsiveListItemRenderer",
            JSONObject()
                .put("playlistItemData", JSONObject().put("videoId", "dQw4w9WgXcQ"))
                .put(
                    "flexColumns",
                    org.json.JSONArray()
                        .put(
                            JSONObject().put(
                                "musicResponsiveListItemFlexColumnRenderer",
                                JSONObject().put(
                                    "text",
                                    JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", "Song A")))
                                )
                            )
                        )
                        .put(
                            JSONObject().put(
                                "musicResponsiveListItemFlexColumnRenderer",
                                JSONObject().put(
                                    "text",
                                    JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", "Artist A • Album")))
                                )
                            )
                        )
                )
                .put(
                    "thumbnail",
                    JSONObject().put(
                        "musicThumbnailRenderer",
                        JSONObject().put(
                            "thumbnail",
                            JSONObject().put("thumbnails", org.json.JSONArray().put(JSONObject().put("url", "https://x/y.jpg")))
                        )
                    )
                )
        )
        val shelf = JSONObject()
            .put(
                "header",
                JSONObject().put(
                    "musicCarouselShelfBasicHeaderRenderer",
                    JSONObject().put("title", JSONObject().put("runs", org.json.JSONArray().put(JSONObject().put("text", "Charts"))))
                )
            )
            .put("contents", JSONObject().put("contents", org.json.JSONArray().put(item)))
        val root = JSONObject().put("s", JSONObject().put("musicCarouselShelfRenderer", shelf))
        val out = InnerTubeApi.parseShelves(root, 8, 12)
        assertEquals(1, out.size)
        assertEquals("Charts", out.keys.first())
        assertEquals("dQw4w9WgXcQ", out.values.first()[0].id)
    }
}
