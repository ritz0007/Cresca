// Podcast MVP pure-logic tests: model codecs, resume math, duration
// formatting, relevance scoring, InnerTube episode parsing (song gates
// must NOT apply), subscription/progress codecs, speed + resume-tracker
// policy. Zero network, zero I/O.

import 'package:test/test.dart';

import 'package:cresca_app/data/innertube.dart';
import 'package:cresca_app/podcasts/models.dart';
import 'package:cresca_app/podcasts/playback_support.dart';
import 'package:cresca_app/podcasts/store.dart';

Map<String, dynamic> episodeRow({
  String videoId = 'dQw4w9WgXcQ',
  String title = 'Ep 42: The Long Conversation',
  String sub = 'My Show • Mar 4, 2026 • 45:12',
  bool live = false,
  bool reel = false,
}) {
  final m = <String, dynamic>{
    'flexColumns': [
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {
            'runs': [
              {'text': title}
            ]
          }
        }
      },
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {
            'runs': [
              {'text': sub}
            ]
          }
        }
      },
    ],
    'playlistItemData': {'videoId': videoId},
    'thumbnail': {
      'musicThumbnailRenderer': {
        'thumbnail': {
          'thumbnails': [
            {'url': 'https://i.ytimg.com/vi/x/hqdefault.jpg=w120-h120'}
          ]
        }
      }
    },
  };
  if (live) {
    m['badges'] = [
      {
        'metadataBadgeRenderer': {'label': 'LIVE'}
      }
    ];
  }
  if (reel) {
    m['navigationEndpoint'] = {
      'reelEndpoint': {'payload': 'x'}
    };
  }
  return m;
}

class FakeSpeedPlayer implements SpeedPlayer {
  double _speed = 1.0;
  @override
  double get speed => _speed;
  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
  }
}

