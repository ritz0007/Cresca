// App state: repository + resolver + controller + library + caches.
// Owns home/trending/search loads (staged paint, 4-way parallel rails,
// incremental +120ms waves), the radio session (200 cap, chained
// autoplay, ≤5-remain top-up), precache waves (next5/prev3/charts6/
// taste3, top-4 search), session save/restore, and all 9 row actions.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../audio/playback.dart';
import '../auth/session.dart';
import '../core/home_feed.dart';
import '../core/motion.dart';
import '../core/queue.dart';
import '../core/session.dart';
import '../core/track.dart';
import '../data/cache.dart';
import '../data/lyrics.dart';
import '../data/repository.dart';
import '../data/resolve.dart';
import 'crash.dart';
import 'library.dart';
import 'radio_store.dart' show SavedRadio;

/// Home paint state (H8): skeleton → content | honest offline error.
enum HomeStatus { loading, ready, error }

class RailData {
  final HomeSection section;
  final List<YtTrack> tracks;
  const RailData(this.section, this.tracks);
}

class AppState extends ChangeNotifier {
  final Directory filesDir;
  late final YoutubeRepository repo;
  late final StreamResolver resolver;
  late final PlayerController controller;
  late final LibraryStore library;
  late final CrashLog crash;
  final YtSession ytSession = YtSession();
  SharedPreferences? prefs;

  bool motionOn = true;
  int refreshCount = 0;

  HomeStatus homeStatus = HomeStatus.loading;
  String homeError = '';
  List<YtTrack> topPicks = [];
  HomeSection topSeed = HomeFeed.topSeeds.first;
  List<RailData> rails = [];
  int discoveryCycle = 0;

  List<YtTrack> trendingGlobal = [];
  List<RailData> trendingRails = [];
  bool trendingLoading = false;

  // Radio session (R3-lite): seed + chained autoplay, 200 cap.
  List<YtTrack> radioTracks = [];
  YtTrack? radioSeed;
  bool radioLoading = false;

  Timer? _debounce;

  /// Session lyrics memo by track id (track re-entry never re-hits).
  final Map<String, LyricsState> lyricsMemo = {};

  /// Registered by the Search tab; double-tap on Search calls it (T1).
  void Function()? onSearchFocusRequest;

  void requestSearchFocus() {
    try {
      onSearchFocusRequest?.call();
    } catch (_) {}
  }

  AppState(this.filesDir);

