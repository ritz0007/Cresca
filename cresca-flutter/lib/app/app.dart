// App shell: 5 tabs + glass bottom bar + double-tap-search-focus
// (T1–T2, first re-tap shows a one-time focus hint), splash + intro
// overlay (A1, readiness-gated), portrait lock + edge-to-edge
// (A2, in main), crash file-logger hookup (A9, in main).
//
// Shell motion (transform/opacity only, 60fps, compositor-safe):
// - Tabs cross-fade + rise 12px (enter 220ms easeOutCubic, exit 180ms
//   easeIn). All five tab subtrees stay mounted behind stable Offstage
//   wrappers (same retention guarantee as IndexedStack) so scroll and
//   screen state survive switches. Inactive tabs are additionally
//   wrapped in ExcludeSemantics, so only the visible tab (plus the
//   briefly exiting one mid-fade) stays in the a11y tree.
// - Bottom chrome: MiniPlayer fades + rises in/out on track load;
//   FloatingTabBar cross-fades selection and carries a subtle bar-wide
//   press scale. The chrome Column is measured post-frame and published
//   via BottomChromeScope, so lists consume the live clearance instead
//   of the estimator. No edits to design.dart.
// - Splash: logo scale-in 0.92→1.0 (400ms easeOutBack, never clipped)
//   + tagline fade (250ms delay, 600ms), minimum 1200ms brand hold,
//   then fade-out once AppState.homeStatus leaves loading (8s
//   failsafe forces it). Motion-off skips the timed hold (1ms via
//   motionMs) and dismisses on readiness with a 150ms minimum
//   crossfade instead of a 1ms flash.
// - Every other duration flows through AppState.motionMs so motion-off
//   collapses each spec to a 1ms step.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/motion.dart';
import 'screens/home_screen.dart';
import 'widgets/cresca_logo.dart';
import 'screens/library_screen.dart';
import 'screens/radio_screen.dart';
import 'screens/search_screen.dart';
import 'screens/trending_screen.dart';
import 'state.dart';
import 'design.dart';
import 'widgets/mini_player.dart';

/// Inherited access to the app state (rows, sheets, screens).
class AppScope extends InheritedWidget {
  final AppState state;
  const AppScope({super.key, required this.state, required super.child});

  static AppState of(BuildContext context) {
    try {
      final scope =
          context.dependOnInheritedWidgetOfExactType<AppScope>();
      if (scope != null) return scope.state;
    } catch (_) {}
    throw StateError('AppScope not found');
  }

  @override
  bool updateShouldNotify(AppScope old) => old.state != state;
}

/// Motion-off floor for the splash crossfade (P2 fix): when motion is
/// off, a 1ms splash fade reads as a broken flash, so both the overlay
/// fade and the shell AnimatedSwitcher use this 150ms minimum instead.
const int _splashMinFadeMs = 150;

/// Measured bottom-chrome clearance (U1 foundation).
///
/// Screens used to hard-code a magic bottom constant for list clearance. That
/// constant drifts from the real chrome (MiniPlayer presence +
/// FloatingTabBar height + system inset all vary). The shell measures
/// the chrome Column post-frame (see [_CrescaAppState]) and publishes
/// it here, above the tab bodies, so lists consume the live value:
///
/// ```dart
/// padding: EdgeInsets.only(
///   bottom: BottomChromeScope.clearanceOf(context),
/// );
/// ```
///
/// Until the first measurement lands, [clearance] falls back to
/// [estimate] (inset + tab bar + optional MiniPlayer), so the first
/// frame never overlaps. The old magic constant is deleted — do not
/// reintroduce magic numbers.
class BottomChromeScope extends InheritedWidget {
  /// Base estimates used by [estimate] (insets added on top).
  static const double tabBarBase = 76.0;
  static const double miniPlayerBase = 68.0;

  /// Measured chrome height in logical pixels (0 until first frame).
  final double chromeHeight;

  /// System bottom inset measured under MaterialApp's MediaQuery.
  final double bottomInset;

  /// Whether a track is loaded (MiniPlayer slot occupied).
  final bool hasTrack;

