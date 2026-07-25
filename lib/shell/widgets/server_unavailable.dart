import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/capability/manifest_providers.dart';

/// The standard "this page needs the server, which we can't reach" state.
/// Used by server-backed pages (Music, Movies, server Files) in place of a
/// raw error string, so offline degradation looks intentional, not broken.
class ServerUnavailable extends ConsumerWidget {
  const ServerUnavailable({
    super.key,
    this.message = "Can't reach your Vault",
    this.detail,
    this.onRetry,
  });

  /// One-line headline.
  final String message;

  /// Optional second line (e.g. the underlying error, trimmed).
  final String? detail;

  /// Retry callback; when null, a generic "reconnect" re-checks the server.
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 16),
            Text(message, style: Theme.of(context).textTheme.titleMedium),
            if (detail != null) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ],
            const SizedBox(height: 20),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
              onPressed: () async {
                if (onRetry != null) {
                  await onRetry!();
                } else {
                  await ref.read(manifestProvider.notifier).reload();
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// A slim, tappable banner shown at the top of the shell whenever the server
/// is unreachable — so the offline state is visible from every tab, and one
/// tap retries. Renders nothing while reachable.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reachable = ref.watch(serverReachableProvider);
    if (reachable) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: InkWell(
        onTap: () => ref.read(manifestProvider.notifier).reload(),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.cloud_off_outlined,
                    size: 16, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Offline — can't reach your Vault. Showing what's on this device.",
                    style: TextStyle(
                        color: scheme.onErrorContainer, fontSize: 12.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text('Retry',
                    style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
