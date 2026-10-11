// System media volume (STREAM_MUSIC) bridge.
//
// MethodChannel `cresca.system_volume`:
//   getVolume -> {volume, max}
//   setVolume {volume 0..maxInt} (flag 0: no UI popup on drags)
// EventChannel `cresca.system_volume/events`: normalized 0..1 doubles
// pushed from a ContentObserver on Settings.System.CONTENT_URI, so
// hardware-button / external changes arrive without polling.
// Never throws: level() falls back to 1.0, setLevel swallows,
// watch() emits nothing when unavailable. Event stream uses local
// caching + distinct() so StreamBuilders don't rebuild redundantly.

import 'dart:async';

import 'package:flutter/services.dart';

class SystemVolume {
  static const _method = MethodChannel('cresca.system_volume');
  static const _events = EventChannel('cresca.system_volume/events');

  static double _cached = 1.0;
  static int _lastMax = 15;
  static Stream<double>? _watch;

  /// 0..1 of STREAM_MUSIC. Returns 1.0 on failure, never throws.
  static Future<double> level() async {
    try {
      final r = await _method.invokeMethod('getVolume');
      if (r is Map) {
        final m = Map<String, dynamic>.from(r);
        final max = ((m['max'] as num?)?.toInt() ?? 0);
        if (max <= 0) return _cached;
        _lastMax = max;
        final vol = ((m['volume'] as num?)?.toInt() ?? max)
            .clamp(0, max);
        final v = (vol / max).clamp(0.0, 1.0);
        _cached = v;
        return v;
      }
      return _cached;
    } catch (_) {
      return _cached;
    }
  }

  /// 0..1 clamped. Swallows all errors, never throws.
  static Future<void> setLevel(double v) async {
    final target = v.isNaN ? _cached : v.clamp(0.0, 1.0);
    _cached = target;
    try {
      var max = _lastMax;
      try {
        final r = await _method.invokeMethod('getVolume');
        if (r is Map) {
          final m = Map<String, dynamic>.from(r);
          final mMax = (m['max'] as num?)?.toInt() ?? 0;
          if (mMax > 0) {
            max = mMax;
            _lastMax = mMax;
          }
        }
      } catch (_) {}
      if (max <= 0) return;
      final want = (target * max).round().clamp(0, max);
      await _method.invokeMethod('setVolume', {'volume': want});
    } catch (_) {}
  }

  /// Emits the current level on hardware-button/external changes.
  /// Distinct + locally cached; emits nothing when unavailable.
  static Stream<double> watch() {
    try {
      _watch ??= _events
          .receiveBroadcastStream()
          .map<double>(_fromEvent)
          .distinct()
          .handleError((_, _) {});
      return _watch!;
    } catch (_) {
      return const Stream<double>.empty();
    }
  }

  static double _fromEvent(dynamic e) {
    try {
      if (e is Map) {
        final m = Map<String, dynamic>.from(e);
        final max = (m['max'] as num?)?.toInt() ?? _lastMax;
        if (max <= 0) return _cached;
        _lastMax = max;
        final vol = (m['volume'] as num?)?.toInt() ?? max;
        final v =
            (vol.clamp(0, max) / max).clamp(0.0, 1.0);
        _cached = v;
        return v;
      }
      if (e is int) {
        // Raw stream volume (older/alternate native payload).
        if (_lastMax <= 0) return _cached;
        final v = (e.clamp(0, _lastMax) / _lastMax)
            .clamp(0.0, 1.0);
        _cached = v;
        return v;
      }
      if (e is num) {
        final v = e.toDouble().clamp(0.0, 1.0);
        _cached = v;
        return v;
      }
    } catch (_) {}
    return _cached;
  }
}
