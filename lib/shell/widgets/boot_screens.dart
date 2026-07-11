import 'package:flutter/material.dart';

/// Shown while the capability manifest is being fetched from the server. The
/// shell can't render until we know what this device+profile is allowed to see.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 28, height: 28, child: CircularProgressIndicator()),
            SizedBox(height: 16),
            Text('Connecting to your Vault…'),
          ],
        ),
      ),
    );
  }
}

/// Fail-closed state: the manifest couldn't be fetched, so we grant nothing and
/// offer a retry rather than guessing at access.
class ManifestErrorScreen extends StatelessWidget {
  const ManifestErrorScreen(
      {super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text("Couldn't reach your Vault server",
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Vault needs to confirm what this device is allowed to access '
                'before it can continue.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
