// In-app updates (Y4): daily GitHub check, banner + once-per-tag
// notification, ABI-picked APK, background download + tap-to-install,
// unknown-apps settings deep-link, progress UI. Native refs:
// UpdateCheck.kt (repo/endpoints/24h/tag compare/ABI pick),
// UpdateDownload.kt + UpdateInstall.kt + UpdateNotify.kt (flow).

import 'dart:async';
import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:open_file/open_file.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/motion.dart'
    show barSlideMs, motionMs, shimmerMs, tabExitMs;

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
AppUpdate? parseRelease(Map<String, dynamic> o, {String deviceAbi = ''}) {
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
        final picked =
            pickApkAsset(names, deviceAbiOverride: deviceAbi);
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

/// Device ABI channel (native Build.SUPPORTED_ABIS, see MainActivity).
const String deviceAbiChannel = 'cresca.device';

/// Throttle gate (pure, tested): manual always checks; auto skips when
/// the last *successful* check is within [updateIntervalMs]. Failures
/// stamp `update_last_attempt` only, never this gate.
bool shouldCheckForUpdates(
    {required bool manual, required int nowMs, required int lastCheckMs}) {
  try {
    if (manual) return true;
    return nowMs - lastCheckMs >= updateIntervalMs;
  } catch (_) {
    return true;
  }
}

/// Normalizes a Build.SUPPORTED_ABIS entry to the release-asset slug
/// (arm64-v8a → arm64, armeabi-v7a → armv7, x86_64 stays).
String normalizeAbi(String raw) {
  try {
    final l = raw.trim().toLowerCase();
    if (l.contains('arm64') || l == 'aarch64' || l.contains('v8a')) {
      return 'arm64';
    }
    if (l.contains('armeabi') || l.contains('armv7')) return 'armv7';
    if (l.contains('x86_64')) return 'x86_64';
    if (l == 'x86') return 'x86';
    if (l == 'universal' || l.isEmpty) return 'universal';
    return l;
  } catch (_) {
    return 'universal';
  }
}

/// Real device ABI via platform channel (SUPPORTED_ABIS[0], normalized);
/// 'universal' when unknown. Tests inject [channel].
Future<String> deviceAbi({MethodChannel? channel}) async {
  try {
    final ch = channel ?? const MethodChannel(deviceAbiChannel);
    final v = await ch
        .invokeMethod('getSupportedAbis')
        .timeout(const Duration(seconds: 2));
    final abis = <String>[];
    if (v is List) {
      for (final e in v) {
        abis.add(e.toString());
      }
    } else if (v is String && v.isNotEmpty) {
      abis.add(v);
    }
    for (final a in abis) {
      final s = normalizeAbi(a);
      if (s.isNotEmpty) return s;
    }
    return 'universal';
  } catch (_) {
    return 'universal';
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
    return names.first;
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
      String abi = '';
      try {
        abi = await deviceAbi();
      } catch (_) {}
      final decoded = jsonDecode(res.body);
      if (single) {
        if (decoded is! Map) return null;
        return parseRelease(decoded.cast<String, dynamic>(),
            deviceAbi: abi);
      }
      if (decoded is! List) return null;
      for (final e in decoded) {
        try {
          if (e is! Map) continue;
          final u = parseRelease(e.cast<String, dynamic>(),
              deviceAbi: abi);
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
                try {
                  sub?.cancel();
                } catch (_) {}
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

/// Update banner motion (H9/Y4): the prompt slides down + fades in
/// over 220 ms ([barSlideMs]); dismiss slides up + fades over 180 ms.
/// Transform/opacity only — 60 fps, dark/light + large-text safe
/// (fractional slide, no fixed heights).
///
/// Wrap banner content and drive [visible] from
/// `state.pendingUpdate != null`. Content stays mounted while the
/// exit runs so the dismiss is visible; pass [onDismissed] to drop it
/// (or keep it mounted — zero-size when fully hidden).
class UpdateBannerMotion extends StatefulWidget {
  final bool visible;
  final bool motionOn;
  final Widget child;
  const UpdateBannerMotion({
    super.key,
    required this.visible,
    required this.child,
    this.motionOn = true,
  });

  @override
  State<UpdateBannerMotion> createState() =>
      _UpdateBannerMotionState();
}

class _UpdateBannerMotionState extends State<UpdateBannerMotion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  // 120Hz polish: hoisted curves (were allocated per build); the
  // banner content paints behind a boundary so the slide/fade never
  // repaints rows beneath it.
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  late final Animation<double> _size;

  Duration get _enter =>
      Duration(milliseconds: motionMs(widget.motionOn, barSlideMs));
  Duration get _exit =>
      Duration(milliseconds: motionMs(widget.motionOn, tabExitMs));

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, value: 0);
    _fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
    _slide = Tween(
      begin: const Offset(0, -0.18),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOut));
    _size = CurvedAnimation(parent: _c, curve: Curves.easeOut);
    _c.duration = _enter;
    _c.reverseDuration = _exit;
    if (widget.visible) _c.value = 1;
  }

  @override
  void didUpdateWidget(covariant UpdateBannerMotion old) {
    super.didUpdateWidget(old);
    _c.duration = _enter;
    _c.reverseDuration = _exit;
    if (widget.visible != old.visible) {
      if (widget.visible) {
        _c.forward();
      } else {
        _c.reverse();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.motionOn) {
      return widget.visible
          ? widget.child
          : const SizedBox.shrink();
    }
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: SizeTransition(
          sizeFactor: _size,
          alignment: Alignment.topCenter,
          child: RepaintBoundary(child: widget.child),
        ),
      ),
    );
  }
}

/// Download progress shimmer: opacity pulse only (never
/// position/blur) while [active]. Wraps the update progress bar.
/// Idle when motion is off or the download isn't running.
class UpdateProgressShimmer extends StatefulWidget {
  final bool motionOn;
  final bool active;
  final Widget child;
  const UpdateProgressShimmer({
    super.key,
    required this.child,
    this.motionOn = true,
    this.active = true,
  });

  @override
  State<UpdateProgressShimmer> createState() =>
      _UpdateProgressShimmerState();
}

class _UpdateProgressShimmerState
    extends State<UpdateProgressShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  // 120Hz polish: hoisted curve (was `CurvedAnimation(...)` allocated
  // inside the per-frame builder — churned at 120 Hz while active).
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: shimmerMs),
    );
    _pulse = CurvedAnimation(parent: _c, curve: Curves.easeInOut);
    if (widget.motionOn && widget.active) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant UpdateProgressShimmer old) {
    super.didUpdateWidget(old);
    if (widget.motionOn && widget.active) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.motionOn || !widget.active) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(
        opacity: 0.55 + 0.45 * _pulse.value,
        child: child,
      ),
      child: RepaintBoundary(child: widget.child),
    );
  }
}
