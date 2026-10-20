// Shared user-feedback toast (U8): one style, one placement, one at a
// time. Informational only — actions belong in Snackbars with Undo
// (queue/playlist/library flows keep theirs); toasts never carry
// action buttons. For loading >300 ms use DelayedSpinner in place,
// never a "Loading…" toast.
//
// Call only with a context inside the tab body (under
// BottomChromeScope); never from a route builder or after navigation
// (guard call sites with `context.mounted`). The margin sits above the
// measured bottom chrome (MiniPlayer + tab bar) so the toast never
// hides behind it; without a scope in the tree it falls back to the
// legacy clearance — still above the chrome, never behind it.
import 'package:flutter/material.dart';

import '../app.dart';

/// Best-effort crash-log breadcrumb for a user-path failure. Never
/// throws — the toast still surfaces the failure when the logger is
/// unreachable.
Future<void> logUserFailure(
    BuildContext context, String label, Object e, StackTrace st) async {
  try {
    await AppScope.of(context).crash.log(label, e, st);
  } catch (_) {
    // silent: logger unreachable from this context, toast still surfaces it
  }
}

/// Shows [message] (short copy only, e.g. 'Signed out',
/// "Couldn't share — try again"), dismissing any toast already
/// visible first so rapid failures never stack. Auto-dismisses after
/// 3 s. Never throws.
Future<void> showCrescaToast(
    BuildContext context, String message) async {
  // Tab-body context only; route/disposed contexts have no messenger
  // worth toasting on.
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        // Above MiniPlayer + tab bar via the U1 live clearance.
        margin: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: BottomChromeScope.clearanceOf(context) + 8,
        ),
      ),
    );
}
