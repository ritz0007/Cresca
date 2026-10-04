---
name: Liquid Glass (Cresca)
description: Apple Liquid Glass material implementation rules used across the Cresca Flutter app — Regular vs Clear variants, bar/full-bleed chrome, tinting, legibility, scroll-edge dissolve, accessibility and compositor-safety notes. Loaded when touching lib/app/design.dart, bars, sheets, or any glass/material work.
---

# Liquid Glass — implementation rules (Axiom liquid-glass, adapted)

Source: CharlesWiltgen/Axiom `axiom-design` skills (liquid-glass.md + liquid-glass-ref.md), MIT. Adapted for the Cresca Flutter port. Full reference text: `liquid-glass-ref.md` in this folder.

## Core rules that bind Cresca

1. **Glass lives on the navigation layer only.** Bars, chrome, discs around actions — yes. Content cards, list rows, images — never (no glass on content).
2. **Regular variant everywhere** (95% case). Clear only over media-rich content + dimming layer + bold/bright content above. Never mix Regular and Clear in one interface.
3. **No solid fills on glass elements.** Material = translucent adaptive tint (gradient/multi-stop), never `Color(0xFF...)` opaque. Tint primary actions only (Apple `glassEffect(.tint)`) → in Cresca that means: Spotify green stays in buttons; bar items are white/gray with NO tint.
4. **Adaptive behavior beats hardcoded looks.** Small elements (bars) flip light/dark by background; large plates don't flip, they adapt depth. No hardcoded shadows/opacity where adaptivity matters.
5. **Scroll-edge dissolve.** Where chrome meets scrolling content, the material runs full-bleed and content scrolls under it (screens keep clearance under chrome — Cresca scroll pads ~190 logical). Hard edge for pinned rows, soft fade otherwise.
6. **Full-bleed bars over the nav-bar inset** (user direction Oct 2026): the tab bar is a rectangular material with a hairline top edge, extends over the system navigation-bar inset, no capsule/pill shape.
7. Hairline edges (top rim) + soft shadow make glass read as glass even when blur is unavailable. Never glass-on-glass stacking.

## Flutter implementation details (Cresca-specific)

- `Glass` (lib/app/design.dart) is the single material primitive: Container + `BorderRadius` decoration + `Border.all` hairline + soft shadow. No `ClipRRect`, no nested clips.
- **Compositor trap (jam16 SwiftShader, bisected):** a `ClipRRect` shell around a decorated container made ALL child painting vanish (semantics + hit-tests stayed alive but pixels never painted). A `BackdropFilter` under a `Clip*` node did the same. Keep: solo `BackdropFilter` (own bounds) is fine; never wrap it in `ClipRRect`. Any future "invisible but tappable" chrome = check for Clip wrappers first.
- Bottom chrome lives ONCE in `app.dart` (Align-bottomed Stack: MiniPlayer above FloatingTabBar). Screens removed their per-screen `MiniPlayer` Scaffold slots — duplicated chrome overlapped and looked empty.
- Bar material covers the system inset inside its own layout (`SizedBox(height: MediaQuery.padding.bottom)` under the tab row), so apps' own SafeArea inside chrome stays `top:false` and the glass really runs over the nav-bar area.
- Semantics debug (kDebugMode `ensureSemantics()` for uiautomator) draws yellow double-underline markers under labels — release builds are clean; don't chase it as a style bug.

## Audit checklist for any new glass surface

- [ ] Navigation layer only, Regular variant
- [ ] Translucent adaptive tint (no solid fill), hairline rim, soft shadow
- [ ] No tint-per-item on bars; white/inactive-gray selection
- [ ] Content scrolls under; clearance ≥ material height + inset
- [ ] No Clip*R*ect/ClipRect hugging BackdropFilter
- [ ] Light + dark both legible; reduced-transparency fallback = raise tint alpha (frostier)
- [ ] Hits the eye as "the same material" as every other Cresca chrome piece
