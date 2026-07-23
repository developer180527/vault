import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/habits/habits.dart';

/// Runs the connect-to-server flow from the You page:
///
///   1. Ask for the server host.
///   2. Passkey login via the system browser (OIDC + PKCE against Pocket ID).
///   3. Device registration — or, when the server has no account for this
///      identity, offer first-admin setup with the one-time code from the
///      server logs.
Future<void> startConnectFlow(BuildContext context, WidgetRef ref) async {
  // Remembered servers first: pick a known one in a tap, or add a new one
  // (prefilled with the most recent, so a re-login isn't a retype).
  final known = ref.read(knownServersProvider);
  String? host;
  if (known.isNotEmpty) {
    final picked = await _pickServer(context, ref, known);
    if (picked == null || !context.mounted) return; // cancelled
    host = picked.isEmpty
        ? await _promptText(
            context,
            title: 'Connect to a new server',
            hint: 'vault-server.taildxxxx.ts.net',
            help: 'Your server\'s Tailscale name. This device must be on the '
                'tailnet.',
            confirm: 'Continue',
            initial: known.first.host,
          )
        : picked;
  } else {
    host = await _promptText(
      context,
      title: 'Connect to your Vault server',
      hint: 'vault-server.taildxxxx.ts.net',
      help:
          'Your server\'s Tailscale name. This device must be on the tailnet.',
      confirm: 'Continue',
    );
  }
  if (host == null || host.isEmpty || !context.mounted) return;

  final session = ref.read(sessionProvider.notifier);
  try {
    await session.login(host);
    // Remember it (canonical host from the session) for one-tap reconnect.
    final saved = ref.read(sessionProvider).asData?.value?.serverHost ?? host;
    await ref.read(habitsProvider.notifier).recordServer(saved);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connected — welcome to your Vault')));
    }
  } on NoVaultAccount catch (na) {
    if (!context.mounted) return;
    // Identity verified, but no Vault account. First admin? Ask for the
    // one-time setup code (vaultd logs it while the users table is empty).
    final code = await _promptText(
      context,
      title: 'No account yet',
      hint: 'one-time setup code',
      help: 'If you are the server admin doing first-time setup, enter the '
          'setup code from the vaultd logs:\n'
          'docker compose logs vaultd | grep "setup code"\n\n'
          'Otherwise, ask your admin to invite your email.',
      confirm: 'Set up as admin',
    );
    if (code == null || code.isEmpty || !context.mounted) return;
    try {
      await session.setupAdmin(host, code.trim(), na.idToken);
      final saved = ref.read(sessionProvider).asData?.value?.serverHost ?? host;
      await ref.read(habitsProvider.notifier).recordServer(saved);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Vault initialized — you are the admin')));
      }
    } catch (e) {
      if (context.mounted) _showError(context, e);
    }
  } catch (e) {
    if (context.mounted) _showError(context, e);
  }
}

/// Confirms and drops the local session.
Future<void> startDisconnectFlow(BuildContext context, WidgetRef ref) async {
  final sure = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Disconnect this device?'),
      content: const Text(
          'Local tokens are removed and the app returns to standalone mode. '
          'Your data on the server is untouched.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Disconnect')),
      ],
    ),
  );
  if (sure == true) {
    await ref.read(sessionProvider.notifier).logout();
  }
}

Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String hint,
  required String help,
  required String confirm,
  String? initial,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            autocorrect: false,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
          ),
          const SizedBox(height: 12),
          Text(help, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: Text(confirm),
        ),
      ],
    ),
  );
}

/// Picks a remembered server. Returns the chosen host, `''` to add a NEW one,
/// or null if cancelled. Long-press a row to forget it.
Future<String?> _pickServer(
    BuildContext context, WidgetRef ref, List<ServerMemory> known) {
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Connect to your Vault server'),
      children: [
        for (final s in known)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(s.host),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: Text(s.host, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: const Text('Tap to reconnect'),
              trailing: IconButton(
                tooltip: 'Forget',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  ref.read(habitsProvider.notifier).forgetServer(s.host);
                  Navigator.of(context).pop(); // reopen picks up the change
                },
              ),
            ),
          ),
        const Divider(),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(''),
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.add),
            title: Text('Connect to a new server'),
          ),
        ),
      ],
    ),
  );
}

void _showError(BuildContext context, Object error) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Connection failed'),
      content: Text('$error'),
      actions: [
        FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK')),
      ],
    ),
  );
}
