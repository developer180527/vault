import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/file_browser_controller.dart';

/// Left side of the Files content toolbar: Finder-style back/forward arrows
/// driven by the browse history, with the current directory name beside them.
class FilesToolbarLeading extends ConsumerWidget {
  const FilesToolbarLeading({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav = ref.watch(fileBrowserControllerProvider);
    final controller = ref.read(fileBrowserControllerProvider.notifier);
    final name = ref.watch(currentDirectoryNameProvider).asData?.value ??
        'My Files';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Arrow(
          icon: Icons.arrow_back,
          enabled: nav.canBack,
          onPressed: controller.goBack,
        ),
        const SizedBox(width: 4),
        _Arrow(
          icon: Icons.arrow_forward,
          enabled: nav.canForward,
          onPressed: controller.goForward,
        ),
        const SizedBox(width: 12),
        Text(name,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow(
      {required this.icon, required this.enabled, required this.onPressed});

  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon),
    );
  }
}
