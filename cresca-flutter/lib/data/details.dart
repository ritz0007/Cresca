// Video details / credits store (P8): "About this song" rows.
// Native ref: YoutubeRepository.videoDetails (NewPipe StreamExtractor:
// views/likes/upload date/description/duration/dash) + MainActivity
// DetailsCard (Shazam-like: Plays/Likes/Released/Duration/Description).
// Session memo keyed by watch URL; extractor rides the same
// device-consistent headers as resolve (bot-gating parity, see
// resolver modernTubeHeaders). Failures → null; UI shows the honest
// not-available state (H8).

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'resolve.dart' show modernTubeHeaders;

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

/// Per-session memo + extractor handle. All failures → null.
class DetailsStore {
  YoutubeExplode? _yt;
  final Map<String, VideoDetails> memo = {};
  VideoDetails? current;

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
      final hit = memo[watchUrl];
      if (hit != null) {
        current = hit;
        return hit;
      }
      final v = await _explode()
          .videos
          .get(watchUrl)
          .timeout(const Duration(seconds: 30));
      final d = detailsFromVideo(v);
      if (d != null) memo[watchUrl] = d;
      current = d;
      return d;
    } catch (_) {
      return null;
    }
  }
}

/// Browser-consistent client (same headers the resolver uses).
class _ModernDetailsClient extends YoutubeHttpClient {
  @override
  Map<String, String> get headers => modernTubeHeaders();
}
