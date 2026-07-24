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
  String? host;
  // Re-read on each turn: forgetting a server mutates the list and loops back
  // to re-show the freshly-trimmed picker (rather than aborting the flow).
  var known = ref.read(knownServersProvider);
  while (known.isNotEmpty) {
    if (!context.mounted) return; // back-edge after a prior-iteration await
    final picked = await _pickServer(context, known);
    if (picked == null || !context.mounted) return; // cancelled
    if (picked is _ForgetServer) {
      await ref.read(habitsProvider.notifier).forgetServer(picked.host);
      if (!context.mounted) return;
      known = ref.read(knownServersProvider);
      continue; // re-show the picker (or fall through to the prompt if empty)
    }
    host = picked.host.isEmpty
        ? await _promptText(
            context,
            title: 'Connect to a new server',
            hint: 'vault-server.taildxxxx.ts.net',
            help: 'Your server\'s Tailscale name. This device must be on the '
                'tailnet.',
            confirm: 'Continue',
            initial: known.first.host,
          )
        : picked.host;
    break;
  }
  if (known.isEmpty) {
    if (!context.mounted) return; // loop may have awaited a forget
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

/// Outcome of the server picker. [_ConnectServer] with a host reconnects; with
/// an empty host it means "add a new server"; [_ForgetServer] means the caller
/// should forget that host and re-show the picker. `null` from the dialog is a
/// plain cancel.
sealed class _PickResult {
  const _PickResult(this.host);
  final String host;
}

class _ConnectServer extends _PickResult {
  const _ConnectServer(super.host);
}

class _ForgetServer extends _PickResult {
  const _ForgetServer(super.host);
}

/// Picks a remembered server. Returns a [_ConnectServer] (host, or `''` to add
/// a new one), a [_ForgetServer] request, or null if cancelled. Forgetting pops
/// with the request so the caller can mutate the store and reopen — we don't
/// mutate-then-close here (that read as a cancel and aborted the whole flow).
Future<_PickResult?> _pickServer(
    BuildContext context, List<ServerMemory> known) {
  return showDialog<_PickResult>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Connect to your Vault server'),
      children: [
        for (final s in known)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_ConnectServer(s.host)),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: Text(s.host, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: const Text('Tap to reconnect'),
              trailing: IconButton(
                tooltip: 'Forget',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () =>
                    Navigator.of(context).pop(_ForgetServer(s.host)),
              ),
            ),
          ),
        const Divider(),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(const _ConnectServer('')),
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
