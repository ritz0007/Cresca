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

import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:math' as math;

import '../core/motion.dart' as motion;

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
    // Explicit text colors on EVERY style: GoogleFonts text themes
    // carry null colors (inheritance), and an inherited white from
    // any dark ancestor renders section headers invisible on light
    // surfaces. .apply() pins onSurface everywhere (verified by probe:
    // titleLarge.color was null before this).
    textTheme: crescaTextTheme(brightness == Brightness.light
            ? Typography.englishLike2018
            : Typography.englishLike2018)
        .apply(
      displayColor: scheme.onSurface,
      bodyColor: scheme.onSurface,
    ),
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
    // TRUE Regular glass (Axiom): translucent adaptive tint over a
    // bounded backdrop blur. Live paint-bisect on jam16 (SwiftShader):
    // a `ClipRRect` shell around a decorated container (blur or not)
    // swallowed child painting entirely — semantics/hit-tests lived,
    // pixels didn't. A LINEAR `ClipRect` bounding the blur region
    // paints perfectly (tab bar proven on-device), so the material is:
    // ClipRect(bounds) → BackdropFilter(blur) → gradient-tinted
    // rounded-rim Container. Rounded corners come from the decoration;
    // the clip stays square so the blur samples only this element's
    // band, never the whole screen.
    final tint = dark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.55);
    final rim = dark
        ? Colors.white.withValues(alpha: 0.26)
        : Colors.white.withValues(alpha: 0.85);
    final deep = dark
        ? Colors.black.withValues(alpha: 0.55)
        : Colors.white.withValues(alpha: 0.85);
    final child2 = Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tint, deep],
        ),
        borderRadius: BorderRadius.circular(radius),
        // Specular rim hairline (uniform; avoids any Clip*R*ect).
        border: Border.all(color: rim, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black
                .withValues(alpha: dark ? 0.40 : 0.14),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
    // RepaintBoundary confines the backdrop-blur repaint to this
    // element's band; inner content must not add its own blur pass
    // (no stacked blurs — the one static sigma here is the layer).
    return ClipRect(
      child: RepaintBoundary(
        child: BackdropFilter(
          filter: ImageFilter.blur(
              sigmaX: blur, sigmaY: blur),
          child: child2,
        ),
      ),
    );
  }
}

/// iOS frosted tab bar shell [D4]: blur + top hairline, no pill.
/// (Unused legacy shell kept for reference; the real bar is
/// FloatingTabBar's full-bleed Apple glass below.)

/// Apple-glass top bar (Regular variant): bounded-bounded blur band
/// with hairline bottom, title/actions row, top safe area. Use as
/// `appBar: GlassBar(title: …)` (implements PreferredSizeWidget).
class GlassBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget> actions;
  const GlassBar({super.key, required this.title, this.actions = const []});

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final style = TextStyle(
        color: dark ? Colors.white : Colors.black,
        fontSize: 17,
        fontWeight: FontWeight.w700);
    return ClipRect(
      child: RepaintBoundary(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: dark
                  ? [
                      Colors.white.withValues(alpha: 0.10),
                      Colors.white.withValues(alpha: 0.04),
                    ]
                  : [
                      Colors.white.withValues(alpha: 0.82),
                      Colors.white.withValues(alpha: 0.62),
                    ],
            ),
            border: Border(
              bottom: BorderSide(
                color: dark
                    ? Colors.white.withValues(alpha: 0.18)
                    : Colors.black.withValues(alpha: 0.12),
                width: 0.8,
              ),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 56,
              child: NavigationToolbar(
                leading: const SizedBox.shrink(),
                middle: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(title, style: style)),
                ),
                trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ...actions,
                      const SizedBox(width: 8),
                    ]),
                centerMiddle: false,
                middleSpacing: 0,
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// Apple-glass sheet root (Regular): rounded-top translucent material
/// that grows opaque toward its base so list rows stay legible
/// (Axiom: sheets adopt glass automatically; content above stays
/// bold/bright). Wrap a sheet's root widget with this.
///
/// Legibility note: the base stops are deliberately deep (near-opaque)
/// because secondary (onSurfaceVariant) text over mid translucency
/// failed AA. The top stays translucent so the Regular-glass
/// character (content ghosting through) is kept — never a solid fill.
class GlassSheetSurface extends StatelessWidget {
  final Widget child;

