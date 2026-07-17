import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logging/vault_log.dart';
import 'media_providers.dart';

final _log = VaultLog.tag('mediaTrash');

/// Vault's media trash — Apple Photos-style "Recently Deleted", implemented
/// app-side because iOS does not expose the system Recently Deleted album to
/// third-party apps at all.
///
/// Deleting in Vault is therefore a two-stage affair:
/// 1. **Trash** (instant, silent): the item is hidden from Vault's grid and
///    recorded here with its deletion time. The asset itself is untouched in
///    the OS library.
/// 2. **Purge** (after [retention], or "Delete now" in the trash sheet): the
///    real OS delete runs — the platform shows its own confirmation and the
///    file is gone (to the OS's own trash where one exists).
class TrashEntry {
  const TrashEntry({required this.id, required this.deletedAt});

  final String id;
  final DateTime deletedAt;

  Duration get age => DateTime.now().difference(deletedAt);

  Map<String, Object?> toJson() => {
    'id': id,
    'deleted_at': deletedAt.millisecondsSinceEpoch,
  };

  factory TrashEntry.fromJson(Map<String, Object?> j) => TrashEntry(
    id: j['id'] as String,
    deletedAt: DateTime.fromMillisecondsSinceEpoch(
      (j['deleted_at'] as num).toInt(),
    ),
  );
}

/// One trashed item resolved for display (the asset may have vanished from
/// the OS library out from under us — those entries clean themselves up).
class TrashedMedia {
  const TrashedMedia({required this.entry, required this.asset});

  final TrashEntry entry;
  final AssetEntity asset;

  /// Days until the automatic permanent delete.
  int get daysLeft =>
      (MediaTrashNotifier.retention - entry.age).inDays.clamp(0, 9999);
}

class MediaTrashNotifier extends AsyncNotifier<List<TrashEntry>> {
  static const retention = Duration(days: 30);
  static const _prefsKey = 'media.trash.v1';

  @override
  Future<List<TrashEntry>> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    var entries = <TrashEntry>[
      if (raw != null)
        for (final e in jsonDecode(raw) as List)
          TrashEntry.fromJson(e as Map<String, Object?>),
    ];
    entries = await _purgeExpired(entries);
    return entries;
  }

  Future<void> _save(List<TrashEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode([for (final e in entries) e.toJson()]),
    );
  }

  /// Stage 1: hide the item and start its 30-day clock. Instant — no OS
  /// dialog, fully undoable from the trash sheet.
  Future<void> trash(String id) async {
    final current = [...state.asData?.value ?? <TrashEntry>[]];
    if (current.any((e) => e.id == id)) return;
    current.insert(0, TrashEntry(id: id, deletedAt: DateTime.now()));
    await _save(current);
    state = AsyncData(current);
    _log.info('trashed', fields: {'id': id});
  }

  /// Bring an item back to the library (just forget the trash record).
  Future<void> restore(String id) async {
    final current = [...state.asData?.value ?? <TrashEntry>[]]
      ..removeWhere((e) => e.id == id);
    await _save(current);
    state = AsyncData(current);
    _log.info('restored', fields: {'id': id});
  }

  /// Stage 2: the REAL delete. The OS shows its own confirmation; entries are
  /// only dropped for ids the platform confirms deleted (cancel keeps them).
  Future<void> deleteForever(List<String> ids) async {
    if (ids.isEmpty) return;
    List<String> deleted;
    try {
      deleted = await PhotoManager.editor.deleteWithIds(ids);
    } catch (e) {
      _log.warn('permanent delete failed', fields: {'error': '$e'});
      return;
    }
    final gone = deleted.toSet();
    final current = [...state.asData?.value ?? <TrashEntry>[]]
      ..removeWhere((e) => gone.contains(e.id));
    await _save(current);
    state = AsyncData(current);
    // The library view must forget the purged assets too.
    ref.invalidate(mediaItemsProvider);
    _log.info(
      'purged',
      fields: {'requested': ids.length, 'deleted': gone.length},
    );
  }

  /// Entries past [retention] get the real OS delete on load. If the user
  /// cancels the system dialog they simply stay until next time — the OS
  /// keeps the final say over destroying media.
  Future<List<TrashEntry>> _purgeExpired(List<TrashEntry> entries) async {
    final expired = [
      for (final e in entries)
        if (e.age > retention) e.id,
    ];
    if (expired.isEmpty) return entries;
    Set<String> gone;
    try {
      gone = (await PhotoManager.editor.deleteWithIds(expired)).toSet();
    } catch (e) {
      _log.warn('expiry purge failed', fields: {'error': '$e'});
      return entries;
    }
    final kept = [
      for (final e in entries)
        if (!gone.contains(e.id)) e,
    ];
    if (kept.length != entries.length) await _save(kept);
    return kept;
  }
}

final mediaTrashProvider =
    AsyncNotifierProvider<MediaTrashNotifier, List<TrashEntry>>(
      MediaTrashNotifier.new,
    );

/// The trashed ids as a set — what the library grid filters against.
final trashedIdsProvider = Provider<Set<String>>(
  (ref) => {
    for (final e
        in ref.watch(mediaTrashProvider).asData?.value ?? const <TrashEntry>[])
      e.id,
  },
);

/// Trash entries resolved to displayable assets, newest deletion first.
/// Records whose assets no longer exist in the OS library are pruned quietly.
final trashedMediaProvider = FutureProvider<List<TrashedMedia>>((ref) async {
  final entries =
      ref.watch(mediaTrashProvider).asData?.value ?? const <TrashEntry>[];
  final out = <TrashedMedia>[];
  final vanished = <String>[];
  for (final e in entries) {
    final asset = await AssetEntity.fromId(e.id);
    if (asset == null) {
      vanished.add(e.id);
    } else {
      out.add(TrashedMedia(entry: e, asset: asset));
    }
  }
  for (final id in vanished) {
    await ref.read(mediaTrashProvider.notifier).restore(id); // drop record
  }
  return out;
});
