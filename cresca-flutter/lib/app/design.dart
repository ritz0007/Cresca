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

/// Cresca red — brand primary in both themes (A3 default song-null).
const crescaRed = Color(0xFFFA243C);

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
  final seed = ColorScheme.fromSeed(
      seedColor: crescaRed, brightness: brightness);
  final scheme = brightness == Brightness.light
      ? seed.copyWith(
          surface: const Color(0xFFFFFFFF),
          surfaceContainerHighest: const Color(0xFFF2F2F6),
        )
      : seed.copyWith(
          surface: const Color(0xFF000000),
          surfaceContainerHighest: const Color(0xFF1C1C1E),
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
