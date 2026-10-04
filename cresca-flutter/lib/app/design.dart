// Cresca design system: iOS spirit + Spotify voice + Liquid Glass.
//
// Sources: RESTRUCTURE catalog (A3 palette, A5 glass bar, A6 type scale),
// Apple Liquid Glass language (translucent blur layers floating over
// content, specular edge highlights, continuous rounded corners,
// light/dark-adaptive legibility), Spotify voice (geometric-humanist
// sans everywhere — Circular is proprietary, so Montserrat, its closest
// open stand-in, carries display through label).
//
// What this file owns:
// - [D1] Montserrat TextTheme mapped 1:1 from the catalog scale
//   (displaySmall 34/40 XB … labelSmall 11 SB).
// - [D2] iOS page transitions on every platform
//   (CupertinoPageTransitionsBuilder for Android/Linux/Windows).
// - [D3] Liquid-glass surfaces: frosted blur + translucent tint +
//   specular rim (bright top-left hairline) + deep shadow. Backdrop blur
//   is the honest Flutter twin of refraction; saturation-lift and true
//   lensing have no twin and are documented deviations.
// - [D4] iOS tab bar styling: no pill indicator (tinted icon + label),
//   frosted background, top hairline.

import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:math' as math;

/// Cresca red — brand moments only (splash/logo). Product actions speak
/// Spotify green (user direction: everything Spotify except the player,
/// which keeps its Apple-Music treatment).
const crescaRed = Color(0xFFFA243C);

/// Spotify resting palette.
const spotifyGreen = Color(0xFF1DB954);
const spotifyGreenBright = Color(0xFF1ED760);
const spotifySubtext = Color(0xFFB3B3B3);

/// Builds the app TextTheme: catalog scale × Montserrat (Spotify voice).
/// Weights: ExtraBold→w800, Bold→w700, SemiBold→w600, Normal→w400.
TextTheme crescaTextTheme(TextTheme base) {
  final t = GoogleFonts.montserratTextTheme(base);
  TextStyle w(TextStyle? s, FontWeight wgt) =>
      (s ?? const TextStyle()).copyWith(fontWeight: wgt);
  return t.copyWith(
    displaySmall: w(t.displaySmall, FontWeight.w800).copyWith(
        fontSize: 34, height: 40 / 34, letterSpacing: -0.5),
    titleLarge:
        w(t.titleLarge, FontWeight.w700).copyWith(fontSize: 22),
    titleMedium:
        w(t.titleMedium, FontWeight.w600).copyWith(fontSize: 17),
    titleSmall:
        w(t.titleSmall, FontWeight.w600).copyWith(fontSize: 13),
    bodyLarge:
        w(t.bodyLarge, FontWeight.w400).copyWith(fontSize: 17),
    bodyMedium:
        w(t.bodyMedium, FontWeight.w400).copyWith(fontSize: 15),
    bodySmall:
        w(t.bodySmall, FontWeight.w400).copyWith(fontSize: 13),
    labelSmall:
        w(t.labelSmall, FontWeight.w600).copyWith(fontSize: 11),
  );
}

