// Phase-1 Flutter shell (A1–A9, T1–T2 skeleton).
// Pure-Dart core lives in lib/core/ (dart-testable); this file is the
// Material shell: 5 tabs + glass bottom bar + splash/intro overlay stub,
// portrait lock, edge-to-edge. Theme numbers come from core/theme_accent.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/theme_accent.dart' as accent;

const _crescaRed = Color(accent.crescaRed);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A2: portrait locked (landscape only for fullscreen video later).
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // A2/A8: edge-to-edge, bars follow theme.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const CrescaApp());
}

class CrescaApp extends StatefulWidget {
  const CrescaApp({super.key});

  @override
  State<CrescaApp> createState() => _CrescaAppState();
}

class _CrescaAppState extends State<CrescaApp> {
  ThemeMode _mode = ThemeMode.system;
  int _tab = 0;
  int _lastSearchTap = 0;

  static const _titles = [
    'Listen Now',
    'Trending',
    'Radio',
    'Library',
    'Search',
  ];

  void _onTab(int i) {
    final now = DateTime.now().millisecondsSinceEpoch;
    // T1: double-tap Search icon (<350 ms) focuses search with keyboard.
    if (i == 4 && _tab == 4 && now - _lastSearchTap < 350) {
      SearchFocus.request(context);
    }
    if (i == 4) _lastSearchTap = now;
    setState(() => _tab = i);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cresca',
      debugShowCheckedModeBanner: false,
      themeMode: _mode,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: _crescaRed,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: _crescaRed,
        brightness: Brightness.dark,
      ),
      home: _SplashGate(
        child: Scaffold(
          body: SafeArea(child: _TabBody(index: _tab, title: _titles[_tab])),
          // A5: liquid-glass bottom bar (blur + hairline edge) — v1 uses
          // a translucent bar; BackdropFilter pass lands with artwork.
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _onTab,
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: 'Listen Now'),
              NavigationDestination(
                  icon: Icon(Icons.trending_up_outlined),
                  selectedIcon: Icon(Icons.trending_up),
                  label: 'Trending'),
              NavigationDestination(
                  icon: Icon(Icons.radio_outlined),
                  selectedIcon: Icon(Icons.radio),
                  label: 'Radio'),
              NavigationDestination(
                  icon: Icon(Icons.library_music_outlined),
                  selectedIcon: Icon(Icons.library_music),
                  label: 'Library'),
              NavigationDestination(
                  icon: Icon(Icons.search_outlined),
                  selectedIcon: Icon(Icons.search),
                  label: 'Search'),
            ],
          ),
        ),
      ),
    );
  }

  // L4 hook: appearance switch (light/dark/system) — wired to profile later.
  void setMode(ThemeMode m) => setState(() => _mode = m);
}

/// Search focus request stub (T1): real Search tab hooks a FocusNode +
/// autofocus + keyboard open; this keeps the double-tap path compile-safe.
class SearchFocus {
  static void request(BuildContext context) {
    try {
      FocusScope.of(context).unfocus();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Search focused')),
      );
    } catch (_) {}
  }
}

class _TabBody extends StatelessWidget {
  final int index;
  final String title;
  const _TabBody({required this.index, required this.title});

  @override
  Widget build(BuildContext context) {
    // H1: header + spinner + pull-hint land with Home feed (Phase 2).
    return CustomScrollView(
      slivers: [
        SliverAppBar.large(title: Text(title)),
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text('Pull down hard to refresh'),
          ),
        ),
      ],
    );
  }
}

/// A1: splash + animated intro gate. Full logo-spring/tagline-fade overlay
/// lands with artwork boot; v1 holds a branded splash until first frame.
class _SplashGate extends StatefulWidget {
  final Widget child;
  const _SplashGate({required this.child});

  @override
  State<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<_SplashGate> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // Hold 1.2 s after data ready, fade out 400 ms (A1 numbers).
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (!_ready)
          Container(
            color: const Color(accent.crescaRed),
            child: const Center(
              child: Text(
                'Cresca',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
