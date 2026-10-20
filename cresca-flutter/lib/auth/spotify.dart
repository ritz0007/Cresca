// Spotify PKCE connect (G2 slice 1: auth only; import/sync follow).
// Native refs: SpotifyAuth.kt (PKCE, no secret) — code_verifier/challenge,
// authorize in browser, cresca://spotify-callback capture, token swap,
// refresh on 401, disconnect wipe. The client ID is BUNDLED at build
// time (--dart-define=SPOTIFY_CLIENT_ID=…); it must never appear in the
// repo, so there is no settings field for it.

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
const String spotifyRedirectUri = 'cresca://spotify-callback';

/// Build-bundled client ID (`--dart-define=SPOTIFY_CLIENT_ID=…`). Empty
/// in FOSS builds compiled without the define — connect then reports
/// "not configured" instead of failing obscurely. The real key lives
/// only in the local build invocation, never in git.
const String bundledSpotifyClientId = String.fromEnvironment(
  'SPOTIFY_CLIENT_ID',
  defaultValue: '',
);

/// Read-only scopes (native SpotifyAuth.SCOPES 1:1).
const String spotifyScopes =
    'playlist-read-private playlist-read-collaborative user-library-read '
    'user-top-read user-read-private';

String _randomVerifier() {
  final rnd = Random.secure();
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  return List.generate(
      64, (_) => chars[rnd.nextInt(chars.length)]).join();
}

/// CSRF state: 16 random bytes, base64url, no padding
/// (native SpotifyAuth.newState 1:1). Never throws.
String _randomState() {
  try {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  } catch (_) {
    return '';
  }
}

