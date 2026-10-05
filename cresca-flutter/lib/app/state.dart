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
import 'package:app_links/app_links.dart' show AppLinks;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../audio/playback.dart';
import '../auth/session.dart';
import '../auth/spotify.dart';
import '../core/home_feed.dart';
import '../core/motion.dart';
import '../core/queue.dart';
import '../core/session.dart';
import '../core/track.dart';
import '../data/cache.dart';
import '../data/lyrics.dart';
import '../data/details.dart';
import '../data/repository.dart';
import '../data/resolve.dart';
import '../jam/protocol.dart';
import '../jam/session.dart';
import 'crash.dart';
import 'downloads.dart';
import 'library.dart';
import 'updates.dart';
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
  late final DownloadStore downloads;
  late final DetailsStore details = DetailsStore();
  late final JamSession jam;
  String jamName = '';
  AppLinks? _jamLinks;
  StreamSubscription? _jamLinkSub;
  final YtSession ytSession = YtSession();
  final SpotifySession spotify = SpotifySession();
  final UpdateChecker updates = UpdateChecker();
  SharedPreferences? prefs;

  /// Pending update (banner source, H9/Y4).
  AppUpdate? pendingUpdate;
  bool updateChecking = false;
  double updateProgress = -1;

  /// Appearance: system / light / dark (L4).
  String appearance = 'system';

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
    await spotify.load();
    final session = RepoSession()
      ..cookies = ytSession.cookies
      ..visitorData = ytSession.visitorData
      ..poToken = ytSession.poToken;
    session.useInnerTube =
        prefs?.getBool('engine_fast') ?? true;
    try {
      appearance = prefs?.getString('appearance') ?? 'system';
    } catch (_) {}
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
    controller.onError = (m) {
      try {
        notifyListeners();
      } catch (_) {}
    };
    library = LibraryStore(filesDir);
    crash = CrashLog(filesDir);
    downloads = DownloadStore(
      filesDir,
      publicDir: _deviceMusicDir(),
    );
    try {
      downloads.location =
          prefs?.getString('dl_location') ?? 'app';
    } catch (_) {}
    controller.localFileFor = downloads.fileFor;
    downloads.onChanged = () {
      try {
        notifyListeners();
      } catch (_) {}
    };
    jam = JamSession(controller, JamAppHooks(
      queueSnapshot: () => controller.engine.snapshot(),
      currentIndex: () => controller.engine.currentIndex,
      isPlaying: () {
        try {
          return controller.player.playing;
        } catch (_) {
          return false;
        }
      },
      positionMs: () {
        try {
          return controller.player.position.inMilliseconds;
        } catch (_) {
          return 0;
        }
      },
      currentTrack: () => controller.engine.current,
      toast: _bannerToast,
      poke: notifyListeners,
    ));
    controller.onAdvanced = () async {
      try {
        jam.onPlayerEvent();
        await ensureRadioTail();
      } catch (_) {}
    };
    controller.onQueueChanged = () {
      try {
        jam.onPlayerEvent();
        notifyListeners();
      } catch (_) {}
    };
    controller.onTransportChanged = () {
      try {
        jam.onPlayerEvent();
        notifyListeners();
      } catch (_) {}
    };
    // JAM create rate-limit client side falls back to the server.
    try {
      jamName = prefs?.getString('jam_name') ?? '';
    } catch (_) {}
    // JAM deep links (cresca://jam/CODE): prefill + auto-join (F2).
    try {
      _jamLinks = AppLinks();
      _jamLinkSub = _jamLinks!.uriLinkStream.listen((uri) {
        try {
          if (uri.host == 'jam' || uri.host == 'jamroom') {
            final seg = uri.pathSegments.isEmpty
                ? uri.host
                : uri.pathSegments.first;
            final code = (seg.isNotEmpty && jamValidCode(seg))
                ? seg
                : (uri.queryParameters['code'] ?? '');
            if (jamValidCode(code)) {
              jamJoin(code, auto: true);
            }
          }
        } catch (_) {}
      }, onError: (_) {});
    } catch (_) {}
    try {
      await library.load();
      await downloads.load();
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
    scheduleAutoUpdateCheck();
  }

  @override
  void dispose() {
    try {
      _debounce?.cancel();
      _jamLinkSub?.cancel();
      jam.dispose();
      downloads.dispose();
      details.dispose();
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

  /// Best-effort public Music dir (device-Music downloads switch).
  Directory? _deviceMusicDir() {
    try {
      const candidates = [
        '/storage/emulated/0/Music',
        '/sdcard/Music',
      ];
      for (final p in candidates) {
        final d = Directory(p);
        try {
          if (d.existsSync()) return d;
        } catch (_) {}
      }
      return Directory('/storage/emulated/0/Music');
    } catch (_) {
      return null;
    }
  }

  Future<void> setDownloadLocation(String value) async {
    try {
      downloads.location = value == 'device' ? 'device' : 'app';
      await prefs?.setString('dl_location', downloads.location);
      notifyListeners();
    } catch (_) {}
  }

  /// Row-menu Download: resolves the stream URL once, then enqueues a
  /// background download. Returns a human status string for the toast.
  Future<String> actDownload(YtTrack t) async {
    try {
      if (downloads.isDownloaded(t.id)) return 'Already downloaded';
      final url = await resolver.audioUrl(t.watchUrl).timeout(
            const Duration(seconds: 45),
          );
      if (url == null || url.isEmpty) {
        return 'Could not resolve audio stream';
      }
      final ok = await downloads.enqueue(t, url);
      return ok ? 'Download started' : 'Download failed to start';
    } catch (_) {
      return 'Download failed to start';
    }
  }

  void setMotion(bool on) {
    try {
      motionOn = on;
      prefs?.setBool(motionPrefKey, on);
      notifyListeners();
    } catch (_) {}
  }

  /// Engine: Fast (InnerTube, default) vs Stable (extractor only).
  bool get engineFast => repo.session.useInnerTube;

  Future<void> setEngineFast(bool fast) async {
    try {
      repo.session.useInnerTube = fast;
      await prefs?.setBool('engine_fast', fast);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setAppearance(String value) async {
    try {
      appearance =
          value == 'light' || value == 'dark' ? value : 'system';
      await prefs?.setString('appearance', appearance);
      notifyListeners();
    } catch (_) {}
  }

  /// Clears network caches (home/search/trending snapshots + stream
  /// URLs + audio bytes) without touching library/downloads/session.
  Future<String> clearCache() async {
    try {
      var bytes = 0;
      final dir = filesDir;
      final entries = await dir.list().toList();
      for (final e in entries) {
        try {
          final name = e.path.split(RegExp(r'[/\\]')).last;
          if (e is File &&
              (name.startsWith('yt_') ||
                  name == urlDiskFile)) {
            try {
              bytes += await e.length();
            } catch (_) {}
            await e.delete();
          }
        } catch (_) {}
      }
      try {
        final audio = Directory(
            '${dir.path}/$audioCacheDirName');
        if (await audio.exists()) {
          await for (final e in audio.list(recursive: true)) {
            try {
              if (e is File) bytes += await e.length();
            } catch (_) {}
          }
          await audio.delete(recursive: true);
        }
      } catch (_) {}
      urlCacheClear();
      return 'Cleared ${_mb(bytes)}';
    } catch (_) {
      return 'Clear failed';
    }
  }

  void urlCacheClear() {
    try {
      resolver.urlCache.rows.clear();
      resolver.urlCache.lastDiskSaveMs = 0;
    } catch (_) {}
  }

  static String _mb(int bytes) {
    try {
      if (bytes < 1024 * 1024) return '${bytes ~/ 1024} KB';
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return '';
    }
  }

  /// Update check (Y4): daily throttle unless manual; sets pendingUpdate
  /// when the release tag is newer than the installed version.
  /// Returns a human status string for toasts.
  Future<String> checkForUpdates({bool manual = false}) async {
    if (updateChecking) return 'Checking…';
    try {
      updateChecking = true;
      updateProgress = -1;
      notifyListeners();
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = prefs?.getInt('update_last_check') ?? 0;
      if (!manual && now - last < updateIntervalMs) return 'Up to date';
      final rel = await updates.latest();
      try {
        await prefs?.setInt('update_last_check', now);
      } catch (_) {}
      if (rel == null) return 'Check failed — try again later';
      final current = await updates.currentVersion();
      if (!isNewerTag(rel.tag, current)) {
        pendingUpdate = null;
        notifyListeners();
        return 'Up to date ($current)';
      }
      pendingUpdate = rel;
      try {
        final raw = prefs?.getStringList('update_notified_tags') ?? [];
        await updates.notifyOnce(
          rel,
          raw.toSet(),
          (tag) async {
            try {
              final next = {...raw, tag}.toList();
              await prefs?.setStringList(
                  'update_notified_tags', next);
            } catch (_) {}
          },
        );
      } catch (_) {}
      notifyListeners();
      return 'Cresca ${rel.tag} available';
    } catch (_) {
      return 'Check failed — try again later';
    } finally {
      updateChecking = false;
      try {
        notifyListeners();
      } catch (_) {}
    }
  }

  /// Quiet auto-check shortly after startup (Y4 daily throttle inside).
  void scheduleAutoUpdateCheck() {
    try {
      unawaited(Future<void>.delayed(
          const Duration(seconds: 10), () async {
        try {
          await checkForUpdates();
        } catch (_) {}
      }));
    } catch (_) {}
  }

  /// Local path of the downloaded update APK (when present).
  String? get updateApkPath {
    try {
      final u = pendingUpdate;
      if (u == null || u.apkName.isEmpty) return null;
      final f = File('${filesDir.path}/Cresca/${u.apkName}');
      return f.existsSync() ? f.path : null;
    } catch (_) {
      return null;
    }
  }

  bool get updateDownloaded => updateApkPath != null;

  Future<String> downloadUpdate() async {
    try {
      final u = pendingUpdate;
      if (u == null) return 'No update pending';
      if (u.apkUrl.isEmpty) {
        if (u.pageUrl.isNotEmpty) {
          try {
            await launchUrl(Uri.parse(u.pageUrl),
                mode: LaunchMode.externalApplication);
          } catch (_) {}
          return 'Opened release page';
        }
        return 'No APK asset for this release';
      }
      updateProgress = 0;
      notifyListeners();
      final ok = await updates.downloadApk(
        u,
        onProgress: (p) {
          try {
            updateProgress = p;
            notifyListeners();
          } catch (_) {}
        },
      );
      updateProgress = -1;
      notifyListeners();
      return ok ? 'Downloading update…' : 'Download failed to start';
    } catch (_) {
      return 'Download failed to start';
    }
  }

  Future<String> installUpdate() async {
    try {
      final path = updateApkPath;
      if (path == null) return 'APK not downloaded yet';
      final ok = await updates.installApk(path);
      return ok ? 'Opening installer…' : 'Allow installs, then retry';
    } catch (_) {
      return 'Install failed';
    }
  }

  Future<void> openReleasePage() async {
    try {
      final url = pendingUpdate?.pageUrl ?? '';
      if (url.isEmpty) return;
      await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void dismissUpdate() {
    try {
      pendingUpdate = null;
      notifyListeners();
    } catch (_) {}
  }

  // ---------- JAM (Phase 4, F1–F10 façade) ----------

  void _bannerToast(String msg) {
    try {
      jam.statusLine = msg;
      notifyListeners();
    } catch (_) {}
  }

  /// Queue the sheet shows: host = live engine; guest = snapshot (F3:
  /// guest's local queue IS the host queue).
  List<YtTrack> jamQueueView() {
    try {
      return jam.isHost
          ? controller.engine.snapshot()
          : [for (final j in jam.snapshotQueue) _jamToYt(j)];
    } catch (_) {
      return const [];
    }
  }

  YtTrack _jamToYt(JamTrack t) => YtTrack(
        id: t.id,
        title: t.title.isEmpty ? 'Unknown' : t.title,
        artist: t.artist.isEmpty ? 'YouTube' : t.artist,
        thumbUrl: t.thumb,
        watchUrl: t.url.isEmpty
            ? 'https://music.youtube.com/watch?v=${t.id}'
            : t.url,
      );

  Future<void> jamSetName(String name) async {
    try {
      jamName = name.trim();
      await prefs?.setString('jam_name', jamName);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> jamCreate() async {
    try {
      await jam.createJam(
          jamName.isEmpty ? 'Host' : jamName);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> jamJoin(String code, {bool auto = false}) async {
    try {
      if (auto) jam.pendingCode = code;
      await jam.joinJam(
          jamName.isEmpty ? 'Guest' : jamName,
          auto ? code : code);
      notifyListeners();
    } catch (_) {}
  }

  void jamSetGuestAllowed(bool on) {
    try {
      jam.setGuestAllowed(on);
      notifyListeners();
    } catch (_) {}
  }

  void jamLeave() {
    try {
      jam.leaveJam();
      notifyListeners();
    } catch (_) {}
  }

  void jamEnd() {
    try {
      jam.endJam();
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
        // Cached server-driven browse rails (YTM titles preserved).
        try {
          final idx = prefs?.getStringList('home_browse_index') ?? const [];
          for (final raw in idx.take(4).toList().reversed) {
            try {
              final parts = raw.split('§');
              if (parts.length != 3) continue;
              final c = await repo.loadSnapshot(
                  parts[1], HomeFeed.sectionTtlMs);
              if (c != null && c.isNotEmpty) {
                cachedRails.insert(
                    0,
                    RailData(
                        HomeSection(
                            title: parts[0],
                            subtitle: 'YouTube Music',
                            query: parts[2],
                            cacheKey: parts[1]),
                        c));
              }
            } catch (_) {}
          }
        } catch (_) {}
        if (cachedRails.isNotEmpty) {
          rails = cachedRails;
          homeStatus = HomeStatus.ready;
          notifyListeners();
        }
      } catch (_) {}

      // Waves: Top Picks + 4-way parallel rails, +120ms incremental.
      // Server-driven YTM shelves first (native HomeFeed shape: Quick
      // Picks → new releases → moods/charts): FEmusic_home browse,
      // real YTM titles kept ("Quick picks", "New releases", ...).
      // Playlist-card shelves ("Featured playlists...") are skipped —
      // cards aren't playable tracks (honest rails only, H8).
      final topFuture = repo
          .searchMusic(topSeed.query, max: 15)
          .timeout(const Duration(seconds: 30))
          .catchError((_) => <YtTrack>[]);
      final browseFuture = repo
          .homeShelves(maxShelves: 8, perShelf: 12)
          .timeout(const Duration(seconds: 30))
          .catchError((_) => <String, List<YtTrack>>{});
      // Playlist-card shelves (YTM kiosk parity): "Trending 20 India" /
      // "New releases"-style cards resolve to real tracks via
      // playlistTracks. Max 2 cards, parallel, 25 s cap.
      final cardsFuture = repo
          .browsePlaylistCards(maxCards: 2)
          .timeout(const Duration(seconds: 40))
          .catchError((_) => <(String, String, String)>[]);
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

      // Server-driven YTM shelves enrich AFTER the query waves paint
      // (never block them): FEmusic_home track shelves first, then
      // playlist-card shelves ("Trending 20 India"-style cards resolve
      // via playlistTracks). Real YTM titles kept throughout.
      try {
        final browse = await browseFuture;
        var touched = false;
        for (final e in browse.entries) {
          try {
            final title = e.key.trim();
            final low = title.toLowerCase();
            if (title.isEmpty || e.value.length < 3) continue;
            if (low.contains('playlist') ||
                low.contains('chart') ||
                low.contains('video')) {
              continue;
            }
            final slug = low.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
            final sec = HomeSection(
              title: title,
              subtitle: 'YouTube Music',
              query: '__browse__$slug',
              cacheKey: 'home_browse_$slug',
            );
            if (fresh.any((r) => r.section.cacheKey == sec.cacheKey)) {
              continue;
            }
            fresh.add(RailData(sec, e.value.take(15).toList()));
            unawaited(repo.saveSnapshot(sec.cacheKey, e.value));
            touched = true;
            if (fresh
                    .where((r) => r.section.query
                        .startsWith('__browse__'))
                    .length >=
                4) {
              break;
            }
          } catch (_) {}
        }
        try {
          final cards = await cardsFuture;
          for (final (shelf, card, bid) in cards) {
            try {
              if (fresh
                  .any((r) => r.section.cacheKey == 'home_pl_$bid')) {
                continue;
              }
              final tracks = await repo
                  .playlistTracks(bid, max: 15)
                  .timeout(const Duration(seconds: 25));
              if (tracks.length < 3) continue;
              final sec = HomeSection(
                title: card,
                subtitle: shelf,
                query: '__browsepl__$bid',
                cacheKey: 'home_pl_$bid',
              );
              fresh.add(RailData(sec, tracks));
              unawaited(repo.saveSnapshot(sec.cacheKey, tracks));
              touched = true;
            } catch (_) {}
          }
        } catch (_) {}
        if (touched) {
          try {
            await prefs?.setStringList(
                'home_browse_index',
                [for (final r in fresh) '${r.section.title}§${r.section.cacheKey}§${r.section.query}']);
          } catch (_) {}
          rails = _mergeRails(fresh);
          notifyListeners();
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
      // Browse (server-driven YTM) rails keep their arrival order
      // first — both track shelves (__browse__) and playlist-card
      // rails (__browsepl__); query rails follow in catalog order.
      final browse = fresh.where((r) =>
          r.section.query.startsWith('__browse__') ||
          r.section.query.startsWith('__browsepl__'));
      final rest = fresh.where((r) =>
          !r.section.query.startsWith('__browse__') &&
          !r.section.query.startsWith('__browsepl__'));
      final order = [
        HomeFeed.released.title,
        ...HomeFeed.core.map((e) => e.title)
      ];
      final byTitle = {for (final r in rest) r.section.title: r};
      return [
        ...browse,
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
  bool _discoveryLoading = false;
  Future<void> loadMoreDiscovery() async {
    if (_discoveryLoading) return;
    _discoveryLoading = true;
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
    } catch (_) {
    } finally {
      _discoveryLoading = false;
    }
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
  Future<void> ensureRadioTail() async {
    try {
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

  /// JAM guest gate (F6): a guest without host-granted control may
  /// queue-add (wish) but cannot start new playback contexts.
  bool get jamPlaybackBlocked =>
      jam.connected && !jam.isHost && !jam.guestAllowed;

  Future<void> actPlay(List<YtTrack> context, int index) async {
    try {
      if (jamPlaybackBlocked) {
        jam.statusLine = 'Only the host controls the JAM';
        notifyListeners();
        return;
      }
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
      if (jamPlaybackBlocked) {
        // Wishes welcome: queue-top rides the room's add path.
        unawaited(jam.guestQueueAdd(t));
        jam.statusLine = 'Only the host controls the JAM';
        notifyListeners();
        return;
      }
      controller.engine.playNext(t);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> actAddToQueue(YtTrack t) async {
    try {
      if (jamPlaybackBlocked) {
        unawaited(jam.guestQueueAdd(t));
        jam.statusLine = 'Song sent to the host for approval';
        notifyListeners();
        return;
      }
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
