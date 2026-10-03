// App shell: 5 tabs + glass bottom bar + double-tap-search-focus
// (T1–T2), splash + intro overlay (A1), portrait lock + edge-to-edge
// (A2, in main), crash file-logger hookup (A9, in main).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_screen.dart';
import 'screens/search_screen.dart';
import 'screens/trending_screen.dart';
import 'state.dart';

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
    // A1: hold 1.2s after data ready, fade handled by AnimatedSwitcher.
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _splash = false);
    });
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
        themeMode: ThemeMode.system,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFFFA243C),
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFFFA243C),
          brightness: Brightness.dark,
        ),
        home: Stack(
          children: [
            Scaffold(
              body: IndexedStack(
                index: _tab,
                children: const [
                  HomeScreen(),
                  TrendingScreen(),
                  _Placeholder(
                      title: 'Radio',
                      hint:
                          'Saved stations + song radio arrive in Phase 3'),
                  _Placeholder(
                      title: 'Library',
                      hint:
                          'Folders, playlists + downloads arrive in Phase 3'),
                  SearchScreen(),
                ],
              ),
              // A5: liquid-glass bottom bar (translucent + hairline).
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

class _Placeholder extends StatelessWidget {
  final String title;
  final String hint;
  const _Placeholder({required this.title, required this.hint});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(hint, textAlign: TextAlign.center),
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
