// Vendored from cresca-streamkit (streaming-logic reference: see its README). Only relative imports rewritten to package:cresca_app/...; do not edit logic here, fix upstream.
// On-device InnerTube youtubei/v1 client specs + request builders.
// No login, no OAuth, no API key of yours: these are the public client
// identities the YouTube web/music front-ends themselves use.
//
// Cache role: this file owns NO cache state (stateless specs). Budgets
// live in lib/data/cache.dart (T1–T7 tier table) + streamkit/bundle.dart
// (T3). Player legs here feed T1 (5h mem / 6h disk) + T3 (24h bundle
// memo); artwork thumbs feed T7 (disk 2000 objs / 30d, see
// artworkDiskMaxObjects). Keep client name/version/key/headers together
// — a mismatched context silently kills that race leg.

/// One YouTube client identity for youtubei/v1 calls.
class TubeClient {
  final String name;
  final String version;
  final String apiKey;
  final String userAgent;
  final String? referer;
  final int androidSdkVersion;
  final String osName;
  final String osVersion;
  final String deviceMake;
  final String deviceModel;

  const TubeClient({
    required this.name,
    required this.version,
    required this.apiKey,
    required this.userAgent,
    this.referer,
    this.androidSdkVersion = 34,
    this.osName = '',
    this.osVersion = '',
    this.deviceMake = '',
    this.deviceModel = '',
  });

  static const uaWeb =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const uaAndroidMusic =
      'com.google.android.apps.youtube.music/6.42.55 '
      '(Linux; U; Android 14) gzip';

  /// music.youtube.com search/browse leg (stable shelves).
  static const webRemix = TubeClient(
    name: 'WEB_REMIX',
    version: '1.20260707.12.00',
    apiKey: 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
    userAgent: uaWeb,
    referer: 'https://music.youtube.com/',
  );

  /// Player leg: direct audio URLs, minimal cipher.
  static const androidMusic = TubeClient(
    name: 'ANDROID_MUSIC',
    version: '6.42.55',
    apiKey: 'AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI',
    userAgent: uaAndroidMusic,
  );

  /// Player leg: direct signed URLs, no cipher (~200ms fast path).
  /// Selectively 403'd at fetch on flagged IPs (GVS poToken rollout).
  static const androidVr = TubeClient(
    name: 'ANDROID_VR',
    version: '1.65.10',
    apiKey: 'AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI',
    userAgent:
        'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    androidSdkVersion: 32,
    osName: 'Android',
    osVersion: '12L',
    deviceMake: 'Oculus',
    deviceModel: 'Quest 3',
  );

  /// iOS — direct signed URLs, no cipher, NO GVS poToken gate.
  /// yt-dlp's primary default player client since 2025.11. The Apple
  /// device fields + iOS UA travel together or the player 400s.
  static const ios = TubeClient(
    name: 'IOS',
    version: '21.26.4',
    apiKey: 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8',
    userAgent:
        'com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
    osName: 'iPhone',
    osVersion: '18.3.2.22D82',
    deviceMake: 'Apple',
    deviceModel: 'iPhone16,2',
  );

  /// Player leg: direct signed URLs, no cipher, NO GVS poToken gate.
  /// yt-dlp's primary default client since 2026. The Apple device
  /// fields + desktop-Safari UA travel together or the player 400s.
  static const visionos = TubeClient(
    name: 'VISIONOS',
    version: '1.02',
    apiKey: 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8',
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) '
        'Version/26.0 Safari/605.1.15',
    osName: 'visionOS',
    osVersion: '26.5.23O471',
    deviceMake: 'Apple',
    deviceModel: 'RealityDevice17,1',
  );

  /// Fallback client for browse/next/search shapes.
  static const web = TubeClient(
    name: 'WEB',
    version: '2.20260708.00.00',
    apiKey: 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
    userAgent: uaWeb,
  );

  /// Phone client: needs a fresh signatureTimestamp (scraped from a watch
  /// page, see parseSignatureTimestamp) or the player answers
  /// UNPLAYABLE/LOGIN_REQUIRED. Version pinned to yt-dlp's maintained
  /// ANDROID spec (2026).
  static const androidPhone = TubeClient(
    name: 'ANDROID',
    version: '21.26.364',
    apiKey: 'AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI',
    userAgent:
        'com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip',
    androidSdkVersion: 30,
    osName: 'Android',
    osVersion: '11',
  );
}

