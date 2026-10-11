// Podcast network service: InnerTube search/browse for shows and
// episodes, plus episode stream resolution via the EXISTING resolver
// path (injected — this file never touches repository.dart or
// resolve.dart directly).
//
// Every hop has a timeout and never throws: [] / null on any failure.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/innertube.dart';
import 'models.dart';

/// Resolves a playable audio URL for an episode watch URL. The
/// coordinator passes `resolver.audioUrl` (StreamResolver, the same leg
/// songs use). Never throws from this side; null = unresolvable.
typedef EpisodeUrlResolver = Future<String?> Function(String watchUrl);

/// POST timeout per InnerTube hop.
const Duration podcastHopTimeout = Duration(seconds: 15);

class PodcastService {
  final http.Client httpClient;
  final String visitorData;

  PodcastService({http.Client? httpClient, this.visitorData = ''})
      : httpClient = httpClient ?? http.Client();

  Future<Map<String, dynamic>?> _post(
      String endpoint, Map<String, dynamic> body,
      {Duration timeout = podcastHopTimeout}) async {
    try {
      final res = await httpClient
          .post(
            Uri.parse(tubeUrl(TubeClient.webRemix, endpoint)),
            headers: tubeHeaders(TubeClient.webRemix,
                visitorData: visitorData),
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      return decoded is Map
          ? decoded.cast<String, dynamic>()
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Search episodes for [query] (unfiltered search body + episode-side
  /// parsing — the shared songs-only gates are never touched). Ranked by
  /// [podcastScore], capped at [max]. Never throws.
  Future<List<PodcastEpisode>> searchEpisodes(String query,
      {int max = 20}) async {
    try {
      if (query.trim().isEmpty || max <= 0) return [];
      final json =
          await _post('search', podcastSearchBody(query, visitorData));
      if (json == null) return [];
      final eps = parsePodcastSearch(json, max * 2);
      eps.sort((a, b) => podcastScore(query, b)
          .compareTo(podcastScore(query, a)));
      return eps.take(max).toList();
    } catch (_) {
      return [];
    }
  }

  /// Episode rows for a show [browseId] (MPREb_*-style channel/show page
  /// id supplied by the caller). Never throws.
  Future<List<PodcastEpisode>> showEpisodes(String browseId,
      {int max = 50}) async {
    try {
      if (browseId.trim().isEmpty || max <= 0) return [];
      final json = await _post(
          'browse', podcastShowBody(browseId, visitorData));
      if (json == null) return [];
      final out = <PodcastEpisode>[];
      final shelves = parsePodcastShelves(json, 8, max);
      final seen = <String>{};
      for (final eps in shelves.values) {
        for (final ep in eps) {
          if (seen.add(ep.id)) out.add(ep);
          if (out.length >= max) return out;
        }
      }
      if (out.isEmpty) {
        // Flat fallback: show pages without shelf wrappers.
        for (final ep in parsePodcastSearch(json, max)) {
          if (seen.add(ep.id)) out.add(ep);
          if (out.length >= max) break;
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Resolve a stream URL for [episode] via the existing resolver path.
  /// Null on any failure (caller keeps the episode row + error state).
  /// Never throws.
  Future<String?> resolveEpisodeUrl(PodcastEpisode episode,
      EpisodeUrlResolver resolve) async {
    try {
      final watch = episode.watchUrl.isEmpty
          ? 'https://www.youtube.com/watch?v=${episode.id}'
          : episode.watchUrl;
      try {
        return await resolve(watch)
            .timeout(const Duration(seconds: 45));
      } catch (_) {
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    try {
      httpClient.close();
    } catch (_) {}
  }
}
