// Pure home-feed model (H3–H4 rails, H6 moods, discovery endless).
// Native ref: HomeFeed.kt (sections, TOP_SEEDS rotation, CORE order,
// DISCOVERY_POOL + discoveryAt cycle keys, personalized + artistSeeds
// with label-word filtering). Loading lives in AppState; this file is
// the rail catalog so tests pin rotation/keys/filters.

class HomeSection {
  final String title;
  final String subtitle;
  final String query;
  final String cacheKey;
  const HomeSection({
    required this.title,
    this.subtitle = '',
    required this.query,
    required this.cacheKey,
  });

  HomeSection copyWith({String? cacheKey}) => HomeSection(
        title: title,
        subtitle: subtitle,
        query: query,
        cacheKey: cacheKey ?? this.cacheKey,
      );
}

class HomeFeed {
  static const sectionTtlMs = 12 * 60 * 60 * 1000;

  /// Curated playlist rail (fetched via playlist, not search).
  static const releasedPlaylistId =
      'RDCLAK5uy_ksEjgm3H_7zOJ_RHzRjN1wY-_FFcs7aAU';
  static const released = HomeSection(
    title: 'Released',
    subtitle: 'Fresh drops',
    query: '__released__',
    cacheKey: 'home_released',
  );

  /// Top Picks seed pool: refresh cycles through these.
  static const topSeeds = [
    HomeSection(
        title: 'Top Picks For You',
        subtitle: 'Made for long listening',
        query: 'top hindi songs',
        cacheKey: 'home_top'),
    HomeSection(
        title: 'Top Picks For You',
        subtitle: 'Fresh rotation',
        query: 'trending hindi songs',
        cacheKey: 'home_top'),
    HomeSection(
        title: 'Top Picks For You',
        subtitle: 'Picked for you',
        query: 'best of arijit singh',
        cacheKey: 'home_top'),
    HomeSection(
        title: 'Top Picks For You',
        subtitle: 'On repeat energy',
        query: 'bollywood party hits',
        cacheKey: 'home_top'),
    HomeSection(
        title: 'Top Picks For You',
        subtitle: 'Evergreen voices',
        query: 'kishore kumar evergreen hits',
        cacheKey: 'home_top'),
    HomeSection(
        title: 'Top Picks For You',
        subtitle: 'Something new',
        query: 'latest punjabi songs',
        cacheKey: 'home_top'),
  ];

  static HomeSection topSeed(int refreshCount) =>
      topSeeds[refreshCount % topSeeds.length];

  /// Core rails after Top Picks (fixed order, like server shelves).
  static const core = [
    HomeSection(
        title: 'Charts Right Now',
        subtitle: 'YouTube music charts',
        query: '__charts__',
        cacheKey: 'home_charts'),
    HomeSection(
        title: 'Trending Now',
        subtitle: 'What India is playing',
        query: 'trending songs india 2026',
        cacheKey: 'home_trending'),
    HomeSection(
        title: 'Punjabi Heat',
        subtitle: 'Bhangra & hip-hop',
        query: 'punjabi hits 2026',
        cacheKey: 'home_punjabi'),
    HomeSection(
        title: 'Chill & Lofi',
        subtitle: 'Slow evenings',
        query: 'lofi chill hindi songs',
        cacheKey: 'home_lofi'),
    HomeSection(
        title: 'Workout Energy',
        subtitle: 'Run it up',
        query: 'workout motivation songs hindi',
        cacheKey: 'home_workout'),
    HomeSection(
        title: 'Party Hits',
        subtitle: 'Dance floor',
        query: 'party dance hits 2026 hindi',
        cacheKey: 'home_party'),
    HomeSection(
        title: 'Romantic',
        subtitle: 'Love songs',
        query: 'arijit singh romantic songs',
        cacheKey: 'home_romantic'),
  ];

