import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../core/auth/session.dart';
import '../../../core/logging/vault_log.dart';
import '../../../core/models/file_node.dart';
import '../../../core/platform/platform_info.dart';

final _log = VaultLog.tag('files.download');

/// Download a server file to a user-chosen local location, with a NATIVE
/// destination picker on every platform:
///
/// - **Desktop** (macOS/Windows/Linux): the native Save panel picks the exact
///   path, then the bytes stream straight there — no whole-file buffering.
/// - **Mobile** (iOS/Android): the native document picker (Files on iOS, the
///   SAF folder browser on Android) chooses where it lands. The picker needs
///   the bytes, so the transfer streams to a temp file first, then hands them
///   to the picker and the temp copy is removed.
///
/// The download itself is always STREAMED (response piped to disk); only the
/// mobile picker step materializes bytes, which is unavoidable for SAF/iOS
/// export. Bearer auth, refreshed up front if the token is stale.
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

  if (isAndroidOrIOS) {
    await _downloadMobile(session, node, messenger);
  } else {
    await _downloadDesktop(session, node, messenger);
  }
}

/// Desktop: choose the path first (native Save panel), then stream to it — so
/// a cancelled dialog costs no bytes.
Future<void> _downloadDesktop(Session session, FileNode node,
    ScaffoldMessengerState messenger) async {
  final path = await FilePicker.saveFile(
    dialogTitle: 'Save “${node.name}”',
    fileName: node.name,
  );
  if (path == null) return; // user cancelled

  messenger.showSnackBar(SnackBar(
      content: Text('Downloading “${node.name}”…'),
      duration: const Duration(seconds: 2)));
  final ok = await _stream(session, node, path, messenger);
  if (ok) {
    messenger.showSnackBar(SnackBar(content: Text('Saved “${node.name}”.')));
  }
}

/// Mobile: stream to a temp file, then let the native document picker place it
/// (Files / SAF). The temp copy is always cleaned up.
Future<void> _downloadMobile(Session session, FileNode node,
    ScaffoldMessengerState messenger) async {
  final tmpDir = await getTemporaryDirectory();
  final tmpPath = '${tmpDir.path}/${_safeName(node.name)}';

  messenger.showSnackBar(SnackBar(
      content: Text('Downloading “${node.name}”…'),
      duration: const Duration(seconds: 2)));
  final ok = await _stream(session, node, tmpPath, messenger);
  if (!ok) return;

  try {
    final bytes = await File(tmpPath).readAsBytes(); // Uint8List
    final saved = await FilePicker.saveFile(
      dialogTitle: 'Save “${node.name}”',
      fileName: node.name,
      bytes: bytes,
    );
    if (saved != null) {
      messenger.showSnackBar(SnackBar(content: Text('Saved “${node.name}”.')));
    }
  } catch (e) {
    _log.warn('save-to failed', fields: {'name': node.name, 'err': '$e'});
    messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
  } finally {
    try {
      final f = File(tmpPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// Streams GET /v1/files/{id}/content to [destPath]. Returns false (and shows a
/// snackbar, deleting any torn partial) on failure.
Future<bool> _stream(Session session, FileNode node, String destPath,
    ScaffoldMessengerState messenger) async {
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
    return true;
  } catch (e) {
    _log.warn('download failed', fields: {'name': node.name, 'err': '$e'});
    try {
      final f = File(destPath);
      if (await f.exists()) await f.delete(); // don't leave a torn partial
    } catch (_) {}
    messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
    return false;
  } finally {
    client.close();
  }
}

/// Strip path separators so a crafted server name can't escape the temp dir.
String _safeName(String name) =>
    name.replaceAll(RegExp(r'[/\\]'), '_').trim().isEmpty
        ? 'download'
        : name.replaceAll(RegExp(r'[/\\]'), '_');