ThemeData crescaTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  // Spotify look: near-black surfaces, white type, green resting
  // accent. Nav selection stays white (Spotify marks tabs with tint,
  // green is reserved for actions).
  final scheme = ColorScheme(
    brightness: brightness,
    primary: spotifyGreen,
    onPrimary: Colors.black,
    primaryContainer:
        dark ? const Color(0xFF282828) : const Color(0xFFE8F5E9),
    onPrimaryContainer: dark ? Colors.white : Colors.black,
    secondary: spotifyGreenBright,
    onSecondary: Colors.black,
    secondaryContainer:
        dark ? const Color(0xFF282828) : const Color(0xFFF2F2F6),
    onSecondaryContainer: dark ? Colors.white : Colors.black,
    tertiary: spotifyGreenBright,
    onTertiary: Colors.black,
    error: dark ? const Color(0xFFF15E6C) : const Color(0xFFBA1A1A),
    onError: dark ? Colors.black : Colors.white,
    surface: dark ? const Color(0xFF121212) : const Color(0xFFFFFFFF),
    onSurface: dark ? Colors.white : Colors.black,
    surfaceDim:
        dark ? const Color(0xFF0A0A0A) : const Color(0xFFF2F2F6),
    surfaceBright:
        dark ? const Color(0xFF282828) : const Color(0xFFFFFFFF),
    surfaceContainerLowest:
        dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
    surfaceContainerLow:
        dark ? const Color(0xFF121212) : const Color(0xFFF7F7F9),
    surfaceContainer:
        dark ? const Color(0xFF181818) : const Color(0xFFF2F2F6),
    surfaceContainerHigh:
        dark ? const Color(0xFF1E1E1E) : const Color(0xFFEDEDF0),
    surfaceContainerHighest:
        dark ? const Color(0xFF282828) : const Color(0xFFE8E8EA),
    onSurfaceVariant:
        dark ? spotifySubtext : const Color(0xFF6E6E73),
    outline: dark ? const Color(0xFF2A2A2A) : const Color(0xFFE5E5EA),
    outlineVariant:
        dark ? const Color(0xFF2A2A2A) : const Color(0xFFE5E5EA),
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: dark ? Colors.white : Colors.black,
    onInverseSurface: dark ? Colors.black : Colors.white,
    inversePrimary:
        dark ? const Color(0xFF0D7A37) : spotifyGreen,
    surfaceTint: Colors.transparent,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme:
        crescaTextTheme(brightness == Brightness.light
            ? Typography.englishLike2018
            : Typography.englishLike2018),
    // [D2] iOS push/pop on every platform.
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android:
          CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
    }),
    // iOS switches + dividers read instantly as iOS.
    switchTheme: SwitchThemeData(
      thumbColor:
          WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return Colors.white;
        }
        return null;
      }),
      trackColor:
          WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const Color(0xFF34C759);
        }
        return null;
      }),
    ),
    dividerTheme: const DividerThemeData(
        space: 1, thickness: 0.5),
    splashFactory: NoSplash.splashFactory,
  );
}

