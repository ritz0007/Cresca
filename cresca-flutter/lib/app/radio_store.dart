// Saved radios (R2): one card per seed track, 30-card / 200-track caps,
// liked-first recency sort, atomic JSON. Native ref: RadioStore.kt
// (radios.json schema 1:1). The 6 static station gradients live here too.

import 'dart:convert';

import '../core/track.dart';
import 'library.dart' show trackRow, trackFromRow;

const int radioCap = 30;
const int radioTrackCap = 200;

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
