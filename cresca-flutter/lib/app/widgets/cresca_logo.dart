// Brand logo: theme-sensitive Cresca Music mark.
//
// The artwork ships as two TRANSPARENT PNGs (only the ring + J mark
// carry pixels; ~80% of the frame is alpha). The ring melts into its
// matching background while the red J pops, so callers pick the
// variant that matches the current brightness and render it raw —
// never clipped, never cropped:
// - light mode  -> assets/logo_light.png (white ring)
// - dark mode   -> assets/logo_dark.png  (black ring)

import 'package:flutter/material.dart';

/// Asset path for the brand mark at [brightness].
String crescaLogoAsset(Brightness brightness) =>
    brightness == Brightness.dark
        ? 'assets/logo_dark.png'
        : 'assets/logo_light.png';

/// Brand mark, sized for its slot (home header, splash, about).
/// Transparent artwork: no clipping — the pixels define the shape.
class CrescaLogo extends StatelessWidget {
  final double size;
  const CrescaLogo({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) {
    final asset =
        crescaLogoAsset(Theme.of(context).brightness);
    return Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
  }
}
