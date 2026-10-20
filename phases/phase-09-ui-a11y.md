# Phase 09 — UI a11y + hygiene (Should/Nice)
Scope: `lib/app/widgets/jam_sheet.dart`, `session_sheet.dart`, `downloads_sheet.dart`, `profile_sheet.dart`, `audio_*_sheet.dart`, `cresca_logo.dart`, `lib/app/design.dart:388-435,423-427,914-959`
Tasks:
1. A11y: Semantics on drag handles/buttons/chips/sliders, close buttons on sheets, announce loading.
2. Dedup: one _DelayedSpinner, one drag handle, one PressScale, one _Dissolve, one songs gate in design.dart. Delete FrostedTabBar, dead _EqBars path already in 07 if left.
3. Theme: respect brightness (no forced dark), fix logo asset swap, tiny tab text clip at large scale.
4. Errors: toasts on sheet open/logout/share/update fail, no pop on fail.
Done: TalkBack pass on sheets, duplicate grep one hit each, no silent fails.