void main() {
  group('episode model', () {
    test('json round-trip with defaults', () {
      const ep = PodcastEpisode(
        id: 'abc123abc12',
        title: 'Ep 1',
        showTitle: 'Show',
        durationSec: 2700,
        resumeMs: 60000,
      );
      final back = PodcastEpisode.fromJson(ep.toJson());
      expect(back.id, 'abc123abc12');
      expect(back.showTitle, 'Show');
      expect(back.durationSec, 2700);
      expect(back.resumeMs, 60000);
      // Missing keys decode to song-safe defaults.
      final bare = PodcastEpisode.fromJson({'id': 'x'});
      expect(bare.durationSec, -1);
      expect(bare.resumeMs, 0);
      expect(bare.showTitle, '');
    });

    test('description capped at 2KB', () {
      final long = 'x' * 5000;
      const ep = PodcastEpisode(id: 'a', title: 't');
      final withLong = ep.copyWith(description: long);
      final json = withLong.toJson();
      expect((json['description'] as String).length,
          lessThanOrEqualTo(2048));
    });

    test('toYtTrack bridges queue/downloads', () {
      const ep = PodcastEpisode(
        id: 'dQw4w9WgXcQ',
        title: 'Ep 7',
        showTitle: 'My Show',
        thumbUrl: 'http://t/x.jpg',
      );
      final t = ep.toYtTrack();
      expect(t.id, 'dQw4w9WgXcQ');
      expect(t.title, 'Ep 7');
      expect(t.artist, 'My Show');
      expect(t.watchUrl, contains('dQw4w9WgXcQ'));
    });
  });

  group('resume math', () {
    test('fraction clamps, -1 when unknown', () {
      expect(resumeFractionOf(900000, 3600), closeTo(0.25, 1e-9));
      expect(resumeFractionOf(0, 3600), 0);
      expect(resumeFractionOf(5000, -1), -1);
      expect(resumeFractionOf(5000, 0), -1);
      expect(resumeFractionOf(99999999, 60), 1.0);
    });

    test('offer policy: 30s in, 95% out', () {
      expect(shouldOfferResumeFor(29999, 3600), isFalse);
      expect(shouldOfferResumeFor(30000, 3600), isTrue);
      expect(
          shouldOfferResumeFor((3600 * 1000 * 0.96).round(), 3600),
          isFalse);
      expect(shouldOfferResumeFor(60000, -1), isFalse);
    });

    test('remaining counts down, -1 unknown', () {
      expect(remainingMsOf(60000, 3600), 3600 * 1000 - 60000);
      expect(remainingMsOf(0, -1), -1);
      expect(remainingMsOf(99999999, 60), 0);
    });

    test('fmtEpisodeMs uses h:mm:ss past one hour', () {
      expect(fmtEpisodeMs(0), '0:00');
      expect(fmtEpisodeMs(245000), '4:05');
      expect(fmtEpisodeMs(3661000), '1:01:01');
      expect(fmtEpisodeMs(7265000), '2:01:05');
    });
  });

  group('scoring', () {
    test('show hits outrank title-only, prefix bonus', () {
      const a = PodcastEpisode(id: 'a', title: 'Unrelated', showTitle: 'History Hour');
      const b = PodcastEpisode(id: 'b', title: 'History Hour special', showTitle: 'Other');
      expect(podcastScore('history hour', a),
          greaterThan(podcastScore('history hour', b)));
      expect(podcastScore('', a), 0);
      expect(podcastScore('history', b), greaterThan(0));
    });
  });

  group('innertube podcast parsers', () {
    test('episode-shaped rows kept (song gates do not apply)', () {
      final ep = parsePodcastEpisodeItem(episodeRow())!;
      expect(ep.id, 'dQw4w9WgXcQ');
      expect(ep.title, contains('Ep 42'));
      expect(ep.showTitle, 'My Show');
      // 45:12 exceeds the 10-min SONG cap — episodes keep it.
      expect(ep.durationSec, 45 * 60 + 12);
      expect(ep.publishDate, 'Mar 4, 2026');
    });

    test('podcast-badge subtitles resolve the show, not the badge', () {
      final ep = parsePodcastEpisodeItem(episodeRow(
          sub: 'Podcast • Deep Dive • 1:02:03'))!;
      expect(ep.showTitle, 'Deep Dive');
      expect(ep.durationSec, 3723);
    });

    test('drops reels, lives, sub-60s clips; keeps unknown duration', () {
      expect(parsePodcastEpisodeItem(episodeRow(reel: true)), isNull);
      expect(parsePodcastEpisodeItem(episodeRow(live: true)), isNull);
      expect(
          parsePodcastEpisodeItem(
              episodeRow(sub: 'Show • 0:45')),
          isNull);
      final unknown = parsePodcastEpisodeItem(
          episodeRow(sub: 'Show • Mar 2026'))!;
      expect(unknown.durationSec, -1);
      expect(
          parsePodcastEpisodeItem(
              episodeRow(title: '', sub: 'Show • 45:12')),
          isNull);
    });

    test('search parse dedupes + caps; shelves group by title', () {
      final root = {
        'contents': {
          'items': [
            {'musicResponsiveListItemRenderer': episodeRow()},
            {
              'musicResponsiveListItemRenderer':
                  episodeRow(videoId: 'AAAAAAAAAAA')
            },
            // Duplicate id dropped.
            {
              'musicResponsiveListItemRenderer': episodeRow(
                  videoId: 'dQw4w9WgXcQ', title: 'Dupe')
            },
          ]
        }
      };
      final eps = parsePodcastSearch(root, 10);
      expect(eps.length, 2);
      expect(parsePodcastSearch(root, 1).length, 1);

      final shelfRoot = {
        'contents': [
          {
            'musicCarouselShelfRenderer': {
              'header': {
                'musicCarouselShelfBasicHeaderRenderer': {
                  'title': {
                    'runs': [
                      {'text': 'New episodes'}
                    ]
                  }
                }
              },
              'contents': {
                'contents': [
                  {
                    'musicResponsiveListItemRenderer':
                        episodeRow()
                  },
                ]
              }
            }
          }
        ]
      };
      final shelves = parsePodcastShelves(shelfRoot, 4, 10);
      expect(shelves.keys, contains('New episodes'));
      expect(shelves['New episodes']!.length, 1);
    });

    test('publish labels + unfiltered search body', () {
      expect(podPublishLabel(['Show', '3 days ago', '45:12']),
          '3 days ago');
      expect(podPublishLabel(['Show', '45:12']), '');
      final body = podcastSearchBody('history', 'vd');
      expect(body['query'], 'history');
      expect(body.containsKey('params'), isFalse);
      expect(podcastShowBody('MPREb_x', 'vd')['browseId'],
          'MPREb_x');
    });
  });

  group('store codecs', () {
    test('subs round-trip + cap', () {
      final subs = {
        's1': const PodcastShow(id: 's1', title: 'One'),
        's2': const PodcastShow(id: 's2', title: 'Two'),
      };
      final back =
          podcastSubsFromJson(podcastSubsToJson(subs));
      expect(back.length, 2);
      expect(back['s1']!.title, 'One');
      expect(podcastSubsFromJson('garbage'), isEmpty);
      expect(podcastSubsFromJson(''), isEmpty);
    });

    test('progress drops fresh window + garbage', () {
      final back = episodeProgressFromJson(
          '{"e1": 5000, "e2": 60000, "e3": "junk"}');
      expect(back.containsKey('e1'), isFalse);
      expect(back['e2'], 60000);
      expect(back.containsKey('e3'), isFalse);
      expect(episodeProgressFromJson(''), isEmpty);
      final out = episodeProgressToJson(
          {'e1': 100, 'e2': 90000});
      expect(out.contains('e2'), isTrue);
      expect(out.contains('e1'), isFalse);
    });
  });

  group('playback support', () {
    test('speed clamp + step wrap', () {
      expect(clampPodcastSpeed(99), 2.0);
      expect(clampPodcastSpeed(0.1), 0.8);
      expect(clampPodcastSpeed(double.nan), 1.0);
      expect(nextPodcastSpeed(1.0), 1.2);
      expect(nextPodcastSpeed(2.0), 0.8);
    });

    test('applyPodcastSpeed drives the player, never throws', () async {
      final fake = FakeSpeedPlayer();
      expect(await applyPodcastSpeed(fake, 1.5), 1.5);
      expect(fake.speed, 1.5);
      expect(await applyPodcastSpeed(null, 9), 2.0);
    });

    test('resume tracker persist + finish-drop policy', () {
      final t = ResumeTracker();
      expect(t.notePosition('e1', 1000, 3600), isFalse);
      expect(t.resumeFor('e1'), 0);
      expect(t.notePosition('e1', 60000, 3600), isTrue);
      expect(t.resumeFor('e1'), 60000);
      // Within 15 s of the end → bookmark cleared (episode finished).
      expect(
          t.notePosition('e1', 3600 * 1000 - 5000, 3600), isTrue);
      expect(t.resumeFor('e1'), 0);
      expect(t.notePause('e2', 2000, 3600), isTrue);
      t.clear('e2');
      expect(t.resumeFor('e2'), 0);
    });

    test('sleep timer fires once, cancel silences', () async {
      var fires = 0;
      final timer = SleepTimer(onFire: () async {
        fires++;
      });
      expect(timer.isActive, isFalse);
      timer.start(const Duration(milliseconds: 40));
      expect(timer.isActive, isTrue);
      expect(timer.remainingMs(), greaterThan(0));
      await Future<void>.delayed(
          const Duration(milliseconds: 120));
      expect(fires, 1);
      expect(timer.isActive, isFalse);

      timer.start(const Duration(milliseconds: 40));
      timer.cancel();
      await Future<void>.delayed(
          const Duration(milliseconds: 120));
      expect(fires, 1);
      timer.dispose();
    });
  });

  group('show model', () {
    test('json round-trip + corrupt fallback', () {
      const s = PodcastShow(
          id: 'UCx', title: 'Deep Dive', author: 'Jane');
      final back = PodcastShow.fromJson(s.toJson());
      expect(back.id, 'UCx');
      expect(back.author, 'Jane');
      expect(PodcastShow.fromJson({}).id, '');
    });
  });
}
