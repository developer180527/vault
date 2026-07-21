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
/// destination picker that appears BEFORE the transfer wherever the platform
/// allows it:
///
/// - **Desktop** (macOS/Windows/Linux): the native Save panel names the file
///   and picks the path first; the bytes then stream straight there.
/// - **iOS**: the native folder picker chooses a destination first, then the
///   file streams directly into it — no waiting on a full download before the
///   picker shows. If iOS blocks writing into the picked (security-scoped)
///   folder, it falls back to the Save-to-Files export below.
/// - **Android**: the Storage Access Framework can't be streamed to via
///   dart:io, so the file streams to a temp copy and the native document
///   picker (which needs the finished bytes) places it.
///
/// The transfer is always STREAMED (response piped to disk); only the Android /
/// fallback path materializes bytes for the OS export API. Bearer auth,
/// refreshed up front if the token is stale.
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

  if (isIOS) {
    await _downloadIntoPickedFolder(session, node, messenger);
  } else if (isAndroidOrIOS) {
    await _downloadViaExport(session, node, messenger); // Android (SAF)
  } else {
    await _downloadDesktop(session, node, messenger);
  }
}

/// Desktop: name + locate the file first (native Save panel), then stream to
/// it — a cancelled dialog costs no bytes.
Future<void> _downloadDesktop(Session session, FileNode node,
    ScaffoldMessengerState messenger) async {
  final path = await FilePicker.saveFile(
    dialogTitle: 'Save “${node.name}”',
    fileName: node.name,
  );
  if (path == null) return; // cancelled
  _downloading(messenger, node);
  try {
    await _downloadTo(session, node, path);
    _saved(messenger, node);
  } catch (e) {
    _failed(messenger, node, e);
  }
}

/// iOS: pick the destination FOLDER first, then stream the file straight into
/// it. If the scoped-folder write is blocked, fall back to the export sheet so
/// the download still lands somewhere.
Future<void> _downloadIntoPickedFolder(Session session, FileNode node,
    ScaffoldMessengerState messenger) async {
  final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose where to save “${node.name}”');
  if (dir == null) return; // cancelled
  _downloading(messenger, node);
  try {
    await _downloadTo(session, node, '$dir/${_safeName(node.name)}');
    _saved(messenger, node);
  } on FileSystemException catch (e) {
    // The picked folder wasn't writable (iOS security scope) — recover via the
    // Save-to-Files export rather than losing the download.
    _log.info('scoped-folder write blocked, exporting instead',
        fields: {'err': '$e'});
    await _downloadViaExport(session, node, messenger);
  } catch (e) {
    _failed(messenger, node, e);
  }
}

/// Android / fallback: stream to a temp copy, then hand the bytes to the native
/// document picker (Files / SAF). The temp copy is always cleaned up.
Future<void> _downloadViaExport(Session session, FileNode node,
    ScaffoldMessengerState messenger) async {
  final tmpDir = await getTemporaryDirectory();
  final tmpPath = '${tmpDir.path}/${_safeName(node.name)}';
  _downloading(messenger, node);
  try {
    await _downloadTo(session, node, tmpPath);
    final bytes = await File(tmpPath).readAsBytes(); // Uint8List
    final saved = await FilePicker.saveFile(
      dialogTitle: 'Save “${node.name}”',
      fileName: node.name,
      bytes: bytes,
    );
    if (saved != null) _saved(messenger, node);
  } catch (e) {
    _failed(messenger, node, e);
  } finally {
    try {
      final f = File(tmpPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// Streams GET /v1/files/{id}/content to [destPath]. Throws on any failure
/// (HTTP error or local write), deleting any torn partial first so a failed
/// download never leaves a half-written file behind.
Future<void> _downloadTo(
    Session session, FileNode node, String destPath) async {
  final client = http.Client();
  try {
    final req = http.Request('GET', session.api('/v1/files/${node.id}/content'))
      ..headers['Authorization'] = 'Bearer ${session.accessToken}';
    final resp = await client.send(req);
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    final sink = File(destPath).openWrite();
    try {
      await resp.stream.pipe(sink); // streamed → disk, never whole-file in RAM
    } finally {
      await sink.close();
    }
    _log.info('downloaded', fields: {'name': node.name, 'to': destPath});
  } catch (e) {
    try {
      final f = File(destPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    rethrow;
  } finally {
    client.close();
  }
}

void _downloading(ScaffoldMessengerState m, FileNode node) =>
    m.showSnackBar(SnackBar(
        content: Text('Downloading “${node.name}”…'),
        duration: const Duration(seconds: 2)));

void _saved(ScaffoldMessengerState m, FileNode node) =>
    m.showSnackBar(SnackBar(content: Text('Saved “${node.name}”.')));

void _failed(ScaffoldMessengerState m, FileNode node, Object e) {
  _log.warn('download failed', fields: {'name': node.name, 'err': '$e'});
  m.showSnackBar(SnackBar(content: Text('Download failed: $e')));
}

/// Strip path separators so a crafted server name can't escape the target dir.
String _safeName(String name) =>
    name.replaceAll(RegExp(r'[/\\]'), '_').trim().isEmpty
        ? 'download'
        : name.replaceAll(RegExp(r'[/\\]'), '_');
