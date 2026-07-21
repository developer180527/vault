import 'dart:io';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/auth/session.dart';
import '../../../core/logging/vault_log.dart';
import '../../../core/models/file_node.dart';
import '../../../core/platform/platform_info.dart';

final _log = VaultLog.tag('files.download');

/// Download a server file to a user-chosen local location.
///
/// - **Desktop** (macOS/Windows/Linux): a native Save dialog picks the exact
///   path; the bytes stream straight there.
/// - **Mobile** (iOS/Android): file_selector has no save dialog, so the bytes
///   stream to a temp file and the native share/save sheet lets the user
///   export it ("Save to Files" on iOS, a location picker on Android).
///
/// The transfer is STREAMED (response body piped to disk) so a multi-GB file
/// never loads into memory. Bearer auth, refreshed if the token is stale.
Future<void> downloadFileToLocal(
    BuildContext context, WidgetRef ref, FileNode node) async {
  final messenger = ScaffoldMessenger.of(context);

  var session = ref.read(sessionProvider).asData?.value;
  if (session == null) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Not connected to a server.')));
    return;
  }
  // A large download can outlive a 15-min token; refresh up front.
  if (session.accessExpires.isBefore(DateTime.now())) {
    session = await ref.read(sessionProvider.notifier).refresh();
    if (session == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Session expired — reconnect.')));
      return;
    }
  }

  // Pick the destination BEFORE streaming so a cancel costs nothing.
  final String destPath;
  final bool exportAfter;
  if (isAndroidOrIOS) {
    final dir = await getTemporaryDirectory();
    destPath = '${dir.path}/${_safeName(node.name)}';
    exportAfter = true;
  } else {
    final loc = await fs.getSaveLocation(suggestedName: node.name);
    if (loc == null) return; // user cancelled the save dialog
    destPath = loc.path;
    exportAfter = false;
  }

  messenger.showSnackBar(SnackBar(
      content: Text('Downloading “${node.name}”…'),
      duration: const Duration(seconds: 2)));

  final client = http.Client();
  try {
    final req = http.Request('GET', session.api('/v1/files/${node.id}/content'))
      ..headers['Authorization'] = 'Bearer ${session.accessToken}';
    final resp = await client.send(req);
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    final sink = File(destPath).openWrite();
    await resp.stream.pipe(sink); // streamed → disk, never whole-file in RAM
    await sink.flush();
    await sink.close();
    _log.info('downloaded', fields: {'name': node.name, 'to': destPath});

    if (!context.mounted) return;
    if (exportAfter) {
      // Hand the temp file to the OS sheet so the user places it themselves.
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(destPath, name: node.name)],
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } else {
      messenger.showSnackBar(
          SnackBar(content: Text('Saved “${node.name}”.')));
    }
  } catch (e) {
    _log.warn('download failed', fields: {'name': node.name, 'err': '$e'});
    try {
      final f = File(destPath);
      if (await f.exists()) await f.delete(); // don't leave a torn partial
    } catch (_) {}
    if (context.mounted) {
      messenger.showSnackBar(
          SnackBar(content: Text('Download failed: $e')));
    }
  } finally {
    client.close();
  }
}

/// Strip path separators so a crafted server name can't escape the temp dir.
String _safeName(String name) =>
    name.replaceAll(RegExp(r'[/\\]'), '_').trim().isEmpty
        ? 'download'
        : name.replaceAll(RegExp(r'[/\\]'), '_');
