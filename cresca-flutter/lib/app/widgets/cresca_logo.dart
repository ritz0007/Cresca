// Brand logo: two TRANSPARENT PNGs (79% alpha), ring colors measured:
// - logo_dark.png  = black ring  -> visible on LIGHT surfaces
// - logo_light.png = white ring  -> visible on DARK surfaces
// (File names describe the ring, not the target mode.)
// Callers pick by brightness and render raw — never clipped, cropped:

import 'package:flutter/material.dart';

/// Asset path for the brand mark at [brightness].
// Black ring for light surfaces, white ring for dark surfaces.
String crescaLogoAsset(Brightness brightness) =>
    brightness == Brightness.dark
        ? 'assets/logo_light.png'
        : 'assets/logo_dark.png';

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
      semanticLabel: 'Cresca Music logo',
    );
  }
}
