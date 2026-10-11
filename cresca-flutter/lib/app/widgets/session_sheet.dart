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
import '../../core/motion.dart' show motionMs;
import '../app.dart';
import '../design.dart';
import '../state.dart';

Future<void> openSessionSheet(BuildContext context) async {
  try {
    bool motionOn = true;
    try {
      motionOn = AppScope.of(context).motionOn;
    } catch (_) {}
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scroll) => GlassSheetSurface(
          motionOn: motionOn,
          child: SessionSheet(scroll: scroll),
        ),
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
        final ms = state.motionMs(180);
        final d = Duration(milliseconds: ms);
        // Material + entrance come from the GlassSheetSurface above
        // (shared queue_sheet pattern). Keyboard-aware bottom padding
        // keeps Done above the keyboard; SafeArea clears the gesture
        // strip. Sign-in logic below is untouched.
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
                bottom:
                    MediaQuery.viewInsetsOf(context).bottom),
            child: CustomScrollView(
              controller: widget.scroll,
              slivers: [
                SliverToBoxAdapter(
                  child: Center(
                    child: Container(
                      margin:
                          const EdgeInsets.only(top: 8),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withValues(alpha: 0.5),
                        borderRadius:
                            BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                  // Signed-out ⇄ signed-in crossfade (180 ms,
                  // opacity/slide only).
                  child: AnimatedSwitcher(
                    duration: d,
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeOut,
                    transitionBuilder:
                        (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.06),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    child: loggedIn
                        ? _SignedIn(
                            key:
                                const ValueKey('in'),
                            state: state,
                            onLogout: () =>
                                _logout(state))
                        : _SignInForm(
                            key: const ValueKey(
                                'out'),
                            web: _web,
                            capturing: _capturing,
                            motionOn: state.motionOn,
                            loginFailed:
                                _loginFailed,
                            onCapture: () =>
                                _capture(state),
                          ),
                  ),
                ),
              ),
              ],
            ),
          ),
        );
      },
    );
  }

  void unawaited(Future<void> f) {}
}

/// Signed-out form: copy + WebView + Done/Cancel. Business logic lives
/// in [_SessionSheetState]; this widget only lays out (same strings,
/// same callbacks).
class _SignInForm extends StatelessWidget {
  final WebViewController? web;
  final bool capturing;
  final bool loginFailed;
  final bool motionOn;
  final VoidCallback onCapture;
  const _SignInForm({
    super.key,
    required this.web,
    required this.capturing,
    required this.loginFailed,
    required this.onCapture,
    this.motionOn = true,
  });

  @override
  Widget build(BuildContext context) {
    final webCtl = web;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Sign in with your Google account',
            style:
                Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('Your session stays on this device',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        // Pre-sized WebView slot (420dp): the delayed spinner holds
        // the space, and web → spinner crossfades (no pop, no jump).
        SizedBox(
          height: 420,
          child: AnimatedSwitcher(
            duration: Duration(
                milliseconds: motionMs(motionOn, 180)),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeOut,
            child: webCtl == null
                ? Center(
                    key: const ValueKey('web-loading'),
                    child: _DelayedSpinner(
                        size: 20, motionOn: motionOn))
                : ClipRRect(
                    key: const ValueKey('web-ready'),
                    borderRadius: BorderRadius.circular(12),
                    child: WebViewWidget(
                        controller: webCtl),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        // Error hint fades + slides in (no layout pop on failure).
        AnimatedSwitcher(
          duration:
              Duration(milliseconds: motionMs(motionOn, 180)),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeOut,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SizeTransition(
              sizeFactor: anim,
              alignment: Alignment.topCenter,
              child: child,
            ),
          ),
          child: loginFailed
              ? Padding(
                  key: const ValueKey('login-error'),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'No session detected — finish signing in above, then tap Done.',
                    style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .error),
                  ),
                )
              : const SizedBox.shrink(
                  key: ValueKey('login-ok')),
        ),
        // Done button label swaps via crossfade (motion-gated 180 ms).
        AnimatedSwitcher(
          duration: Duration(
              milliseconds: motionMs(motionOn, 180)),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeOut,
          child: FilledButton(
            key: ValueKey(capturing ? 'saving' : 'done'),
            style: spotifyPlayStyle(),
            onPressed:
                capturing ? null : () => onCapture(),
            child:
                Text(capturing ? 'Saving...' : 'Done'),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Signed-in state: status + logout (same callbacks as before).
class _SignedIn extends StatelessWidget {
  final AppState state;
  final VoidCallback onLogout;
  const _SignedIn(
      {super.key, required this.state, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('You are signed in on this device',
            style:
                Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => onLogout(),
          child: const Text('Logout'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Spinner that reserves its slot from frame one (no size jump) and
/// fades in only after 300 ms (no flicker on fast loads). Motion-off
/// shows it immediately (1 ms via [motionMs]).
class _DelayedSpinner extends StatefulWidget {
  final double size;
  final bool motionOn;
  const _DelayedSpinner({this.size = 20, this.motionOn = true});

  @override
  State<_DelayedSpinner> createState() => _DelayedSpinnerState();
}

class _DelayedSpinnerState extends State<_DelayedSpinner> {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    if (!widget.motionOn) {
      _show = true;
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void didUpdateWidget(covariant _DelayedSpinner old) {
    super.didUpdateWidget(old);
    if (widget.motionOn != old.motionOn && !widget.motionOn) {
      setState(() => _show = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedOpacity(
        opacity: _show ? 1.0 : 0.0,
        duration: Duration(
            milliseconds: motionMs(widget.motionOn, 180)),
        curve: Curves.easeOut,
        child: _show ? const IosSpinner() : null,
      ),
    );
  }
}