  static const discoveryPool = [
    HomeSection(
        title: '90s Evergreen',
        subtitle: 'Golden oldies',
        query: '90s hindi hit songs',
        cacheKey: 'disc_90s'),
    HomeSection(
        title: '2000s Hits',
        subtitle: 'Throwbacks',
        query: '2000s hindi hits',
        cacheKey: 'disc_2000s'),
    HomeSection(
        title: 'Arijit Essentials',
        subtitle: 'The voice',
        query: 'arijit singh best songs',
        cacheKey: 'disc_arijit'),
    HomeSection(
        title: 'Shreya Melodies',
        subtitle: 'Soulful',
        query: 'shreya ghoshal songs',
        cacheKey: 'disc_shreya'),
    HomeSection(
        title: 'Hip-Hop India',
        subtitle: 'Desi rap',
        query: 'indian hip hop songs',
        cacheKey: 'disc_hiphop'),
    HomeSection(
        title: 'EDM Nights',
        subtitle: 'Turn it up',
        query: 'edm party mix hindi',
        cacheKey: 'disc_edm'),
    HomeSection(
        title: 'Acoustic Mornings',
        subtitle: 'Unplugged',
        query: 'hindi acoustic covers',
        cacheKey: 'disc_acoustic'),
    HomeSection(
        title: 'Sufi Soul',
        subtitle: 'Timeless',
        query: 'sufi songs hindi',
        cacheKey: 'disc_sufi'),
    HomeSection(
        title: 'Tamil Hits',
        subtitle: 'Kollywood',
        query: 'latest tamil songs',
        cacheKey: 'disc_tamil'),
    HomeSection(
        title: 'Telugu Hits',
        subtitle: 'Tollywood',
        query: 'latest telugu songs',
        cacheKey: 'disc_telugu'),
    HomeSection(
        title: 'Marathi Beats',
        subtitle: 'Regional',
        query: 'marathi hit songs',
        cacheKey: 'disc_marathi'),
    HomeSection(
        title: 'Ghazals',
        subtitle: 'Late night',
        query: 'best ghazals hindi',
        cacheKey: 'disc_ghazal'),
    HomeSection(
        title: 'Road Trip',
        subtitle: 'Windows down',
        query: 'road trip hindi songs',
        cacheKey: 'disc_road'),
    HomeSection(
        title: 'Monsoon Feels',
        subtitle: 'Rainy day',
        query: 'monsoon hindi songs',
        cacheKey: 'disc_monsoon'),
  ];

  /// Next endless rail for cycle [cycle] at position [pos].
  static HomeSection discoveryAt(int pos, int cycle) {
    final s = discoveryPool[(pos + cycle * 5) % discoveryPool.length];
    return s.copyWith(cacheKey: '${s.cacheKey}_c${cycle % 3}');
  }

  /// "`More like <artist>`" sections from library seeds.
  static List<HomeSection> personalized(
      List<String> likedArtists, List<String> recentArtists,
      {int max = 4}) {
    final seeds = artistSeeds(
        [...likedArtists, ...recentArtists], max);
    return [
      for (var i = 0; i < seeds.length; i++)
        HomeSection(
          title: 'More like ${seeds[i]}',
          subtitle: 'Because you listened',
          query: '${seeds[i]} songs',
          cacheKey: 'home_like_$i',
        ),
    ];
  }

  static const labelWords = {
    'music',
    'official',
    'films',
    'records',
    'studio',
    't-series',
    'tseries',
    'vevo',
    'tips',
    'saregama',
    'sony',
    'zee',
    'universal',
    'eros',
    'jiosaavn',
    'wynk',
    'hungama',
    'shemaroo',
    'superhits',
    'radio',
    'topic',
    'movies',
    'talkies',
    'audio',
    'channel',
    'network',
    'entertainment',
    'multimedia',
    'creations',
    'junction',
    'jukebox',
    'melodies',
    'hits',
    'originals',
    'pictures',
    'episode',
    'episodes',
    'podcast',
    'song',
    'video',
    'shorts',
  };

  /// Real singer names from artist blobs (splits multi-artist, drops
  /// label-like names), ranked by frequency.
  static List<String> artistSeeds(List<String> artists, int max) {
    try {
      final counts = <String, int>{};
      final order = <String>[];
      for (final raw in artists) {
        final parts = raw
            .split(RegExp(r'[,&+/;|•·:]'))
            .expand((e) => e.split(RegExp(
                r' and | x | X | feat | feat\. | ft | ft\. ',
                caseSensitive: false)))
            .toList();
        for (final p in parts) {
          var name = p.trim();
          name = name.replaceAll(RegExp('^["\'\\-–]+|["\'\\-–]+\$'), '');
          name = name.replaceAll(RegExp(r'\s+'), ' ');
          if (name.length < 3 || name.length > 40) continue;
          final low = name.toLowerCase();
          if (low == 'youtube' ||
              low == 'unknown artist' ||
              low == 'song' ||
              low == 'songs' ||
              low == 'various artists' ||
              low == 'various') {
            continue;
          }
          if (low.split(' ').any(labelWords.contains)) continue;
          if (!counts.containsKey(name)) order.add(name);
          counts[name] = (counts[name] ?? 0) + 1;
        }
      }
      order.sort((a, b) => counts[b]!.compareTo(counts[a]!));
      return order.take(max).toList();
    } catch (_) {
      return [];
    }
  }

  /// Mood tiles (H6): dotted tiles → deep-search.
  static const moods = [
    ('Hindi Love', 'hindi love romantic songs'),
    ('Workout', 'workout motivation songs hindi'),
    ('Lofi Chill', 'lofi chill hindi songs'),
    ('Party', 'party dance hits hindi'),
  ];
}
