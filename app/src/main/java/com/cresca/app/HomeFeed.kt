package com.cresca.app

/**
 * YT Music style home sections, SimpMusic-shaped but NewPipe-powered.
 *
 * SimpMusic's suggestions are server-driven shelves (FEmusic_home quick
 * picks first, then new releases, moods, charts, all paginated via
 * continuation). We mirror that shape with YouTube Music search +
 * charts kiosk + related mixes:
 *  - Quick/Top Picks first, ROTATED on every refresh (never the same page)
 *  - Charts from the real trending_music kiosk
 *  - "Because you listened" mixes from related streams of recent tracks
 *  - Endless discovery rails appended as the user scrolls
 */
data class HomeSection(
    val title: String,
    val subtitle: String = "",
    val query: String,
    val cacheKey: String
)

object HomeFeed {
    const val SECTION_TTL_MS = 12 * 60 * 60 * 1000L

    /** Curated playlist rails (fetched via playlist, not search). */
    const val RELEASED_PLAYLIST_ID = "RDCLAK5uy_ksEjgm3H_7zOJ_RHzRjN1wY-_FFcs7aAU"
    val RELEASED = HomeSection("Released", "Fresh drops", "__released__", "home_released")

    /** Top Picks seed pool: refresh cycles through these, so the page changes. */
    val TOP_SEEDS: List<HomeSection> = listOf(
        HomeSection("Top Picks For You", "Made for long listening", "top hindi songs", "home_top"),
        HomeSection("Top Picks For You", "Fresh rotation", "trending hindi songs", "home_top"),
        HomeSection("Top Picks For You", "Picked for you", "best of arijit singh", "home_top"),
        HomeSection("Top Picks For You", "On repeat energy", "bollywood party hits", "home_top"),
        HomeSection("Top Picks For You", "Evergreen voices", "kishore kumar evergreen hits", "home_top"),
        HomeSection("Top Picks For You", "Something new", "latest punjabi songs", "home_top"),
    )

    fun topSeed(refreshCount: Int): HomeSection =
        TOP_SEEDS[Math.floorMod(refreshCount, TOP_SEEDS.size)]

    /** Core rails after Quick Picks (fixed order, like server shelves). */
    val CORE: List<HomeSection> = listOf(
        HomeSection("Charts Right Now", "YouTube music charts", "__charts__", "home_charts"),
        HomeSection("Trending Now", "What India is playing", "trending songs india 2026", "home_trending"),
        HomeSection("Punjabi Heat", "Bhangra & hip-hop", "punjabi hits 2026", "home_punjabi"),
        HomeSection("Chill & Lofi", "Slow evenings", "lofi chill hindi songs", "home_lofi"),
        HomeSection("Workout Energy", "Run it up", "workout motivation songs hindi", "home_workout"),
        HomeSection("Party Hits", "Dance floor", "party dance hits 2026 hindi", "home_party"),
        HomeSection("Romantic", "Love songs", "arijit singh romantic songs", "home_romantic"),
    )

    /**
     * Endless discovery pool: appended rail-by-rail as the user scrolls to
     * the bottom, cycling forever with per-cycle variety (cycle index shifts
     * the start so repeats never look identical).
     */
    val DISCOVERY_POOL: List<HomeSection> = listOf(
        HomeSection("90s Evergreen", "Golden oldies", "90s hindi hit songs", "disc_90s"),
        HomeSection("2000s Hits", "Throwbacks", "2000s hindi hits", "disc_2000s"),
        HomeSection("Arijit Essentials", "The voice", "arijit singh best songs", "disc_arijit"),
        HomeSection("Shreya Melodies", "Soulful", "shreya ghoshal songs", "disc_shreya"),
        HomeSection("Hip-Hop India", "Desi rap", "indian hip hop songs", "disc_hiphop"),
        HomeSection("EDM Nights", "Turn it up", "edm party mix hindi", "disc_edm"),
        HomeSection("Acoustic Mornings", "Unplugged", "hindi acoustic covers", "disc_acoustic"),
        HomeSection("Sufi Soul", "Timeless", "sufi songs hindi", "disc_sufi"),
        HomeSection("Tamil Hits", "Kollywood", "latest tamil songs", "disc_tamil"),
        HomeSection("Telugu Hits", "Tollywood", "latest telugu songs", "disc_telugu"),
        HomeSection("Marathi Beats", "Regional", "marathi hit songs", "disc_marathi"),
        HomeSection("Ghazals", "Late night", "best ghazals hindi", "disc_ghazal"),
        HomeSection("Road Trip", "Windows down", "road trip hindi songs", "disc_road"),
        HomeSection("Monsoon Feels", "Rainy day", "monsoon hindi songs", "disc_monsoon"),
    )

    /** Next endless rail for cycle [cycle] at position [pos]. */
    fun discoveryAt(pos: Int, cycle: Int): HomeSection {
        val s = DISCOVERY_POOL[Math.floorMod(pos + cycle * 5, DISCOVERY_POOL.size)]
        // Unique cache key per cycle so rotations persist separately.
        return s.copy(cacheKey = s.cacheKey + "_c" + (cycle % 3))
    }

    /** "Because you liked <artist>" sections from library seeds. */
    fun personalized(liked: List<YtTrack>, recent: List<YtTrack>, max: Int = 4): List<HomeSection> {
        val seeds = artistSeeds(liked + recent, max)
        return seeds.mapIndexed { i, artist ->
            HomeSection(
                title = "More like $artist",
                subtitle = "Because you listened",
                query = "$artist songs",
                cacheKey = "home_like_$i"
            )
        }
    }

    // Labels/channels pollute the artist field (plain search stores the
    // uploader). Split multi-artist blobs and drop label-like names so
    // artist seeds are real singer names usable for channel feeds.
    private val LABEL_WORDS = listOf(
        "music", "official", "films", "records", "studio", "t-series", "tseries",
        "vevo", "tips", "saregama", "sony", "zee", "universal", "eros",
        "jiosaavn", "wynk", "hungama", "shemaroo", "superhits", "radio",
        "topic", "movies", "talkies", "audio", "channel", "network",
        "entertainment", "multimedia", "creations", "junction", "jukebox",
        "melodies", "hits", "originals", "pictures", "talkies",
        "episode", "episodes", "podcast", "song", "video", "shorts"
    )

    fun artistSeeds(tracks: List<YtTrack>, max: Int): List<String> {
        val counts = LinkedHashMap<String, Int>()
        for (t in tracks) {
            val parts = t.artist.split(",", "&", "+", "/", ";", "|", "•", "·", ":")
                .flatMap { it.split(" and ", " x ", " X ", " feat ", " feat. ", " ft ", " ft. ") }
            for (p in parts) {
                val name = p.trim().trim('"', '\'', '-', '–')
                    .replace(Regex("\\s+"), " ")
                if (name.length < 3 || name.length > 40) continue
                val low = name.lowercase()
                if (low == "youtube" || low == "unknown artist" ||
                    low == "song" || low == "songs" ||
                    low == "various artists" || low == "various"
                ) continue
                if (LABEL_WORDS.any { low.contains(it) }) continue
                if (!name.all { it.isLetter() || it == ' ' || it == '.' || it == '\'' }) continue
                val words = name.split(" ")
                if (words.size > 4) continue
                counts[name] = (counts[name] ?: 0) + 1
            }
        }
        return counts.entries.sortedByDescending { it.value }.map { it.key }.take(max)
    }
}
