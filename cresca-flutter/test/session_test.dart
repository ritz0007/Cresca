import 'package:test/test.dart';

import 'package:cresca_app/auth/session.dart';
import 'package:cresca_app/auth/spotify.dart';
import 'package:cresca_app/data/innertube.dart';

void main() {
  group('login user agent', () {
    test('strips the embedded-browser token', () {
      expect(
          loginUserAgent(
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.0.0 Mobile Safari/537.36; wv'),
          isNot(contains('; wv')));
      expect(loginUserAgent(''), contains('Chrome/126.0.0.0'));
    });

    test('empty input falls back (never blank)', () {
      expect(loginUserAgent(''), fallbackLoginUserAgent);
      expect(loginUserAgent('   '), fallbackLoginUserAgent);
      expect(loginUserAgent(''), isNot(contains('; wv')));
    });
  });

  group('login check', () {
    test('SAPISID/SID means logged in', () {
      expect(cookiesLoggedIn('SID=x; SAPISID=abc; X=y'), isTrue);
      expect(cookiesLoggedIn('SID=x'), isTrue);
      expect(cookiesLoggedIn('VISITOR_INFO1_LIVE=abc; YSC=def'),
          isFalse);
      expect(cookiesLoggedIn(''), isFalse);
    });

    test('SID substrings do not match', () {
      expect(cookiesLoggedIn('SSID=x'), isFalse);
      expect(cookiesLoggedIn('HSID=a; SSID=b; RESIDUAL=c'), isFalse);
      expect(cookiesLoggedIn('SID2=x; XSAPISID=y'), isFalse);
      expect(cookiesLoggedIn(' SID=x '), isTrue);
    });
  });

  group('cookie jar', () {
    test('jar login check is exact-name', () {
      expect(jarLoggedIn({'SID': 'x'}), isTrue);
      expect(jarLoggedIn({'SAPISID': 'abc'}), isTrue);
      expect(jarLoggedIn({'SSID': 'x'}), isFalse);
      expect(jarLoggedIn({}), isFalse);
    });

    test('jar builds a cookie header', () {
      final h = cookieHeaderFromJar({'SID': 'x', 'YSC': 'y'});
      expect(h, contains('SID=x'));
      expect(h, contains('YSC=y'));
      expect(cookieHeaderFromJar({}), isEmpty);
    });
  });

  group('cookie capture', () {
    test('keeps VISITOR_INFO1_LIVE as visitor data', () {
      final cap = captureCookies(
          'SID=x; VISITOR_INFO1_LIVE=Cgtasdf; YSC=z', 'old');
      expect(cap.cookies, contains('SID=x'));
      expect(cap.visitorData, 'Cgtasdf');
    });

    test('preserves previous visitor without the cookie', () {
      final cap = captureCookies('SID=x; YSC=z', 'old');
      expect(cap.visitorData, 'old');
    });
  });

  group('logout wipe', () {
    test('no poToken header without poToken', () {
      final h = tubeHeaders(TubeClient.webRemix, poToken: '');
      expect(h.containsKey('X-Goog-EOM-Visitor-Id'), isFalse);
      final authed = tubeHeaders(TubeClient.webRemix, poToken: 'tok');
      expect(authed['X-Goog-EOM-Visitor-Id'], 'tok');
    });
  });

  group('spotify state', () {
    test('requires equal non-empty states', () {
      expect(spotifyStateOk('abc', 'abc'), isTrue);
      expect(spotifyStateOk('abc', 'xyz'), isFalse);
      expect(spotifyStateOk('', ''), isFalse);
      expect(spotifyStateOk('abc', ''), isFalse);
      expect(spotifyStateOk('', 'abc'), isFalse);
    });
  });
}
