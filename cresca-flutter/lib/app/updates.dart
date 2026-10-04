// In-app updates (Y4): daily GitHub check, banner + once-per-tag
// notification, ABI-picked APK, background download + tap-to-install,
// unknown-apps settings deep-link, progress UI. Native refs:
// UpdateCheck.kt (repo/endpoints/24h/tag compare/ABI pick),
// UpdateDownload.kt + UpdateInstall.kt + UpdateNotify.kt (flow).

import 'dart:async';
import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:open_file/open_file.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

const String updateRepo = 'ritz0007/Cresca';
const int updateIntervalMs = 24 * 60 * 60 * 1000;
const String updateChannelId = 'com.cresca.updates';
const String updateApkTaskId = 'cresca-update-apk';

class AppUpdate {
  final String tag;
  final String pageUrl;
  final String apkUrl;
  final String apkName;
  const AppUpdate({
    required this.tag,
    required this.pageUrl,
    this.apkUrl = '',
    this.apkName = '',
  });
}

/// Parses one release object. Null when unusable.
AppUpdate? parseRelease(Map<String, dynamic> o) {
  try {
    if ((o['draft'] == true) || (o['prerelease'] == true)) return null;
    final tag = (o['tag_name'] ?? '').toString().trim();
    if (tag.isEmpty) return null;
    final pageUrl = (o['html_url'] ?? '').toString();
    String apkUrl = '';
    String apkName = '';
    try {
      final assets = o['assets'];
      if (assets is List) {
        final names = <(String, String)>[];
        for (final a in assets) {
          try {
            if (a is! Map) continue;
            final n = (a['name'] ?? '').toString();
            final u = (a['browser_download_url'] ?? '').toString();
            if (n.endsWith('.apk') && u.isNotEmpty) {
              names.add((n, u));
            }
          } catch (_) {}
        }
        final picked = pickApkAsset(names, deviceAbiOverride: '');
        if (picked != null) {
          apkName = picked.$1;
          apkUrl = picked.$2;
        }
      }
    } catch (_) {}
    return AppUpdate(
        tag: tag, pageUrl: pageUrl, apkUrl: apkUrl, apkName: apkName);
  } catch (_) {
    return null;
  }
}

/// Device ABI slug matching release asset names (arm64/armv7/x86_64).
/// [deviceAbiOverride] is the test seam (native reads Build.SUPPORTED_ABIS).
String _abi([String override = '']) {
  try {
    if (override.isNotEmpty) return override;
    return 'universal';
  } catch (_) {
    return 'universal';
  }
}