  const BottomChromeScope({
    super.key,
    required this.chromeHeight,
    required this.bottomInset,
    required this.hasTrack,
    required super.child,
  });

  /// Rough pre-layout estimate (inset + bar + optional MiniPlayer).
  static double estimate(
          {required double bottomInset, required bool hasTrack}) =>
      bottomInset + tabBarBase + (hasTrack ? miniPlayerBase : 0.0);

  /// Live clearance: measured height once known, else [estimate]
  /// (inset + bar + optional MiniPlayer) so the first frame is safe.
  double get clearance => chromeHeight > 0
      ? chromeHeight
      : estimate(bottomInset: bottomInset, hasTrack: hasTrack);

  static BottomChromeScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BottomChromeScope>();

  static BottomChromeScope of(BuildContext context) {
    final scope = maybeOf(context);
    if (scope == null) throw StateError('BottomChromeScope not found');
    return scope;
  }

  /// Drop-in clearance: measured chrome when available, [estimate]
  /// otherwise. Never throws (safe when no scope is found — the
  /// fallback assumes a track is loaded so the pad errs on the safe
  /// side instead of overlapping).
  static double clearanceOf(BuildContext context) =>
      maybeOf(context)?.clearance ??
      estimate(bottomInset: 0, hasTrack: true);

  @override
  bool updateShouldNotify(BottomChromeScope old) =>
      old.chromeHeight != chromeHeight ||
      old.bottomInset != bottomInset ||
      old.hasTrack != hasTrack;
}

class CrescaApp extends StatefulWidget {
  final AppState state;
  const CrescaApp({super.key, required this.state});

  @override
  State<CrescaApp> createState() => _CrescaAppState();
}

class _CrescaAppState extends State<CrescaApp> {
  int _tab = 0;
  int _lastSearchTap = 0;
  bool _splash = true;
  // P1: measured bottom-chrome height (MiniPlayer + tab bar + inset),
  // published via BottomChromeScope so lists consume live clearance.
  double _chromeHeight = 0.0;
  final GlobalKey _chromeKey = GlobalKey();
  // P2: messenger key lets _onTab (no BuildContext) show the one-time
  // Search double-tap hint without touching the T1 focus path.
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  bool _searchHintShown = false;

  @override
  void initState() {
    super.initState();
    // Rebuild chrome (theme mode) when app state changes appearance.
    try {
      widget.state.addListener(_onState);
    } catch (_) {}
    // A1: the splash timeline (hold → fade-out → onDone) now lives in
    // _SplashOverlay. No timer here.
    // P1: belt-and-braces first chrome measurement (size notifications
    // cover every later change).
    _scheduleChromeMeasure();
  }

