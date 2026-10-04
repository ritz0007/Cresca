// Encrypted on-device YouTube login session (G1).
// Native ref: YtSessionManager.kt (encrypted prefs, cookies/visitor/
// po_token keys, SAPISID/SID login check, VISITOR_INFO1_LIVE visitor,
// logout wipe) + LoginWebView.kt (UA/header tricks as pure fns).
// Storage backend is flutter_secure_storage; file IO stays in AppState.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const String musicUrl = 'https://music.youtube.com';

/// Stock WebView UA minus the embedded-browser token. Device-consistent
/// UA (version + hints match a real browser); fallback when the
/// platform default is unavailable.
String loginUserAgent(String defaultUa) {
  try {
    var ua = defaultUa.trim();
    if (ua.isEmpty) {
      return 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
    }
    ua = ua.replaceAll('; wv', '');
    return ua;
  } catch (_) {
    return defaultUa;
  }
}

/// True when a cookie header carries a login session.
bool cookiesLoggedIn(String cookies) {
  try {
    return cookies.contains('SAPISID') || cookies.contains('SID');
  } catch (_) {
    return false;
  }
}

/// Result of capturing the WebView cookie jar after Done.
class CapturedSession {
  final String cookies;
  final String visitorData;
  const CapturedSession(this.cookies, this.visitorData);
}

/// Parses a `document.cookie` header: raw cookies + VISITOR_INFO1_LIVE
/// kept as visitor data when present (native capture 1:1).
CapturedSession captureCookies(String raw, String previousVisitor) {
  try {
    var visitor = previousVisitor;
    for (final part in raw.split(';')) {
      final p = part.trim();
      final eq = p.indexOf('=');
      if (eq <= 0) continue;
      if (p.substring(0, eq).trim() == 'VISITOR_INFO1_LIVE') {
        final value = p.substring(eq + 1).trim();
        if (value.isNotEmpty) visitor = value;
      }
    }
    return CapturedSession(raw, visitor);
  } catch (_) {
    return CapturedSession(raw, previousVisitor);
  }
}

class YtSession {
  final FlutterSecureStorage _store;
  String cookies = '';
  String visitorData = '';
  String poToken = '';

  YtSession({FlutterSecureStorage? store})
      : _store = store ?? const FlutterSecureStorage();

  static const _kCookies = 'yt_cookies';
  static const _kVisitor = 'yt_visitor';
  static const _kPoToken = 'yt_po_token';

  Future<void> load() async {
    try {
      cookies = await _store.read(key: _kCookies) ?? '';
      visitorData = await _store.read(key: _kVisitor) ?? '';
      poToken = await _store.read(key: _kPoToken) ?? '';
    } catch (_) {}
  }

  bool get isLoggedIn => cookiesLoggedIn(cookies);

  Future<void> saveSession(String rawCookies, String visitor) async {
    try {
      cookies = rawCookies;
      visitorData = visitor;
      await _store.write(key: _kCookies, value: rawCookies);
      await _store.write(key: _kVisitor, value: visitor);
    } catch (_) {}
  }

  Future<void> savePoToken(String token) async {
    try {
      poToken = token;
      await _store.write(key: _kPoToken, value: token);
    } catch (_) {}
  }

  /// Logout wipes the encrypted session (WebView cookies cleared by
  /// the sheet via WebViewCookieManager).
  Future<void> logout() async {
    try {
      cookies = '';
      visitorData = '';
      await _store.delete(key: _kCookies);
      await _store.delete(key: _kVisitor);
    } catch (_) {}
  }
}
