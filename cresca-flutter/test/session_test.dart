import 'package:test/test.dart';

import 'package:cresca_app/auth/session.dart';

void main() {
  group('login user agent', () {
    test('strips the embedded-browser token', () {
      expect(
          loginUserAgent(
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.0.0 Mobile Safari/537.36; wv'),
          isNot(contains('; wv')));
      expect(loginUserAgent(''), contains('Chrome/126.0.0.0'));
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
}
