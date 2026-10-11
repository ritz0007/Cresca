// Real audio effects (Audio Pipeline sheet): platform Equalizer +
// LoudnessEnhancer (volume boost) attached to just_audio's audio
// session via the `cresca.audiofx` MethodChannel (MainActivity).
// Everything is live: band count/range/freqs come from the device,
// every set returns success, presets persist in SharedPreferences.
// No native support (emulator edge cases, old devices) -> attach()
// returns null and the sheet says so honestly instead of faking it.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device band layout returned by attach().
class FxBands {
  final int count;
  final int minMb;
  final int maxMb;
  final List<int> freqsMHZ;
  const FxBands(
      {required this.count,
      required this.minMb,
      required this.maxMb,
      required this.freqsMHZ});
}

/// Preset curves in dB for a 5-band reference layout; resampled to
/// the device band count (index-fraction mapping).
const Map<String, List<double>> fxPresetDb = {
  'Flat': [0, 0, 0, 0, 0],
  'Bass Boost': [6, 4, 1, 0, -1],
  'Treble Boost': [-1, 0, 1, 4, 6],
  'Vocal': [-2, -1, 3, 4, 2],
  'Rock': [4, 2, -1, 2, 4],
  'Pop': [1, 3, 4, 3, 1],
};

class AudioFx {
  static const _ch = MethodChannel('cresca.audiofx');
  static const _kEnabled = 'audiofx.enabled';
  static const _kBands = 'audiofx.bands';
  static const _kBoost = 'audiofx.boost';

  FxBands? bands;
  bool hasBoost = false;
  bool available = false;
  bool enabled = true;
  List<int> levelsMb = const [];
  int boostMb = 0;

  Future<Map<String, dynamic>?> _call(
      String method, Map<String, dynamic> args) async {
    try {
      final r = await _ch.invokeMethod(method, args);
      if (r is Map) return Map<String, dynamic>.from(r);
      if (r is bool) return {'ok': r};
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Attaches to [sessionId]; returns band layout or null when the
  /// device cannot do effects. Applies the persisted preset on success.
  Future<FxBands?> attach(int sessionId) async {
    if (sessionId <= 0) {
      available = false;
      return null;
    }
    try {
      final r = await _ch.invokeMethod('attach', {
        'sessionId': sessionId,
      });
      if (r is! Map) {
        available = false;
        return null;
      }
      final m = Map<String, dynamic>.from(r);
      final n = (m['bands'] as int? ?? 0);
      if (n <= 0) {
        available = false;
        return null;
      }
      final info = FxBands(
        count: n,
        minMb: (m['minMb'] as int? ?? -1500),
        maxMb: (m['maxMb'] as int? ?? 1500),
        freqsMHZ: [
          for (final f in (m['freqs'] as List? ?? const []))
            (f as int? ?? 0)
        ],
      );
      bands = info;
      hasBoost =
          (m['hasBoost'] as bool?) ?? false;
      available = true;
      await _applyPersisted(info);
      return info;
    } catch (_) {
      available = false;
      return null;
    }
  }

  Future<void> _applyPersisted(FxBands info) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(_kEnabled) ?? true;
      final saved = prefs.getStringList(_kBands);
      if (saved != null && saved.length == info.count) {
        levelsMb = [
          for (final s in saved)
            (int.tryParse(s) ?? 0)
                .clamp(info.minMb, info.maxMb)
        ];
      } else {
        levelsMb = List<int>.filled(info.count, 0);
      }
      boostMb = (prefs.getInt(_kBoost) ?? 0).clamp(0, 1500);
      await _call('setEnabled', {'enabled': enabled});
      for (var i = 0; i < levelsMb.length; i++) {
        await _call('setBand', {'band': i, 'levelMb': levelsMb[i]});
      }
      if (hasBoost) {
        await _call('setBoost', {'gainMb': boostMb});
      }
    } catch (_) {
      levelsMb = List<int>.filled(info.count, 0);
    }
  }

  Future<bool> setBand(int band, int mb) async {
    final info = bands;
    if (!available || info == null) return false;
    final v = mb.clamp(info.minMb, info.maxMb);
    final r = await _call('setBand', {'band': band, 'levelMb': v});
    final ok = r?['ok'] == true;
    if (ok) {
      try {
        final next = List<int>.from(levelsMb);
        if (band >= 0 && band < next.length) {
          next[band] = v;
          levelsMb = next;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList(
              _kBands, [for (final l in next) '$l']);
        }
      } catch (_) {}
    }
    return ok;
  }

  Future<bool> setEnabled(bool on) async {
    enabled = on;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, on);
    } catch (_) {}
    if (!available) return false;
    final r = await _call('setEnabled', {'enabled': on});
    return r?['ok'] == true;
  }

  Future<bool> setBoost(int mb) async {
    boostMb = mb.clamp(0, 1500);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kBoost, boostMb);
    } catch (_) {}
    if (!available || !hasBoost) return false;
    final r = await _call('setBoost', {'gainMb': boostMb});
    return r?['ok'] == true;
  }

  Future<void> applyPreset(String name) async {
    final info = bands;
    if (!available || info == null) return;
    final ref = fxPresetDb[name] ?? fxPresetDb['Flat']!;
    for (var i = 0; i < info.count; i++) {
      final f = info.count == 1
          ? 0.0
          : i / (info.count - 1) * (ref.length - 1);
      final lo = f.floor().clamp(0, ref.length - 1);
      final hi = f.ceil().clamp(0, ref.length - 1);
      final t = (f - lo).clamp(0.0, 1.0);
      final db = ref[lo] + (ref[hi] - ref[lo]) * t;
      await setBand(i, (db * 100).round());
    }
  }

  /// dB label for a band from its center freq (mHz from the device).
  static String bandLabel(int freqMHZ, int index) {
    try {
      if (freqMHZ > 0) {
        final hz = freqMHZ / 1000.0;
        if (hz >= 1000) {
          final k = hz / 1000.0;
          final s = k >= 10
              ? k.toStringAsFixed(0)
              : k.toStringAsFixed(1);
          return '${s}kHz';
        }
        return '${hz.toStringAsFixed(0)}Hz';
      }
    } catch (_) {}
    return 'Band ${index + 1}';
  }
}