  Future<void> init() async {
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}
    try {
      motionOn = prefs?.getBool(motionPrefKey) ?? true;
      refreshCount = prefs?.getInt('home_refresh_count') ?? 0;
    } catch (_) {}
    final urlCache = UrlCache();
    await ytSession.load();
    final session = RepoSession()
      ..cookies = ytSession.cookies
      ..visitorData = ytSession.visitorData
      ..poToken = ytSession.poToken;
    repo = YoutubeRepository(
      httpClient: http.Client(),
      session: session,
      cacheDir: filesDir,
    );
    resolver = StreamResolver(
      urlCache: urlCache,
      cookies: () => ytSession.cookies,
      visitorData: () => ytSession.visitorData,
      poToken: () => ytSession.poToken,
    );
    controller = PlayerController(
      engine: QueueEngine(),
      resolver: resolver,
      cacheDir: filesDir,
    );
    controller.onSaveSession = _writeSession;
    controller.onAdvanced = () async {
      try {
        await ensureRadioTail();
      } catch (_) {}
    };
    controller.onQueueChanged = () {
      try {
        notifyListeners();
      } catch (_) {}
    };
    controller.onError = (m) {
      try {
        notifyListeners();
      } catch (_) {}
    };
    library = LibraryStore(filesDir);
    crash = CrashLog(filesDir);
    try {
      await library.load();
      await controller.init();
      await _restoreSession();
      await _restoreUrlCache();
    } catch (e) {
      try {
        await crash.log('app init failed', e);
      } catch (_) {}
    }
    // Kick the home load from here too (screen initState ordering is
    // fragile across embedding versions); the screen also triggers
    // on demand via post-frame callback.
    try {
      if (topPicks.isEmpty && rails.isEmpty) {
        unawaited(loadHome());
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    try {
      _debounce?.cancel();
      controller.dispose();
      repo.dispose();
      resolver.dispose();
    } catch (_) {}
    super.dispose();
  }

  /// Pushes the encrypted session into the repository (login/logout).
  void syncSessionToRepo() {
    try {
      repo.session.cookies = ytSession.cookies;
      repo.session.visitorData = ytSession.visitorData;
      repo.session.poToken = ytSession.poToken;
      notifyListeners();
    } catch (_) {}
  }

  /// YouTube logout: wipes the encrypted session (the sheet clears the
  /// WebView cookies) and drops session-bound caches.
  Future<void> logoutYouTube() async {
    try {
      await ytSession.logout();
      syncSessionToRepo();
    } catch (_) {}
  }

  /// Taste seeds pull after login (liked + history, persisted for
  /// recommendations only — never merged into local liked/recent).
  Future<void> pullTasteSeeds() async {
    try {
      if (!ytSession.isLoggedIn) return;
      final (liked, history) = await repo.ytLibrary(max: 50);
      final seeds = [...liked, ...history].take(100).toList();
      if (seeds.isEmpty) return;
      final f = File('${filesDir.path}/yt_seeds.json');
      await atomicWrite(
          f,
          jsonEncode([
            for (final t in seeds)
              {
                'id': t.id,
                'title': t.title,
                'artist': t.artist,
                'thumb': t.thumbUrl,
                'watch': t.watchUrl,
              },
          ]));
    } catch (_) {}
  }

  void setMotion(bool on) {
    try {
      motionOn = on;
      prefs?.setBool(motionPrefKey, on);
      notifyListeners();
    } catch (_) {}
  }

  /// Manual refresh after direct engine mutations from sheets
  /// (remove/reorder), which bypass the controller hooks.
  void poke() {
    try {
      notifyListeners();
    } catch (_) {}
  }

  int motionMs(int ms) => motionOn ? ms : 1;

  // ---------- session ----------

  Future<void> _writeSession(Map<String, dynamic>? root) async {
    try {
      if (root == null) return;
      final f = File('${filesDir.path}/$sessionFile');
      await atomicWrite(f, _json(root));
    } catch (_) {}
  }

  Future<void> _restoreSession() async {
    try {
      final f = File('${filesDir.path}/$sessionFile');
      if (!await f.exists()) return;
      final text = await f.readAsString();
      final decoded = _jsonDecode(text);
      if (decoded is! Map) return;
      // Cold start: queue + position, no autoplay (P13).
      await controller.restore(decoded.cast<String, dynamic>());
    } catch (_) {}
  }

  Future<void> _restoreUrlCache() async {
    try {
      final f = File('${filesDir.path}/$urlDiskFile');
      if (!await f.exists()) return;
      resolver.restoreUrlSnapshot(await f.readAsString());
    } catch (_) {}
  }

  Future<void> persistUrlCache() async {
    try {
      final s = resolver.encodeUrlSnapshot();
      if (s == null) return;
      await atomicWrite(File('${filesDir.path}/$urlDiskFile'), s);
    } catch (_) {}
  }

  // ---------- home (H1–H4, H6–H10) ----------

  Future<List<YtTrack>> _fetchSection(HomeSection s) async {
    try {
      List<YtTrack> out;
      if (s.query == '__released__') {
        out = await repo.playlistTracks(
            HomeFeed.releasedPlaylistId, max: 25);
      } else if (s.query == '__charts__') {
        out = await repo.chartTopVideos(max: 25);
      } else {
        out = await repo.searchMusic(s.query, max: 15);
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /// Staged paint (H10): cached waves instantly, then 4-way parallel
  /// refresh with incremental +120ms waves. Never demo data (H8).
  /// Re-entry guarded (screen post-frame + AppState.init both trigger).
  bool _homeLoading = false;

  Future<void> loadHome({bool force = false}) async {
    if (_homeLoading) return;
    _homeLoading = true;
    try {
      homeStatus = HomeStatus.loading;
      homeError = '';
      notifyListeners();

      topSeed = HomeFeed.topSeed(refreshCount);
      // Wave 0: instant cached paint.
      try {
        final cachedTop =
            await repo.loadSnapshot('home_top', homeCacheTtlMs);
        if (cachedTop != null && cachedTop.isNotEmpty) {
          topPicks = cachedTop;
          notifyListeners();
        }
        final cachedRails = <RailData>[];
        for (final s in [HomeFeed.released, ...HomeFeed.core]) {
          try {
            final c = await repo.loadSnapshot(
                s.cacheKey, HomeFeed.sectionTtlMs);
            if (c != null && c.isNotEmpty) cachedRails.add(RailData(s, c));
          } catch (_) {}
        }
        if (cachedRails.isNotEmpty) {
          rails = cachedRails;
          homeStatus = HomeStatus.ready;
          notifyListeners();
        }
      } catch (_) {}

      // Waves: Top Picks + 4-way parallel rails, +120ms incremental.
      final topFuture = repo
          .searchMusic(topSeed.query, max: 15)
          .timeout(const Duration(seconds: 30))
          .catchError((_) => <YtTrack>[]);
      final sections = [HomeFeed.released, ...HomeFeed.core];
      final fresh = <RailData>[];
      for (var i = 0; i < sections.length; i += 4) {
        try {
          final chunk = sections.sublist(
              i, i + 4 > sections.length ? sections.length : i + 4);
          final results = await Future.wait(chunk.map(_fetchSection));
          for (var k = 0; k < chunk.length; k++) {
            if (results[k].isNotEmpty) {
              fresh.add(RailData(chunk[k], results[k]));
              unawaited(repo.saveSnapshot(chunk[k].cacheKey, results[k]));
            }
          }
          rails = _mergeRails(fresh);
          if (topPicks.isEmpty) {
            final t = await topFuture;
            if (t.isNotEmpty) {
              topPicks = t;
              unawaited(repo.saveSnapshot('home_top', t));
            }
          }
          homeStatus = HomeStatus.ready;
          notifyListeners();
          await Future<void>.delayed(const Duration(milliseconds: 120));
        } catch (_) {}
      }
      try {
        final t = await topFuture;
        if (t.isNotEmpty) {
          topPicks = t;
          unawaited(repo.saveSnapshot('home_top', t));
        }
      } catch (_) {}

      // Personalized: Because-you-played (2 seeds) + More-like-artist.
      try {
        await _loadPersonalized(fresh);
      } catch (_) {}

      if (topPicks.isEmpty && rails.isEmpty) {
        homeStatus = HomeStatus.error;
        homeError = 'You appear to be offline. Pull to retry.';
      } else {
        homeStatus = HomeStatus.ready;
      }
      notifyListeners();
      unawaited(_precacheChartsTaste());
      _homeLoading = false;
    } catch (_) {
      homeStatus = HomeStatus.error;
      homeError = 'Something went wrong. Pull to retry.';
      notifyListeners();
      _homeLoading = false;
    }
  }

  List<RailData> _mergeRails(List<RailData> fresh) {
    try {
      final order = [
        HomeFeed.released.title,
        ...HomeFeed.core.map((e) => e.title)
      ];
      final byTitle = {for (final r in fresh) r.section.title: r};
      return [
        for (final t in order)
          if (byTitle[t] != null) byTitle[t]!,
      ];
    } catch (_) {
      return fresh;
    }
  }

  Future<void> _loadPersonalized(List<RailData> fresh) async {
    try {
      final seeds = library.recent.take(2).toList();
      for (final s in seeds) {
        try {
          final rel = await repo.relatedTracks(s.watchUrl, max: 12);
          if (rel.length >= 3) {
            fresh.add(RailData(
              HomeSection(
                  title: 'Because you played ${s.displayArtist()}',
                  subtitle: 'Related mix',
                  query: '__related__${s.id}',
                  cacheKey: 'home_because_${s.id}'),
              rel,
            ));
          }
        } catch (_) {}
      }
      final likedArtists =
          library.liked.map((e) => e.displayArtist()).toList();
      final recentArtists =
          library.recent.map((e) => e.displayArtist()).toList();
      for (final sec in HomeFeed.personalized(likedArtists, recentArtists,
          max: 2)) {
        try {
          final hits = await repo.searchMusic(sec.query, max: 12);
          if (hits.isNotEmpty) fresh.add(RailData(sec, hits));
        } catch (_) {}
      }
      rails = _mergeRails(fresh);
      notifyListeners();
    } catch (_) {}
  }

  /// Endless discovery rails (H4): appended as the user scrolls.
  Future<void> loadMoreDiscovery() async {
    try {
      final pos = rails.length;
      final sec = HomeFeed.discoveryAt(pos, discoveryCycle);
      if (rails.any((r) => r.section.cacheKey == sec.cacheKey)) {
        discoveryCycle++;
        return;
      }
      final hits = await _fetchSection(sec);
      if (hits.isNotEmpty) {
        rails = [...rails, RailData(sec, hits)];
        unawaited(repo.saveSnapshot(sec.cacheKey, hits));
        notifyListeners();
      } else {
        discoveryCycle++;
      }
    } catch (_) {}
  }

  Future<void> hardRefresh() async {
    try {
      refreshCount++;
      try {
        await prefs?.setInt('home_refresh_count', refreshCount);
      } catch (_) {}
      await loadHome(force: true);
    } catch (_) {}
  }

  // ---------- trending (R1) ----------

  Future<void> loadTrending({bool force = false}) async {
    try {
      trendingLoading = true;
      notifyListeners();
      final cached =
          await repo.loadSnapshot('trending_global', trendingCacheTtlMs);
      if (cached != null && cached.isNotEmpty && !force) {
        trendingGlobal = cached;
        notifyListeners();
      }
      final results = await Future.wait([
        repo.chartTopVideos(max: 100).catchError((_) => <YtTrack>[]),
        repo
            .searchMusic('top hindi songs', max: 15)
            .catchError((_) => <YtTrack>[]),
        repo
            .searchMusic('top international songs', max: 15)
            .catchError((_) => <YtTrack>[]),
        repo
            .searchMusic('top telugu songs', max: 15)
            .catchError((_) => <YtTrack>[]),
        repo
            .searchMusic('top punjabi songs', max: 15)
            .catchError((_) => <YtTrack>[]),
      ]);
      if (results[0].isNotEmpty) {
        trendingGlobal = results[0];
        unawaited(repo.saveSnapshot('trending_global', results[0]));
      }
      const titles = ['Hindi', 'International', 'Telugu', 'Punjabi'];
      trendingRails = [
        for (var i = 0; i < 4; i++)
          if (results[i + 1].isNotEmpty)
            RailData(
              HomeSection(
                  title: titles[i],
                  query: '',
                  cacheKey: 'trending_${titles[i].toLowerCase()}'),
              results[i + 1],
            ),
      ];
      trendingLoading = false;
      notifyListeners();
    } catch (_) {
      trendingLoading = false;
      notifyListeners();
    }
  }

  // ---------- search (S1–S4) ----------

  Future<List<YtTrack>> searchNow(String query, {int max = 15}) async {
    try {
      final hits = await repo.searchMusic(query, max: max);
      unawaited(repo.saveSnapshot('search_${query.hashCode}', hits));
      unawaited(_precacheSearchTop(hits));
      return hits;
    } catch (_) {
      return [];
    }
  }

  Future<List<YtTrack>?> searchCached(String query) =>
      repo.loadSnapshot('search_${query.hashCode}', searchCacheTtlMs);

  Future<List<String>> suggestions(String input) =>
      repo.suggestions(input);

  Future<List<YtArtist>> artistsFor(
      String query, List<YtTrack> rows) async {
    try {
      final hits = await repo.searchArtists(query, max: 8);
      if (hits.isNotEmpty) return hits;
      // Track-derived fallback (real channels unknown).
      final seen = <String>{};
      final out = <YtArtist>[];
      for (final t in rows) {
        final a = t.displayArtist();
        if (a == 'Unknown Artist' || !seen.add(a.toLowerCase())) continue;
        out.add(YtArtist(name: a, thumbUrl: t.thumbUrl));
        if (out.length >= 8) break;
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  // ---------- radio (R2–R3) ----------

  /// Station tap: music-only search → play from top (native onStation).
  Future<void> startStation(String query) async {
    try {
      radioLoading = true;
      notifyListeners();
      final res = await repo.searchMusic(query, max: 20);
      if (res.isNotEmpty) {
        radioSeed = null;
        radioTracks = [];
        await controller.playQueue(res, 0);
      }
      radioLoading = false;
      notifyListeners();
    } catch (_) {
      radioLoading = false;
      notifyListeners();
    }
  }

  /// Resume a saved radio card (plays its stored tracks).
  Future<void> openRadio(SavedRadio radio) async {
    try {
      if (radio.tracks.isEmpty) {
        await startRadio(radio.seed);
        return;
      }
      radioSeed = radio.seed;
      radioTracks = List.of(radio.tracks);
      await controller.playQueue(radioTracks, 0);
      await library.upsertRadio(radio);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> toggleRadioLike(String seedId) async {
    try {
      await library.toggleRadioLike(seedId);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> deleteRadio(String seedId) async {
    try {
      await library.deleteRadio(seedId);
      notifyListeners();
    } catch (_) {}
  }

  /// Saves the current song-radio session as a card (R3 Save as playlist
  /// counterpart: radios persist separately from playlists).
  Future<void> saveRadioCard() async {
    try {
      final seed = radioSeed;
      if (seed == null || radioTracks.isEmpty) return;
      await library.upsertRadio(SavedRadio(
        id: 'radio_${seed.id}',
        seed: seed,
        title: '${seed.displayArtist()} Radio',
        subtitle: '${radioTracks.length} songs',
        thumbUrl: seed.thumbUrl,
        tracks: List.of(radioTracks),
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      notifyListeners();
    } catch (_) {}
  }

  // ---------- radio lite (R3 path for Phase-2 audio) ----------

  Future<void> startRadio(YtTrack seed) async {
    try {
      radioLoading = true;
      radioSeed = seed;
      notifyListeners();
      final fill = await repo.autoplayFor(seed, max: 60);
      radioTracks = distinctById([seed, ...fill]).take(200).toList();
      await controller.playQueue(radioTracks, 0);
      radioLoading = false;
      unawaited(saveRadioCard());
      notifyListeners();
    } catch (_) {
      radioLoading = false;
      notifyListeners();
    }
  }

  /// Chained autoplay: ≤5 remain → extend from the tail (200 cap).
  Future<void> ensureRadioTail() async {    try {
      if (radioTracks.isEmpty) {
        // Plain queue: top up from related once (endless fixed-20).
        final cur = controller.engine.current;
        if (cur == null) return;
        if (controller.engine.upcomingCount() > 5) return;
        final fill = await repo.autoplayFor(cur, max: 20);
        if (fill.isNotEmpty) {
          controller.engine.appendAuto(fill.take(20).toList());
          notifyListeners();
        }
        return;
      }
      if (controller.engine.upcomingCount() > 5) return;
      if (radioTracks.length >= 200) return;
      final tail = radioTracks.last;
      final more = await repo.relatedTracks(tail.watchUrl, max: 20);
      final fresh =
          more.where((t) => !radioTracks.any((e) => e.id == t.id)).toList();
      if (fresh.isEmpty) return;
      radioTracks = [...radioTracks, ...fresh].take(200).toList();
      controller.engine.appendAuto(fresh);
      notifyListeners();
    } catch (_) {}
  }

  // ---------- precache waves (C5) ----------

  Future<void> _precacheChartsTaste() async {
    try {
      final charts = trendingGlobal.take(6).toList();
      for (final t in charts) {
        try {
          await resolver.audioUrl(t.watchUrl).timeout(
                const Duration(seconds: 10),
              );
        } catch (_) {}
      }
      final seeds = [
        ...library.liked.take(2),
        ...library.recent.take(1),
      ];
      for (final s in seeds.take(3)) {
        try {
          final rel = await repo.relatedTracks(s.watchUrl, max: 3);
          for (final t in rel.take(1)) {
            try {
              await resolver.audioUrl(t.watchUrl).timeout(
                    const Duration(seconds: 10),
                  );
            } catch (_) {}
          }
        } catch (_) {}
      }
      unawaited(persistUrlCache());
    } catch (_) {}
  }

  Future<void> _precacheSearchTop(List<YtTrack> hits) async {
    try {
      for (final t in hits.take(4)) {
        try {
          await resolver.audioUrl(t.watchUrl).timeout(
                const Duration(seconds: 10),
              );
        } catch (_) {}
      }
      unawaited(persistUrlCache());
    } catch (_) {}
  }

  Future<void> precacheAroundPlay() async {
    try {
      for (final t in controller.engine.upcomingIds(5)) {
        try {
          await resolver.audioUrl(t.watchUrl).timeout(
                const Duration(seconds: 10),
              );
        } catch (_) {}
      }
      for (final t in controller.engine.previousIds(3)) {
        try {
          await resolver.audioUrl(t.watchUrl).timeout(
                const Duration(seconds: 10),
              );
        } catch (_) {}
      }
      unawaited(persistUrlCache());
    } catch (_) {}
  }

  // ---------- row actions (M1, identical everywhere) ----------

  Future<void> actPlay(List<YtTrack> context, int index) async {
    try {
      await controller.playQueue(context, index);
      if (context.isNotEmpty &&
          index >= 0 &&
          index < context.length) {
        unawaited(library.pushRecent(context[index]));
      }
      unawaited(precacheAroundPlay());
      notifyListeners();
    } catch (_) {}
  }

  Future<void> actPlayNext(YtTrack t) async {
    try {
      controller.engine.playNext(t);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> actAddToQueue(YtTrack t) async {
    try {
      controller.engine.addToQueue(t);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> actToggleLike(YtTrack t) async {
    try {
      await library.toggleLike(t);
      notifyListeners();
    } catch (_) {}
  }

  Future<String?> actShare(YtTrack t) async {
    try {
      final text = '${t.title} — ${t.displayArtist()}\n${t.watchUrl}';
      await SharePlus.instance.share(ShareParams(text: text));
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> actOpenYouTube(YtTrack t) async {
    try {
      final uri = Uri.tryParse(t.watchUrl);
      if (uri == null) return;
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// Downloads land in Phase 3 (background_downloader): honest stub.
  String get downloadStub =>
      'Downloads arrive with offline mode in Phase 3';

  String _json(Map<String, dynamic> root) {
    try {
      return jsonEncode(root);
    } catch (_) {
      return '{}';
    }
  }

  dynamic _jsonDecode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  void unawaited(Future<void> f) {}
}