  /// Motion kill-switch (AppState.motionOn). Entrance is opacity +
  /// offset only — blur sigma is static, never animated per-frame.
  final bool motionOn;
  const GlassSheetSurface(
      {super.key, required this.child, this.motionOn = true});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = ClipRect(
      child: RepaintBoundary(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.42, 1.0],
                colors: dark
                    ? [
                        Colors.white.withValues(alpha: 0.16),
                        Colors.white.withValues(alpha: 0.12),
                        const Color(0xFA1A1A1A),
                      ]
                    : [
                        Colors.white.withValues(alpha: 0.88),
                        Colors.white.withValues(alpha: 0.92),
                        const Color(0xFCFAFAFA),
                      ],
              ),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(28),
              topRight: Radius.circular(28),
            ),
            border: Border(
              top: BorderSide(
                color: dark
                    ? Colors.white.withValues(alpha: 0.22)
                    : Colors.black.withValues(alpha: 0.10),
                width: 1,
              ),
            ),
          ),
          child: child,
          ),
        ),
      ),
    );
    // Show-only entrance: slide-up + fade (transform/opacity). The
    // BackdropFilter above keeps a static sigma — never animated.
    return SheetEntrance(motionOn: motionOn, child: surface);
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
      child: Container(
        decoration: BoxDecoration(
          color: (dark
              ? const Color(0xF01C1C1E)
              : const Color(0xF8FFFFFF)),
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
///
/// Smooth-scroll rule: the drift is ONE-SHOT per palette/mount (a
/// single ~1.2s glide that rests at the end) — never a perpetual
/// repeat, so idle frames cost zero CustomPaint repaints.
class MeshBackdrop extends StatefulWidget {
  /// Motion kill-switch (AppState.motionOn). Off = static wash, no
  /// drift ticks; palette still swaps instantly (1 ms fade).
  final bool motionOn;
  const MeshBackdrop({super.key, this.motionOn = true});

  @override
  State<MeshBackdrop> createState() => _MeshBackdropState();
}

class _MeshBackdropState extends State<MeshBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift;
  List<Color>? _prev;
  List<Color>? _shown;
  int _paletteKey = 0;

  @override
  void initState() {
    super.initState();
    // One-shot glide (not repeat): settles and rests so idle frames
    // never repaint the wash. Duration via the sheet-enter spec.
    _drift = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: motion.sheetEnterMs * 4));
    if (widget.motionOn) {
      _drift.forward(from: 0);
    } else {
      _drift.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant MeshBackdrop old) {
    super.didUpdateWidget(old);
    // Gate drift on the kill-switch: no per-frame ticks when off.
    // Palette swaps re-glide once from rest, then settle again.
    if (widget.motionOn != old.motionOn) {
      if (widget.motionOn) {
        _drift.forward(from: 0);
      } else {
        _drift.stop();
        _drift.value = 1;
      }
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  static bool _paletteEq(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark =
        Theme.of(context).brightness == Brightness.dark;
    final colors = [
      scheme.primary,
      scheme.secondary,
      scheme.tertiary,
      scheme.primaryContainer,
    ];
    // Palette crossfade on track/theme change: keep the previous wash
    // underneath and fade the new one in over 600 ms (opacity only).
    // The drift re-glides once per palette swap, then rests.
    if (_shown == null) {
      _shown = colors;
    } else if (!_paletteEq(_shown!, colors)) {
      _prev = _shown;
      _shown = colors;
      _paletteKey++;
      if (widget.motionOn) {
        // Post-frame: build must stay side-effect free for the value,
        // but restarting the (already-mounted) controller is safe.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _drift.forward(from: 0);
        });
      }
    }
    final on = widget.motionOn;
    final fadeMs = motion.motionMs(on, 600);
    // 120Hz polish: the legibility scrim is static — it sits OUTSIDE
    // the drift AnimatedBuilder so the gradient box isn't rebuilt every
    // frame. Only the wash repaints on drift ticks.
    final scrim = Container(
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
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: scheme.surface),
        AnimatedBuilder(
      animation: _drift,
      builder: (_, _) {
        Widget wash(List<Color> cs, double drift) {
          // RepaintBoundary confines the soft-gradient paint to the
          // backdrop bounds so drifting blobs never repaint content
          // above. Single paint layer here by design — callers must
          // not stack another filter over this wash, and the falloff
          // is static (drift moves blob centers only, no per-frame
          // MaskFilter blur pass).
          return RepaintBoundary(
            child: CustomPaint(
              painter:
                  _MeshPainter(colors: cs, drift: drift),
            ),
          );
        }
        final drift = on ? _drift.value : 0.0;
        if (_prev != null) {
          return Stack(
            fit: StackFit.expand,
            children: [
              wash(_prev!, on ? drift : 0.0),
              TweenAnimationBuilder<double>(
                key: ValueKey(_paletteKey),
                tween: Tween(begin: 0, end: 1),
                duration: Duration(milliseconds: fadeMs),
                curve: Curves.easeOut,
                onEnd: () {
                  if (mounted) setState(() => _prev = null);
                },
                builder: (_, v, child) => Opacity(
                  opacity: v,
                  child: wash(_shown!, drift),
                ),
              ),
            ],
          );
        }
        return wash(_shown!, drift);
      },
    ),
        scrim,
        // Heavy blur melts the blobs into a wash. The mesh painter
        // already renders soft radial gradients directly, so the
        // extra BackdropFilter pass (compositor-unsafe on SwiftShader
        // emulators: filtered layers stamp over content) is dropped.
      ],
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
      // Soft falloff WITHOUT a per-frame MaskFilter blur (120Hz
      // polish): a radial shader melts each blob into the wash on the
      // GPU with identical anchors/alpha, but no software blur pass
      // ticking at 120 Hz.
      final radius = r / 3.2;
      final base = colors[i % colors.length];
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            base.withValues(alpha: 0.85),
            base.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: a, radius: radius));
      canvas.drawCircle(a, radius, paint);
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

  /// Motion kill-switch (AppState.motionOn). Off = instant selection
  /// swaps, no press scaling.
  final bool motionOn;

  /// System navigation-bar inset (measured ABOVE any SafeArea so the
  /// material can paint over the full nav-bar zone — SafeArea consumes
  /// the inset for its children, which left raw content visible in the
  /// gesture strip).
  final double bottomInset;
  const FloatingTabBar({
    super.key,
    required this.current,
    required this.onTap,
    this.bottomInset = 24,
    this.motionOn = true,
    // U2: visible search affordance. When true, the Search cell grows a
    // "Tap to type" chip above its icon; tapping it focuses the search
    // field (via [onSearchHintTap]) and dismisses the chip for the
    // session. Replaces the old Tooltip/long-press/SnackBar trio.
    this.showSearchHint = false,
    this.onSearchHintTap,
  });

  /// Tap handler for the U2 search hint chip (select Search + focus).
  final VoidCallback? onSearchHintTap;

  /// Whether the Search cell shows the "Tap to type" hint chip.
  final bool showSearchHint;

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
    // Apple Liquid Glass tab bar (Axiom liquid-glass skill, Regular
    // variant): full-bleed rectangular material — no capsule/pill, no
    // side gutters — that extends over the system navigation-bar inset
    // and lets content scroll under it. Adaptive "regular" glass =
    // translucent material + blur + vertical adaptive tint (top sheen
    // eating into dark), NOT a solid fill. Axiom rules applied: glass
    // lives only on the navigation layer; no tint on bar items (white
    // active selection; tinting is reserved for primary actions, so
    // Spotify green stays in buttons); hairline top edge; content
    // dissolves behind the material (app screens keep scroll clearance
    // under the chrome).
    //
    // Compositor note (jam16 paint-bisect): BackdropFilter must not sit
    // under a Clip* node here — glass painted blank when wrapped by
    // ClipRRect. Solo BackdropFilter (own bounds = full-bleed bar rect)
    // is safe; screens were verified pixel-perfect after each step.
    final selected = dark ? Colors.white : Colors.black;
    final bottomInsetV = bottomInset;
    // Label style rides the Theme (labelSmall 11 SB) so text scaling
    // and font-choice stay centralized; selection only recolors.
    final labelBase =
        Theme.of(context).textTheme.labelSmall ??
            const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600);
    // Selection motion: 180 ms tint crossfade (no pill — iOS
    // tint-only rule stays). Transform/opacity only, 60 fps.
    // NOTE (120Hz polish): label fontSize stays fixed (was 10.5↔11 —
    // animating fontSize relaid out every frame); selection reads via
    // color + dot alone. Icon scale derives from the same tint tween
    // (no nested AnimatedScale double-tick).
    final selMs = motion.motionMs(motionOn, motion.tabExitMs);
    final selDur = Duration(milliseconds: selMs);
    // Unselected tabs use full onSurfaceVariant (no dimming alpha):
    // 0.65 alpha measured ~3:1 over the glass and failed AA.
    // The bar's own glass gradient doubles as the scrim behind them.
    final unselected = scheme.onSurfaceVariant;
    // Full-bleed Apple-glass tab bar: the Regular material's adaptive
    // tint is layered translucently and dissolves content behind the
    // bar (scroll-under + darker scrim at the bottom = the "dissolve
    // into glass" edge effect). Bounded blur (same Glass pattern:
    // ClipRect bounds → BackdropFilter, NEVER ClipRRect over the
    // filter) melts scrolled content into the material; the linear
    // clip keeps the blur band on this element alone. Tint + hairline
    // + no-pill rule unchanged. See .opencode/skill/liquid-glass.
    final Widget glass = Container(
      decoration: BoxDecoration(
        // Regular-glass adaptive tint: translucent top sheen into a
        // deeper base. Never a solid fill (Axiom: solid fills break the
        // material character).
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? [
                  Colors.white.withValues(alpha: 0.13),
                  Colors.white.withValues(alpha: 0.05),
                  Colors.black.withValues(alpha: 0.72),
                ]
              : [
                  Colors.white.withValues(alpha: 0.96),
                  Colors.white.withValues(alpha: 0.88),
                  Colors.white.withValues(alpha: 0.98),
                ],
        ),
        // Hairline top edge; sides/bottom end to end (full-bleed).
        border: Border(
          top: BorderSide(
            color: dark
                ? Colors.white.withValues(alpha: 0.20)
                : Colors.black.withValues(alpha: 0.14),
            width: 0.8,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                for (var i = 0; i < _items.length; i++)
                  Expanded(
                    // Semantics expose selection to screen readers;
                    // InkWell gives focus/hover affordance (tap itself
                    // handled here — no outer GestureDetector so the
                    // cell isn't a bare tap target). Tint-only rule
                    // stays: no pill indicator, selection animation
                    // below is untouched.
                    child: Semantics(
                      selected: i == current,
                      button: true,
                      label: _items[i].$3,
                      child: InkWell(
                        borderRadius:
                            BorderRadius.circular(12),
                        onTap: () => onTap(i),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // U2: visible search affordance — a "Tap to
                            // type" chip above the Search icon. Session
                            // flag hides it after first search focus.
                            // Green pill / black text (primary-action
                            // voice); row height wraps content and the
                            // chrome clearance absorbs the growth.
                            if (i == 4 && showSearchHint)
                              Padding(
                                padding: const EdgeInsets.only(
                                    bottom: 4),
                                child: Semantics(
                                  button: true,
                                  label:
                                      'Search hint. Tap to type in the search field',
                                  child: InkWell(
                                    borderRadius:
                                        BorderRadius.circular(
                                            10),
                                    onTap: onSearchHintTap,
                                    child: Container(
                                      padding: const EdgeInsets
                                          .symmetric(
                                              horizontal: 8,
                                              vertical: 3),
                                      decoration: BoxDecoration(
                                        color: spotifyGreen,
                                        borderRadius:
                                            BorderRadius.circular(
                                                10),
                                      ),
                                      child: const Text('Tap to type',
                                          maxLines: 1,
                                          softWrap: false,
                                          overflow: TextOverflow
                                              .ellipsis,
                                          style: TextStyle(
                                              color: Colors.black,
                                              fontSize: 10,
                                              fontWeight:
                                                  FontWeight
                                                      .w700)),
                                    ),
                                  ),
                                ),
                              ),
                            // Selection tint: 0→1 tween lerped per-frame
                            // (transform/opacity-class color lerp). A
                            // ColorTween(begin: unselected) snapped on
                            // deselect (begin is fixed); the 0/1 double
                            // tween retargets from the live value both
                            // ways, so select + deselect both glide.
                            TweenAnimationBuilder<double>(
                              tween: Tween(
                                begin: 0,
                                end: i == current
                                    ? 1.0
                                    : 0.0,
                              ),
                              duration: selDur,
                              curve: Curves.easeOut,
                              builder: (_, t, child) =>
                                  Transform.scale(
                                scale: 0.92 + 0.08 * t,
                                child: Icon(
                                  i == current
                                      ? _items[i].$2
                                      : _items[i].$1,
                                  size: 25,
                                  color: Color.lerp(
                                      unselected,
                                      selected,
                                      t),
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            AnimatedDefaultTextStyle(
                              duration: selDur,
                              curve: Curves.easeOut,
                              style: labelBase.copyWith(
                                  color: i == current
                                      ? selected
                                      : unselected),
                              child: Text(_items[i].$3,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow:
                                      TextOverflow.ellipsis),
                            ),
                            // Subtle selection dot (tint-only rule:
                            // no pill indicator).
                            AnimatedOpacity(
                              opacity:
                                  i == current ? 1.0 : 0.0,
                              duration: selDur,
                              curve: Curves.easeOut,
                              child: Container(
                                margin:
                                    const EdgeInsets.only(
                                        top: 3),
                                width: 4,
                                height: 4,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: selected.withValues(
                                      alpha: 0.8),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Material runs over the system navigation-bar inset.
          SizedBox(height: bottomInsetV),
        ],
      ),
    );
    // Bounded-blur glass (mini-player Glass pattern): ClipRect bounds
    // the BackdropFilter to the bar band; the sigma is static, never
    // animated. Tint + hairline live on the container under the filter.
    //
    // Material wrapper: this bar rides in the app-shell overlay
    // (Stack outside any Scaffold), so raw Text widgets below would
    // otherwise inherit the red/yellow missing-Material error style
    // (yellow underlines under every label).
    return Material(
      type: MaterialType.transparency,
      child: ClipRect(
        child: RepaintBoundary(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: glass,
          ),
        ),
      ),
    );
  }
}

/// Shared press feedback: tap-down to 0.94 over 120 ms, spring back on
/// release (transform only). Off = plain tap (no scaling).
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool motionOn;
  final double pressedScale;
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.motionOn = true,
    this.pressedScale = 0.94,
  });

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final ms = motion.motionMs(widget.motionOn, motion.pressMs);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        if (widget.motionOn && mounted) setState(() => _down = true);
      },
      onTapUp: (_) {
        if (mounted) setState(() => _down = false);
        widget.onTap?.call();
      },
      onTapCancel: () {
        if (mounted) setState(() => _down = false);
      },
      child: AnimatedScale(
        scale: _down
            ? widget.pressedScale
            : motion.motionDouble(widget.motionOn, 1, 1),
        duration: Duration(milliseconds: ms),
        curve: _down ? Curves.easeOut : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}

/// One-shot fade + 12 px slide entrance (transform/opacity only).
/// [delay] staggers siblings; [offsetY] defaults to 12 px down → rest.
class FadeSlide extends StatefulWidget {
  final Widget child;
  final bool motionOn;
  final Duration? duration;
  final Duration delay;
  final double offsetY;
  const FadeSlide({
    super.key,
    required this.child,
    this.motionOn = true,
    this.duration,
    this.delay = Duration.zero,
    this.offsetY = 12,
  });

  @override
  State<FadeSlide> createState() => _FadeSlideState();
}

class _FadeSlideState extends State<FadeSlide> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    final ms = motion.motionMs(widget.motionOn, 1);
    Future<void>.delayed(
      Duration(milliseconds: ms) + widget.delay,
      () {
        if (mounted) setState(() => _shown = true);
      },
    );
    if (!widget.motionOn) _shown = true;
  }

  @override
  Widget build(BuildContext context) {
    final ms = motion.motionMs(
        widget.motionOn, widget.duration?.inMilliseconds ?? motion.sheetEnterMs);
    if (!widget.motionOn) return widget.child;
    return AnimatedOpacity(
      opacity: _shown ? 1 : 0,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: Duration(milliseconds: ms),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(
            0, _shown ? 0 : widget.offsetY, 0),
        // RepaintBoundary: the entrance repaints at 120 Hz for one
        // shot — keep it off the sheet's blur layer.
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}

/// Cheap stagger helper: wraps each child in a [FadeSlide] delayed by
/// `index * staggerMs` (default 40 ms). One-shot, transform/opacity.
class StaggerColumn extends StatelessWidget {
  final List<Widget> children;
  final bool motionOn;
  final int staggerMs;
  final double offsetY;
  final CrossAxisAlignment crossAxisAlignment;
  const StaggerColumn({
    super.key,
    required this.children,
    this.motionOn = true,
    this.staggerMs = 40,
    this.offsetY = 12,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAxisAlignment,
      children: [
        for (var i = 0; i < children.length; i++)
          FadeSlide(
            motionOn: motionOn,
            delay: Duration(
                milliseconds:
                    motion.motionMs(motionOn, staggerMs * i)),
            offsetY: offsetY,
            child: children[i],
          ),
      ],
    );
  }
}

/// Bottom-sheet entrance: slide-up + fade over 320 ms easeOutCubic
/// (exit is the route's 220 ms fade). One-shot on first mount;
/// transform/opacity only, blur untouched.
class SheetEntrance extends StatefulWidget {
  final Widget child;
  final bool motionOn;
  const SheetEntrance(
      {super.key, required this.child, this.motionOn = true});

  @override
  State<SheetEntrance> createState() => _SheetEntranceState();
}

class _SheetEntranceState extends State<SheetEntrance> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
    if (!widget.motionOn) _shown = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.motionOn) return widget.child;
    final ms = motion.motionMs(widget.motionOn, motion.sheetEnterMs);
    final d = Duration(milliseconds: ms);
    return AnimatedOpacity(
      opacity: _shown ? 1 : 0,
      duration: d,
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: d,
        curve: Curves.easeOutCubic,
        transform:
            Matrix4.translationValues(0, _shown ? 0 : 28, 0),
        // RepaintBoundary: one-shot entrance stays off the static
        // BackdropFilter layer behind it.
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}

/// Opacity-only pulse for in-progress surfaces (download/update
/// shimmer): alpha oscillates, never position/blur. Off = static child.
class PulseOpacity extends StatefulWidget {  final Widget child;
  final bool motionOn;
  final bool pulsing;
  const PulseOpacity({
    super.key,
    required this.child,
    this.motionOn = true,
    this.pulsing = true,
  });

  @override
  State<PulseOpacity> createState() => _PulseOpacityState();
}

class _PulseOpacityState extends State<PulseOpacity>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration:
          Duration(milliseconds: motion.shimmerMs),
    );
    // Hoisted curve: allocating a CurvedAnimation per-frame inside the
    // builder churned at 120 Hz; one instance reuses the same mapping.
    _pulse = CurvedAnimation(parent: _c, curve: Curves.easeInOut);
    if (widget.motionOn && widget.pulsing) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant PulseOpacity old) {
    super.didUpdateWidget(old);
    if (widget.motionOn && widget.pulsing) {
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
    if (!widget.motionOn || !widget.pulsing) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(
        opacity: 0.55 + 0.45 * _pulse.value,
        child: widget.child,
      ),
    );
  }
}