/// Picks the direct APK asset for this device (exact ABI, else universal).
(String, String)? pickApkAsset(List<(String, String)> names,
    {String deviceAbiOverride = ''}) {
  try {
    if (names.isEmpty) return null;
    final abi = deviceAbiOverride.isNotEmpty
        ? deviceAbiOverride
        : _abi();
    for (final n in names) {
      if (n.$1.contains('-$abi.apk')) return n;
    }
    for (final n in names) {
      if (n.$1.contains('-universal.apk')) return n;
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// True when [tag] (v1.5.0 / 1.5.0) is newer than [current] (1.4.1).
bool isNewerTag(String tag, String current) {
  try {
    List<int> parts(String v) {
      var s = v.trim();
      if (s.startsWith('v') || s.startsWith('V')) {
        s = s.substring(1);
      }
      s = s.split(RegExp(r'[-+]')).first;
      return s.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    }

    final a = parts(tag);
    final b = parts(current);
    final n = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  } catch (_) {
    return false;
  }
}

class UpdateChecker {
  final http.Client _http;
  final FlutterLocalNotificationsPlugin _notes;
  bool _notesReady = false;

  /// Last-seen tag per session (banner dedupe); persisted notified tags
  /// live in SharedPreferences via the callbacks.
  UpdateChecker({http.Client? httpClient})
      : _http = httpClient ?? http.Client(),
        _notes = FlutterLocalNotificationsPlugin();

  Future<void> ensureNotifications() async {
    try {
      if (_notesReady) return;
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _notes.initialize(settings);
      const channel = AndroidNotificationChannel(
        updateChannelId,
        'Cresca updates',
        importance: Importance.high,
      );
      await _notes
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
      _notesReady = true;
    } catch (_) {}
  }

  Future<void> requestNotificationPermission() async {
    try {
      await Permission.notification.request();
    } catch (_) {}
  }

  /// Latest release: /latest then newest-of-list fallback. Null on failure.
  Future<AppUpdate?> latest() async {
    try {
      final one = await _fetchRelease(
          'https://api.github.com/repos/$updateRepo/releases/latest',
          single: true);
      if (one != null) return one;
    } catch (_) {}
    try {
      return await _fetchRelease(
          'https://api.github.com/repos/$updateRepo/releases?per_page=5',
          single: false);
    } catch (_) {
      return null;
    }
  }

  Future<AppUpdate?> _fetchRelease(String url,
      {required bool single}) async {
    try {
      final res = await _http.get(
        Uri.parse(url),
        headers: const {
          'User-Agent': 'Cresca',
          'Accept': 'application/vnd.github+json',
          'Cache-Control': 'no-cache',
        },
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (single) {
        if (decoded is! Map) return null;
        return parseRelease(decoded.cast<String, dynamic>());
      }
      if (decoded is! List) return null;
      for (final e in decoded) {
        try {
          if (e is! Map) continue;
          final u =
              parseRelease(e.cast<String, dynamic>());
          if (u != null) return u;
        } catch (_) {}
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String> currentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version.isEmpty ? '0.0.0' : info.version;
    } catch (_) {
      return '0.0.0';
    }
  }

  /// Once-per-tag notification (Y4). No-op when already notified.
  Future<void> notifyOnce(AppUpdate u, Set<String> notifiedTags,
      Future<void> Function(String tag) markNotified) async {
    try {
      if (notifiedTags.contains(u.tag)) return;
      await ensureNotifications();
      await _notes.show(
        u.tag.hashCode & 0x7fffffff,
        'Cresca ${u.tag} available',
        'Tap to view release notes.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            updateChannelId,
            'Cresca updates',
            importance: Importance.high,
          ),
        ),
      );
      await markNotified(u.tag);
    } catch (_) {}
  }

  /// Enqueues the ABI APK download (progress via onProgress 0–100).
  /// Returns false when there is no APK asset.
  Future<bool> downloadApk(AppUpdate u,
      {void Function(double progress)? onProgress}) async {
    try {
      if (u.apkUrl.isEmpty) return false;
      StreamSubscription<TaskUpdate>? sub;
      try {
        sub = FileDownloader().updates.listen((ev) {
          try {
            if (ev.task.taskId != updateApkTaskId) return;
            if (ev is TaskProgressUpdate) {
              onProgress?.call(
                  (ev.progress * 100).clamp(0.0, 100.0));
            } else if (ev is TaskStatusUpdate) {
              if (ev.status == TaskStatus.complete) {
                onProgress?.call(100);
              }
            }
          } catch (_) {}
        });
      } catch (_) {}
      final ok = await FileDownloader().enqueue(DownloadTask(
        taskId: updateApkTaskId,
        url: u.apkUrl,
        filename: u.apkName.isEmpty ? 'cresca-update.apk' : u.apkName,
        directory: 'Cresca',
        baseDirectory: BaseDirectory.applicationDocuments,
        updates: Updates.statusAndProgress,
        retries: 2,
      ));
      if (!ok) {
        try {
          await sub?.cancel();
        } catch (_) {}
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Tap-to-install: opens the APK (system installer prompts), after
  /// confirming install-packages permission with a settings deep-link
  /// fallback (Y4 unknown-apps row).
  Future<bool> installApk(String filePath) async {
    try {
      try {
        var status = await Permission.requestInstallPackages.status;
        if (!status.isGranted) {
          status =
              await Permission.requestInstallPackages.request();
        }
        if (!status.isGranted) {
          try {
            await openAppSettings();
          } catch (_) {}
          return false;
        }
      } catch (_) {}
      final res = await OpenFile.open(filePath);
      return res.type == ResultType.done;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    try {
      _http.close();
    } catch (_) {}
  }
}
