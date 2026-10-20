// Video details / credits store (P8): "About this song" rows.
// Native ref: YoutubeRepository.videoDetails (NewPipe StreamExtractor:
// views/likes/upload date/description/duration/dash) + MainActivity
// DetailsCard (Shazam-like: Plays/Likes/Released/Duration/Description).
// Session memo keyed by watch URL; extractor rides the same
// device-consistent headers as resolve (bot-gating parity, see
// resolver modernTubeHeaders). Failures → null; UI shows the honest
// not-available state (H8).

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/track.dart' show extractVideoId;
import 'resolve.dart' show modernTubeHeaders;
import 'streamkit/bundle.dart' as sk;

class VideoDetails {
  final int views;
  final int likes;
  final String uploadDate;
  final String description;
  final int durationSec;
  final String dashUrl;
  const VideoDetails({
    required this.views,
    required this.likes,
    required this.uploadDate,
    required this.description,
    required this.durationSec,
    required this.dashUrl,
  });
}

/// Clustered-views compact formatter (native fmtCompact 1:1).
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

/// Pure field-mapping half (unit-tested directly; Video ctor is
/// private in youtube_explode 2.x).
VideoDetails? detailsFromFields({
  required int views,
  required int? likes,
  required DateTime? uploadDate,
  required String? uploadDateRaw,
  required String description,
  required Duration? duration,
}) {
  try {
    var date = '';
    final raw = uploadDateRaw;
    if (raw != null && raw.isNotEmpty) date = raw;
    if (date.isEmpty && uploadDate != null) {
      date = uploadDate.toLocal().toString().split(' ').first;
    }
    final d = VideoDetails(
      views: views,
      likes: likes ?? -1,
      uploadDate: date,
      description: description,
      durationSec: duration?.inSeconds ?? -1,
      dashUrl: '',
    );
    return views >= 0 || description.isNotEmpty ? d : null;
  } catch (_) {
    return null;
  }
}

/// Extractor Video → details (pure mapping used by the store).
VideoDetails? detailsFromVideo(Video v) => detailsFromFields(
      views: v.engagement.viewCount,
      likes: v.engagement.likeCount,
      uploadDate: v.uploadDate,
      uploadDateRaw: v.uploadDateRaw,
      description: v.description,
      duration: v.duration,
    );

/// Bundle TrackMeta → VideoDetails (likes stay -1: player responses
/// never carry them; the extractor backfills on About-panel open).
/// Pure; unit-tested.
VideoDetails detailsFromMeta(sk.TrackMeta m) => VideoDetails(
      views: m.viewCount,
      likes: m.likeCount,
      uploadDate: m.uploadDate,
      description: m.description,
      durationSec: m.durationSec,
      dashUrl: '',
    );

/// Per-session memo + extractor handle. All failures → null.
class DetailsStore {
  YoutubeExplode? _yt;
  final Map<String, VideoDetails> memo = {};
  VideoDetails? current;

  /// Memo budget: 200 videoIds, LRU (oldest evicted first).
  static const int memoCap = 200;

  VideoDetails? _memoGet(String key) {
    try {
      final hit = memo.remove(key);
      if (hit == null) return null;
      memo[key] = hit; // refresh recency
      return hit;
    } catch (_) {
      return null;
    }
  }

  void _memoPut(String key, VideoDetails d) {
    try {
      if (key.isEmpty) return;
      memo.remove(key);
      memo[key] = d;
      while (memo.length > memoCap) {
        memo.remove(memo.keys.first);
      }
    } catch (_) {}
  }

  YoutubeExplode _explode() {
    final e = _yt;
    if (e != null) return e;
    final created = YoutubeExplode(_ModernDetailsClient());
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

  Future<VideoDetails?> load(String watchUrl) async {
    try {
      // Canonical key: videoId only (deep-link / restored-queue URL forms
      // share one row, so repeat opens skip the extractor).
      final key = extractVideoId(watchUrl) ?? watchUrl;
      final hit = _memoGet(key);
      if (hit != null) {
        current = hit;
        return hit;
      }
      final v = await _explode()
          .videos
          .get(watchUrl)
          .timeout(const Duration(seconds: 30));
      final d = detailsFromVideo(v);
      if (d != null) _memoPut(key, d);
      current = d;
      return d;
    } catch (_) {
      return null;
    }
  }

  /// Zero-request path: memoize bundle metadata at resolve time (wired
  /// to PlayerController.onBundleResolved). No-op for detail-less
  /// metas. Never throws.
  void rememberMeta(String videoId, sk.TrackMeta meta) {
    try {
      if (videoId.isEmpty || !meta.hasDetails) return;
      _memoPut(videoId, detailsFromMeta(meta));
    } catch (_) {}
  }
}

/// Browser-consistent client (same headers the resolver uses).
class _ModernDetailsClient extends YoutubeHttpClient {
  @override
  Map<String, String> get headers => modernTubeHeaders();
}
