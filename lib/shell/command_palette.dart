import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/actions/vault_action.dart';
import '../core/capability/manifest_providers.dart';
import '../core/platform/design/adaptive_icons.dart';

/// Opens the Cmd-K command palette. This is the keyboard-first home for every
/// command — the modern replacement for a menu bar's discoverability. It lists
/// navigation ("Go to …") plus every permitted service's actions, searchable.
Future<void> showCommandPalette(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (_) => const _CommandPalette(),
  );
}

class _CommandPalette extends ConsumerStatefulWidget {
  const _CommandPalette();

  @override
  ConsumerState<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<_CommandPalette> {
  String _query = '';

  /// All commands: navigation to each permitted service, then each service's
  /// own actions (only those currently enabled).
  List<VaultAction> _allCommands() {
    final services = ref.read(permittedServicesProvider);
    return [
      for (final s in services)
        VaultAction(
          id: 'goto-${s.id}',
          label: 'Go to ${s.label}',
          icon: s.icon,
          onInvoke: (context, ref) => context.go('/${s.id}'),
        ),
      for (final s in services)
        for (final a in s.actions)
          if (a.enabled(ref)) a,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final commands = [
      for (final c in _allCommands())
        if (q.isEmpty || c.label.toLowerCase().contains(q)) c,
    ];

    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 96, left: 24, right: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Type a command…',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  if (commands.isNotEmpty) _invoke(commands.first);
                },
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: commands.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No matching commands'))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: commands.length,
                      itemBuilder: (context, i) {
                        final c = commands[i];
                        return ListTile(
                          leading: AdaptiveIcon(c.icon, size: 20),
                          title: Text(c.label),
                          onTap: () => _invoke(c),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _invoke(VaultAction action) {
    Navigator.of(context).pop();
    action.onInvoke(context, ref);
  }
}
