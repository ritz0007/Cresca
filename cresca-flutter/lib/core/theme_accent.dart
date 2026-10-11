// Pure-Dart port of the song-accent + dominant-color math.
// Native refs: MainActivity.dominantColor (8x8 avg, saturation boost,
// x0.5 darkened, fallback 0xFF3A0A12), Theme.songAccentOf (x1.8 revive,
// luminance guards, on-color by luminance>0.45), Color.kt palette,
// Type.kt scale.
//
// Colors are 0xAARRGGBB ints so this file has zero Flutter imports and
// stays runnable under plain `dart test`.
//
// The functions above are byte-for-byte native parity — do not change
// their math. The legibility helpers below are ADDITIVE (no existing
// caller changes): use them when the accent tints foreground glyphs
// (icons, rings, selected labels) on the app background. Filled-button
// usage keeps the raw accent + [onColorFor] (text-on-accent contrast,
// already native-guarded).

import 'dart:math' as math;

const int crescaRed = 0xFFFA243C;
const int crescaRedDark = 0xFFFC5C6E;
const int fallbackDom = 0xFF3A0A12;

const int lightBackground = 0xFFFFFFFF;
const int lightSurface = 0xFFF2F2F6;
const int lightText = 0xFF000000;
const int lightSubtext = 0xFF8E8E93;

const int darkBackground = 0xFF000000;
const int darkSurface = 0xFF1C1C1E;
const int darkText = 0xFFFFFFFF;
const int darkSubtext = 0xFF98989F;

double _r(int c) => ((c >> 16) & 0xFF) / 255.0;
double _g(int c) => ((c >> 8) & 0xFF) / 255.0;
double _b(int c) => (c & 0xFF) / 255.0;

int _argb(double r, double g, double b, [double a = 1.0]) {
  int clamp(double v) => (v.clamp(0.0, 1.0) * 255.0).round().clamp(0, 255);
  return ((a.clamp(0.0, 1.0) * 255.0).round().clamp(0, 255) << 24) |
      (clamp(r) << 16) |
      (clamp(g) << 8) |
      clamp(b);
}

/// Rec.709 luminance in 0..1.
double luminanceOf(int color) =>
    0.2126 * _r(color) + 0.7152 * _g(color) + 0.0722 * _b(color);

/// On-color for an accent: dark ink when bright, white when dark.
/// Native threshold: luminance > 0.45.
int onColorFor(int accent) =>
    luminanceOf(accent) > 0.45 ? 0xFF1A1A1E : 0xFFFFFFFF;

/// Revives the darkened player dominant color into a vivid-but-tasteful
/// accent: lifts brightness x1.8, keeps hue. Returns null when there is no
/// song (caller falls back to default red).
int? songAccentOf(int dom, bool hasSong) {
  if (!hasSong) return null;
  try {
    final r = (_r(dom) * 1.8).clamp(0.0, 1.0);
    final g = (_g(dom) * 1.8).clamp(0.0, 1.0);
    final b = (_b(dom) * 1.8).clamp(0.0, 1.0);
    final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    if (lum < 0.08 || lum > 0.92) return crescaRed;
    return _argb(r, g, b);
  } catch (_) {
    return null;
  }
}

/// 8x8-average dominant color with the native saturation boost and x0.5
/// darkening. [pixels] is the downscaled 64-pixel ARGB list; empty input
/// yields the fallback. Pure function of the pixel math so tests never need
/// real image bytes.
int dominantOfPixels(List<int> pixels) {
  try {
    if (pixels.isEmpty) return fallbackDom;
    double r = 0, g = 0, b = 0;
    for (final p in pixels) {
      r += (p >> 16) & 0xFF;
      g += (p >> 8) & 0xFF;
      b += p & 0xFF;
    }
    final n = pixels.length.toDouble();
    double rf = r / n / 255.0;
    double gf = g / n / 255.0;
    double bf = b / n / 255.0;
    final mx = [rf, gf, bf].reduce((a, v) => a > v ? a : v);
    final mn = [rf, gf, bf].reduce((a, v) => a < v ? a : v);
    if (mx > 0) {
      final boost = 1.0 + 0.4 * (1.0 - (mx - mn) / mx);
      rf = (rf * boost).clamp(0.0, 1.0);
      gf = (gf * boost).clamp(0.0, 1.0);
      bf = (bf * boost).clamp(0.0, 1.0);
    }
    return _argb(rf * 0.5, gf * 0.5, bf * 0.5);
  } catch (_) {
    return fallbackDom;
  }
}

