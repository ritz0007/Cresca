// Vendored from cresca-streamkit (streaming-logic reference: see its README). Only relative imports rewritten to package:cresca_app/...; do not edit logic here, fix upstream.
// Video metadata store: zero-request reads from bundle memo, extractor
// backfill only when the user opens the About panel.
//
// Hot path: the player calls [rememberMeta] on every bundle resolve, so
// [load] mem-hits and never touches the network. Cold path (deep link,
// restored queue): the extractor video page fills views/likes/upload
// date/description/duration. All failures -> null; the UI shows the
// honest not-available state.

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'package:cresca_app/data/streamkit/bundle.dart';

class VideoDetails {
  final int views;
  final int likes;
  final String uploadDate;
  final String description;
  final int durationSec;
  const VideoDetails({
    required this.views,
    required this.likes,
    required this.uploadDate,
    required this.description,
    required this.durationSec,
  });
}

/// Clustered-views compact formatter: 1500 -> "1.5K", 2.3M, 1.2B.
String fmtCompact(int n) {
  try {
    if (n < 0) return '';
    if (n < 1000) return '$n';
    if (n < 1000000) return '${(n ~/ 100) / 10.0}K';
    if (n < 1000000000) return '${(n ~/ 100000) / 10.0}M';
    return '${(n ~/ 100000000) / 10.0}B';
  } catch (_) {
    return '';
  }
}

/// m:ss helper for durations.
String fmtDuration(int seconds) {
  try {
    if (seconds <= 0) return '0:00';
    final m = seconds ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  } catch (_) {
    return '0:00';
  }
}

/// TrackMeta -> VideoDetails (likes stay -1: player responses never
/// carry them; the extractor backfills on About-panel open).
VideoDetails detailsFromMeta(TrackMeta m) => VideoDetails(
      views: m.viewCount,
      likes: m.likeCount,
      uploadDate: m.uploadDate,
      description: m.description,
      durationSec: m.durationSec,
    );

class _DetailsClient extends YoutubeHttpClient {
  @override
  Map<String, String> get headers => scrapeHeaders();
}

/// Per-session memo + extractor handle. All failures -> null.
class DetailsStore {
  YoutubeExplode? _yt;
  final Map<String, VideoDetails> memo = {};
  VideoDetails? current;

  /// Extractor video-page fetch, injectable for tests.
  final Future<VideoDetails?> Function(String videoId)? videoFetcher;

  DetailsStore({this.videoFetcher});

  YoutubeExplode _explode() {
    final e = _yt;
    if (e != null) return e;
    final created = YoutubeExplode(_DetailsClient());
    _yt = created;
    return created;
  }

  void dispose() {
    try {
      _yt?.close();
    } catch (_) {}
    _yt = null;
    memo.clear();
    current = null;
  }

  /// Zero-request path: memoize bundle metadata at resolve time.
  void rememberMeta(String videoId, TrackMeta meta) {
    try {
      if (videoId.isEmpty || !meta.hasDetails) return;
      memo[videoId] = detailsFromMeta(meta);
    } catch (_) {}
  }

  /// Metadata for a track: memo first (no network), else extractor
  /// backfill (views/likes/date/description/duration). Never throws.
  Future<VideoDetails?> load(String videoId) async {
    try {
      if (videoId.length != 11) return null;
      final hit = memo[videoId];
      if (hit != null) {
        current = hit;
        return hit;
      }
      VideoDetails? d;
      if (videoFetcher != null) {
        d = await videoFetcher!(videoId);
      } else {
        final v = await _explode()
            .videos
            .get(videoId)
            .timeout(const Duration(seconds: 30));
        d = _fromVideo(v);
      }
      if (d != null) memo[videoId] = d;
      current = d;
      return d;
    } catch (_) {
      return null;
    }
  }

  VideoDetails? _fromVideo(Video v) {
    try {
      var date = '';
      try {
        final raw = v.uploadDateRaw;
        if (raw != null && raw.isNotEmpty) date = raw;
        if (date.isEmpty && v.uploadDate != null) {
          date = v.uploadDate!.toLocal().toString().split(' ').first;
        }
      } catch (_) {}
      final d = VideoDetails(
        views: v.engagement.viewCount,
        likes: v.engagement.likeCount ?? -1,
        uploadDate: date,
        description: v.description,
        durationSec: v.duration?.inSeconds ?? -1,
      );
      return (d.views >= 0 || d.description.isNotEmpty) ? d : null;
    } catch (_) {
      return null;
    }
  }
}
