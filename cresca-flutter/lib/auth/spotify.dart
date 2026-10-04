// Spotify PKCE connect (G2 slice 1: auth only; import/sync follow).
// Native refs: SpotifyAuth.kt (PKCE, no secret) — code_verifier/challenge,
// authorize in browser, cresca://spotify-callback capture, token swap,
// refresh on 401, disconnect wipe. Client ID is user-supplied (setup
// row in Profile) and persisted.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

const String spotifyCallbackScheme = 'cresca';
const String spotifyCallbackHost = 'spotify-callback';

String _randomVerifier() {
  final rnd = Random.secure();
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  return List.generate(
      64, (_) => chars[rnd.nextInt(chars.length)]).join();
}

String codeChallenge(String verifier) {
  try {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  } catch (_) {
    return '';
  }
}

class SpotifySession {
  final FlutterSecureStorage _store;
  String clientId = '';
  String accessToken = '';
  String refreshToken = '';
  String displayName = '';
  int expiresAtMs = 0;

  StreamSubscription<Uri>? _linkSub;
  String _verifier = '';

  SpotifySession({FlutterSecureStorage? store})
      : _store = store ?? const FlutterSecureStorage();

  static const _kClient = 'spotify_client_id';
  static const _kAccess = 'spotify_access';
  static const _kRefresh = 'spotify_refresh';
  static const _kName = 'spotify_name';
  static const _kExpiry = 'spotify_expiry';

  Future<void> load() async {
    try {
      clientId = await _store.read(key: _kClient) ?? '';
      accessToken = await _store.read(key: _kAccess) ?? '';
      refreshToken = await _store.read(key: _kRefresh) ?? '';
      displayName = await _store.read(key: _kName) ?? '';
      expiresAtMs =
          int.tryParse(await _store.read(key: _kExpiry) ?? '') ?? 0;
    } catch (_) {}
  }

  bool get isConnected =>
      accessToken.isNotEmpty && refreshToken.isNotEmpty;

  bool get tokenFresh {
    try {
      return accessToken.isNotEmpty &&
          DateTime.now().millisecondsSinceEpoch < expiresAtMs - 60000;
    } catch (_) {
      return false;
    }
  }

  Future<void> setClientId(String id) async {
    try {
      clientId = id.trim();
      await _store.write(key: _kClient, value: clientId);
    } catch (_) {}
  }

  /// Starts PKCE login in the system browser. Completes true when the
  /// callback arrives and tokens swap (also refreshes the profile).
  Future<bool> connect() async {
    try {
      if (clientId.isEmpty) return false;
      _verifier = _randomVerifier();
      final challenge = codeChallenge(_verifier);
      if (challenge.isEmpty) return false;
      final done = Completer<bool>();
      try {
        await _linkSub?.cancel();
      } catch (_) {}
      final links = AppLinks();
      _linkSub = links.uriLinkStream.listen((uri) async {
        try {
          if (uri.scheme != spotifyCallbackScheme ||
              uri.host != spotifyCallbackHost) {
            return;
          }
          final code = uri.queryParameters['code'] ?? '';
          final err = uri.queryParameters['error'] ?? '';
          if (code.isEmpty || err.isNotEmpty) {
            if (!done.isCompleted) done.complete(false);
            return;
          }
          final ok = await _swap(code);
          if (!done.isCompleted) done.complete(ok);
        } catch (_) {
          if (!done.isCompleted) done.complete(false);
        }
      }, onError: (_) {
        if (!done.isCompleted) done.complete(false);
      });
      final auth = Uri.https('accounts.spotify.com', '/authorize', {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': '$spotifyCallbackScheme://$spotifyCallbackHost',
        'scope': 'user-library-read playlist-read-private',
        'code_challenge_method': 'S256',
        'code_challenge': challenge,
      });
      final launched = await launchUrl(auth,
          mode: LaunchMode.externalApplication);
      if (!launched) {
        if (!done.isCompleted) done.complete(false);
        return false;
      }
      return await done.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    } finally {
      try {
        await _linkSub?.cancel();
      } catch (_) {}
    }
  }

  Future<bool> _swap(String code) async {
    try {
      final res = await http
          .post(
            Uri.parse('https://accounts.spotify.com/api/token'),
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: {
              'grant_type': 'authorization_code',
              'code': code,
              'redirect_uri':
                  '$spotifyCallbackScheme://$spotifyCallbackHost',
              'client_id': clientId,
              'code_verifier': _verifier,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final d = jsonDecode(res.body) as Map;
      accessToken = (d['access_token'] ?? '').toString();
      refreshToken = (d['refresh_token'] ?? '').toString();
      final expiresIn =
          int.tryParse(d['expires_in'].toString()) ?? 3600;
      expiresAtMs = DateTime.now().millisecondsSinceEpoch +
          expiresIn * 1000;
      if (accessToken.isEmpty || refreshToken.isEmpty) return false;
      await _store.write(key: _kAccess, value: accessToken);
      await _store.write(key: _kRefresh, value: refreshToken);
      await _store.write(
          key: _kExpiry, value: expiresAtMs.toString());
      await refreshProfile();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> refresh() async {
    try {
      if (refreshToken.isEmpty || clientId.isEmpty) return false;
      final res = await http
          .post(
            Uri.parse('https://accounts.spotify.com/api/token'),
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: {
              'grant_type': 'refresh_token',
              'refresh_token': refreshToken,
              'client_id': clientId,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final d = jsonDecode(res.body) as Map;
      final at = (d['access_token'] ?? '').toString();
      if (at.isEmpty) return false;
      accessToken = at;
      final expiresIn =
          int.tryParse(d['expires_in'].toString()) ?? 3600;
      expiresAtMs = DateTime.now().millisecondsSinceEpoch +
          expiresIn * 1000;
      await _store.write(key: _kAccess, value: accessToken);
      await _store.write(
          key: _kExpiry, value: expiresAtMs.toString());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> refreshProfile() async {
    try {
      var at = accessToken;
      if (!tokenFresh) {
        await refresh();
        at = accessToken;
      }
      if (at.isEmpty) return;
      final res = await http
          .get(
            Uri.parse('https://api.spotify.com/v1/me'),
            headers: {'Authorization': 'Bearer $at'},
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final d = jsonDecode(res.body) as Map;
      displayName = (d['display_name'] ?? '').toString();
      await _store.write(key: _kName, value: displayName);
    } catch (_) {}
  }

  Future<void> disconnect() async {
    try {
      accessToken = '';
      refreshToken = '';
      displayName = '';
      expiresAtMs = 0;
      await _store.delete(key: _kAccess);
      await _store.delete(key: _kRefresh);
      await _store.delete(key: _kName);
      await _store.delete(key: _kExpiry);
    } catch (_) {}
  }

  void dispose() {
    try {
      _linkSub?.cancel();
    } catch (_) {}
  }
}