/// CSRF state check (native exchange 1:1): the callback state must equal
/// the stored state, and neither may be empty — old links without state
/// are rejected instead of trusted. Pure; never throws.
bool spotifyStateOk(String gotState, String wantState) {
  try {
    if (gotState.isEmpty || wantState.isEmpty) return false;
    return gotState == wantState;
  } catch (_) {
    return false;
  }
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
  String _state = '';

  SpotifySession({FlutterSecureStorage? store})
      : _store = store ?? const FlutterSecureStorage();

  static const _kClient = 'spotify_client_id';
  static const _kAccess = 'spotify_access';
  static const _kRefresh = 'spotify_refresh';
  static const _kName = 'spotify_name';
  static const _kExpiry = 'spotify_expiry';

  /// Persisted PKCE verifier + CSRF state (native SpotifyAuth K_VERIFIER /
  /// K_STATE 1:1): the browser round-trip may kill the process, so the
  /// exchange reloads these when the in-memory copies are gone.
  static const _kVerifier = 'spotify_verifier';
  static const _kState = 'spotify_state';

  Future<void> load() async {
    try {
      clientId = await _store.read(key: _kClient) ?? '';
      // No settings field: fall back to the build-bundled ID so prior
      // installs (which persisted a user-typed ID) keep working while
      // fresh installs use the bundled key.
      if (clientId.isEmpty) clientId = bundledSpotifyClientId;
      accessToken = await _store.read(key: _kAccess) ?? '';
      refreshToken = await _store.read(key: _kRefresh) ?? '';
      displayName = await _store.read(key: _kName) ?? '';
      expiresAtMs =
          int.tryParse(await _store.read(key: _kExpiry) ?? '') ?? 0;
    } catch (_) {}
  }

  bool get isConnected =>
      accessToken.isNotEmpty || refreshToken.isNotEmpty;

  /// True when a client ID is available (stored or bundled).
  bool get hasClientId => clientId.isNotEmpty;

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
  /// Uses the full read-only [spotifyScopes] (native SCOPES 1:1) plus
  /// show_dialog (stale narrow grants are otherwise reused silently and
  /// playlist reads 403 forever) and a state check against CSRF.
  Future<bool> connect() async {
    try {
      if (clientId.isEmpty) return false;
      _verifier = _randomVerifier();
      final challenge = codeChallenge(_verifier);
      if (challenge.isEmpty) return false;
      _state = _randomState();
      try {
        await _store.write(key: _kVerifier, value: _verifier);
        await _store.write(key: _kState, value: _state);
      } catch (_) {}
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
          // CSRF check (native exchange 1:1): the callback state must
          // equal the stored state, and neither may be empty.
          final gotState = uri.queryParameters['state'] ?? '';
          var wantState = _state;
          if (wantState.isEmpty) {
            try {
              wantState = await _store.read(key: _kState) ?? '';
            } catch (_) {
              wantState = '';
            }
          }
          if (!spotifyStateOk(gotState, wantState)) {
            if (!done.isCompleted) done.complete(false);
            return;
          }
          // Process may have died in the browser: reload the verifier.
          if (_verifier.isEmpty) {
            try {
              _verifier = await _store.read(key: _kVerifier) ?? '';
            } catch (_) {}
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
        'scope': spotifyScopes,
        'show_dialog': 'true',
        'code_challenge_method': 'S256',
        'code_challenge': challenge,
        'state': _state,
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
      // Rotation-less re-auth omits refresh_token: keep the prior one
      // (native saveTokenJson 1:1) instead of wiping the session.
      final swappedRefresh = (d['refresh_token'] ?? '').toString();
      if (swappedRefresh.isNotEmpty) refreshToken = swappedRefresh;
      final expiresIn =
          int.tryParse(d['expires_in'].toString()) ?? 3600;
      expiresAtMs = DateTime.now().millisecondsSinceEpoch +
          expiresIn * 1000;
      if (accessToken.isEmpty || refreshToken.isEmpty) return false;
      await _store.write(key: _kAccess, value: accessToken);
      await _store.write(key: _kRefresh, value: refreshToken);
      await _store.write(
          key: _kExpiry, value: expiresAtMs.toString());
      // Single-use: drop the PKCE verifier/state (native exchange 1:1).
      try {
        await _store.delete(key: _kVerifier);
        await _store.delete(key: _kState);
      } catch (_) {}
      _verifier = '';
      _state = '';
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
      // Persist rotated refresh tokens (native saveTokenJson 1:1).
      final rotated = (d['refresh_token'] ?? '').toString();
      if (rotated.isNotEmpty) {
        refreshToken = rotated;
        await _store.write(key: _kRefresh, value: refreshToken);
      }
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
      final at = await validAccessToken();
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
      _verifier = '';
      _state = '';
      await _store.delete(key: _kAccess);
      await _store.delete(key: _kRefresh);
      await _store.delete(key: _kName);
      await _store.delete(key: _kExpiry);
      await _store.delete(key: _kVerifier);
      await _store.delete(key: _kState);
    } catch (_) {}
  }

  /// Valid access token, refreshing once when expired (native
  /// SpotifyAuth.accessToken 1:1). "" when logged out or refresh fails.
  /// Never throws — import/sync call this instead of reading the field.
  Future<String> validAccessToken() async {
    try {
      if (tokenFresh) return accessToken;
      if (refreshToken.isEmpty || clientId.isEmpty) return '';
      final ok = await refresh();
      return ok ? accessToken : '';
    } catch (_) {
      return '';
    }
  }

  void dispose() {
    try {
      _linkSub?.cancel();
    } catch (_) {}
  }
}

// ---- Spotify import correctness (pure; native SpotifyApi/SpotifyImport
// parse + query + backoff 1:1). Import/sync resolve through these so
// episodes, local files, and artist-less stubs never become dead local
// tracks. All pure; never throw. ----

/// Minimal Spotify track ref (native SpotifyTrack 1:1).
class SpotifyTrackRef {
  final String id;
  final String name;
  final List<String> artists;
  final String album;
  const SpotifyTrackRef({
    required this.id,
    required this.name,
    required this.artists,
    this.album = '',
  });

  /// YouTube search query for this ref (native queryFor 1:1).
  String get query => spotifyQueryFor(name, artists);
}

/// Minimal Spotify playlist ref (native SpotifyPlaylist 1:1).
class SpotifyPlaylistRef {
  final String id;
  final String name;
  final int total;
  const SpotifyPlaylistRef({
    required this.id,
    required this.name,
    this.total = 0,
  });
}

/// One Spotify track object → ref (native SpotifyApi.parseTrack 1:1):
/// unwraps playlist-item `{track: …}` wrappers; drops local files,
/// episodes (podcasts), blank names, and artist-less stubs. Null = skip.
SpotifyTrackRef? parseSpotifyTrack(Map<String, dynamic> o) {
  try {
    var t = o;
    final wrapped = t['track'];
    if (wrapped is Map) t = wrapped.cast<String, dynamic>();
    if (t['is_local'].toString() == 'true') return null;
    if ((t['type'] ?? 'track').toString() == 'episode') return null;
    final name = (t['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    final artists = <String>[];
    try {
      final arr = t['artists'];
      if (arr is List) {
        for (final e in arr) {
          final n = e is Map
              ? (e['name'] ?? '').toString().trim()
              : e.toString().trim();
          if (n.isNotEmpty) artists.add(n);
        }
      }
    } catch (_) {}
    if (artists.isEmpty) return null;
    var album = '';
    try {
      final a = t['album'];
      if (a is Map) album = (a['name'] ?? '').toString();
    } catch (_) {}
    return SpotifyTrackRef(
      id: (t['id'] ?? '').toString(),
      name: name,
      artists: artists,
      album: album,
    );
  } catch (_) {
    return null;
  }
}

/// One Spotify playlist object → ref (native parsePlaylist 1:1).
/// Null = skip (blank id or blank name).
SpotifyPlaylistRef? parseSpotifyPlaylist(Map<String, dynamic> o) {
  try {
    final id = (o['id'] ?? '').toString();
    final name = (o['name'] ?? '').toString().trim();
    if (id.isEmpty || name.isEmpty) return null;
    var total = 0;
    try {
      final tracks = o['tracks'];
      if (tracks is Map) {
        total = int.tryParse(tracks['total'].toString()) ?? 0;
      }
    } catch (_) {}
    return SpotifyPlaylistRef(id: id, name: name, total: total);
  } catch (_) {
    return null;
  }
}

/// YouTube search query for a Spotify track: title + first artist,
/// whitespace squashed (native SpotifyImport.queryFor 1:1).
String spotifyQueryFor(String name, List<String> artists) {
  try {
    final first = artists.isEmpty ? '' : artists.first.trim();
    return ('$name $first').trim().replaceAll(RegExp(r'\s+'), ' ');
  } catch (_) {
    return name;
  }
}

/// Local mirror name (rename-safe link lives in the store; this is the
/// legacy display name 1:1 with native `"Spotify • <name>"`).
String spotifyLocalName(String name) {
  try {
    final n = name.trim();
    return 'Spotify • ${n.isEmpty ? 'Playlist' : n}';
  } catch (_) {
    return 'Spotify • Playlist';
  }
}

/// Next-page URL, or null. Guards Spotify's literal null plus the
/// org.json quirk that surfaces it as the string "null" (native
/// nextUrl 1:1 — otherwise one bogus scheme-less request per list).
String? spotifyNextUrl(String? next) {
  try {
    if (next == null || next.isEmpty) return null;
    if (next == 'null' || !next.startsWith('http')) return null;
    return next;
  } catch (_) {
    return null;
  }
}

/// GET retry gate: 429 always retried (Retry-After honored), 403 retried
/// too (Spotify rate-limits surface as bare 403s); auth-scope 403s won't
/// heal — they cost the backoff then return null (native getJson 1:1).
bool spotifyShouldRetry(int statusCode, int attempt) {
  try {
    return (statusCode == 429 || statusCode == 403) && attempt < 2;
  } catch (_) {
    return false;
  }
}

/// Backoff before the next GET retry: Retry-After (capped 15 s) wins,
/// else 1 s doubling to 8 s (native getJson waitMs 1:1). Never throws.
int spotifyBackoffMs(int attempt, {int retryAfterMs = 0}) {
  try {
    if (retryAfterMs > 0) {
      return retryAfterMs > 15000 ? 15000 : retryAfterMs;
    }
    var wait = 1000 << (attempt < 0 ? 0 : attempt);
    if (wait < 1000) wait = 1000;
    return wait > 8000 ? 8000 : wait;
  } catch (_) {
    return 1000;
  }
}

/// Live-sync throttle (native SpotifySync.THROTTLE_MS 1:1): 6 h.
const int spotifySyncThrottleMs = 6 * 60 * 60 * 1000;

/// True when a live sync is due (throttle elapsed). Pure; never throws.
bool spotifySyncDue(int lastSyncMs, [int? nowMs]) {
  try {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return now - lastSyncMs >= spotifySyncThrottleMs;
  } catch (_) {
    return false;
  }
}