// ── Adaptive text foundation ──────────────────────────────────────
// User direction: every text adapts its color to its background for
// guaranteed contrast. All helpers below are pure/static (no
// animation, no BackdropFilter) and compositor-safe.

/// WCAG relative luminance of [c] (sRGB linearized per WCAG 2.x).
double _luminance(Color c) {
  double lin(double v) {
    v /= 255.0;
    return v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * lin(c.r * 255.0) +
      0.7152 * lin(c.g * 255.0) +
      0.0722 * lin(c.b * 255.0);
}

/// WCAG contrast ratio of foreground [fg] over background [bg]:
/// (L1 + 0.05) / (L2 + 0.05). Translucent [fg] is alpha-composited
/// onto [bg] first, so muted colors (black87/white70) measure at
/// their on-screen luminance, not their opaque equivalent.
double _contrast(Color fg, Color bg) {
  final a = fg.a;
  double comp(double f, double b) => a * f + (1 - a) * b;
  final eff = Color.fromARGB(
    255,
    (comp(fg.r, bg.r) * 255).round(),
    (comp(fg.g, bg.g) * 255).round(),
    (comp(fg.b, bg.b) * 255).round(),
  );
  final la = _luminance(eff);
  final lb = _luminance(bg);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Primary text color on [bg]: returns [Colors.black] or [Colors.white],
/// whichever gives the HIGHER WCAG contrast ratio against [bg].
///
/// Contrast guarantee: the winner always scores ≥ ~4.5:1 on opaque
/// backgrounds (the black/white pair brackets every luminance, so the
/// max of the two ratios is at least 4.5:1 for fully-opaque [bg]).
/// Translucent [bg] blends with content behind it, so callers over
/// artwork/photos should layer [TextScrim] underneath instead of
/// relying on the raw surface color.
Color textOn(Color bg) {
  final blackC = _contrast(Colors.black, bg);
  final whiteC = _contrast(Colors.white, bg);
  return blackC >= whiteC ? Colors.black : Colors.white;
}

/// Secondary text color on [bg]: the higher-contrast of black87 /
/// white70 against [bg].
///
/// Contrast guarantee with fallback: muted colors intentionally trade
/// ratio for hierarchy, so if NEITHER candidate reaches 4.5:1 the
/// result falls back to [textOn](bg) (full-contrast primary) to stay
/// legible. Either way the returned color is the most legible of the
/// secondary pair, and never worse than primary text.
Color subtextOn(Color bg) {
  const black87 = Color(0xDD000000);
  const white70 = Color(0xB3FFFFFF);
  final blackC = _contrast(black87, bg);
  final whiteC = _contrast(white70, bg);
  if (blackC < 4.5 && whiteC < 4.5) return textOn(bg);
  return blackC >= whiteC ? black87 : white70;
}

/// Text that adapts its color to [background] for guaranteed contrast.
///
/// Merges with the ambient [DefaultTextStyle] (size/weight preserved —
/// only the color is overridden), so it respects the Montserrat scale
/// and text-scaling. Pass [secondary] for hierarchy text (falls back
/// to primary contrast when muted colors can't reach 4.5:1).
class AdaptiveText extends StatelessWidget {
  final String data;
  final Color background;
  final TextStyle? style;
  final bool secondary;
  final TextAlign? align;
  final int? maxLines;
  final TextOverflow? overflow;
  const AdaptiveText({
    super.key,
    required this.data,
    required this.background,
    this.style,
    this.secondary = false,
    this.align,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    return Text(
      data,
      style: base.copyWith(
        color: secondary ? subtextOn(background) : textOn(background),
      ),
      textAlign: align,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

/// Static gradient scrim behind text over artwork/photos where the
/// background color is unknown (album art, mesh washes, thumbnails).
///
/// Compositor-safe: plain [DecoratedBox] gradient only — no
/// BackdropFilter, no per-frame work. [radius] rounds the gradient via
/// the decoration itself (no clip node needed unless the child can
/// overflow, in which case callers wrap with [ClipRect]).
class TextScrim extends StatelessWidget {
  final Widget child;
  final List<Color> scrim;
  final List<double>? stops;
  final AlignmentGeometry begin;
  final AlignmentGeometry end;
  final BorderRadius? radius;
  final EdgeInsetsGeometry padding;
  const TextScrim({
    super.key,
    required this.child,
    // Light bottom-weighted wash: the text zone (bottom ~35%) gets a
    // soft lift over ANY artwork, bright concert lights included.
    // Stops pin a SHORT dark zone instead of washing the whole card —
    // legibility rides the text shadow + AdaptiveText, not a black
    // wash. Light placeholders stay dark green (track_row fallback),
    // so white titles never sit on white.
    this.scrim = const [
      Color(0x99000000),
      Color(0x52000000),
      Colors.transparent
    ],
    this.stops = const [0.0, 0.35, 0.75],
    this.begin = Alignment.bottomCenter,
    this.end = Alignment.topCenter,
    this.radius,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: begin,
          end: end,
          colors: scrim,
          stops: stops,
        ),
        borderRadius: radius,
      ),
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }
}

/// Primary text color on [Glass]/[GlassSheetSurface] material.
/// Derived from the theme's [ColorScheme.onSurface] (never hardcoded),
/// which is the AA-verified foreground for translucent surfaces:
/// white in dark mode, black in light mode.
Color glassText(bool dark) =>
    crescaTheme(dark ? Brightness.dark : Brightness.light)
        .colorScheme
        .onSurface;

/// Secondary text color on [Glass]/[GlassSheetSurface] material.
/// Derived from the theme's [ColorScheme.onSurfaceVariant] (never
/// hardcoded): spotifySubtext grey in dark mode, system grey in light
/// mode — both AA-verified against the sheet's near-opaque base stops.
Color glassSubtext(bool dark) =>
    crescaTheme(dark ? Brightness.dark : Brightness.light)
        .colorScheme
        .onSurfaceVariant;