/// Typography scale (Type.kt), kept as data for the Flutter TextTheme port.
class CrescaTypeScale {
  final double size;
  final double? lineHeight;
  final String weight;
  const CrescaTypeScale(this.size, this.weight, [this.lineHeight]);
}

const displaySmall = CrescaTypeScale(34, 'extraBold', 40);
const titleLarge = CrescaTypeScale(22, 'bold');
const titleMedium = CrescaTypeScale(17, 'semiBold');
const titleSmall = CrescaTypeScale(13, 'semiBold');
const bodyLarge = CrescaTypeScale(17, 'regular');
const bodyMedium = CrescaTypeScale(15, 'regular');
const bodySmall = CrescaTypeScale(13, 'regular');
const labelSmall = CrescaTypeScale(11, 'semiBold');

double _lin(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// WCAG 2.x relative luminance (linearized), 0..1. Unlike
/// [luminanceOf] (gamma-space, native parity) this is the correct
/// input for contrast math.
double relativeLuminance(int color) =>
    0.2126 * _lin(_r(color)) +
    0.7152 * _lin(_g(color)) +
    0.0722 * _lin(_b(color));

/// WCAG contrast ratio of two colors, 1..21.
double contrastRatio(int a, int b) {
  try {
    final l1 = relativeLuminance(a);
    final l2 = relativeLuminance(b);
    final hi = l1 > l2 ? l1 : l2;
    final lo = l1 > l2 ? l2 : l1;
    return (hi + 0.05) / (lo + 0.05);
  } catch (_) {
    return 1.0;
  }
}

int _mix(int a, int b, double t) {
  int ch(int c, int s) => (c >> s) & 0xFF;
  int mix1(int x, int y) =>
      (x + ((y - x) * t)).round().clamp(0, 255);
  return (0xFF << 24) |
      (mix1(ch(a, 16), ch(b, 16)) << 16) |
      (mix1(ch(a, 8), ch(b, 8)) << 8) |
      mix1(ch(a, 0), ch(b, 0));
}

/// True when [accent] as a foreground tint on the mode background
/// meets [minRatio] (default 3.0, WCAG non-text/graphical objects:
/// icons, rings, selected labels). Filled buttons are NOT this case —
/// their contrast is text-on-accent, guarded by [onColorFor].
bool legibleOn(int accent, bool darkMode, {double minRatio = 3.0}) {
  try {
    final bg = darkMode ? darkBackground : lightBackground;
    return contrastRatio(accent, bg) >= minRatio;
  } catch (_) {
    return true;
  }
}

/// Returns [accent] unchanged when [legibleOn] passes; otherwise mixes
/// it toward white (dark mode) or dark ink (light mode) until the
/// ratio passes. Bounded (10 steps) and pure; sane mid-luminance song
/// accents pass through untouched, only near-invisible extremes shift.
int ensureLegible(int accent, bool darkMode, {double minRatio = 3.0}) {
  try {
    if (legibleOn(accent, darkMode, minRatio: minRatio)) return accent;
    final target = darkMode ? 0xFFFFFFFF : 0xFF1A1A1E;
    for (var i = 1; i <= 10; i++) {
      final c = _mix(accent, target, i / 10.0);
      if (legibleOn(c, darkMode, minRatio: minRatio)) return c;
    }
    return target;
  } catch (_) {
    return accent;
  }
}
