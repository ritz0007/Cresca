// Shared list-state widgets (U6 home for the U3 sliver/EndFooter pattern;
// U3 adopts for slivers, U7 copies verbatim). One definition — screens
// import, never duplicate.
//
// Copy deck (phases/ui-shared-appendix.md §B) is normative:
// - loading: spinner only, zero copy (DelayedSpinner 300 ms)
// - true empty: "No results for '<q>'" / "Nothing here yet" + one action
// - transport error: "Couldn't load '<scope>' — check connection" + Retry
// - inline (stale rows visible): "Couldn't refresh — showing saved rows"
// - terminal footer: "You're all caught up"

import 'package:flutter/material.dart';

import '../app.dart';
import '../design.dart';
import 'track_row.dart';

/// Loading: DelayedSpinner (300 ms, no flicker) + skeleton rows (no jump).
/// Zero copy. Never throws.
class LoadingState extends StatelessWidget {
  final int itemCount;
  const LoadingState({super.key, this.itemCount = 8});

  @override
  Widget build(BuildContext context) {
    bool motion = true;
    try {
      motion = AppScope.of(context).motionOn;
    } catch (_) {}
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Center(child: DelayedSpinner(motionOn: motion)),
        ),
        for (var i = 0; i < itemCount; i++) const TrackSkeleton(),
      ],
    );
  }
}

/// True empty: icon + title (+ optional subtitle) + one action.
/// Gentle fade/scale entrance, transform/opacity only. Never throws.
class EmptyState extends StatefulWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends State<EmptyState> {
  bool _in = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _in = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    bool on = true;
    int ms = 220;
    try {
      final s = AppScope.of(context);
      on = s.motionOn;
      ms = s.motionMs(220);
    } catch (_) {}
    final scheme = Theme.of(context).colorScheme;
    final body = Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.icon, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(widget.title, textAlign: TextAlign.center),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                widget.subtitle!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
            if (widget.actionLabel != null && widget.onAction != null) ...[
              const SizedBox(height: 12),
              TextButton(
                style: TextButton.styleFrom(
                    minimumSize: const Size(64, 48)),
                onPressed: widget.onAction,
                child: Text(widget.actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
    if (!on) return body;
    return AnimatedOpacity(
      duration: Duration(milliseconds: ms),
      opacity: _in ? 1.0 : 0.0,
      child: AnimatedScale(
        duration: Duration(milliseconds: ms),
        scale: _in ? 1.0 : 0.97,
        child: body,
      ),
    );
  }
}

/// Transport error: icon + deck-copy message + Retry wired to the same
/// loader. Never throws.
class ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final IconData icon;
  const ErrorRetry({
    super.key,
    required this.message,
    required this.onRetry,
    this.icon = Icons.cloud_off_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// Inline banner for failed refresh over stale-but-visible rows.
/// One line + Retry. Never throws.
class InlineRetryBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const InlineRetryBanner({
    super.key,
    this.message = "Couldn't refresh — showing saved rows",
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 20, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          TextButton(
            style:
                TextButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

/// Feed footer: spinner while the feed may still grow
/// (`loading || hasMore`), terminal copy once done.
///
/// Callers gate any `loadMore` on `hasMore && !loading` — the spinner
/// never fires paging unconditionally at max extent. Never throws.
class EndFooter extends StatelessWidget {
  final bool hasMore;
  final bool loading;
  const EndFooter({super.key, this.hasMore = false, this.loading = false});

  @override
  Widget build(BuildContext context) {
    bool motion = true;
    try {
      motion = AppScope.of(context).motionOn;
    } catch (_) {}
    if (loading || hasMore) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(child: DelayedSpinner(motionOn: motion)),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: Text(
          "You're all caught up",
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}
