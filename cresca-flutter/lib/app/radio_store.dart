// Saved radios (R2): one card per seed track, 30-card / 200-track caps,
// liked-first recency sort, atomic JSON. Native ref: RadioStore.kt
// (radios.json schema 1:1). The 6 static station gradients live here too.
//
// Taste memory lives here too (TasteStore): the persisted TasteProfile
// (artist/mood affinity + skip/impression counts) behind Top Picks and
// Up Next ranking. Same taste.json schema as repository.saveTaste/
// loadTaste — one file, one profile, last-writer-wins; the app layer
// should pick a single writer. Mix assembly for chained radio sessions
// is nextRadioBatch (taste-ranked, session-deduped, 200-capped).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../core/discovery.dart';
import '../core/track.dart';
import 'library.dart' show trackRow, trackFromRow;

const int radioCap = 30;
const int radioTrackCap = 200;

/// Chained radio session cap (RESTRUCTURE numbers: radio session 200).
const int radioSessionCap = 200;

/// Taste profile snapshot file (shared with repository.saveTaste).
const String tasteStoreFile = 'taste.json';

class SavedRadio {
  final String id;
  final YtTrack seed;
  final String title;
  final String subtitle;
  final String thumbUrl;
  final List<YtTrack> tracks;
  final bool liked;
  final int createdAt;
  final int updatedAt;
  const SavedRadio({
    required this.id,
    required this.seed,
    required this.title,
    this.subtitle = '',
    this.thumbUrl = '',
    this.tracks = const [],
    this.liked = false,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  SavedRadio copyWith({
    String? id,
    List<YtTrack>? tracks,
    bool? liked,
    int? createdAt,
    int? updatedAt,
    String? title,
    String? subtitle,
    String? thumbUrl,
  }) =>
      SavedRadio(
        id: id ?? this.id,
        seed: seed,
        title: title ?? this.title,
        subtitle: subtitle ?? this.subtitle,
        thumbUrl: thumbUrl ?? this.thumbUrl,
        tracks: tracks ?? this.tracks,
        liked: liked ?? this.liked,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

List<SavedRadio> radiosFromJson(String raw) {
  final out = <SavedRadio>[];
  try {
    if (raw.trim().isEmpty) return out;
    final arr = jsonDecode(raw);
    if (arr is! List) return out;
    final seen = <String>{};
    for (final e in arr) {
      try {
        if (e is! Map) continue;
        final m = e.cast<String, dynamic>();
        final seedId = (m['seedId'] ?? '').toString();
        if (seedId.isEmpty || !seen.add(seedId)) continue;
        final tracks = <YtTrack>[];
        final tarr = m['tracks'];
        if (tarr is List) {
          for (final te in tarr) {
            try {
              if (tracks.length >= radioTrackCap) break;
              if (te is! Map) continue;
              final t = trackFromRow(te.cast<String, dynamic>());
              if (t == null) continue;
              tracks.add(t);
            } catch (_) {}
          }
        }
        final title = (m['title'] ?? '').toString();
        out.add(SavedRadio(
          id: (m['id'] ?? 'radio_$seedId').toString(),
          seed: YtTrack(
            id: seedId,
            title: (m['seedTitle'] ?? '').toString(),
            artist: (m['seedArtist'] ?? '').toString(),
            thumbUrl: (m['seedThumb'] ?? '').toString(),
            watchUrl: (m['seedWatch'] ?? '').toString(),
          ),
          title: title.isEmpty ? 'Radio' : title,
          subtitle: (m['subtitle'] ?? '').toString(),
          thumbUrl: (m['thumb'] ?? '').toString(),
          tracks: tracks,
          liked: m['liked'] == true,
          createdAt: int.tryParse(m['createdAt'].toString()) ?? 0,
          updatedAt: int.tryParse(m['updatedAt'].toString()) ?? 0,
        ));
        if (out.length >= radioCap) break;
      } catch (_) {}
    }
    out.sort(_radioOrder);
  } catch (_) {}
  return out;
}

int _radioOrder(SavedRadio a, SavedRadio b) {
  if (a.liked != b.liked) return a.liked ? -1 : 1;
  return b.updatedAt.compareTo(a.updatedAt);
}

String radiosToJson(List<SavedRadio> radios) => jsonEncode([
      for (final r in radios.take(radioCap))
        {
          'id': r.id,
          'seedId': r.seed.id,
          'seedTitle': r.seed.title,
          'seedArtist': r.seed.artist,
          'seedThumb': r.seed.thumbUrl,
          'seedWatch': r.seed.watchUrl,
          'title': r.title.length > 120
              ? r.title.substring(0, 120)
              : r.title,
          'subtitle': r.subtitle.length > 120
              ? r.subtitle.substring(0, 120)
              : r.subtitle,
          'thumb': r.thumbUrl,
          'liked': r.liked,
          'createdAt': r.createdAt,
          'updatedAt': r.updatedAt,
          'tracks': [
            for (final t in r.tracks.take(radioTrackCap))
              if (t.id.isNotEmpty) trackRow(t),
          ],
        },
    ]);

/// Static station: label + seed query + gradient colors (ARGB, R2).
class RadioStation {
  final String label;
  final String query;
  final int top;
  final int bottom;
  const RadioStation(this.label, this.query, this.top, this.bottom);
}

const radioStations = [
  RadioStation('Arijit Radio', 'arijit singh', 0xFFFA243C, 0xFF7D0018),
  RadioStation('Lofi Radio', 'lofi chill beats', 0xFF5E5CE6, 0xFF1B1B6B),
  RadioStation('Workout Radio', 'workout motivation songs', 0xFFFF9F0A,
      0xFFB25000),
  RadioStation('Party Radio', 'party dance hits', 0xFFFF375F, 0xFFBF5AF2),
  RadioStation('Romantic Radio', 'romantic hindi songs', 0xFF64D2FF,
      0xFF0A84FF),
  RadioStation('2000s Hits', '2000s hindi hits', 0xFF30D158, 0xFF0B5C2A),
];

/// File-backed taste memory: loads the persisted [TasteProfile] (with
/// background decay so stale taste fades), records plays/skips/
/// impressions, and saves atomically. All IO silent, never throws.
class TasteStore {
  final Directory dir;
  TasteProfile profile = const TasteProfile();

  TasteStore(this.dir);

  File get _file => File('${dir.path}/$tasteStoreFile');

  Future<void> load() async {
    try {
      if (!await _file.exists()) {
        profile = const TasteProfile();
        return;
      }
      profile = TasteProfile.decode(await _file.readAsString()).decayed();
    } catch (_) {
      profile = const TasteProfile();
    }
  }

  Future<void> _save() async {
    try {
      final raw = profile.encode();
      if (raw.isEmpty) return;
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(raw);
      try {
        if (await _file.exists()) await _file.delete();
      } catch (_) {}
      await tmp.rename(_file.path);
    } catch (_) {}
  }

  Future<void> recordPlay(YtTrack t) async {
    try {
      profile = profile.recordPlay(t,
          nowMs: DateTime.now().millisecondsSinceEpoch);
      await _save();
    } catch (_) {}
  }

  /// Skip-aware decay lives in TasteProfile.recordSkip: the skip is
  /// remembered and the artist affinity is multiplied down.
  Future<void> recordSkip(YtTrack t) async {
    try {
      profile = profile.recordSkip(t,
          nowMs: DateTime.now().millisecondsSinceEpoch);
      await _save();
    } catch (_) {}
  }

  /// Freshness memory: the ids a Top Picks refresh surfaced.
  Future<void> noteShown(Iterable<String> ids) async {
    try {
      profile = profile.noteShown(ids,
          nowMs: DateTime.now().millisecondsSinceEpoch);
      await _save();
    } catch (_) {}
  }

  /// Adopt an external profile (e.g. freshly built from library signals
  /// or loaded via repository.loadTaste): keeps the newer one, merging
  /// skip memory so aversions are never lost.
  Future<void> merge(TasteProfile other) async {
    try {
      if (other.isEmpty) return;
      if (other.updatedAt < profile.updatedAt) return;
      final skips = <String, int>{
        ...other.skipCounts,
        ...profile.skipCounts,
      };
      profile = TasteProfile(
        artistScores: other.artistScores,
        moodScores: other.moodScores,
        playCounts: other.playCounts,
        skipCounts: skips,
        shownCounts: other.shownCounts,
        updatedAt: other.updatedAt,
      );
      await _save();
    } catch (_) {}
  }
}

/// Rotation salt for a Top Picks / Up Next refresh: mixes [refreshCount]
/// with a 6h time bucket (Knuth hash) so the same count re-seeds across
/// the day and adjacent refreshes never tiebreak identically. Pure,
/// never throws — feed into `rotationSalt:` params.
int rotationSaltFor(int refreshCount, [int? nowMs]) {
  try {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final bucket = now ~/ (6 * 60 * 60 * 1000);
    return ((refreshCount + 1) * 2654435761 + bucket * 40503) & 0x7fffffff;
  } catch (_) {
    return refreshCount;
  }
}

/// Next chained-radio batch (R3): taste-ranked candidates from the
/// session tail, deduped against the whole session, capped so the session
/// never exceeds [radioSessionCap]. Pure + sync — the caller fetches
/// candidates (bounded, e.g. repository.relatedTracks) then ranks off the
/// hot path with rankUpNextAsync for large pools. [sessionContext] (live
/// tail) steers the moment; [skipArtists] buries skipped singers;
/// [rotationSalt] re-rolls ties; [moodArc] resequences for variety.
List<YtTrack> nextRadioBatch(
  List<YtTrack> session,
  List<YtTrack> candidates, {
  TasteProfile? taste,
  Set<String> skipIds = const {},
  Set<String> skipArtists = const {},
  List<YtTrack> sessionContext = const [],
  bool moodArc = true,
  int? rotationSalt,
  int max = 20,
  int maxPerArtist = tasteUpNextPerArtist,
}) {
  try {
    if (session.isEmpty || candidates.isEmpty) return [];
    if (session.length >= radioSessionCap) return [];
    final tail = session.last;
    final exclude = <String>{for (final t in session) t.id};
    final room = radioSessionCap - session.length;
    final take = max < room ? max : room;
    return rankUpNext(
      tail,
      candidates,
      taste: taste,
      excludeIds: exclude,
      recentIds: exclude,
      skipIds: skipIds,
      skipArtists: skipArtists,
      sessionContext: sessionContext.isEmpty ? session : sessionContext,
      moodArc: moodArc,
      rotationSalt: rotationSalt,
      max: take,
      maxPerArtist: maxPerArtist,
    );
  } catch (_) {
    return [];
  }
}

/// Endless-queue batch (pure + sync): mood-ranked candidates for the
/// CURRENT sounding track, deduped against the whole played session +
/// queue ([excludeIds]) with skips hard-dropped, capped so the session
/// never exceeds [radioSessionCap]. The caller fetches candidates
/// (bounded, e.g. repository.endlessRefillFor) and appends via
/// engine.appendAuto when engine.needsRefill() fires (≤2 remaining, for
/// ANY played song — single-song queues refill too). Same steering knobs
/// as [nextRadioBatch].
List<YtTrack> nextEndlessBatch(
  YtTrack current,
  List<YtTrack> session,
  List<YtTrack> candidates, {
  TasteProfile? taste,
  Set<String> skipIds = const {},
  Set<String> skipArtists = const {},
  List<YtTrack> sessionContext = const [],
  bool moodArc = true,
  int? rotationSalt,
  int max = 20,
  int maxPerArtist = tasteUpNextPerArtist,
}) {
  try {
    if (candidates.isEmpty) return [];
    if (session.length >= radioSessionCap) return [];
    final exclude = <String>{for (final t in session) t.id};
    final room = radioSessionCap - session.length;
    final take = max < room ? max : room;
    if (take <= 0) return [];
    return rankUpNext(
      current,
      candidates,
      taste: taste,
      excludeIds: exclude,
      recentIds: exclude,
      skipIds: skipIds,
      skipArtists: skipArtists,
      sessionContext: sessionContext.isEmpty ? session : sessionContext,
      moodArc: moodArc,
      rotationSalt: rotationSalt,
      max: take,
      maxPerArtist: maxPerArtist,
    );
  } catch (_) {
    return [];
  }
}

/// Offline-capable library fill (pure + sync, zero network): scores
/// [library] tracks by mood/type fit to [seed] (same mood, language,
/// energy, era, keywords via moodFitScore), re-ranked by [taste] affinity
/// + session moment when given, dedupes [excludeIds], hard-drops
/// [skipIds], caps per-artist, resequences a mood arc. Used as the last
/// endless tier when the related graph + mood queries return nothing
/// (offline, single-song start). [rotationSalt] re-rolls score ties so
/// offline refills vary instead of repeating one order.
List<YtTrack> libraryMoodFill(
  YtTrack seed,
  List<YtTrack> library, {
  Set<String> excludeIds = const {},
  Set<String> skipIds = const {},
  Set<String> skipArtists = const {},
  Set<String> likedIds = const {},
  TasteProfile? taste,
  List<YtTrack> sessionContext = const [],
  bool moodArc = true,
  int? rotationSalt,
  int max = 20,
  int maxPerArtist = tasteUpNextPerArtist,
}) {
  try {
    if (library.isEmpty || max <= 0) return [];
    final sessAff = sessionContext.isEmpty
        ? const <String, double>{}
        : sessionAffinityFor(sessionContext);
    final sessMoods = sessionContext.isEmpty
        ? const <String, double>{}
        : sessionMoodsFor(sessionContext);
    final seen = <String>{seed.id, ...excludeIds};
    final saltRand = rotationSalt != null ? Random(rotationSalt) : Random();
    final salts = <String, int>{};
    int saltFor(String id) {
      try {
        return salts.putIfAbsent(id, () => saltRand.nextInt(1 << 30));
      } catch (_) {
        return 0;
      }
    }

    final scored = <(double, int, YtTrack)>[];
    for (final c in library) {
      try {
        if (c.id.isEmpty || c.id == seed.id || !seen.add(c.id)) continue;
        if (skipIds.contains(c.id)) continue;
        if (isSameName(c, seed)) continue;
        var s = moodFitScore(seed, c);
        if (taste != null) {
          s += taste.artistAffinity(c.artist) * tasteArtistWeight;
          final m = detectMood('${c.title} ${c.artist}');
          if (m != null) s += taste.moodAffinity(m) * tasteMoodWeight;
        }
        if (sessAff.isNotEmpty) {
          var best = 0.0;
          for (final k in tasteArtistKeys(c.artist)) {
            final v = sessAff[k] ?? 0.0;
            if (v > best) best = v;
          }
          s += best * tasteSessionArtistWeight;
        }
        if (sessMoods.isNotEmpty) {
          final m = detectMood('${c.title} ${c.artist}');
          if (m != null) s += (sessMoods[m] ?? 0.0) * tasteSessionMoodWeight;
        }
        if (likedIds.contains(c.id)) s += tasteLikedTrackBoost;
        try {
          final skips = taste?.skipCounts[c.id] ?? 0;
          if (skips > 0) {
            s -= (tasteSkipFirst + (skips - 1) * tasteSkipPerExtra)
                .clamp(0.0, tasteSkipMax);
          }
        } catch (_) {}
        if (skipArtists.isNotEmpty) {
          var hit = false;
          try {
            for (final k in tasteArtistKeys(c.artist)) {
              if (skipArtists.contains(k)) {
                hit = true;
                break;
              }
            }
          } catch (_) {}
          if (hit) s -= tasteSkipArtistPenalty;
        }
        scored.add((s, saltFor(c.id), c));
      } catch (_) {}
    }
    scored.sort((a, b) {
      final d = b.$1.compareTo(a.$1);
      return d != 0 ? d : a.$2.compareTo(b.$2);
    });
    final picked = <(double, YtTrack)>[];
    final perArtist = <String, int>{};
    for (final e in scored) {
      if (picked.length >= max) break;
      try {
        final key = e.$3.artist.toLowerCase();
        final n = (perArtist[key] ?? 0) + 1;
        if (n > maxPerArtist) continue;
        perArtist[key] = n;
        picked.add((e.$1, e.$3));
      } catch (_) {}
    }
    if (moodArc) return arcOrder(picked);
    return picked.map((e) => e.$2).toList();
  } catch (_) {
    return [];
  }
}
