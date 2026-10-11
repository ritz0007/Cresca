// Podcast MVP models: show + episode shapes with JSON codecs,
// resume math, duration formatting, and relevance scoring.
//
// Pure-Dart (no Flutter) so `flutter test` covers it with zero I/O.
// Additive to YtTrack: episodes convert via toYtTrack() for queue /
// playback / downloads integration without touching song gates.

import '../core/track.dart';

/// One subscribed podcast show.
class PodcastShow {
  final String id;
  final String title;
  final String author;
  final String thumbUrl;
  final String description;
  final int subscribedAtMs;

  const PodcastShow({
    required this.id,
    required this.title,
    this.author = '',
    this.thumbUrl = '',
    this.description = '',
    this.subscribedAtMs = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'thumbUrl': thumbUrl,
        'description': _capDescription(description),
        'subscribedAtMs': subscribedAtMs,
      };

  factory PodcastShow.fromJson(Map<String, dynamic> j) {
    try {
      return PodcastShow(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        author: (j['author'] ?? '').toString(),
        thumbUrl: (j['thumbUrl'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        subscribedAtMs: _asInt(j['subscribedAtMs']),
      );
    } catch (_) {
      return const PodcastShow(id: '', title: '');
    }
  }
}

/// One podcast episode. `durationSec` is -1 when unknown (row carried no
/// length segment); `resumeMs` is the last persisted bookmark (0 = fresh).
class PodcastEpisode {
  final String id;
  final String showTitle;
  final String title;
  final String description;
  final int durationSec;
  final String publishDate;
  final String thumbUrl;
  final String watchUrl;
  final int resumeMs;

  const PodcastEpisode({
    required this.id,
    required this.title,
    this.showTitle = '',
    this.description = '',
    this.durationSec = -1,
    this.publishDate = '',
    this.thumbUrl = '',
    this.watchUrl = '',
    this.resumeMs = 0,
  });

  PodcastEpisode copyWith({
    String? showTitle,
    String? title,
    String? description,
    int? durationSec,
    String? publishDate,
    String? thumbUrl,
    String? watchUrl,
    int? resumeMs,
  }) {
    return PodcastEpisode(
      id: id,
      showTitle: showTitle ?? this.showTitle,
      title: title ?? this.title,
      description: description ?? this.description,
      durationSec: durationSec ?? this.durationSec,
      publishDate: publishDate ?? this.publishDate,
      thumbUrl: thumbUrl ?? this.thumbUrl,
      watchUrl: watchUrl ?? this.watchUrl,
      resumeMs: resumeMs ?? this.resumeMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'showTitle': showTitle,
        'title': title,
        'description': _capDescription(description),
        'durationSec': durationSec,
        'publishDate': publishDate,
        'thumbUrl': thumbUrl,
        'watchUrl': watchUrl,
        'resumeMs': resumeMs,
      };

  factory PodcastEpisode.fromJson(Map<String, dynamic> j) {
    try {
      return PodcastEpisode(
        id: (j['id'] ?? '').toString(),
        showTitle: (j['showTitle'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        durationSec: _asInt(j['durationSec'], fallback: -1),
        publishDate: (j['publishDate'] ?? '').toString(),
        thumbUrl: (j['thumbUrl'] ?? '').toString(),
        watchUrl: (j['watchUrl'] ?? '').toString(),
        resumeMs: _asInt(j['resumeMs']),
      );
    } catch (_) {
      return const PodcastEpisode(id: '', title: '');
    }
  }

  /// Queue/playback/downloads bridge: episodes ride YtTrack unchanged
  /// (artist carries the show name; duration/resume stay on this side).
  YtTrack toYtTrack() {
    try {
      return YtTrack(
        id: id,
        title: title.isEmpty ? 'Untitled episode' : title,
        artist: showTitle.isEmpty ? 'Podcast' : showTitle,
        thumbUrl: thumbUrl,
        watchUrl: watchUrl.isEmpty
            ? 'https://www.youtube.com/watch?v=$id'
            : watchUrl,
      );
    } catch (_) {
      return YtTrack(
        id: id,
        title: title,
        artist: showTitle,
        thumbUrl: '',
        watchUrl: '',
      );
    }
  }

  /// 0..1 playback fraction from the bookmark. -1 when unknown.
  double resumeFraction() => resumeFractionOf(resumeMs, durationSec);

  /// True when a "Resume from …" affordance is warranted (past the
  /// fresh-start window, well before the credits).
  bool shouldOfferResume() =>
      shouldOfferResumeFor(resumeMs, durationSec);
}

int _asInt(dynamic v, {int fallback = 0}) {
  try {
    if (v is int) return v;
    if (v is double) return v.round();
    return int.tryParse(v.toString()) ?? fallback;
  } catch (_) {
    return fallback;
  }
}

/// Cap inline show notes so caches never balloon (2 KB, research §3).
String _capDescription(String s) {
  try {
    const cap = 2048;
    return s.length <= cap ? s : s.substring(0, cap);
  } catch (_) {
    return '';
  }
}

/// 0..1 fraction for [positionMs] over [durationSec]. -1 when the
/// duration is unknown or non-positive. Clamped to 0..1. Never throws.
double resumeFractionOf(int positionMs, int durationSec) {
  try {
    if (durationSec <= 0) return -1;
    if (positionMs <= 0) return 0;
    final total = durationSec * 1000;
    if (total <= 0) return -1;
    return (positionMs / total).clamp(0.0, 1.0);
  } catch (_) {
    return -1;
  }
}

/// Resume-prompt policy: needs ≥30 s in and ≤95% done, with a known
/// duration. Never throws.
bool shouldOfferResumeFor(int positionMs, int durationSec) {
  try {
    if (durationSec <= 0 || positionMs < 30000) return false;
    final total = durationSec * 1000;
    if (total <= 0) return false;
    return positionMs < (total * 0.95).round();
  } catch (_) {
    return false;
  }
}

/// Milliseconds remaining from a bookmark. -1 when unknown. Never throws.
int remainingMsOf(int positionMs, int durationSec) {
  try {
    if (durationSec <= 0) return -1;
    final total = durationSec * 1000;
    final left = total - positionMs;
    return left > 0 ? left : 0;
  } catch (_) {
    return -1;
  }
}

/// h:mm:ss when ≥1 h, else m:ss (songs keep `fmtMs`; episodes need the
/// hour slot — 3661 s renders 1:01:01, not 61:01). Never throws.
String fmtEpisodeMs(int ms) {
  try {
    if (ms <= 0) return '0:00';
    final s = ms ~/ 1000;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = (s % 60).toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$sec';
    return '$m:$sec';
  } catch (_) {
    return '0:00';
  }
}

/// Episode relevance for a free-text query: show-title hits weigh most,
/// then title tokens, then prefix bonus. Pure + deterministic (testable).
/// Never throws.
double podcastScore(String query, PodcastEpisode ep) {
  try {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return 0;
    final tokens =
        q.split(RegExp(r'\s+')).where((e) => e.length > 1).toList();
    if (tokens.isEmpty) return 0;
    final show = ep.showTitle.toLowerCase();
    final title = ep.title.toLowerCase();
    var score = 0.0;
    for (final t in tokens) {
      if (show.contains(t)) score += 2.0;
      if (title.contains(t)) score += 1.0;
    }
    if (title.startsWith(q) || show.startsWith(q)) score += 1.5;
    if (title == q || show == q) score += 2.0;
    // Freshness-agnostic: no date parsing here (labels are free-form).
    return score;
  } catch (_) {
    return 0;
  }
}

/// Download state snapshot for one episode, fed by the coordinator from
/// the existing DownloadStore (read-only usage by id). Pure data.
class PodcastDownloadState {
  final bool downloaded;
  final bool downloading;
  final int progress; // 0..100, -1 unknown
  const PodcastDownloadState({
    this.downloaded = false,
    this.downloading = false,
    this.progress = -1,
  });
}