/// youtubei endpoint URL for a client + method.
String tubeUrl(TubeClient client, String endpoint,
        {String host = 'https://music.youtube.com'}) =>
    '$host/youtubei/v1/$endpoint?key=${client.apiKey}&prettyPrint=false';

/// Request context. The context MUST match the calling client
/// (name/version travel together); a mismatched context silently kills
/// that race leg.
Map<String, dynamic> contextMap(TubeClient client, String visitorData) {
  final c = <String, dynamic>{
    'clientName': client.name,
    'clientVersion': client.version,
    'hl': 'en',
    'gl': 'US',
  };
  if (visitorData.isNotEmpty) c['visitorData'] = visitorData;
  if (client.name.startsWith('ANDROID')) {
    c['androidSdkVersion'] = client.androidSdkVersion;
  }
  if (client.osName.isNotEmpty) c['osName'] = client.osName;
  if (client.osVersion.isNotEmpty) c['osVersion'] = client.osVersion;
  if (client.deviceMake.isNotEmpty) c['deviceMake'] = client.deviceMake;
  if (client.deviceModel.isNotEmpty) {
    c['deviceModel'] = client.deviceModel;
  }
  return {
    'client': c,
    'user': {'lockedSafetyMode': false},
  };
}

/// Player request body for [videoId].
Map<String, dynamic> playerBody(
  TubeClient client,
  String videoId,
  String visitorData, {
  String poToken = '',
  int signatureTimestamp = 0,
}) {
  final body = <String, dynamic>{
    'context': contextMap(client, visitorData),
    'videoId': videoId,
    'racyCheckOk': true,
    'contentCheckOk': true,
  };
  if (poToken.isNotEmpty) {
    body['serviceIntegrityDimensions'] = {'poToken': poToken};
  }
  if (signatureTimestamp > 0) {
    body['playbackContext'] = {
      'contentPlaybackContext': {
        'signatureTimestamp': signatureTimestamp,
      },
    };
  }
  return body;
}

/// POST headers for a youtubei call.
Map<String, String> tubeHeaders(
  TubeClient client, {
  String cookies = '',
  String visitorData = '',
  String poToken = '',
}) {
  final h = <String, String>{
    'Content-Type': 'application/json',
    'X-Goog-Api-Format-Version': '1',
    'X-YouTube-Client-Name': client.name,
    'X-YouTube-Client-Version': client.version,
    'User-Agent': client.userAgent,
    'Origin': 'https://music.youtube.com',
    'X-Origin': 'https://music.youtube.com',
  };
  if (client.referer != null) h['Referer'] = client.referer!;
  if (visitorData.isNotEmpty) h['X-Goog-Visitor-Id'] = visitorData;
  if (cookies.isNotEmpty) h['Cookie'] = cookies;
  if (poToken.isNotEmpty) h['X-Goog-EOM-Visitor-Id'] = poToken;
  return h;
}

/// Signature timestamp for the phone leg, scraped from a watch page
/// (`"STS":20725`). 0 when absent.
int parseSignatureTimestamp(String html) {
  try {
    final m = RegExp(r'"STS":(\d+)').firstMatch(html);
    if (m == null) return 0;
    return int.tryParse(m.group(1) ?? '') ?? 0;
  } catch (_) {
    return 0;
  }
}

/// Extracts the 11-char video id from a youtube watch url, else null.
String? extractVideoId(String url) {
  try {
    final m = RegExp(r'[?&]v=([A-Za-z0-9_-]{11})').firstMatch(url);
    return m?.group(1);
  } catch (_) {
    return null;
  }
}
