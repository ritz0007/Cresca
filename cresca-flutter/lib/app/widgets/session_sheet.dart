// YouTube sign-in sheet (G1): embedded login WebView (device-consistent
// UA minus the `; wv` token, JS + DOM storage, third-party cookies),
// Done captures the cookie jar (VISITOR_INFO1_LIVE kept as visitor),
// encrypted on-device session, logout wipes. Native refs:
// SessionSheet.kt (flow/copy), LoginWebView.kt (UA trick),
// YtSessionManager.kt (capture/logout).
//
// Known documented deviation: webview_flutter exposes no
// shouldInterceptRequest, so the native X-Requested-With re-issue trick
// has no twin — the cleaned UA carries the undetectability here. If
// Google ever refuses the embedded flow, the failed hint guides retry.

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../auth/session.dart';
import '../app.dart';
import '../state.dart';

Future<void> openSessionSheet(BuildContext context) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scroll) => SessionSheet(scroll: scroll),
      ),
    );
  } catch (_) {}
}

class SessionSheet extends StatefulWidget {
  final ScrollController scroll;
  const SessionSheet({super.key, required this.scroll});

  @override
  State<SessionSheet> createState() => _SessionSheetState();
}

class _SessionSheetState extends State<SessionSheet> {
  WebViewController? _web;
  bool _capturing = false;
  bool _loginFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final c = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setUserAgent(loginUserAgent(''))
          ..setNavigationDelegate(NavigationDelegate(
            onProgress: (_) {},
            onPageFinished: (_) {},
            onWebResourceError: (_) {},
          ))
          ..loadRequest(Uri.parse(musicUrl));
        if (mounted) setState(() => _web = c);
      } catch (_) {}
    });
  }

  Future<void> _capture(AppState state) async {
    if (_capturing) return;
    setState(() => _capturing = true);
    try {
      String raw = '';
      try {
        final res = await _web?.runJavaScriptReturningResult(
            'document.cookie');
        raw = res?.toString() ?? '';
      } catch (_) {}
      final prev = state.ytSession.visitorData;
      final cap = captureCookies(raw, prev);
      await state.ytSession.saveSession(cap.cookies, cap.visitorData);
      state.syncSessionToRepo();
      if (!mounted) return;
      if (state.ytSession.isLoggedIn) {
        setState(() => _loginFailed = false);
        unawaited(state.pullTasteSeeds());
        if (mounted) Navigator.pop(context);
      } else {
        setState(() => _loginFailed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _loginFailed = true);
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _logout(AppState state) async {
    try {
      await state.logoutYouTube();
      try {
        await WebViewCookieManager().clearCookies();
      } catch (_) {}
      if (mounted) Navigator.pop(context);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) {
        final loggedIn = state.ytSession.isLoggedIn;
        return CustomScrollView(
          controller: widget.scroll,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!loggedIn) ...[
                      const Text(
                          'Sign in with your Google account — your session stays on this device'),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 420,
                        child: _web == null
                            ? const Center(
                                child: CircularProgressIndicator())
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: WebViewWidget(
                                    controller: _web!),
                              ),
                      ),
                      const SizedBox(height: 12),
                      if (_loginFailed)
                        Text(
                          'No session detected — finish signing in above, then tap Done.',
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .error),
                        ),
                      if (_loginFailed) const SizedBox(height: 8),
                      FilledButton(
                        onPressed: _capturing
                            ? null
                            : () => _capture(state),
                        child: Text(
                            _capturing ? 'Saving...' : 'Done'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                    ] else ...[
                      Text('You are signed in on this device',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => _logout(state),
                        child: const Text('Logout'),
                      ),
                    ],
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void unawaited(Future<void> f) {}
}