  @override
  void didUpdateWidget(covariant CrescaApp old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      try {
        old.state.removeListener(_onState);
      } catch (_) {}
      try {
        widget.state.addListener(_onState);
      } catch (_) {}
    }
  }

  void _onState() {
    try {
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    try {
      widget.state.removeListener(_onState);
    } catch (_) {}
    super.dispose();
  }

  void _onTab(int i) {
    final now = DateTime.now().millisecondsSinceEpoch;
    // T1: double-tap Search icon (<doubleTapMs) focuses search +
    // keyboard. P2: the gesture was undiscoverable, so the first
    // single re-tap on an already-active Search tab shows a one-time
    // hint instead of silently doing nothing. T1 timing is untouched.
    if (i == 4) {
      if (_tab == 4) {
        if (now - _lastSearchTap < doubleTapMs) {
          widget.state.requestSearchFocus();
        } else if (!_searchHintShown) {
          _searchHintShown = true;
          _showSearchHint();
        }
      }
      _lastSearchTap = now;
    }
    // Per-visit taste rotation: every arrival on Home re-ranks Top
    // Picks from the accumulated pool (instant, no network). Re-taps
    // on the active Home tab leave the list alone.
    if (i == 0 && _tab != 0) {
      try {
        widget.state.visitHome();
      } catch (_) {}
    }
    // Same for Trending arrivals: charts visibly rotate every visit.
    if (i == 1 && _tab != 1) {
      try {
        widget.state.visitTrending();
      } catch (_) {}
    }
    setState(() => _tab = i);
  }

  void _showSearchHint() {
    try {
      _messengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Semantics(liveRegion: true, child: Text('Tip: tap Search again to focus the search field')),
          // Content display timeout, not animation — kept readable even
          // with motion off.
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {}
  }

  /// Reads the chrome Column size post-frame and publishes it via
  /// BottomChromeScope. No-ops until layout exists; only rebuilds when
  /// the height actually moves (>0.5dp).
  void _scheduleChromeMeasure() {
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureChrome());
    } catch (_) {}
  }

  void _measureChrome() {
    try {
      final ctx = _chromeKey.currentContext;
      if (ctx == null || !mounted) return;
      final box = ctx.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        final h = box.size.height;
        if ((h - _chromeHeight).abs() > 0.5 && mounted) {
          setState(() => _chromeHeight = h);
        }
      }
    } catch (_) {}
  }

  void _dismissSplash() {
    try {
      if (mounted) setState(() => _splash = false);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'Cresca Music',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: _messengerKey,
        themeMode: switch (state.appearance) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        // iOS spirit + Spotify voice (see design.dart D1–D4).
        theme: crescaTheme(Brightness.light),
        darkTheme: crescaTheme(Brightness.dark),
        // P1: BottomChromeScope sits above the tab bodies (Builder grabs
        // MaterialApp's MediaQuery) so lists read live chrome clearance
        // instead of a magic constant. Rebuilds with _onState
        // keep hasTrack fresh as tracks load/clear.
        home: Builder(builder: (shellCtx) {
          final shellInset = MediaQuery.of(shellCtx).padding.bottom;
          final shellHasTrack =
              state.controller.engine.current != null;
          return BottomChromeScope(
            chromeHeight: _chromeHeight,
            bottomInset: shellInset,
            hasTrack: shellHasTrack,
            child: Stack(
              children: [
            Scaffold(
              // Content flows under the glass chrome (liquid glass).
              extendBody: true,
              body: _TabStack(
                index: _tab,
                enterMs: state.motionMs(tabEnterMs),
                exitMs: state.motionMs(tabExitMs),
                children: const [
                  HomeScreen(),
                  TrendingScreen(),
                  RadioScreen(),
                  LibraryScreen(),
                  SearchScreen(),
                ],
              ),
              // NOTE: bottom chrome (mini player above the floating
              // glass pill) is stacked here ONCE. Screens no longer
              // carry their own MiniPlayer in a Scaffold
              // bottomNavigationBar slot — that rendered a second
              // full-screen scaffold bottom chrome straight on top of
              // the pill (overlapping bars → misaligned/empty look).
            ),
            // Shared bottom chrome: mini player pinned above the Apple
            // full-bleed glass bar. Inset is measured HERE (above the
            // bar), so the material covers the whole navigation zone —
            // no SafeArea, no gutters (Axiom full-bleed bar + user
            // direction: use the entire area over the nav bar).
            Align(
              alignment: Alignment.bottomCenter,
              child: Builder(builder: (context) {
                final bottomInset =
                    MediaQuery.of(context).padding.bottom;
                // P1: SizeChangedLayoutNotifier reports every real size
                // change (MiniPlayer slot collapse/expand, inset change);
                // _chromeKey lets us read the height post-frame. Enter/
                // exit animations are transform/opacity only, so they
                // never fire this.
                return NotificationListener<
                    SizeChangedLayoutNotification>(
                  onNotification: (_) {
                    _scheduleChromeMeasure();
                    return true;
                  },
                  child: SizeChangedLayoutNotifier(
                    child: Column(
                      key: _chromeKey,
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    // MiniPlayer enter/exit: fade + rise, 220ms. Driven
                    // by AppState (track loaded or not); opacity and
                    // fractional translation only — no layout thrash.
                    AnimatedBuilder(
                      animation: state,
                      builder: (_, _) {
                        final hasTrack = state.controller.engine.current !=
                            null;
                        final ms = state.motionMs(tabEnterMs);
                        return AnimatedSlide(
                          duration: Duration(milliseconds: ms),
                          curve: Curves.easeOutCubic,
                          offset: hasTrack
                              ? Offset.zero
                              : const Offset(0, 0.4),
                          child: AnimatedOpacity(
                            duration: Duration(milliseconds: ms),
                            curve: Curves.easeOutCubic,
                            opacity: hasTrack ? 1.0 : 0.0,
                            // 120Hz polish: chrome fade stays off list
                            // paint — MiniPlayer repaints behind its own
                            // boundary while rising in/out.
                            child: const RepaintBoundary(
                                child: MiniPlayer()),
                          ),
                        );
                      },
                    ),
                    // Tab selection: subtle bar cross-fade (the bar is
                    // stateless, so remounting it per tab is free) under
                    // a bar-wide press scale. Passive Listener only —
                    // FloatingTabBar keeps its own gestures.
                    _PressScale(
                      scale: 0.97,
                      durationMs: state.motionMs(pressMs),
                      child: AnimatedSwitcher(
                        duration: Duration(
                            milliseconds:
                                state.motionMs(tabExitMs)),
                        transitionBuilder: (child, anim) =>
                            FadeTransition(
                                opacity: anim, child: child),
                        child: KeyedSubtree(
                          key: ValueKey<int>(_tab),
                          // P2: visible affordance for the T1 double-tap
                          // gesture — long-press anywhere on the bar shows
                          // the hint (Tooltip also feeds screen readers).
                          // The one-time SnackBar in _onTab covers the
                          // first single re-tap on Search.
                          child: Tooltip(
                            message:
                                'Double-tap Search to focus the search field',
                            child: FloatingTabBar(
                              current: _tab,
                              onTap: _onTab,
                              bottomInset: bottomInset,
                              motionOn: state.motionOn,
                            ),
                          ),
                        ),
                      ),
                    ),
                      ],
                    ),
                  ),
                );
              }),
            ),
            // A1: splash + intro overlay (staggered timeline inside).
            // P2: motion-off uses the 150ms minimum crossfade, not 1ms.
            AnimatedSwitcher(
              duration: Duration(
                  milliseconds: state.motionOn
                      ? splashFadeMs
                      : _splashMinFadeMs),
              child: _splash
                  ? _SplashOverlay(
                      key: const ValueKey('splash'),
                      state: state,
                      onDone: _dismissSplash,
                    )
                  : const SizedBox.shrink(
                      key: ValueKey('ready')),
            ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

/// Retentive tab switcher: fade + 12px rise on enter, quick fade on
/// exit. Every tab child keeps the exact same wrapper chain
/// (ExcludeSemantics → Offstage → Opacity → Transform) in tab order on
/// every frame, so Flutter never remounts a tab subtree — scroll
/// positions and screen state survive switches, exactly as with
/// IndexedStack (which this mirrors: all children laid out, hidden
/// ones offstage). Unlike a raw IndexedStack, inactive tabs are
/// excluded from the semantics tree (P1 a11y fix); briefly exiting
/// tabs stay included mid-fade (a set, so rapid A→B→C switches never
/// pop a mid-fade tab offstage) so visible content never drops from
/// screen readers.
class _TabStack extends StatefulWidget {
  final int index;
  final List<Widget> children;
  final int enterMs;
  final int exitMs;
  const _TabStack({
    required this.index,
    required this.children,
    required this.enterMs,
    required this.exitMs,
  });

  @override
  State<_TabStack> createState() => _TabStackState();
}

class _TabStackState extends State<_TabStack>
    with TickerProviderStateMixin {
  late int _current = widget.index;
  // Exiting tabs stay mounted until the shared exit fade completes, so
  // rapid A→B→C switches never pop a mid-fade tab offstage (the dropped
  // tab would vanish for one frame with a single int? slot).
  final Set<int> _exiting = <int>{};
  late final AnimationController _enter;
  late final AnimationController _exit;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      value: 1,
      duration: Duration(milliseconds: widget.enterMs),
    );
    _exit = AnimationController(
      vsync: this,
      value: 0,
      duration: Duration(milliseconds: widget.exitMs),
    );
    _exit.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _exiting.clear());
      }
    });
  }

  @override
  void didUpdateWidget(covariant _TabStack old) {
    super.didUpdateWidget(old);
    final enterDur = Duration(milliseconds: widget.enterMs);
    final exitDur = Duration(milliseconds: widget.exitMs);
    if (_enter.duration != enterDur) _enter.duration = enterDur;
    if (_exit.duration != exitDur) _exit.duration = exitDur;
    if (widget.index != _current) {
      setState(() {
        _exiting.add(_current);
        _exiting.remove(widget.index);
        _current = widget.index;
      });
      _exit.forward(from: 0);
      _enter.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_enter, _exit]),
      builder: (_, _) {
        final e = Curves.easeOutCubic.transform(_enter.value);
        final x = Curves.easeIn.transform(_exit.value);
        return Stack(
          fit: StackFit.expand,
          children: [
            for (var i = 0; i < widget.children.length; i++)
              // P1 a11y: Offstage hides visually, ExcludeSemantics drops
              // inactive tabs from the semantics tree (a raw IndexedStack
              // keeps all five reachable). The exiting tab stays
              // included during its 180ms fade-out.
              ExcludeSemantics(
                excluding: i != _current && !_exiting.contains(i),
                child: Offstage(
                  offstage: i != _current && !_exiting.contains(i),
                  // 120Hz polish: each tab paints behind its own
                  // boundary so the enter/exit opacity fade never
                  // repaints sibling tab subtrees at 120 Hz.
                  child: RepaintBoundary(
                  child: Opacity(
                    opacity: i == _current
                        ? e
                        : (_exiting.contains(i) ? 1 - x : 1),
                    // 12px upward drift on enter; transform-only.
                    child: Transform.translate(
                      offset: i == _current
                          ? Offset(0, 12 * (1 - e))
                          : Offset.zero,
                      child: widget.children[i],
                    ),
                  ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Press-scale wrapper: 1.0 → [scale] over [durationMs] on tap-down,
/// spring back on up/cancel. A passive [Listener] (never a gesture
/// competitor) drives an [AnimatedScale], so wrapped gesture targets
/// keep their own hit-testing. Defaults match the motion catalog
/// (pressedScale 0.94, pressMs 120ms); callers may pass a subtler
/// scale (e.g. the bar-wide 0.97) where a full press would read wrong.
class _PressScale extends StatefulWidget {
  final Widget child;
  final double scale;
  final int durationMs;
  const _PressScale({
    required this.child,
    this.scale = pressedScale,
    required this.durationMs,
  });

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    // Kill-switch: motion-off never scales (1ms flash would read as a
    // flicker on the full-width bar). Listener stays passive either way.
    if (widget.durationMs <= 1) {
      if (_pressed) _pressed = false;
      return widget.child;
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1.0,
        duration: Duration(milliseconds: widget.durationMs),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// A1 splash overlay: staggered logo scale-in (0.92→1.0, 400ms
/// easeOutBack — no Clip* ancestor, so the overshoot never clips) +
/// tagline fade (250ms delay, 600ms), minimum 1200ms brand hold, then a
/// fade-out of the whole splash once AppState.homeStatus leaves
/// loading (P2 readiness gate — no more fixed dismiss while content is
/// still skeleton; 8s failsafe forces the fade so a stalled load can
/// never trap the app). Fade is 400ms with motion on, 150ms minimum
/// crossfade with motion off (never the 1ms flash). Logo/tag/hold
/// still collapse via AppState.motionMs. Opacity/scale only; the
/// theme-sensitive logo mark + wordmark read in both modes.
class _SplashOverlay extends StatefulWidget {
  final AppState state;
  final VoidCallback onDone;
  const _SplashOverlay(
      {super.key, required this.state, required this.onDone});

  @override
  State<_SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<_SplashOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _logo;
  late final AnimationController _tag;
  late final AnimationController _fade;
  late final Animation<double> _logoScale;
  late final Animation<double> _tagOpacity;
  late final Animation<double> _fadeOpacity;
  bool _holdDone = false;
  bool _fading = false;

  /// Readiness gate (P2): AppState exposes homeStatus, so the splash
  /// lifts when content is actually painted (ready or honest error),
  /// not on a blind timer.
  bool get _ready => widget.state.homeStatus != HomeStatus.loading;

  void _maybeFade() {
    if (_fading || !_holdDone || !mounted) return;
    if (!_ready) return;
    _fading = true;
    try {
      _fade.forward();
    } catch (_) {
      try {
        widget.onDone();
      } catch (_) {}
    }
  }

  void _onStateTick() {
    // Fires on every AppState notify; _maybeFade no-ops until both the
    // brand hold elapsed and homeStatus leaves loading.
    _maybeFade();
  }

  @override
  void initState() {
    super.initState();
    final m = widget.state.motionMs;
    try {
      widget.state.addListener(_onStateTick);
    } catch (_) {}
    _logo = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: m(400)),
    );
    _tag = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: m(taglineFadeMs)),
    );
    _fade = AnimationController(
      vsync: this,
      // P2: 150ms minimum crossfade with motion off, not a 1ms cut.
      duration: Duration(
          milliseconds: widget.state.motionOn
              ? splashFadeMs
              : _splashMinFadeMs),
    );
    _logoScale = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _logo, curve: Curves.easeOutBack),
    );
    _tagOpacity =
        CurvedAnimation(parent: _tag, curve: Curves.easeOut);
    _fadeOpacity = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(parent: _fade, curve: Curves.easeOut),
    );
    _fade.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        try {
          widget.onDone();
        } catch (_) {}
      }
    });
    _logo.forward();
    Future<void>.delayed(Duration(milliseconds: m(taglineDelayMs)),
        () {
      if (mounted) _tag.forward();
    });
    // Minimum brand hold (1200ms motion-on; 1ms via motionMs when off —
    // then readiness alone gates the fade). The fade itself starts only
    // via _maybeFade, i.e. hold elapsed AND homeStatus != loading.
    Future<void>.delayed(Duration(milliseconds: m(splashHoldMs)), () {
      if (!mounted) return;
      _holdDone = true;
      _maybeFade();
    });
    // Failsafe: a stalled home load must never trap the splash.
    Future<void>.delayed(const Duration(seconds: 8), () {
      if (!mounted || _fading) return;
      _fading = true;
      try {
        _fade.forward();
      } catch (_) {
        try {
          widget.onDone();
        } catch (_) {}
      }
    });
  }

  @override
  void dispose() {
    try {
      widget.state.removeListener(_onStateTick);
    } catch (_) {}
    _logo.dispose();
    _tag.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge([_logo, _tag, _fade]),
      builder: (_, _) => Opacity(
        opacity: _fadeOpacity.value,
        child: Material(
          color: scheme.surface,
          child: Center(
            // No Clip* wrapper: easeOutBack overshoots past 1.0 and
            // must never be clipped.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Brand lockup: theme-sensitive logo mark (white
                // surround in light, black in dark) over the matching
                // surface, then the Cresca Music wordmark.
                // Legibility decision (P0 sweep): the wordmark and
                // tagline derive from the surface (never fixed white),
                // so both modes clear the 3:1 large-text bar.
                Transform.scale(
                  scale: _logoScale.value,
                  child: Image.asset(
                    crescaLogoAsset(
                        Theme.of(context).brightness),
                    width: 112,
                    height: 112,
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(height: 14),
                Text('Cresca Music',
                    style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 32,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Opacity(
                  opacity: _tagOpacity.value,
                  child: Text('your music, uninterrupted',
                      style: TextStyle(
                          color: scheme.onSurface
                              .withValues(alpha: 0.7))),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Portrait lock helper (A2; landscape returns with video in Phase 3).
Future<void> lockPortrait() async {
  try {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge);
  } catch (_) {}
}