/// Liquid-glass container [D3]: frosted blur over content, translucent
/// tint, specular rim (bright top/left hairline fading out), soft lifted
/// shadow. Wrap content that must float above scrolling art/lists.
class Glass extends StatelessWidget {
  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry padding;
  const Glass({
    super.key,
    required this.child,
    this.radius = 20,
    this.blur = 24,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final dark =
        Theme.of(context).brightness == Brightness.dark;
    final tint = dark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.white.withValues(alpha: 0.55);
    final rim = dark
        ? Colors.white.withValues(alpha: 0.22)
        : Colors.white.withValues(alpha: 0.85);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(
            sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            color: tint,
            // Specular rim: bright top + left hairline.
            border: Border(
              top: BorderSide(color: rim, width: 1),
              left: BorderSide(
                  color: rim.withValues(alpha: 0.6), width: 1),
              right: BorderSide(
                  color: rim.withValues(alpha: 0.25), width: 1),
              bottom: BorderSide(
                  color: rim.withValues(alpha: 0.12), width: 1),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black
                    .withValues(alpha: dark ? 0.45 : 0.14),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// iOS frosted tab bar shell [D4]: blur + top hairline, no pill.
class FrostedTabBar extends StatelessWidget {
  final NavigationBar child;
  const FrostedTabBar({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark =
        Theme.of(context).brightness == Brightness.dark;
    return ClipRect(
      child: BackdropFilter(
        filter:
            ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          decoration: BoxDecoration(
            color: (dark ? Colors.black : Colors.white)
                .withValues(alpha: dark ? 0.55 : 0.62),
            border: Border(
              top: BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: 0.6),
                width: 0.5,
              ),
            ),
          ),
          child: Theme(
            data: Theme.of(context).copyWith(
              navigationBarTheme:
                  const NavigationBarThemeData(
                backgroundColor: Colors.transparent,
                // No pill: iOS marks selection with tint alone.
                indicatorColor: Colors.transparent,
                labelBehavior:
                    NavigationDestinationLabelBehavior.alwaysShow,
                // Montserrat runs wide: compact labels keep all five
                // tabs legible at 1080p.
                labelTextStyle: WidgetStatePropertyAll(
                    TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.1)),
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Spotify primary action: green pill, black label/glyph.
ButtonStyle spotifyPlayStyle() => FilledButton.styleFrom(
      backgroundColor: spotifyGreen,
      foregroundColor: Colors.black,
      textStyle: const TextStyle(fontWeight: FontWeight.w700),
    );

/// iOS spinner (Cupertino activity indicator in M3 clothing).
class IosSpinner extends StatelessWidget {
  final double size;
  const IosSpinner({super.key, this.size = 20});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: const CupertinoActivityIndicator(radius: 10),
    );
  }
}

/// Artwork mesh backdrop (Apple-Music/BitChord shape): 4 color blobs at
/// fixed anchors drifting slowly, heavy blur, dark scrim for legibility.
/// Colors ride the theme seed (artwork-palette tinting lands with the
/// palette_generator hookup); blobs rest after each track change.
class MeshBackdrop extends StatefulWidget {
  const MeshBackdrop({super.key});

  @override
  State<MeshBackdrop> createState() => _MeshBackdropState();
}

class _MeshBackdropState extends State<MeshBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift;

  @override
  void initState() {
    super.initState();
    _drift = AnimationController(
        vsync: this, duration: const Duration(seconds: 8))
      ..repeat();
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark =
        Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _drift,
      builder: (_, _) => Stack(
        fit: StackFit.expand,
        children: [
          Container(color: scheme.surface),
          CustomPaint(
            painter: _MeshPainter(
              colors: [
                scheme.primary,
                scheme.secondary,
                scheme.tertiary,
                scheme.primaryContainer,
              ],
              drift: _drift.value,
            ),
          ),
          // Heavy blur melts the blobs into a wash.
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 64, sigmaY: 64),
            child: Container(color: Colors.transparent),
          ),
          // Scrim for legibility (10% → 38% top-to-bottom).
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(
                      alpha: dark ? 0.10 : 0.04),
                  Colors.black.withValues(alpha: 0.38),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MeshPainter extends CustomPainter {
  final List<Color> colors;
  final double drift;
  const _MeshPainter({required this.colors, required this.drift});

  @override
  void paint(Canvas canvas, Size size) {
    final maxSide =
        size.width > size.height ? size.width : size.height;
    final r = 0.62 * maxSide;
    // BitChord anchors: (0.20,0.25) (0.80,0.20) (0.75,0.80) (0.25,0.75).
    final anchors = [
      Offset(size.width * 0.20, size.height * 0.25),
      Offset(size.width * 0.80, size.height * 0.20),
      Offset(size.width * 0.75, size.height * 0.80),
      Offset(size.width * 0.25, size.height * 0.75),
    ];
    // Slow drift (0.45π per 8s cycle), then rest is inherent to repeat.
    final wobble = 0.45 * 3.14159 * drift;
    for (var i = 0; i < 4; i++) {
      final a = anchors[i] +
          Offset(18 * math.sin(wobble + i * 1.7),
              18 * math.cos(wobble * 0.8 + i));
      final paint = Paint()
        ..color = colors[i % colors.length].withValues(alpha: 0.85)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawCircle(a, r / 3.2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MeshPainter old) =>
      old.drift != drift || old.colors != colors;
}

/// Floating pill tab bar (BitChord/Apple-Music shape): glass pill with
/// side gutters (max 440 centered), 5 tint-marked destinations, no
/// indicator pill. Used with Scaffold.extendBody so content flows under
/// the blur.
class FloatingTabBar extends StatelessWidget {
  final int current;
  final ValueChanged<int> onTap;
  const FloatingTabBar(
      {super.key, required this.current, required this.onTap});

  static const _items = [
    (Icons.home_outlined, Icons.home, 'Listen Now'),
    (Icons.trending_up_outlined, Icons.trending_up, 'Trending'),
    (Icons.radio_outlined, Icons.radio, 'Radio'),
    (Icons.library_music_outlined, Icons.library_music, 'Library'),
    (Icons.search_outlined, Icons.search, 'Search'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark =
        Theme.of(context).brightness == Brightness.dark;
    // Spotify marks the active tab white (dark) / black (light);
    // green is reserved for actions.
    final selected = dark ? Colors.white : Colors.black;
    return SafeArea(
      top: false,
      child: Padding(
        padding:
            const EdgeInsets.fromLTRB(10, 0, 10, 10),
        // heightFactor: intrinsic height only. A bare Center expands
        // to the full bottomNav area and Scaffold centers the pill
        // mid-screen (tabs at y~1103 on 2400px). Align keeps the bar
        // pinned to the bottom.
        child: Align(
          alignment: Alignment.center,
          heightFactor: 1.0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Glass(
              radius: 28,
              blur: 22,
              padding: const EdgeInsets.symmetric(
                  vertical: 9, horizontal: 6),
              child: Row(
                children: [
                  for (var i = 0; i < _items.length; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onTap(i),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              i == current
                                  ? _items[i].$2
                                  : _items[i].$1,
                              size: 25,
                              color: i == current
                                  ? selected
                                  : scheme.onSurfaceVariant.withValues(
                                      alpha: 0.65),
                            ),
                            const SizedBox(height: 2),
                            Text(_items[i].$3,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: i == current
                                        ? selected
                                        : scheme.onSurfaceVariant
                                            .withValues(
                                                alpha: 0.65))),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
