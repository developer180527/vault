import 'package:flutter/material.dart';

/// Contained failure panel. Installed as the global `ErrorWidget.builder`, so
/// when a feature's widget subtree throws during build, Flutter replaces *only
/// that subtree* with this card — the shell, sidebar, and every other service
/// keep working. This is the "one feature can't break the whole app" guarantee.
class FeatureErrorView extends StatelessWidget {
  const FeatureErrorView({super.key, required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    // ErrorWidget can be built without Material ancestors in edge cases; guard
    // with a minimal theme so this never itself throws.
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text('This service hit a problem',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                'The rest of Vault is unaffected. Try another tab, or reopen '
                'this one.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
