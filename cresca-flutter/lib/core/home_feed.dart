// Pure home-feed model (H3–H4 rails, H6 moods, discovery endless).
// Native ref: HomeFeed.kt (sections, TOP_SEEDS rotation, CORE order,
// DISCOVERY_POOL + discoveryAt cycle keys, personalized + artistSeeds
// with label-word filtering). Loading lives in AppState; this file is
// the rail catalog so tests pin rotation/keys/filters.
//
// Taste layer (topSeedForTaste/tasteSeedQueries/freshRotation): picks the
// Top Picks seed from recency-weighted affinity ([TasteProfile]) instead
// of blind rotation, and rotates freshness so refreshes never repeat the
// same page. Ranked-track assembly lives in discovery.dart
// (rankTopPicks); fetch orchestration in repository.topPicksFor.

import 'discovery.dart';

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

  /// Taste-biased Top Picks seed: the highest-affinity artists rotate
  /// through the seed slot by [refreshCount] (freshness rotation — never
  /// the same page twice in a row), falling back to the static pool when
  /// taste is empty. Keeps the `home_top` cache key so snapshots stay
  /// compatible.
  static HomeSection topSeedForTaste(
    int refreshCount, {
    TasteProfile? taste,
    List<String> recentArtists = const [],
    List<String> likedArtists = const [],
  }) {
    try {
      final ranked = tasteSeedQueries(
        taste: taste,
        recentArtists: recentArtists,
        likedArtists: likedArtists,
        max: 3,
      );
      if (ranked.isEmpty) return topSeed(refreshCount);
      final pick = ranked[refreshCount % ranked.length];
      final fallback = topSeed(refreshCount);
      // Never repeat the previous page: when taste yields a single seed
      // and it matches the fallback query, take the next static seed.
      if (ranked.length == 1 && pick == fallback.query) {
        return topSeed(refreshCount + 1);
      }
      return HomeSection(
        title: 'Top Picks For You',
        subtitle: 'Tuned to your taste',
        query: pick,
        cacheKey: 'home_top',
      );
    } catch (_) {
      return topSeed(refreshCount);
    }
  }

  /// Ranked Top Picks seed queries from taste: profile affinity first,
  /// then recency order, then the static pool as filler. All distinct,
  /// longest-first trimmed to [max].
  static List<String> tasteSeedQueries({
    TasteProfile? taste,
    List<String> recentArtists = const [],
    List<String> likedArtists = const [],
    int max = 4,
  }) {
    try {
      final out = <String>[];
      void add(String q) {
        final t = q.trim();
        if (t.length < 3 || t.length > 60) return;
        if (out.any((e) => e.toLowerCase() == t.toLowerCase())) return;
        if (out.length < max) out.add(t);
      }

      final affinity = taste?.topArtists(max) ?? const [];
      for (final a in affinity) {
        add('$a songs');
      }
      for (final a in [...recentArtists, ...likedArtists]) {
        final seeds = artistSeeds([a], 1);
        for (final s in seeds) {
          add('$s songs');
        }
        if (out.length >= max) break;
      }
      // Static filler keeps rails full for thin taste (rotation varies).
      var i = out.length;
      while (out.length < max) {
        final q = topSeeds[i % topSeeds.length].query;
        if (!out.contains(q)) out.add(q);
        i++;
        if (i > out.length + topSeeds.length) break;
      }
      return out.take(max).toList();
    } catch (_) {
      return [];
    }
  }

  /// Freshness rotation for surfaced track ids: drops ids shown within
  /// the last [memory] refreshes so Top Picks pages never repeat. The
  /// caller persists the returned list (cap [memory]) and feeds the
  /// dropped ids back as `shownIds` next refresh.
  static List<String> freshRotation(
    List<String> shownHistory,
    List<String> justShown, {
    int memory = 60,
  }) {
    try {
      final out = [...justShown, ...shownHistory];
      final seen = <String>{};
      return out.where((id) => seen.add(id)).take(memory).toList();
    } catch (_) {
      return shownHistory;
    }
  }

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
