// App shell: 5 tabs + glass bottom bar + double-tap-search-focus
// (T1–T2), splash + intro overlay (A1), portrait lock + edge-to-edge
// (A2, in main), crash file-logger hookup (A9, in main).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_screen.dart';
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

  @override
  void initState() {
    super.initState();
    // Rebuild chrome (theme mode) when app state changes appearance.
    try {
      widget.state.addListener(_onState);
    } catch (_) {}
    // A1: hold 1.2s after data ready, fade handled by AnimatedSwitcher.
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _splash = false);
    });
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
    // T1: double-tap Search icon (<350ms) focuses search + keyboard.
    if (i == 4) {
      if (_tab == 4 && now - _lastSearchTap < 350) {
        widget.state.requestSearchFocus();
      }
      _lastSearchTap = now;
    }
    setState(() => _tab = i);
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: MaterialApp(
        title: 'Cresca',
        debugShowCheckedModeBanner: false,
        themeMode: switch (widget.state.appearance) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        // iOS spirit + Spotify voice (see design.dart D1–D4).
        theme: crescaTheme(Brightness.light),
        darkTheme: crescaTheme(Brightness.dark),
        home: Stack(
          children: [
            Scaffold(
              // Content flows under the glass chrome (liquid glass).
              extendBody: true,
              body: IndexedStack(
                index: _tab,
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
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const MiniPlayer(),
                    FloatingTabBar(
                      current: _tab,
                      onTap: _onTab,
                      bottomInset: bottomInset,
                    ),
                  ],
                );
              }),
            ),
            // A1: splash + intro overlay.
            AnimatedSwitcher(
              duration: Duration(
                  milliseconds:
                      widget.state.motionMs(400)),
              child: _splash
                  ? Container(
                      key: const ValueKey('splash'),
                      color: const Color(0xFFFA243C),
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Cresca',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 44,
                                    fontWeight: FontWeight.w800)),
                            SizedBox(height: 8),
                            Text('your music, uninterrupted',
                                style: TextStyle(
                                    color: Colors.white70)),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox.shrink(
                      key: ValueKey('ready')),
            ),
          ],
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
